import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

public enum ShellBuild {
    /// Changes whenever source transformation, generated Shell, interface, or
    /// native-call descriptor semantics change. This invalidates local build
    /// facts without changing a shipped protocol or schema version.
    public static let transformPipelineHash = Core.Digest.sha256(
        "Helix.ShellBuild.DynamicSourceTransform.v1:declaration-groups:frozen-value-hooks:source-body-dispatch:async-original-thunks:native-call-descriptor-v1:objective-c-invoker:objective-c-lightweight-generic-erasure:c-invoker-main-actor-unqualified-reference:swift-adapter-pack-v1:development-native-candidate-emission:production-native-capability-manifest:indexed-source-baseline-metadata:objective-c-declaration-qualified-sil:property-declaration-identity:exact-module-imports:separate-hub-contract-object:module-native-api-catalog:bounded-parallel-native-probes:published-catalog-projection:catalog-authoritative-descriptor:measured-native-type-isolation"
    )
}

extension ShellBuild {
public struct Limits: Hashable, Sendable {
    public var maximumSourceBytes: Int
    public var maximumTotalSourceBytes: Int

    public init(
        maximumSourceBytes: Int = 64 * 1_024 * 1_024,
        maximumTotalSourceBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumTotalSourceBytes = maximumTotalSourceBytes
    }

    fileprivate func validate() throws {
        guard maximumSourceBytes > 0,
              maximumTotalSourceBytes >= maximumSourceBytes
        else {
            throw ShellBuild.Error.invalidInput("source size limits are invalid")
        }
    }
}

public struct Artifact: Codable, Hashable, Sendable {
    public var path: String
    public var contentHash: Core.Digest
    public var byteCount: UInt64

    public init(path: String, data: Data) {
        self.path = path
        contentHash = .sha256(data)
        byteCount = UInt64(data.count)
    }
}

public struct Report: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var receiptHash: Core.Digest
    public var archiveDigest: Core.Digest
    public var archiveContainerHash: Core.Digest
    public var shellInterfaceHash: Core.Digest
    public var nativeCapabilityManifestHash: Core.Digest
    public var nativeCapabilityCount: UInt32
    public var sourceBaselineHash: Core.Digest
    public var reloadIndexHash: Core.Digest
    public var eligibleFunctionCount: UInt32
    public var rejectedFunctionCount: UInt32
    public var emittedNativeImportCount: UInt32
    public var adapterPacks: [ShellBuild.AdapterPackReport]
    public var applicationAdapterCount: UInt32
    public var objectiveCInvokerCount: UInt32
    public var cInvokerCount: UInt32
    public var transformedSources: [ShellBuild.Artifact]
    public var generatedSources: [ShellBuild.Artifact]
    public var diagnostics: [Core.Diagnostic]
}

public struct AdapterPackReport: Codable, Hashable, Sendable {
    public var identity: NativeAdapterPack.Identity
    public var moduleName: String
    public var entryCount: UInt32
    public var sourcePath: String
    public var sourceHash: Core.Digest
    public var sourceByteCount: UInt64
    public var cacheSource: BuildCache.Source
}

public struct Output: Sendable {
    public var archive: InterfaceArchive.Archive
    public var archiveBytes: Data
    public var nativeCapabilityManifest: Core.NativeCapability.Manifest
    public var nativeCapabilityManifestBytes: Data
    public var bridge: BridgeGeneration.Output
    public var transformedSources: [String: Data]
    public var reloadIndex: ReloadIndex.Document
    public var reloadIndexBytes: Data
    public var xcodeIntegration: XcodeIntegration.Output
    public var report: ShellBuild.Report

    public func artifacts() throws -> [String: Data] {
        var result: [String: Data] = [
            "Shell.provisional.hlxi": archiveBytes,
            "NativeCapabilities.json": nativeCapabilityManifestBytes,
            "ReloadIndex.json": reloadIndexBytes,
        ]
        for (path, source) in bridge.sourceFiles {
            try Self.insert(Data(source.utf8), at: path, into: &result)
        }
        for (logicalPath, source) in transformedSources {
            try Self.insert(
                source,
                at: "DerivedSources/\(SourceTransform.transformedFilePath(for: logicalPath))",
                into: &result
            )
        }
        for (path, data) in xcodeIntegration.artifacts {
            try Self.insert(data, at: path, into: &result)
        }
        try Self.insert(
            try Core.CanonicalJSON.encode(report),
            at: "ShellBuildReport.json",
            into: &result
        )
        return result
    }

