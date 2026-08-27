import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension NativeAPICatalog {
public struct BuildRequest: Sendable {
    public var identity: NativeAPICatalog.Identity
    public var frontendInvocation: InterfaceArchive.FrontendInvocation
    public var compilerURL: URL
    public var precomputedToolchain: ReleaseCompiler.ToolchainIdentity?

    public init(
        identity: NativeAPICatalog.Identity,
        frontendInvocation: InterfaceArchive.FrontendInvocation,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        precomputedToolchain: ReleaseCompiler.ToolchainIdentity? = nil
    ) {
        self.identity = identity
        self.frontendInvocation = frontendInvocation
        self.compilerURL = compilerURL
        self.precomputedToolchain = precomputedToolchain
    }
}

public struct BuildMetrics: Hashable, Sendable {
    public var cacheSource: BuildCache.Source
    public var importedTypeCount: UInt64
    public var candidateCount: UInt64
    public var entryCount: UInt64
    public var unpublishedCandidateCount: UInt64
    public var symbolGraphCacheHitCount: UInt64
    public var symbolGraphCacheMissCount: UInt64
    public var probeCacheHitCount: UInt64
    public var probeCacheMissCount: UInt64
    public var probeAttemptCount: UInt64
}

public struct BuildOutput: Sendable {
    public let snapshot: NativeAPICatalog.Snapshot
    public let metrics: NativeAPICatalog.BuildMetrics
}

public struct Builder: Sendable {
    private struct PreparedInvocation {
        var execution: InterfaceArchive.FrontendInvocation
        var cacheIdentity: InterfaceArchive.FrontendInvocation
    }

    private struct CacheKey: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var identity: NativeAPICatalog.Identity
        var invocation: InterfaceArchive.FrontendInvocation
        var transformPipelineHash: Core.Digest
    }

    private struct CachedMetrics: Codable, Hashable, Sendable {
        var importedTypeCount: UInt64
        var candidateCount: UInt64
        var entryCount: UInt64
        var unpublishedCandidateCount: UInt64
    }

    private struct CachePayload: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var document: NativeAPICatalog.Document
        var compilerProjection: NativeAPICatalog.CompilerProjection
        var invocation: InterfaceArchive.FrontendInvocation
        var metrics: CachedMetrics
    }

    public var cache: BuildCache.Store
    public var invocationObserver: SwiftFrontend.InvocationObserver?

    public init(
        cache: BuildCache.Store,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.cache = cache
        self.invocationObserver = invocationObserver
    }

    public func build(
        _ request: NativeAPICatalog.BuildRequest
    ) throws -> NativeAPICatalog.BuildOutput {
        try request.frontendInvocation.validate()
        try NativeAPICatalog.Document(
            identity: request.identity,
            entries: []
        ).validate()
        let frontend = SwiftFrontend.Driver(
            compilerURL: request.compilerURL,
            invocationObserver: invocationObserver
        )
        let toolchain = try request.precomputedToolchain
            ?? ReleaseCompiler.Driver().toolchainIdentity(
                compilerURL: request.compilerURL,
                invocationObserver: invocationObserver
            )
        guard toolchain.fingerprint == request.identity.compilerFingerprint,
              request.frontendInvocation.targetTriple
                == request.identity.targetTriple,
              request.frontendInvocation.sdkBuild
                == request.identity.sdkProductBuild
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog identity disagrees with the captured compiler, target, or SDK"
            )
        }
        let sdk = try frontend.sdkIdentity(
            name: request.frontendInvocation.sdkName
        )
        guard sdk.buildVersion == request.identity.sdkProductBuild else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog identity does not match the installed SDK"
            )
        }
        let preparedInvocation = try canonicalInvocation(
            request.frontendInvocation,
            identity: request.identity,
            frontend: frontend
        )
        let cacheKey = try BuildCache.key(
            domain: "HLX.BuildCache.NativeAPICatalog.v1",
            value: CacheKey(
                identity: request.identity,
                invocation: preparedInvocation.cacheIdentity,
                transformPipelineHash: ShellBuild.transformPipelineHash
            )
        )
        var generatedSurfaceMetrics: FrontendReceipt.ManagedNativeSurface
            .Metrics?
        var validatedPayload: CachePayload?
        let value = try cache.value(
            namespace: .nativeAPICatalog,
            key: cacheKey,
            maximumBytes: 384 * 1_024 * 1_024,
            validate: { data in
                validatedPayload = try decode(
                    data,
                    identity: request.identity,
                    invocation: preparedInvocation.cacheIdentity
                )
            }
        ) {
            let surface = try FrontendReceipt.ManagedNativeSurface.catalog(
                moduleName: request.identity.moduleName,
                sourceFileLogicalID: NativeAPICatalog.Projector
                    .sourceFileLogicalID(moduleName: request.identity.moduleName),
                minimumOS: request.identity.minimumDeployment,
                frontend: frontend,
                invocation: preparedInvocation.execution,
                cache: cache,
                compilerFingerprint: toolchain.fingerprint,
                moduleInputHash: cacheKey
            )
            let projection = NativeAPICatalog.CompilerProjection(
                sourceFileLogicalID: NativeAPICatalog.Projector
                    .sourceFileLogicalID(moduleName: request.identity.moduleName),
                importedTypes: surface.importedTypes,
                operations: surface.operations,
                modulesByDeclarationUSR: surface.modulesByDeclarationUSR
            )
            let entries = try NativeAPICatalog.Projector.entries(
                projection: projection,
                identity: request.identity,
                invocation: preparedInvocation.cacheIdentity
            )
            let document = NativeAPICatalog.Document(
                identity: request.identity,
                entries: entries
            )
            generatedSurfaceMetrics = surface.metrics
            let unpublished = surface.metrics.candidateCount
                >= UInt64(entries.count)
                ? surface.metrics.candidateCount - UInt64(entries.count) : 0
            return try Core.CanonicalJSON.encode(CachePayload(
                document: document,
                compilerProjection: projection,
                invocation: preparedInvocation.cacheIdentity,
                metrics: .init(
                    importedTypeCount: UInt64(surface.importedTypes.count),
                    candidateCount: surface.metrics.candidateCount,
                    entryCount: UInt64(entries.count),
                    unpublishedCandidateCount: unpublished
                )
            ))
        }
        guard let payload = validatedPayload else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog cache payload was not validated"
            )
        }
        let snapshot = NativeAPICatalog.Snapshot(
            document: payload.document,
            compilerProjection: payload.compilerProjection
        )
        let surfaceMetrics = generatedSurfaceMetrics
        return .init(
            snapshot: snapshot,
            metrics: .init(
                cacheSource: value.source,
                importedTypeCount: payload.metrics.importedTypeCount,
                candidateCount: payload.metrics.candidateCount,
                entryCount: payload.metrics.entryCount,
                unpublishedCandidateCount:
                    payload.metrics.unpublishedCandidateCount,
                symbolGraphCacheHitCount:
                    surfaceMetrics?.symbolGraphCacheHitCount ?? 0,
                symbolGraphCacheMissCount:
                    surfaceMetrics?.symbolGraphCacheMissCount ?? 0,
                probeCacheHitCount: surfaceMetrics?.probeCacheHitCount ?? 0,
                probeCacheMissCount: surfaceMetrics?.probeCacheMissCount ?? 0,
                probeAttemptCount: surfaceMetrics?.probeAttemptCount ?? 0
            )
        )
    }

    private func canonicalInvocation(
        _ invocation: InterfaceArchive.FrontendInvocation,
        identity: NativeAPICatalog.Identity,
        frontend: SwiftFrontend.Driver
    ) throws -> PreparedInvocation {
        var arguments = try frontend.symbolGraphImportArguments(
            invocation.semanticArguments
        )
        let languageOptions = ["-swift-version", "-language-mode"]
        var observedLanguageMode: String?
        for index in arguments.indices where languageOptions.contains(
            arguments[index]
        ) {
            guard arguments.indices.contains(index + 1) else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog language-mode option is incomplete"
                )
            }
            if let observedLanguageMode,
               observedLanguageMode != arguments[index + 1] {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog invocation has conflicting language modes"
                )
            }
            observedLanguageMode = arguments[index + 1]
        }
        if let observedLanguageMode {
            guard observedLanguageMode == identity.swiftLanguageMode else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog language mode disagrees with its identity"
                )
            }
        } else {
            arguments += ["-swift-version", identity.swiftLanguageMode]
        }
        arguments = ["-parse-as-library"] + arguments
        let execution = InterfaceArchive.FrontendInvocation(
            moduleName: probeModuleName(catalogModule: identity.moduleName),
            targetTriple: invocation.targetTriple,
            sdkName: invocation.sdkName,
            sdkBuild: invocation.sdkBuild,
            optimization: "-Onone",
            semanticArguments: arguments
        )
        var cacheIdentity = execution
        cacheIdentity.semanticArguments = Self.cacheIdentityArguments(arguments)
        return .init(execution: execution, cacheIdentity: cacheIdentity)
    }

    /// Search paths select module bytes, but their absolute project/DerivedData
    /// locations are not API identity. The caller-provided content/search
    /// digests carry that authority; this projection retains only option order
    /// and non-path language/import modes.
    static func cacheIdentityArguments(_ arguments: [String]) -> [String] {
        let pathOptions = Set([
            "-F", "-Fsystem", "-I", "-Isystem", "-L", "-resource-dir",
        ])
        let attachedPathPrefixes = ["-Fsystem", "-Isystem", "-F", "-I", "-L"]
        let clangSplitPathOptions = Set([
            "-F", "-I", "-idirafter", "-iframework", "-imacros",
            "-include", "-internal-iframework", "-internal-isystem",
            "-iquote", "-isysroot", "-isystem", "-ivfsoverlay",
            "-vfsoverlay", "-working-directory", "-fmodule-file",
            "-fmodule-map-file", "-fmodules-cache-path",
        ])
        let clangAttachedPathPrefixes = [
            "-fmodules-cache-path=", "-fmodule-map-file=",
            "-fmodule-file=", "-internal-iframework",
            "-internal-isystem", "-working-directory=", "-idirafter",
            "-iframework", "-isystem", "-iquote", "-F", "-I",
        ]
        var result: [String] = []
        var pathIndex = 0
        var clangPathIndex = 0
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-module-cache-path",
               index + 1 < arguments.count {
                index += 2
                continue
            }
            if pathOptions.contains(argument), index + 1 < arguments.count {
                result += [argument, "<module-path:\(pathIndex)>"]
                pathIndex += 1
                index += 2
                continue
            }
            if argument == "-Xcc", index + 1 < arguments.count {
                let value = arguments[index + 1]
                if clangSplitPathOptions.contains(value),
                   index + 3 < arguments.count,
                   arguments[index + 2] == "-Xcc" {
                    if value != "-fmodules-cache-path" {
                        result += [
                            argument, value, "-Xcc",
                            "<clang-module-path:\(clangPathIndex)>",
                        ]
                        clangPathIndex += 1
                    }
                    index += 4
                    continue
                }
                if value.hasPrefix("-fmodules-cache-path=") {
                    index += 2
                    continue
                }
                if let prefix = clangAttachedPathPrefixes.first(where: {
                    value.hasPrefix($0) && value != $0
                }) {
                    let suffix = String(value.dropFirst(prefix.count))
                    let label: String
                    if prefix == "-fmodule-file=",
                       let separator = suffix.firstIndex(of: "="),
                       !suffix[..<separator].contains("/") {
                        label = String(suffix[...separator])
                    } else {
                        label = ""
                    }
                    result += [
                        argument,
                        "\(prefix)\(label)<clang-module-path:\(clangPathIndex)>",
                    ]
                    clangPathIndex += 1
                    index += 2
                    continue
                }
                result += [argument, value]
                index += 2
                continue
            }
            if let prefix = attachedPathPrefixes.first(where: {
                argument.hasPrefix($0) && argument != $0
            }) {
                result.append("\(prefix)<module-path:\(pathIndex)>")
                pathIndex += 1
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    private func probeModuleName(catalogModule: String) -> String {
        catalogModule == "HelixNativeCatalogProbe"
            ? "HelixNativeCatalogProbeModule"
            : "HelixNativeCatalogProbe"
    }

    private func decode(
        _ data: Data,
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> CachePayload {
        let payload: CachePayload
        do {
            payload = try JSONDecoder().decode(CachePayload.self, from: data)
        } catch {
            throw NativeAPICatalog.Error.invalid(
                "Catalog cache payload cannot be decoded: \(error)"
            )
        }
        guard payload.schemaVersion == 1,
              payload.document.identity == identity,
              payload.invocation == invocation,
              payload.metrics.importedTypeCount
                == UInt64(payload.compilerProjection.importedTypes.count),
              payload.metrics.entryCount
                == UInt64(payload.document.entries.count),
              payload.metrics.candidateCount >= payload.metrics.entryCount,
              payload.metrics.unpublishedCandidateCount
                == payload.metrics.candidateCount - payload.metrics.entryCount,
              try Core.CanonicalJSON.encode(payload) == data
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog cache payload is noncanonical or inconsistent"
            )
        }
        try validate(
            .init(
                document: payload.document,
                compilerProjection: payload.compilerProjection
            ),
            identity: identity,
            invocation: invocation
        )
        return payload
    }

    private func validate(
        _ snapshot: NativeAPICatalog.Snapshot,
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws {
        try snapshot.document.validate()
        _ = try NativeAPICatalog.Codec.encode(snapshot.document)
        try snapshot.compilerProjection.validate(moduleName: identity.moduleName)
        let entries = try NativeAPICatalog.Projector.entries(
            projection: snapshot.compilerProjection,
            identity: identity,
            invocation: invocation
        )
        guard snapshot.document.identity == identity,
              snapshot.document.entries == entries
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog document does not match its compiler projection"
            )
        }
    }
}
}
