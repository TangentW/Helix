import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension NativeAPICatalog {
public struct BuildRequest: Codable, Hashable, Sendable {
    public var identity: NativeAPICatalog.Identity
    public var frontendInvocation: InterfaceArchive.FrontendInvocation
    public var compilerURL: URL
    public var workingDirectoryURL: URL?
    public var precomputedToolchain: ReleaseCompiler.ToolchainIdentity?
    public var precomputedSDK: SwiftFrontend.Driver.SDKIdentity?

    public init(
        identity: NativeAPICatalog.Identity,
        frontendInvocation: InterfaceArchive.FrontendInvocation,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        workingDirectoryURL: URL? = nil,
        precomputedToolchain: ReleaseCompiler.ToolchainIdentity? = nil,
        precomputedSDK: SwiftFrontend.Driver.SDKIdentity? = nil
    ) {
        self.identity = identity
        self.frontendInvocation = frontendInvocation
        self.compilerURL = compilerURL
        self.workingDirectoryURL = workingDirectoryURL
        self.precomputedToolchain = precomputedToolchain
        self.precomputedSDK = precomputedSDK
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
    private struct PreparedBuild {
        var frontend: SwiftFrontend.Driver
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var invocation: PreparedInvocation
        var cacheKey: Core.Digest
    }

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
        let prepared = try prepare(request)
        var generatedSurfaceMetrics: FrontendReceipt.ManagedNativeSurface
            .Metrics?
        var validatedPayload: CachePayload?
        let value = try cache.value(
            namespace: .nativeAPICatalog,
            key: prepared.cacheKey,
            maximumBytes: 384 * 1_024 * 1_024,
            validate: { data in
                validatedPayload = try decode(
                    data,
                    identity: request.identity,
                    invocation: prepared.invocation.cacheIdentity
                )
            }
        ) {
            let surface = try FrontendReceipt.ManagedNativeSurface.catalog(
                moduleName: request.identity.moduleName,
                sourceFileLogicalID: NativeAPICatalog.Projector
                    .sourceFileLogicalID(moduleName: request.identity.moduleName),
                minimumOS: request.identity.minimumDeployment,
                frontend: prepared.frontend,
                invocation: prepared.invocation.execution,
                cache: cache,
                compilerFingerprint: prepared.toolchain.fingerprint,
                moduleInputHash: prepared.cacheKey
            )
            let measuredProjection = NativeAPICatalog.CompilerProjection(
                sourceFileLogicalID: NativeAPICatalog.Projector
                    .sourceFileLogicalID(moduleName: request.identity.moduleName),
                importedTypes: surface.importedTypes,
                operations: surface.operations,
                modulesByDeclarationUSR: surface.modulesByDeclarationUSR,
                referencedModules: []
            )
            let projected = try NativeAPICatalog.Projector.project(
                projection: measuredProjection,
                identity: request.identity,
                invocation: prepared.invocation.cacheIdentity
            )
            let declarationUSRs = Set(
                projected.operations.compactMap(\.declarationUSR)
            )
            let projection = NativeAPICatalog.CompilerProjection(
                sourceFileLogicalID: measuredProjection.sourceFileLogicalID,
                importedTypes: projected.importedTypes,
                operations: projected.operations,
                modulesByDeclarationUSR: measuredProjection
                    .modulesByDeclarationUSR.filter {
                        declarationUSRs.contains($0.key)
                    },
                referencedModules: projected.referencedModules
            )
            let entries = projected.entries
            let filteredEntries = try NativeAPICatalog.Projector.entries(
                projection: projection,
                identity: request.identity,
                invocation: prepared.invocation.cacheIdentity
            )
            guard filteredEntries == entries else {
                let expectedKeys = Set(entries.map(\.key))
                let filteredKeys = Set(filteredEntries.map(\.key))
                throw NativeAPICatalog.Error.invalid(
                    "Catalog projection filtering changed its published entries; "
                        + "removed=\(expectedKeys.subtracting(filteredKeys).count), "
                        + "added=\(filteredKeys.subtracting(expectedKeys).count)"
                )
            }
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
                invocation: prepared.invocation.cacheIdentity,
                metrics: .init(
                    importedTypeCount: UInt64(projection.importedTypes.count),
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
        return output(
            payload: payload,
            source: value.source,
            surfaceMetrics: generatedSurfaceMetrics
        )
    }

    /// Reads a complete Catalog only when it is already published and no
    /// producer currently owns its cache key. No compiler work is started.
    public func cached(
        _ request: NativeAPICatalog.BuildRequest
    ) throws -> NativeAPICatalog.BuildOutput? {
        let prepared = try prepare(request)
        var payload: CachePayload?
        guard let value = try cache.cachedValue(
            namespace: .nativeAPICatalog,
            key: prepared.cacheKey,
            maximumBytes: 384 * 1_024 * 1_024,
            validate: { data in
                payload = try decode(
                    data,
                    identity: request.identity,
                    invocation: prepared.invocation.cacheIdentity
                )
            }
        ), let payload else { return nil }
        return output(payload: payload, source: value.source)
    }

    public func cacheKey(
        for request: NativeAPICatalog.BuildRequest
    ) throws -> Core.Digest {
        try prepare(request).cacheKey
    }

    private func prepare(
        _ request: NativeAPICatalog.BuildRequest
    ) throws -> PreparedBuild {
        try request.frontendInvocation.validate()
        try NativeAPICatalog.Document(
            identity: request.identity,
            entries: []
        ).validate()
        guard request.compilerURL.standardizedFileURL.path
                == request.compilerURL.path,
              request.compilerURL.path.hasPrefix("/"),
              !request.compilerURL.path.contains("\n"),
              !request.compilerURL.path.contains("\r")
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog compiler path is unsafe or noncanonical"
            )
        }
        let frontend = SwiftFrontend.Driver(
            compilerURL: request.compilerURL,
            defaultWorkingDirectoryURL: request.workingDirectoryURL,
            invocationObserver: invocationObserver
        )
        if let workingDirectoryURL = request.workingDirectoryURL {
            let workingDirectory = workingDirectoryURL.standardizedFileURL
            guard workingDirectory.path == workingDirectoryURL.path,
                  workingDirectory.path.hasPrefix("/"),
                  !workingDirectory.path.contains("\n"),
                  !workingDirectory.path.contains("\r")
            else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog working directory is unsafe or noncanonical"
                )
            }
        }
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
        let sdk = try request.precomputedSDK
            ?? frontend.sdkIdentity(name: request.frontendInvocation.sdkName)
        guard sdk.name == request.frontendInvocation.sdkName,
              URL(fileURLWithPath: sdk.path).standardizedFileURL.path
                == sdk.path,
              sdk.path.hasPrefix("/"),
              !sdk.path.contains("\n"),
              !sdk.path.contains("\r"),
              sdk.buildVersion == request.identity.sdkProductBuild
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog identity does not match the installed SDK"
            )
        }
        let invocation = try canonicalInvocation(
            request.frontendInvocation,
            identity: request.identity,
            frontend: frontend
        )
        let key = try BuildCache.key(
            domain: "HLX.BuildCache.NativeAPICatalog.v1",
            value: CacheKey(
                identity: request.identity,
                invocation: invocation.cacheIdentity,
                transformPipelineHash: ShellBuild.transformPipelineHash
            )
        )
        return .init(
            frontend: frontend,
            toolchain: toolchain,
            invocation: invocation,
            cacheKey: key
        )
    }

    private func output(
        payload: CachePayload,
        source: BuildCache.Source,
        surfaceMetrics: FrontendReceipt.ManagedNativeSurface.Metrics? = nil
    ) -> NativeAPICatalog.BuildOutput {
        .init(
            snapshot: .init(
                document: payload.document,
                compilerProjection: payload.compilerProjection
            ),
            metrics: .init(
                cacheSource: source,
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
        var arguments = invocation.semanticArguments
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
        } else if identity.swiftLanguageMode != "default" {
            arguments += ["-swift-version", identity.swiftLanguageMode]
        }
        if !arguments.contains("-parse-as-library") {
            arguments.insert("-parse-as-library", at: 0)
        }
        // Validate the extractor projection now, even on a Catalog cache hit.
        // Probe frontends retain the complete captured semantic invocation;
        // the Symbol Graph tool applies its own narrower projection later.
        _ = try frontend.symbolGraphImportArguments(arguments)
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
        let projected = try NativeAPICatalog.Projector.project(
            projection: snapshot.compilerProjection,
            identity: identity,
            invocation: invocation
        )
        guard snapshot.document.identity == identity,
              snapshot.document.entries == projected.entries,
              snapshot.compilerProjection.importedTypes
                == projected.importedTypes,
              snapshot.compilerProjection.operations == projected.operations
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog document does not match its compiler projection"
            )
        }
    }
}
}
