import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

public enum ShellBuild {
    /// Changes whenever the source-to-Shell transformation changes semantics.
    public static let transformPipelineHash = Core.Digest.sha256(
        "Helix.ShellBuild.DynamicSourceTransform.v1"
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
    public var sourceBaselineHash: Core.Digest
    public var reloadIndexHash: Core.Digest
    public var eligibleFunctionCount: UInt32
    public var rejectedFunctionCount: UInt32
    public var emittedNativeImportCount: UInt32
    public var transformedSources: [ShellBuild.Artifact]
    public var generatedSources: [ShellBuild.Artifact]
    public var diagnostics: [Core.Diagnostic]
}

public struct Output: Sendable {
    public var archive: InterfaceArchive.Archive
    public var archiveBytes: Data
    public var bridge: BridgeGeneration.Output
    public var transformedSources: [String: Data]
    public var reloadIndex: ReloadIndex.Document
    public var reloadIndexBytes: Data
    public var xcodeIntegration: XcodeIntegration.Output
    public var report: ShellBuild.Report

    public func artifacts() throws -> [String: Data] {
        var result: [String: Data] = [
            "Shell.provisional.hlxi": archiveBytes,
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
        hubBinding: ShellBuild.HubBinding? = nil
    ) throws -> ShellBuild.Output {
        try limits.validate()
        try receipt.validate()
        let sourceContents = try loadSources(receipt.sources, from: sourceRoot)
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
        let candidateByMangledName = Dictionary(
            uniqueKeysWithValues: receipt.declarations.map { ($0.mangledName, $0) }
        )
        var transformedSources: [String: Data] = [:]
        var indexedSources: [InterfaceArchive.SourceRecord] = []
        for source in receipt.sources {
            guard let contents = sourceContents[source.logicalPath] else {
                throw ShellBuild.Error.invalidInput("source loader omitted \(source.logicalPath)")
            }
            let descriptors = receipt.roots.filter {
                candidateByMangledName[$0.declarationMangledName]?.sourceFileLogicalID
                    == source.logicalPath
            }
            if descriptors.isEmpty {
                transformedSources[source.logicalPath] = contents
                indexedSources.append(
                    .init(logicalPath: source.logicalPath, contentHash: source.contentHash)
                )
                continue
            }
            let edits = try descriptors.map { descriptor -> SourceTransform.Edit in
                guard let function = functionByMangledName[descriptor.declarationMangledName] else {
                    throw ShellBuild.Error.rootSetMismatch
                }
                return .init(
                    utf8Offset: descriptor.declarationUTF8Offset,
                    expectedDeclarationPrefix: descriptor.expectedDeclarationPrefix,
                    functionKey: function.key
                )
            }
            let transformed = try SourceTransform.Transformer().transform(
                source: contents,
                logicalPath: source.logicalPath,
                expectedSourceHash: source.contentHash,
                edits: edits
            )
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
        var bridge = try BridgeGeneration.Generator().generate(
            archive: indexed.archive,
            moduleName: indexed.archive.metadata.frontendInvocation.moduleName,
            roots: bridgeRoots,
            nativeImports: importBindings,
            nativeTypes: typeBindings
        )
        let devContract = try ShellBuild.DevContractGenerator().generate(
            archive: indexed.archive,
            reloadIndexHash: reloadIndexHash,
            hubBinding: hubBinding
        )
        guard bridge.sourceFiles.updateValue(
            devContract.contents,
            forKey: devContract.path
        ) == nil else {
            throw ShellBuild.Error.outputCollision(devContract.path)
        }
        let provider = try ShellBuild.BridgeProviderGenerator().generate(
            archive: indexed.archive,
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
        let report = ShellBuild.Report(
            schemaVersion: ShellBuild.Report.currentSchemaVersion,
            receiptHash: try receipt.contentHash(),
            archiveDigest: try indexed.archive.archiveDigest(),
            archiveContainerHash: .sha256(archiveBytes),
            shellInterfaceHash: indexed.archive.shellInterfaceHash,
            sourceBaselineHash: indexed.archive.metadata.sourceBaselineHash,
            reloadIndexHash: reloadIndexHash,
            eligibleFunctionCount: UInt32(indexed.eligibleCount),
            rejectedFunctionCount: UInt32(indexed.rejectedCount),
            emittedNativeImportCount: UInt32(indexed.emittedImportCount),
            transformedSources: transformedArtifacts,
            generatedSources: generatedArtifacts,
            diagnostics: indexed.diagnostics
        )
        return .init(
            archive: indexed.archive,
            archiveBytes: archiveBytes,
            bridge: bridge,
            transformedSources: transformedSources,
            reloadIndex: reloadIndex,
            reloadIndexBytes: reloadIndexBytes,
            xcodeIntegration: xcodeIntegration,
            report: report
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
                capabilities: Set(receipt.capabilities)
            )
        )
    }

    private func loadSources(
        _ sources: [ShellBuildReceipt.Source],
        from sourceRoot: URL
    ) throws -> [String: Data] {
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw ShellBuild.Error.invalidFilesystemEntry(root.path)
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var total = 0
        var result: [String: Data] = [:]
        for source in sources {
            let unresolved = root.appendingPathComponent(source.logicalPath).standardizedFileURL
            let url = unresolved.resolvingSymlinksInPath()
            guard url.path.hasPrefix(rootPrefix) else {
                throw ShellBuild.Error.sourceEscapesRoot(source.logicalPath)
            }
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
            guard root.declarationUTF8Offset <= source.count,
                  anchor.count <= source.count - root.declarationUTF8Offset,
                  source[root.declarationUTF8Offset..<(root.declarationUTF8Offset + anchor.count)]
                    == anchor,
                  Self.occurrence(
                      of: anchor,
                      at: root.declarationUTF8Offset,
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
                originalReference: bridge.originalReference,
                replacementDeclaration: bridge.replacementDeclaration,
                parameterExpressions: bridge.parameterExpressions,
                parameterSwiftTypes: bridge.parameterSwiftTypes,
                resultSwiftType: bridge.resultSwiftType,
                originalInvocation: bridge.originalInvocation,
                bridgeInvocation: bridge.bridgeInvocation,
                enclosingPrefix: bridge.enclosingPrefix,
                enclosingSuffix: bridge.enclosingSuffix
            )
        }
    }

    private func makeImportBindings(
        archive: InterfaceArchive.Archive,
        receiptBindings: [ShellBuildReceipt.NativeImportBinding]
    ) throws -> [BridgeGeneration.NativeImportBinding] {
        let emitted = archive.nativeImports.filter(\.isEmittedToDevice)
        let byKey = Dictionary(uniqueKeysWithValues: receiptBindings.map { ($0.key, $0) })
        guard Set(emitted.map(\.key)) == Set(byKey.keys) else {
            throw ShellBuild.Error.nativeImportBindingMismatch
        }
        return try emitted.map { item in
            guard let id = item.id, let binding = byKey[item.key] else {
                throw ShellBuild.Error.nativeImportBindingMismatch
            }
            return .init(
                id: id,
                key: item.key,
                invokerExpression: binding.invokerExpression,
                importedModules: binding.importedModules,
                generated: binding.generated.map { generated in
                    let dispatch: BridgeGeneration.GeneratedNativeImport.Dispatch =
                        switch generated.dispatch {
                        case .globalFunction: .globalFunction
                        case .initializer: .initializer
                        case .staticMethod: .staticMethod
                        case .nativeUpcast: .nativeUpcast
                        case .anyObjectBridge: .anyObjectBridge
                        case .staticGetter: .staticGetter
                        case .staticSetter: .staticSetter
                        case .instanceMethod: .instanceMethod
                        case .instanceGetter: .instanceGetter
                        case .instanceSetter: .instanceSetter
                        case .instanceValueSetter: .instanceValueSetter
                        }
                    return BridgeGeneration.GeneratedNativeImport(
                        declarationMangledName: generated.declarationMangledName,
                        sourceFileLogicalID: generated.sourceFileLogicalID,
                        dispatch: dispatch,
                        ownerType: generated.ownerType,
                        baseName: generated.baseName,
                        argumentLabels: generated.argumentLabels,
                        parameterSwiftTypes: generated.parameterSwiftTypes,
                        resultSwiftType: generated.resultSwiftType
                    )
                }
            )
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
            return .init(
                id: type.id,
                canonicalName: type.canonicalName,
                layoutFingerprint: type.layoutFingerprint,
                requiresMainActor: type.requiresMainActor,
                operationsExpression: binding.operationsExpression,
                importedModules: binding.importedModules,
                generated: binding.generated.map {
                    let representation: BridgeGeneration.GeneratedNativeType.Representation =
                        switch $0.representation {
                        case .reference: .reference
                        case .rawRepresentable: .rawRepresentable
                        case .opaqueValue: .opaqueValue
                        }
                    return BridgeGeneration.GeneratedNativeType(
                        sourceFileLogicalID: $0.sourceFileLogicalID,
                        swiftType: $0.swiftType,
                        representation: representation
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
                declarationAnchor: replacement.declarationAnchor,
                declarationOccurrence: replacement.declarationOccurrence,
                loweredType: replacement.loweredType,
                originalReference: replacement.originalReference,
                replacementDeclaration: replacement.replacementDeclaration,
                enclosingPrefix: replacement.enclosingPrefix,
                enclosingSuffix: replacement.enclosingSuffix,
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