    private static func insert(
        _ data: Data,
        at path: String,
        into artifacts: inout [String: Data]
    ) throws {
        guard Self.isSafeArtifactPath(path), artifacts.updateValue(data, forKey: path) == nil else {
            throw ShellBuild.Error.outputCollision(path)
        }
    }

    private static func isSafeArtifactPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct Materializer: Sendable {
    public var limits: ShellBuild.Limits

    public init(limits: ShellBuild.Limits = .init()) {
        self.limits = limits
    }

    public func materialize(
        receipt: ShellBuildReceipt.Document,
        sourceRoot: URL,
        hubBinding: ShellBuild.HubBinding? = nil,
        cache: BuildCache.Store? = nil
    ) throws -> ShellBuild.Output {
        let sourceMappings = try sourceMappings(
            for: receipt.sources,
            from: sourceRoot
        )
        return try materialize(
            receipt: receipt,
            sourceMappings: sourceMappings,
            hubBinding: hubBinding,
            cache: cache
        )
    }

    public func materialize(
        receipt: ShellBuildReceipt.Document,
        sourceMappings: [String: URL],
        hubBinding: ShellBuild.HubBinding? = nil,
        cache: BuildCache.Store? = nil
    ) throws -> ShellBuild.Output {
        try limits.validate()
        try receipt.validate()
        let sourceContents = try loadSources(
            receipt.sources,
            from: sourceMappings
        )
        try validateNativeAnchors(receipt: receipt, sources: sourceContents)
        let initialSources = receipt.sources.map {
            InterfaceArchive.SourceRecord(logicalPath: $0.logicalPath, contentHash: $0.contentHash)
        }
        let initial = try index(receipt: receipt, sources: initialSources)
        let rootsByMangledName = Dictionary(
            uniqueKeysWithValues: receipt.roots.map { ($0.declarationMangledName, $0) }
        )
        let eligible = initial.archive.functions.filter(\.patchability.isEligible)
        let bridgedNames = Set(receipt.roots.compactMap {
            $0.bridge == nil ? nil : $0.declarationMangledName
        })
        guard Set(eligible.map(\.mangledName)) == bridgedNames else {
            throw ShellBuild.Error.rootSetMismatch
        }

        let functionByMangledName = Dictionary(
            uniqueKeysWithValues: initial.archive.functions.map { ($0.mangledName, $0) }
        )
        let initialBridgeRoots = try makeBridgeRoots(
            archive: initial.archive,
            descriptors: rootsByMangledName
        )
        let sourceBodyTransform = try BridgeGeneration.Generator()
            .renderSourceBodyTransform(
                archive: initial.archive,
                roots: initialBridgeRoots
            )
        let candidateByMangledName = Dictionary(
            uniqueKeysWithValues: receipt.declarations.map { ($0.mangledName, $0) }
        )
        let frozenValuesBySource = Dictionary(
            grouping: initial.archive.frozenValueTypes,
            by: \.sourceFileLogicalID
        )
        let moduleName = initial.archive.metadata.frontendInvocation.moduleName
        var transformedSources: [String: Data] = [:]
        var indexedSources: [InterfaceArchive.SourceRecord] = []
        var transformedSourceBytes = 0
        func accountForTransformedSource(_ byteCount: Int) throws {
            let total = transformedSourceBytes.addingReportingOverflow(byteCount)
            guard byteCount <= limits.maximumSourceBytes,
                  !total.overflow,
                  total.partialValue <= limits.maximumTotalSourceBytes
            else {
                throw ShellBuild.Error.sourceSetTooLarge
            }
            transformedSourceBytes = total.partialValue
        }
        for source in receipt.sources {
            guard let contents = sourceContents[source.logicalPath] else {
                throw ShellBuild.Error.invalidInput("source loader omitted \(source.logicalPath)")
            }
            let descriptors = receipt.roots.filter {
                candidateByMangledName[$0.declarationMangledName]?.sourceFileLogicalID
                    == source.logicalPath
            }
            let frozenValues = frozenValuesBySource[source.logicalPath] ?? []
            let sourceBodySupplemental = sourceBodyTransform
                .supplementalDeclarations[source.logicalPath] ?? ""
            if descriptors.isEmpty, frozenValues.isEmpty,
               sourceBodySupplemental.isEmpty {
                try accountForTransformedSource(contents.count)
                transformedSources[source.logicalPath] = contents
                indexedSources.append(
                    .init(logicalPath: source.logicalPath, contentHash: source.contentHash)
                )
                continue
            }
            let descriptorGroups = Dictionary(
                grouping: descriptors,
                by: { $0.sourceDeclaration.identity }
            ).values
            let locationMap = SourceTransform.LocationMap(contents)
            let edits = try descriptorGroups.compactMap {
                values -> SourceTransform.Edit? in
                guard let first = values.first else {
                    throw ShellBuild.Error.rootSetMismatch
                }
                let keys = try values.map { descriptor -> Core.FunctionKey in
                    guard let function = functionByMangledName[
                        descriptor.declarationMangledName
                    ] else {
                        throw ShellBuild.Error.rootSetMismatch
                    }
                    return function.key
                }
                guard let insertion = first.declarationInsertion else { return nil }
                return .init(
                    utf8Offset: first.declarationUTF8Offset,
                    expectedDeclarationPrefix: first.expectedDeclarationPrefix,
                    insertion: insertion,
                    functionKeys: keys
                )
            }
            let replacements = try descriptors.compactMap {
                descriptor -> SourceTransform.Replacement? in
                guard let transform = descriptor.sourceBodyTransform else { return nil }
                guard let function = functionByMangledName[
                    descriptor.declarationMangledName
                ], let body = sourceBodyTransform.bodies[function.key]
                else {
                    throw ShellBuild.Error.rootSetMismatch
                }
                let upperBound = transform.closingBraceUTF8Offset
                    .addingReportingOverflow(1)
                guard !upperBound.overflow else {
                    throw ShellBuild.Error.rootSetMismatch
                }
                return .init(
                    utf8Range: transform.openingBraceUTF8Offset..<upperBound.partialValue,
                    expectedContentHash: transform.expectedBodyHash,
                    replacement: try renderSourceBody(
                        body,
                        source: contents,
                        transform: transform,
                        logicalPath: source.logicalPath,
                        locationMap: locationMap
                    ),
                    functionKey: function.key,
                    restoresSourceLocationBeforeFinalBrace: true
                )
            }
            let frozenValueDeclarations = ShellBuild.FrozenValueHooks.render(
                frozenValues,
                moduleName: moduleName
            )
            let bridgeDeclarations = Array(Set(descriptors.compactMap {
                $0.bridge?.sourceSupplementalDeclaration
            })).sorted()
            let supplementalDeclarations = (
                [frozenValueDeclarations] + bridgeDeclarations
                    + [sourceBodySupplemental]
            )
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let transformed = try SourceTransform.Transformer().transform(
                source: contents,
                logicalPath: source.logicalPath,
                expectedSourceHash: source.contentHash,
                edits: edits,
                replacements: replacements,
                supplementalDeclarations: supplementalDeclarations
            )
            try accountForTransformedSource(transformed.contents.count)
            transformedSources[source.logicalPath] = transformed.contents
            indexedSources.append(
                .init(
                    logicalPath: source.logicalPath,
                    contentHash: source.contentHash,
                    transformHash: transformed.transformedHash
                )
            )
        }

        let indexed = try index(receipt: receipt, sources: indexedSources)
        guard indexed.archive.shellInterfaceHash == initial.archive.shellInterfaceHash else {
            throw ShellBuild.Error.invalidInput(
                "source transform unexpectedly changed the Shell interface"
            )
        }
        let bridgeRoots = try makeBridgeRoots(
            archive: indexed.archive,
            descriptors: rootsByMangledName
        )
        let importBindings = try makeImportBindings(
            archive: indexed.archive,
            receiptBindings: receipt.nativeImportBindings
        )
        let typeBindings = try makeTypeBindings(
            archive: indexed.archive,
            receiptBindings: receipt.nativeTypeBindings
        )
        let reloadIndex = try makeReloadIndex(
            receipt: receipt,
            archive: indexed.archive,
            rootsByMangledName: rootsByMangledName
        )
        let reloadIndexHash = try reloadIndex.contentHash()
        let nativeCapabilityManifest = try indexed.archive
            .nativeCapabilityManifest()
        let nativeCapabilityManifestBytes = try Core.CanonicalJSON.encode(
            nativeCapabilityManifest
        )
        var bridge = try BridgeGeneration.Generator().generate(
            archive: indexed.archive,
            moduleName: indexed.archive.metadata.frontendInvocation.moduleName,
            roots: bridgeRoots,
            nativeImports: importBindings,
            nativeTypes: typeBindings
        )
        let adapterPackCacheSources = try cacheAdapterPacks(
            in: &bridge,
            receipt: receipt,
            cache: cache
        )
        if let hubBinding {
            let hubContract = try ShellBuild.HubContractGenerator().generate(
                archive: indexed.archive,
                binding: hubBinding
            )
            guard bridge.sourceFiles.updateValue(
                hubContract.contents,
                forKey: hubContract.path
            ) == nil else {
                throw ShellBuild.Error.outputCollision(hubContract.path)
            }
        }
        let provider = try ShellBuild.BridgeProviderGenerator().generate(
            archive: indexed.archive,
            nativeCapabilityManifest: nativeCapabilityManifest,
            reloadIndexHash: reloadIndexHash
        )
        guard bridge.sourceFiles.updateValue(
            provider.contents,
            forKey: provider.path
        ) == nil else {
            throw ShellBuild.Error.outputCollision(provider.path)
        }
        let archiveBytes = try InterfaceArchive.Codec.encode(indexed.archive)
        let reloadIndexBytes = try Core.CanonicalJSON.encode(reloadIndex)
        let xcodeIntegration = try XcodeIntegration.Generator().generate(
            moduleName: indexed.archive.metadata.frontendInvocation.moduleName,
            transformedSourcePaths: transformedSources.keys.map {
                SourceTransform.transformedFilePath(for: $0)
            },
            bridgeSourcePaths: Array(bridge.sourceFiles.keys)
        )
        let transformedArtifacts = transformedSources.map {
            ShellBuild.Artifact(
                path: "DerivedSources/\(SourceTransform.transformedFilePath(for: $0.key))",
                data: $0.value
            )
        }.sorted { $0.path < $1.path }
        let generatedArtifacts = (bridge.sourceFiles.map {
            ShellBuild.Artifact(path: $0.key, data: Data($0.value.utf8))
        } + xcodeIntegration.artifacts.map {
            ShellBuild.Artifact(path: $0.key, data: $0.value)
        }).sorted { $0.path < $1.path }
        let adapterPackReports = try bridge.adapterPacks.map { pack in
            guard let source = bridge.sourceFiles[pack.sourcePath] else {
                throw ShellBuild.Error.nativeImportBindingMismatch
            }
            let data = Data(source.utf8)
            let identity = NativeAdapterPack.Identity(
                compilerFingerprint: receipt.compatibility.compilerFingerprint,
                sdkBuild: receipt.metadata.sdkBuild,
                targetTriple: receipt.metadata.targetTriple,
                minimumDeployment: receipt.metadata.minimumOS,
                transformPipelineHash: receipt.metadata.transformPipelineHash,
                moduleName: pack.moduleName,
                importedModules: pack.importedModules,
                keys: pack.keys
            )
            return ShellBuild.AdapterPackReport(
                identity: identity,
                moduleName: pack.moduleName,
                entryCount: UInt32(pack.keys.count),
                sourcePath: pack.sourcePath,
                sourceHash: .sha256(data),
                sourceByteCount: UInt64(data.count),
                cacheSource: adapterPackCacheSources[pack.moduleName]
                    ?? .bypassed
            )
        }.sorted { $0.moduleName < $1.moduleName }
        let emittedBindingKeys = Set(indexed.archive.nativeImports.compactMap {
            $0.isEmittedToDevice ? $0.key : nil
        })
        let emittedBindings = receipt.nativeImportBindings.filter {
            emittedBindingKeys.contains($0.key)
        }
        let report = ShellBuild.Report(
            schemaVersion: ShellBuild.Report.currentSchemaVersion,
            receiptHash: try receipt.contentHash(),
            archiveDigest: try indexed.archive.archiveDigest(),
            archiveContainerHash: .sha256(archiveBytes),
            shellInterfaceHash: indexed.archive.shellInterfaceHash,
            nativeCapabilityManifestHash: .sha256(
                nativeCapabilityManifestBytes
            ),
            nativeCapabilityCount: UInt32(
                nativeCapabilityManifest.entries.count
            ),
            sourceBaselineHash: indexed.archive.metadata.sourceBaselineHash,
            reloadIndexHash: reloadIndexHash,
            eligibleFunctionCount: UInt32(indexed.eligibleCount),
            rejectedFunctionCount: UInt32(indexed.rejectedCount),
            emittedNativeImportCount: UInt32(indexed.emittedImportCount),
            adapterPacks: adapterPackReports,
            applicationAdapterCount: UInt32(emittedBindings.filter {
                $0.strategy == .generatedSwiftAdapter
                    && $0.generated?.nativeModuleName == nil
            }.count),
            objectiveCInvokerCount: UInt32(emittedBindings.filter {
                $0.strategy == .objectiveCInvoker
            }.count),
            cInvokerCount: UInt32(emittedBindings.filter {
                $0.strategy == .cInvoker
            }.count),
            transformedSources: transformedArtifacts,
            generatedSources: generatedArtifacts,
            diagnostics: indexed.diagnostics
        )
        return .init(
            archive: indexed.archive,
            archiveBytes: archiveBytes,
            nativeCapabilityManifest: nativeCapabilityManifest,
            nativeCapabilityManifestBytes: nativeCapabilityManifestBytes,
            bridge: bridge,
            transformedSources: transformedSources,
            reloadIndex: reloadIndex,
            reloadIndexBytes: reloadIndexBytes,
            xcodeIntegration: xcodeIntegration,
            report: report
        )
    }

    private func cacheAdapterPacks(
        in bridge: inout BridgeGeneration.Output,
        receipt: ShellBuildReceipt.Document,
        cache: BuildCache.Store?
    ) throws -> [String: BuildCache.Source] {
        var sources: [String: BuildCache.Source] = [:]
        for pack in bridge.adapterPacks {
            guard let generated = bridge.sourceFiles[pack.sourcePath] else {
                throw ShellBuild.Error.nativeImportBindingMismatch
            }
            let identity = NativeAdapterPack.Identity(
                compilerFingerprint: receipt.compatibility.compilerFingerprint,
                sdkBuild: receipt.metadata.sdkBuild,
                targetTriple: receipt.metadata.targetTriple,
                minimumDeployment: receipt.metadata.minimumOS,
                transformPipelineHash: receipt.metadata.transformPipelineHash,
                moduleName: pack.moduleName,
                importedModules: pack.importedModules,
                keys: pack.keys
            )
            let document = NativeAdapterPack.Document(
                identity: identity,
                sourcePath: pack.sourcePath,
                source: generated
            )
            try document.validate(source: generated)
            guard let cache else {
                sources[pack.moduleName] = .bypassed
                continue
            }
            let artifact = NativeAdapterPack.CachedArtifact(
                document: document,
                source: generated
            )
            var decoded: NativeAdapterPack.CachedArtifact?
            let value = try cache.value(
                namespace: .adapterPack,
                key: identity.cacheKey,
                maximumBytes: NativeAdapterPack.Codec.maximumBytes,
                validate: { data in
                    let candidate = try NativeAdapterPack.Codec.decode(data)
                    decoded = try candidate.validated(
                        against: document,
                        source: generated
                    )
                },
                produce: {
                    try NativeAdapterPack.Codec.encode(artifact)
                }
            )
            guard let decoded else {
                throw NativeAdapterPack.Error.invalid
            }
            bridge.sourceFiles[pack.sourcePath] = decoded.source
            sources[pack.moduleName] = value.source
        }
        return sources
    }

    private func renderSourceBody(
        _ body: BridgeGeneration.SourceBodyTransform.Body,
        source: Data,
        transform: ShellBuildReceipt.SourceBodyTransform,
        logicalPath: String,
        locationMap: SourceTransform.LocationMap
    ) throws -> String {
        let lowerBound = transform.openingBraceUTF8Offset
            .addingReportingOverflow(1)
        guard !lowerBound.overflow,
              lowerBound.partialValue <= transform.closingBraceUTF8Offset,
              transform.closingBraceUTF8Offset <= source.count,
              let original = String(
                  data: source.subdata(
                      in: lowerBound.partialValue..<transform.closingBraceUTF8Offset
                  ),
                  encoding: .utf8
              )
        else {
            throw ShellBuild.Error.rootSetMismatch
        }
        guard let location = locationMap.location(
            atUTF8Offset: transform.openingBraceUTF8Offset
        ) else {
            throw ShellBuild.Error.rootSetMismatch
        }
        return body.render(
            originalBody: original,
            logicalPath: logicalPath,
            openingBraceLine: location.line,
            openingBraceColumn: location.column
        )
    }

    private func index(
        receipt: ShellBuildReceipt.Document,
        sources: [InterfaceArchive.SourceRecord]
    ) throws -> ReleaseCompiler.IndexReport {
        try ReleaseCompiler.Indexer().index(
            .init(
                metadata: receipt.metadata,
                compatibility: receipt.compatibility,
                configuration: receipt.configuration,
                sources: sources,
                declarations: receipt.declarations,
                nativeImportCandidates: receipt.nativeImportCandidates,
                nativeTypes: receipt.nativeTypes,
                frozenValueTypes: receipt.frozenValueTypes,
                capabilities: Set(receipt.capabilities)
            )
        )
    }

    private func sourceMappings(
        for sources: [ShellBuildReceipt.Source],
        from sourceRoot: URL
    ) throws -> [String: URL] {
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw ShellBuild.Error.invalidFilesystemEntry(root.path)
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [String: URL] = [:]
        for source in sources {
            let unresolved = root.appendingPathComponent(source.logicalPath)
                .standardizedFileURL
            let url = unresolved.resolvingSymlinksInPath()
            guard url.path.hasPrefix(rootPrefix) else {
                throw ShellBuild.Error.sourceEscapesRoot(source.logicalPath)
            }
            result[source.logicalPath] = url
        }
        return result
    }

    private func loadSources(
        _ sources: [ShellBuildReceipt.Source],
        from sourceMappings: [String: URL]
    ) throws -> [String: Data] {
        guard Set(sourceMappings.keys) == Set(sources.map(\.logicalPath)),
              Set(sourceMappings.values.map { $0.standardizedFileURL.path }).count
                == sourceMappings.count,
              Set(sourceMappings.values.map {
                  $0.standardizedFileURL.resolvingSymlinksInPath().path
              }).count == sourceMappings.count
        else {
            throw ShellBuild.Error.invalidInput(
                "source mappings must exactly and uniquely cover the receipt"
            )
        }
        var total = 0
        var result: [String: Data] = [:]
        for source in sources {
            guard let mapped = sourceMappings[source.logicalPath],
                  mapped.isFileURL,
                  mapped.path.hasPrefix("/")
            else {
                throw ShellBuild.Error.invalidFilesystemEntry(source.logicalPath)
            }
            let url = mapped.standardizedFileURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let byteCount = values.fileSize,
                  byteCount <= limits.maximumSourceBytes
            else {
                throw ShellBuild.Error.invalidFilesystemEntry(url.path)
            }
            let addition = total.addingReportingOverflow(byteCount)
            guard !addition.overflow, addition.partialValue <= limits.maximumTotalSourceBytes else {
                throw ShellBuild.Error.sourceSetTooLarge
            }
            total = addition.partialValue
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == byteCount, Core.Digest.sha256(data) == source.contentHash else {
                throw ShellBuild.Error.sourceHashMismatch(source.logicalPath)
            }
            result[source.logicalPath] = data
        }
        return result
    }

    private func validateNativeAnchors(
        receipt: ShellBuildReceipt.Document,
        sources: [String: Data]
    ) throws {
        let declarations = Dictionary(
            uniqueKeysWithValues: receipt.declarations.map { ($0.mangledName, $0) }
        )
        for root in receipt.roots {
            guard let replacement = root.nativeReplacement,
                  let declaration = declarations[root.declarationMangledName],
                  let source = sources[declaration.sourceFileLogicalID]
            else { continue }
            let anchor = Data(replacement.declarationAnchor.utf8)
            let offset = replacement.declarationAnchorUTF8Offset
            guard offset <= source.count,
                  anchor.count <= source.count - offset,
                  source[offset..<(offset + anchor.count)]
                    == anchor,
                  Self.occurrence(
                      of: anchor,
                      at: offset,
                      in: source
                  ) == replacement.declarationOccurrence
            else {
                throw ShellBuild.Error.invalidInput(
                    "native declaration anchor is stale, misplaced, or ambiguous for "
                        + root.declarationMangledName
                )
            }
        }
    }

    private static func occurrence(of needle: Data, at offset: Int, in haystack: Data) -> UInt32? {
        guard !needle.isEmpty else { return nil }
        var occurrence: UInt32 = 0
        var lowerBound = haystack.startIndex
        while lowerBound <= haystack.endIndex - min(needle.count, haystack.count) {
            guard let match = haystack.range(
                  of: needle,
                  options: [],
                  in: lowerBound..<haystack.endIndex
            ) else { return nil }
            if match.lowerBound == offset { return occurrence }
            if match.lowerBound > offset { return nil }
            let next = occurrence.addingReportingOverflow(1)
            guard !next.overflow else { return nil }
            occurrence = next.partialValue
            lowerBound = match.upperBound
        }
        return nil
    }

    private func makeBridgeRoots(
        archive: InterfaceArchive.Archive,
        descriptors: [String: ShellBuildReceipt.Root]
    ) throws -> [BridgeGeneration.Root] {
        try archive.functions.filter(\.patchability.isEligible).map { function in
            guard let descriptor = descriptors[function.mangledName],
                  let bridge = descriptor.bridge,
                  let entryIndex = function.entryIndex
            else {
                throw ShellBuild.Error.rootSetMismatch
            }
            return .init(
                functionKey: function.key,
                entryIndex: entryIndex,
                sourceFileLogicalID: function.sourceFileLogicalID,
                privateImportSourceFile: URL(
                    fileURLWithPath: function.sourceFileLogicalID
                ).lastPathComponent,
                sourceDeclaration: descriptor.sourceDeclaration,
                memberRole: descriptor.memberRole,
                parameterExpressions: bridge.parameterExpressions,
                parameterSwiftTypes: bridge.parameterSwiftTypes,
                resultSwiftType: bridge.resultSwiftType,
                originalInvocation: bridge.originalInvocation,
                bridgeInvocation: bridge.bridgeInvocation,
                installation: descriptor.sourceBodyTransform == nil
                    ? .dynamicReplacement : .sourceBody
            )
        }
    }

    private func makeImportBindings(
        archive: InterfaceArchive.Archive,
        receiptBindings: [ShellBuildReceipt.NativeImportBinding]
    ) throws -> [BridgeGeneration.NativeImportBinding] {
        let emitted = archive.nativeImports.filter(\.isEmittedToDevice)
        let byKey = Dictionary(uniqueKeysWithValues: receiptBindings.map { ($0.key, $0) })
        guard Set(emitted.map(\.key)).isSubset(of: Set(byKey.keys)) else {
            throw ShellBuild.Error.nativeImportBindingMismatch
        }
        return try emitted.map { item in
            guard let binding = byKey[item.key] else {
                throw ShellBuild.Error.nativeImportBindingMismatch
            }
            return try binding.bridgeBinding(for: item)
        }
    }

    private func makeTypeBindings(
        archive: InterfaceArchive.Archive,
        receiptBindings: [ShellBuildReceipt.NativeTypeBinding]
    ) throws -> [BridgeGeneration.NativeTypeBinding] {
        let emitted = archive.nativeTypes.filter(\.isEmittedToDevice)
        func key(_ name: String, _ layout: Core.Digest, _ requiresMainActor: Bool) -> String {
            "\(name):\(layout.hex):\(requiresMainActor)"
        }
        let byKey = Dictionary(uniqueKeysWithValues: receiptBindings.map {
            (key($0.canonicalName, $0.layoutFingerprint, $0.requiresMainActor), $0)
        })
        guard Set(emitted.map {
            key($0.canonicalName, $0.layoutFingerprint, $0.requiresMainActor)
        })
                == Set(byKey.keys)
        else {
            throw ShellBuild.Error.nativeTypeBindingMismatch
        }
        return try emitted.map { type in
            guard let binding = byKey[key(
                type.canonicalName,
                type.layoutFingerprint,
                type.requiresMainActor
            )] else {
                throw ShellBuild.Error.nativeTypeBindingMismatch
            }
            let strategy: BridgeGeneration.NativeTypeBinding.Strategy
            switch binding.strategy {
            case .factory: strategy = .factory
            case .objectiveCReference: strategy = .objectiveCReference
            }
            return .init(
                id: type.id,
                canonicalName: type.canonicalName,
                layoutFingerprint: type.layoutFingerprint,
                requiresMainActor: type.requiresMainActor,
                strategy: strategy,
                operationsExpression: binding.operationsExpression,
                importedModules: binding.importedModules,
                generated: binding.generated.map {
                    let representation: BridgeGeneration.GeneratedNativeType.Representation =
                        switch $0.representation {
                        case .reference: .reference
                        case .rawRepresentable: .rawRepresentable
                        case .opaqueValue: .opaqueValue
                        case .objectiveCStructure: .objectiveCStructure
                        }
                    return BridgeGeneration.GeneratedNativeType(
                        sourceFileLogicalID: $0.sourceFileLogicalID,
                        swiftType: $0.swiftType,
                        representation: representation,
                        nativeABIEncoding: $0.nativeABIEncoding,
                        nativeModuleName: $0.nativeModuleName
                    )
                }
            )
        }
    }

    private func makeReloadIndex(
        receipt: ShellBuildReceipt.Document,
        archive: InterfaceArchive.Archive,
        rootsByMangledName: [String: ShellBuildReceipt.Root]
    ) throws -> ReloadIndex.Document {
        let functionByMangledName = Dictionary(
            uniqueKeysWithValues: archive.functions.map { ($0.mangledName, $0) }
        )
        let selected = try rootsByMangledName.keys.map { name -> InterfaceArchive.FunctionRecord in
            guard let function = functionByMangledName[name] else {
                throw ShellBuild.Error.rootSetMismatch
            }
            return function
        }
        let roots = try selected.map { function -> ReloadIndex.Root in
            guard let descriptor = rootsByMangledName[function.mangledName] else {
                throw ShellBuild.Error.rootSetMismatch
            }
            return .init(
                functionKey: function.key,
                nominalTypeID: descriptor.nominalType?.id,
                role: descriptor.reloadRole
            )
        }
        let grouped = Dictionary(grouping: selected, by: \.sourceFileLogicalID)
        let sourceRoots = grouped.map { logicalPath, functions in
            ReloadIndex.SourceRoots(
                sourceFileID: LiveReload.SourceFileID.derive(logicalPath: logicalPath),
                roots: functions.map(\.key)
            )
        }
        let nativeReplacements = try selected.compactMap {
            function -> ReloadIndex.NativeReplacement? in
            guard let descriptor = rootsByMangledName[function.mangledName] else {
                throw ShellBuild.Error.rootSetMismatch
            }
            guard let replacement = descriptor.nativeReplacement else { return nil }
            return .init(
                functionKey: function.key,
                sourceFileID: .derive(logicalPath: function.sourceFileLogicalID),
                sourceDeclaration: descriptor.sourceDeclaration,
                memberRole: descriptor.memberRole,
                declarationAnchor: replacement.declarationAnchor,
                declarationOccurrence: replacement.declarationOccurrence,
                loweredType: replacement.loweredType,
                importedModules: replacement.importedModules
            )
        }
        let edges = receipt.superclassEdges.map {
            ReloadIndex.SuperclassEdge(subtype: $0.subtype.id, superclass: $0.superclass.id)
        }
        let rules = receipt.reloadRules.map {
            ReloadIndex.Rule(
                sourceFileIDs: $0.sourceLogicalPaths.map(LiveReload.SourceFileID.derive),
                controllerTypeID: $0.controllerType.id,
                policy: $0.policy,
                invalidationHints: $0.invalidationHints,
                factoryID: $0.factoryID
            )
        }
        let factories = receipt.factories.map {
            ReloadIndex.FactoryDescriptor(id: $0.id, controllerTypeID: $0.controllerType.id)
        }
        let document = ReloadIndex.Document(
            sourceRoots: sourceRoots,
            roots: roots,
            nativeReplacements: nativeReplacements,
            superclassEdges: edges,
            explicitReloadRules: rules,
            factories: factories
        )
        do {
            try document.validate()
        } catch {
            throw ShellBuild.Error.invalidReloadIndex(String(describing: error))
        }
        return document
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)
    case invalidFilesystemEntry(String)
    case sourceEscapesRoot(String)
    case sourceHashMismatch(String)
    case sourceSetTooLarge
    case rootSetMismatch
    case nativeImportBindingMismatch
    case nativeTypeBindingMismatch
    case invalidReloadIndex(String)
    case outputCollision(String)
    case prelinkArchiveRequired
    case missingMachOUUID
    case executableMismatch(String)

    public var description: String {
        switch self {
        case let .invalidInput(reason): "invalid Shell build input: \(reason)"
        case let .invalidFilesystemEntry(path): "invalid Shell build filesystem entry: \(path)"
        case let .sourceEscapesRoot(path): "source escapes the declared source root: \(path)"
        case let .sourceHashMismatch(path): "source changed after receipt emission: \(path)"
        case .sourceSetTooLarge: "Shell build source set exceeds its byte limit"
        case .rootSetMismatch:
            "eligible HLXI functions and typed Bridge roots do not form the same set"
        case .nativeImportBindingMismatch:
            "emitted native imports and typed invoker bindings do not form the same set"
        case .nativeTypeBindingMismatch:
            "emitted native types and typed operation bindings do not form the same set"
        case let .invalidReloadIndex(reason): "generated Reload Index is invalid: \(reason)"
        case let .outputCollision(path): "two Shell build artifacts use \(path)"
        case .prelinkArchiveRequired: "Shell finalization requires a provisional pre-link HLXI"
        case .missingMachOUUID: "linked App executable has no LC_UUID"
        case let .executableMismatch(reason): "linked App executable disagrees with HLXI: \(reason)"
        }
    }
}
}
