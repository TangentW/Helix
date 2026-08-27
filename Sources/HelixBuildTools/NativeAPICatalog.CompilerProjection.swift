import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension NativeAPICatalog {
/// A validated Catalog plus the compiler facts needed to bind it into a
/// project. The projection deliberately remains opaque to callers because
/// typed-AST and SIL details are not a public or persisted product contract.
public struct Snapshot: Sendable {
    public let document: NativeAPICatalog.Document

    let compilerProjection: CompilerProjection
    private let storageWasValidated: Bool
    private let cacheIdentityStorage: Core.Digest?
    private let documentDigestStorage: Core.Digest?
    private let compilerProjectionDigestStorage: Core.Digest?

    init(
        document: NativeAPICatalog.Document,
        compilerProjection: CompilerProjection
    ) {
        self.document = document
        self.compilerProjection = compilerProjection
        storageWasValidated = false
        cacheIdentityStorage = nil
        documentDigestStorage = nil
        compilerProjectionDigestStorage = nil
    }

    private init(
        validatedDocument document: NativeAPICatalog.Document,
        compilerProjection: CompilerProjection,
        cacheIdentity: Core.Digest?,
        documentDigest: Core.Digest?,
        compilerProjectionDigest: Core.Digest?
    ) {
        self.document = document
        self.compilerProjection = compilerProjection
        storageWasValidated = true
        cacheIdentityStorage = cacheIdentity
        documentDigestStorage = documentDigest
        compilerProjectionDigestStorage = compilerProjectionDigest
    }

    /// Stable opaque identity for frontend/build-cache keys. Callers can bind
    /// cached compiler facts without gaining access to their private schema.
    public func compilerProjectionDigest() throws -> Core.Digest {
        if let compilerProjectionDigestStorage {
            return compilerProjectionDigestStorage
        }
        return .sha256(try Core.CanonicalJSON.encode(compilerProjection))
    }

    /// Stable document identity for project cache keys. Validated Catalog
    /// snapshots compute it once when loaded rather than serializing thousands
    /// of entries again for every downstream cache lookup.
    public func documentDigest() throws -> Core.Digest {
        if let documentDigestStorage { return documentDigestStorage }
        return .sha256(try Core.CanonicalJSON.encode(document))
    }

    /// Complete identity of a validated cached Catalog artifact. Builder
    /// snapshots reuse the content-addressed cache key; direct test or custom
    /// snapshots derive an equivalent identity from their actual contents.
    public func cacheIdentity() throws -> Core.Digest {
        if let cacheIdentityStorage { return cacheIdentityStorage }
        var hasher = Core.StableHasher(
            domain: "HLX.NativeAPICatalog.Snapshot.v1"
        )
        hasher.append(try documentDigest())
        hasher.append(try compilerProjectionDigest())
        return hasher.finalize()
    }

    /// Modules referenced through reexports, overlays, protocol defaults, or
    /// foreign declarations while this module was measured. Prepare follows
    /// this list automatically to construct the complete Catalog closure.
    public var referencedModules: [String] {
        compilerProjection.referencedModules
    }

    static func validated(
        document: NativeAPICatalog.Document,
        compilerProjection: NativeAPICatalog.CompilerProjection,
        cacheIdentity: Core.Digest? = nil,
        performance: BuildPerformance.Recorder? = nil
    ) throws -> Self {
        let snapshot = Self(
            document: document,
            compilerProjection: compilerProjection
        )
        if let performance {
            try performance.measure(
                "native_api_catalog.validate_document"
            ) {
                try document.validate()
            }
            try performance.measure(
                "native_api_catalog.validate_projection"
            ) {
                try compilerProjection.validatePublished(document: document)
            }
        } else {
            try snapshot.validateStorage()
        }
        let documentDigest = try cacheIdentity == nil
            ? Core.Digest.sha256(Core.CanonicalJSON.encode(document)) : nil
        let projectionDigest = try cacheIdentity == nil
            ? Core.Digest.sha256(Core.CanonicalJSON.encode(compilerProjection))
            : nil
        return Self(
            validatedDocument: document,
            compilerProjection: compilerProjection,
            cacheIdentity: cacheIdentity,
            documentDigest: documentDigest,
            compilerProjectionDigest: projectionDigest
        )
    }

    func validateIfNeeded() throws {
        guard !storageWasValidated else { return }
        try validateStorage()
    }

    private func validateStorage() throws {
        try document.validate()
        try compilerProjection.validatePublished(document: document)
    }
}

struct CompilerProjection: Codable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var sourceFileLogicalID: String
    var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
    var operations: [FrontendReceipt.Adapter.ImportedOperation]
    /// Stable Catalog entry keys aligned one-to-one with `operations` after
    /// projection. Raw compiler measurements leave this empty; persisted
    /// snapshots must populate it so consumers never rerun whole-module API
    /// classification on a cache hit.
    var publishedEntryKeys: [Core.NativeCall.Key] = []
    /// Project-independent NativeImport candidates produced once while the
    /// module Catalog is generated. Consumer builds only remap placeholder
    /// native TypeIDs into their Shell namespace; they do not rediscover or
    /// reclassify the complete module surface on every Prepare.
    var publishedCapabilities: [PublishedCapability] = []
    var modulesByDeclarationUSR: [String: String]
    var referencedModules: [String] = []

    struct PublishedCapability: Codable, Hashable, Sendable {
        var entryKey: Core.NativeCall.Key
        var record: InterfaceArchive.NativeImportRecord
        var binding: ShellBuildReceipt.NativeImportBinding
    }
}
}

extension NativeAPICatalog.CompilerProjection {
    func validate(moduleName: String) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              sourceFileLogicalID
                == NativeAPICatalog.Projector.sourceFileLogicalID(
                    moduleName: moduleName
                ),
              importedTypes.count <= 250_000,
              operations.count <= 250_000,
              publishedCapabilities.count <= 250_000,
              publishedEntryKeys.isEmpty
                || publishedEntryKeys.count == operations.count,
              publishedCapabilities.isEmpty
                || publishedCapabilities == publishedCapabilities.sorted(by: {
                    $0.entryKey < $1.entryKey
                }),
              modulesByDeclarationUSR.count <= 250_000,
              referencedModules.count <= 256,
              referencedModules == Array(Set(referencedModules)).sorted(),
              !referencedModules.contains(moduleName),
              importedTypes == importedTypes.sorted(by: {
                  ($0.canonicalName, $0.swiftType)
                      < ($1.canonicalName, $1.swiftType)
              }),
              Set(importedTypes.map(\.canonicalName)).count
                == importedTypes.count,
              importedTypes.allSatisfy({ type in
                  type.sourceFileLogicalID == sourceFileLogicalID
                      && type.nativeModuleName == nil
                      && type.importedModules == Array(
                          Set(type.importedModules)
                      ).sorted()
                      && type.importedModules.contains(moduleName)
              }),
              operations.allSatisfy({ operation in
                  operation.sourceFileLogicalID == sourceFileLogicalID
                      && operation.catalogEntry == nil
                      && operation.catalogAuthorityKey == nil
                      && operation.importedModules == Array(
                          Set(operation.importedModules)
                      ).sorted()
                      && operation.importedModules.contains(moduleName)
                      && !operation.isEmittedToDevice
              }),
              modulesByDeclarationUSR.allSatisfy({ usr, module in
                  !usr.isEmpty && usr.utf8.count <= 4_096
                      && module == moduleName
              }),
              (try? NativeAPICatalog.ModuleSelection.catalogModules(
                  referencedModules,
                  excluding: moduleName
              )) == referencedModules
        else {
            throw NativeAPICatalog.Error.invalid(
                "compiler projection is oversized or noncanonical"
            )
        }
        let normalizedTypes = try FrontendReceipt.Adapter()
            .mergeImportedNativeTypes(
                discoveredTypes: [],
                operationTypes: importedTypes
            )
        let expectedModulesByUSR = Dictionary(
            uniqueKeysWithValues: Set(operations.compactMap(\.declarationUSR))
                .map { ($0, moduleName) }
        )
        guard normalizedTypes == importedTypes,
              try FrontendReceipt.Adapter().mergeImportedOperations(operations)
                == operations,
              modulesByDeclarationUSR == expectedModulesByUSR
        else {
            throw NativeAPICatalog.Error.invalid(
                "compiler projection types, operations, or declaration modules are noncanonical"
            )
        }
    }

    func validatePublished(
        document: NativeAPICatalog.Document
    ) throws {
        let moduleName = document.identity.moduleName
        try validate(moduleName: moduleName)
        guard publishedEntryKeys.count == operations.count else {
            throw NativeAPICatalog.Error.invalid(
                "published compiler projection has no exact operation-to-entry index"
            )
        }
        let entriesByKey = Dictionary(
            uniqueKeysWithValues: document.entries.map { ($0.key, $0) }
        )
        guard Set(publishedEntryKeys) == Set(entriesByKey.keys) else {
            throw NativeAPICatalog.Error.invalid(
                "published compiler projection and Catalog entries disagree"
            )
        }
        let supportedEntries = document.entries.filter {
            $0.support.state == .supported
        }
        let supportedKeys = Set(supportedEntries.map(\.key))
        guard publishedCapabilities.count == supportedEntries.count,
              Set(publishedCapabilities.map(\.entryKey)) == supportedKeys,
              Set(publishedCapabilities.map(\.record.key)) == supportedKeys,
              Set(publishedCapabilities.map(\.binding.key)) == supportedKeys
        else {
            throw NativeAPICatalog.Error.invalid(
                "published compiler capabilities do not cover every supported Catalog entry exactly once"
            )
        }
        let placeholderTypeIDs = Set(importedTypes.map {
            NativeAPICatalog.Projector.placeholderTypeID(
                $0,
                moduleName: moduleName
            )
        })
        for capability in publishedCapabilities {
            guard let entry = entriesByKey[capability.entryKey] else {
                throw NativeAPICatalog.Error.invalid(
                    "published compiler capability names an absent Catalog entry"
                )
            }
            let record = capability.record
            let binding = capability.binding
            let referencedTypeIDs = (record.parameterTypes
                + [record.resultType]).reduce(into: Set<Core.TypeID>()) {
                    $0.formUnion($1.referencedNativeTypeIDs)
                }
            var differences: [String] = []
            if record.id != nil { differences.append("compact ID") }
            if record.isEmittedToDevice { differences.append("publication") }
            if record.key != entry.key { differences.append("record key") }
            if record.descriptor != entry.descriptor {
                differences.append("descriptor")
            }
            if record.contract != entry.contract {
                differences.append("contract")
            }
            if record.capability != .nativeImportsV1 {
                differences.append("required capability")
            }
            if record.parameterTypes.count
                != record.descriptor.logicalSignature.parameters.count {
                differences.append("logical parameter arity")
            }
            if !record.parameterProjection.isValid(
                logicalParameterCount: record.parameterTypes.count
            ) {
                differences.append("parameter projection")
            }
            if record.silMangledNames.isEmpty
                || record.silMangledNames
                    != Array(Set(record.silMangledNames)).sorted() {
                differences.append("compiler symbols")
            }
            if !referencedTypeIDs.isSubset(of: placeholderTypeIDs) {
                differences.append("placeholder native types")
            }
            if binding.key != entry.key { differences.append("binding key") }
            if !Self.binding(binding, matches: entry) {
                differences.append("binding")
            }
            guard differences.isEmpty else {
                throw NativeAPICatalog.Error.invalid(
                    "published compiler capability disagrees with Catalog entry "
                        + "\(entry.key) (\(entry.descriptor.canonicalCallee), "
                        + "backend=\(entry.descriptor.target.backend.rawValue), "
                        + "binding=\(binding.strategy.rawValue), "
                        + "nativeModule=\(binding.generated?.nativeModuleName ?? "none")); "
                        + "differing: " + differences.joined(separator: ", ")
                )
            }
        }
        for (operation, key) in zip(operations, publishedEntryKeys) {
            guard let entry = entriesByKey[key] else {
                throw NativeAPICatalog.Error.invalid(
                    "published compiler operation names an absent Catalog entry \(key)"
                )
            }
            var differences: [String] = []
            if entry.descriptor.target.module != moduleName {
                differences.append("module")
            }
            if entry.descriptor.logicalSignature.parameters.count
                != operation.parameterSwiftTypes.count {
                differences.append("parameter arity")
            }
            if entry.descriptor.logicalSignature.isThrowing
                != operation.mayThrow {
                differences.append("throws")
            }
            if entry.descriptor.effects.requiresMainActor
                != operation.requiresMainActor {
                differences.append("actor isolation")
            }
            if entry.descriptor.effects.isAsync {
                differences.append("async effect")
            }
            if !Self.operation(operation, matches: entry) {
                differences.append("call target")
            }
            let compilerIdentities = Set(
                operation.silReferences
                    + (operation.declarationUSR.map { [$0] } ?? [])
            )
            if compilerIdentities.isDisjoint(with: entry.compilerSymbols) {
                differences.append("compiler declaration")
            }
            guard differences.isEmpty else {
                throw NativeAPICatalog.Error.invalid(
                    "published compiler operation \(operation.ownerType)."
                        + "\(operation.baseName) is associated with "
                        + "\(entry.descriptor.canonicalCallee) using different "
                        + differences.joined(separator: ", ")
                )
            }
        }
        let boundaryTypes = FrontendReceipt.ImportedTypeIndex(
            types: importedTypes
        ).logicalBoundaryTypes(for: operations)
        guard boundaryTypes == importedTypes else {
            throw NativeAPICatalog.Error.invalid(
                "published compiler projection retains unused or missing native types"
            )
        }
    }

    private static func binding(
        _ binding: ShellBuildReceipt.NativeImportBinding,
        matches entry: NativeAPICatalog.Entry
    ) -> Bool {
        switch (entry.descriptor.target.backend, binding.strategy) {
        case (.objectiveCMessage, .objectiveCInvoker):
            return binding.factoryReference == nil
                && binding.generated == nil
                && binding.cFunction == nil
                && binding.importedModules.isEmpty
        case (.cFunction, .cInvoker):
            return binding.factoryReference == nil
                && binding.generated == nil
                && binding.cFunction?.moduleName
                    == entry.descriptor.target.module
                && binding.cFunction?.swiftName
                    == entry.descriptor.target.member
        case (.swiftAdapter, .generatedSwiftAdapter):
            return binding.factoryReference == nil
                && binding.generated != nil
                && binding.cFunction == nil
                && binding.generated?.nativeModuleName
                    == entry.descriptor.target.module
                && binding.importedModules.contains(
                    entry.descriptor.target.module
                )
        case (.builtin, .factory):
            return false
        case (.objectiveCMessage, _), (.cFunction, _), (.swiftAdapter, _),
             (.builtin, _):
            return false
        }
    }

    private static func operation(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        matches entry: NativeAPICatalog.Entry
    ) -> Bool {
        let target = entry.descriptor.target
        switch target.backend {
        case .objectiveCMessage:
            guard let evidence = operation.objectiveC else { return false }
            return target.entryPoint == evidence.selector
                && entry.descriptor.objectiveC?.runtimeClassName
                    == evidence.runtimeClassName
                && entry.descriptor.objectiveC?.dispatchClassName
                    == evidence.dispatchClassName
                && target.member == foreignMember(for: operation)
        case .cFunction:
            guard let evidence = operation.c else { return false }
            return target.entryPoint == evidence.symbol
                && target.member == operation.baseName
        case .swiftAdapter:
            return target.entryPoint.hasSuffix(
                swiftAdapterSuffix(for: operation)
            )
        case .builtin:
            return false
        }
    }

    private static func foreignMember(
        for operation: FrontendReceipt.Adapter.ImportedOperation
    ) -> String {
        switch operation.dispatch {
        case .instanceGetter, .staticGetter:
            operation.baseName + ".get"
        case .instanceSetter, .staticSetter:
            operation.baseName + ".set"
        case .instanceValueSetter:
            operation.baseName + ".mutate"
        case .initializer, .globalFunction, .staticMethod, .instanceMethod:
            callableReference(for: operation)
        case .nativeUpcast:
            "upcast"
        case .anyObjectBridge:
            "bridge"
        }
    }

    private static func swiftAdapterSuffix(
        for operation: FrontendReceipt.Adapter.ImportedOperation
    ) -> String {
        switch operation.dispatch {
        case .initializer:
            "." + callableReference(for: operation)
        case .nativeUpcast:
            ".upcast(from:\(operation.parameterSwiftTypes.first ?? ""))"
        case .anyObjectBridge:
            ".bridge(from:Swift.Any)"
        case .instanceGetter, .staticGetter:
            ".\(operation.baseName).get"
        case .instanceSetter, .staticSetter:
            ".\(operation.baseName).set"
        case .instanceValueSetter:
            ".\(operation.baseName).mutate"
        case .globalFunction, .staticMethod, .instanceMethod:
            "." + callableReference(for: operation) + ".call"
        }
    }

    private static func callableReference(
        for operation: FrontendReceipt.Adapter.ImportedOperation
    ) -> String {
        operation.baseName + "("
            + operation.argumentLabels.map {
                ($0 == "_" ? "_" : $0) + ":"
            }.joined() + ")"
    }
}

extension NativeAPICatalog {
enum Projector {}
}

extension NativeAPICatalog.Projector {
    struct ProjectionResult {
        var entries: [NativeAPICatalog.Entry]
        var entriesByOperation: [
            FrontendReceipt.Adapter.ImportedOperation: NativeAPICatalog.Entry
        ]
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
        var capabilities: [
            NativeAPICatalog.CompilerProjection.PublishedCapability
        ]
        var referencedModules: [String]
    }

    /// Identity shared by a compiler declaration and the binding generated
    /// from it. The public native-call callee is deliberately excluded: C and
    /// Objective-C projection replaces Swift's callable spelling with the
    /// foreign ABI identity after discovery.
    private struct GeneratedBindingKey: Hashable {
        var mangledName: String
        var sourceFileLogicalID: String
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String?
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var invocationParameterSwiftTypes: [String]?
        var resultSwiftType: String
        var importedModules: [String]
        var nativeModuleName: String?

        init(_ declaration: NativeImportDiscovery.Declaration) {
            mangledName = declaration.mangledName
            sourceFileLogicalID = declaration.sourceFileLogicalID
            dispatch = declaration.dispatch
            ownerType = declaration.ownerType
            baseName = declaration.baseName
            argumentLabels = declaration.argumentLabels
            parameterSwiftTypes = declaration.parameterSwiftTypes
            invocationParameterSwiftTypes =
                declaration.invocationParameterSwiftTypes
            resultSwiftType = declaration.resultSwiftType
            importedModules = declaration.importedModules
            nativeModuleName = declaration.nativeModuleName
        }

        init(_ candidate: NativeImportDiscovery.Candidate) {
            let generated = candidate.generatedBinding
            mangledName = generated.declarationMangledName
            sourceFileLogicalID = generated.sourceFileLogicalID
            dispatch = generated.dispatch
            ownerType = generated.ownerType
            baseName = generated.baseName
            argumentLabels = generated.argumentLabels
            parameterSwiftTypes = generated.parameterSwiftTypes
            invocationParameterSwiftTypes =
                generated.invocationParameterSwiftTypes
            resultSwiftType = generated.resultSwiftType
            importedModules = generated.importedModules
            nativeModuleName = generated.nativeModuleName
        }
    }

    static func sourceFileLogicalID(moduleName: String) -> String {
        "NativeAPICatalog/\(moduleName).swift"
    }

    static func entries(
        projection: NativeAPICatalog.CompilerProjection,
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [NativeAPICatalog.Entry] {
        try project(
            projection: projection,
            identity: identity,
            invocation: invocation
        ).entries
    }

    static func project(
        projection: NativeAPICatalog.CompilerProjection,
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> ProjectionResult {
        try projection.validate(moduleName: identity.moduleName)
        guard projection.publishedEntryKeys.isEmpty else {
            throw NativeAPICatalog.Error.invalid(
                "a published compiler projection cannot be projected again"
            )
        }
        let nativeTypes = placeholderNativeTypes(
            projection.importedTypes,
            moduleName: identity.moduleName
        )
        // A generic Swift implementation may back several distinct overlay
        // types. Source discovery must fail closed when it has only that SIL
        // symbol, but a module Catalog also has the exact owner, declaration
        // USR, and logical signature measured by its dedicated probe. Project
        // each logical operation independently so a shared implementation
        // cannot collapse or reject otherwise distinct APIs.
        var declarations: [NativeImportDiscovery.Declaration] = []
        var declarationUSRsByCallee: [String: Set<String>] = [:]
        var operationIndicesByDeclaration: [
            GeneratedBindingKey: Set<Int>
        ] = [:]
        for (operationIndex, operation) in projection.operations.enumerated() {
            let projected = try FrontendReceipt.Adapter()
                .makeImportedOperationDeclarations(
                    [operation],
                    moduleName: invocation.moduleName,
                    nativeTypes: nativeTypes
                )
            declarations += projected
            for declaration in projected {
                operationIndicesByDeclaration[
                    GeneratedBindingKey(declaration),
                    default: []
                ].insert(operationIndex)
            }
            guard let usr = operation.declarationUSR else { continue }
            for declaration in projected {
                declarationUSRsByCallee[
                    declaration.canonicalCallee,
                    default: []
                ].insert(usr)
            }
        }
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.native-api-catalog",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.native-api-catalog",
                buildNumber: "1",
                seed: identity.cacheKey.hex
            ),
            machOUUIDs: [],
            targetTriple: identity.targetTriple,
            minimumOS: identity.minimumDeployment,
            xcodeBuild: identity.xcodeProductBuild,
            sdkBuild: identity.sdkProductBuild,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: identity.cacheKey
        )
        let configuration = PatchConfiguration.Document
            .automaticProjectPolicy(moduleName: invocation.moduleName)
        var kinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:]
        for type in projection.importedTypes {
            let typeID = placeholderTypeID(
                type,
                moduleName: identity.moduleName
            )
            if let existing = kinds[typeID], existing != type.kind {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog placeholder type identity has conflicting kinds"
                )
            }
            kinds[typeID] = type.kind
        }
        let discovery = try NativeImportDiscovery.Engine().discover(
            declarations: declarations,
            metadata: metadata,
            configuration: configuration,
            nativeTypeKinds: kinds
        )
        var entries: [NativeAPICatalog.Entry] = []
        entries.reserveCapacity(discovery.candidates.count)
        var entriesByOperation: [
            FrontendReceipt.Adapter.ImportedOperation: NativeAPICatalog.Entry
        ] = [:]
        var capabilities: [
            NativeAPICatalog.CompilerProjection.PublishedCapability
        ] = []
        var publishedOperationIndices = Set<Int>()
        var referencedModules = Set(projection.referencedModules)
        for candidate in discovery.candidates {
            let record = candidate.record
            // VM-native standard-library operations are classified before
            // Catalog-backed native calls. Publishing a second descriptor for
            // them would create duplicate authority in every consumer Shell.
            if NativeImportCatalog.Builtins.automaticCallees.contains(
                record.descriptor.canonicalCallee
            ) {
                continue
            }
            if record.descriptor.target.module != identity.moduleName {
                // Reexports and overlays can surface Swift, Objective-C, or C
                // declarations owned by another module. They cannot enter
                // this document, but Prepare must follow their owning module
                // so the overall Catalog closure remains complete.
                // The generated probe module itself is only an evidence
                // carrier; its private helper declarations are never a native
                // dependency and cannot be imported by a consumer build.
                if record.descriptor.target.module != invocation.moduleName {
                    referencedModules.insert(record.descriptor.target.module)
                }
                continue
            }
            let projectionKey = GeneratedBindingKey(candidate)
            guard let operationIndices = operationIndicesByDeclaration[
                projectionKey
            ], !operationIndices.isEmpty else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog candidate cannot be mapped back to its compiler operation: "
                        + "\(record.descriptor.canonicalCallee), "
                        + "symbol=\(projectionKey.mangledName), "
                        + "owner=\(projectionKey.ownerType ?? "none"), "
                        + "module=\(projectionKey.nativeModuleName ?? "none")"
                )
            }
            publishedOperationIndices.formUnion(operationIndices)
            let strategy: NativeAPICatalog.BindingStrategy = switch
                record.descriptor.target.backend {
            case .objectiveCMessage: .objectiveCInvoker
            case .cFunction: .cInvoker
            case .swiftAdapter: .swiftAdapter
            case .builtin: .builtin
            }
            let adapterID: String? = switch strategy {
            case .swiftAdapter, .builtin:
                "\(identity.moduleName).\(record.key.rawValue.hex)"
            case .objectiveCInvoker, .cInvoker:
                nil
            }
            let compilerSymbols = Array(Set(
                record.silMangledNames
                    + (declarationUSRsByCallee[
                        record.descriptor.canonicalCallee
                    ] ?? [])
            ).sorted().prefix(64))
            let entry = try NativeAPICatalog.Entry(
                descriptor: record.descriptor,
                contract: record.contract,
                swiftNames: [record.descriptor.canonicalCallee],
                compilerSymbols: compilerSymbols,
                binding: .init(
                    strategy: strategy,
                    adapterID: adapterID,
                    importedModules: Array(Set(
                        candidate.generatedBinding.importedModules
                            + [identity.moduleName]
                    )).sorted()
                )
            )
            entries.append(entry)
            capabilities.append(.init(
                entryKey: entry.key,
                record: record,
                binding: try candidate.shellBuildBinding(
                    catalogModuleName: identity.moduleName
                )
            ))
            for operationIndex in operationIndices {
                let operation = projection.operations[operationIndex]
                if let existing = entriesByOperation[operation],
                   existing != entry {
                    throw NativeAPICatalog.Error.invalid(
                        "Catalog operation maps to conflicting published entries"
                    )
                }
                entriesByOperation[operation] = entry
            }
        }
        let publishedOperations = publishedOperationIndices.sorted().map {
            projection.operations[$0]
        }
        return .init(
            entries: entries.sorted { $0.key < $1.key },
            entriesByOperation: entriesByOperation,
            importedTypes: FrontendReceipt.ImportedTypeIndex(
                types: projection.importedTypes
            ).logicalBoundaryTypes(for: publishedOperations),
            operations: publishedOperations,
            capabilities: capabilities.sorted { $0.entryKey < $1.entryKey },
            referencedModules: try NativeAPICatalog.ModuleSelection
                .catalogModules(
                    Array(referencedModules.subtracting([
                        invocation.moduleName,
                    ])),
                    excluding: identity.moduleName
                )
        )
    }

    private static func placeholderNativeTypes(
        _ types: [FrontendReceipt.Adapter.ImportedNativeType],
        moduleName: String
    ) -> [String: Core.TypeID] {
        var exact: [String: Core.TypeID] = [:]
        var candidates: [String: Set<Core.TypeID>] = [:]
        for type in types {
            let placeholder = placeholderTypeID(type, moduleName: moduleName)
            exact[type.canonicalName] = placeholder
            var names = Set(
                [type.canonicalName, type.swiftType,
                 "__C.\(type.canonicalName)"] + type.aliases
            )
            let relativeNames = names
            for module in type.importedModules {
                for name in relativeNames where !name.hasPrefix(module + ".") {
                    names.insert(module + "." + name)
                }
            }
            for name in names {
                candidates[name, default: []].insert(placeholder)
            }
        }
        var result = exact
        for (name, typeIDs) in candidates
        where result[name] == nil && typeIDs.count == 1 {
            result[name] = typeIDs.first
        }
        return result
    }

    static func placeholderTypeID(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        moduleName: String
    ) -> Core.TypeID {
        Core.TypeID(rawValue: .sha256(
            "HLX.APICatalogType.v1:\(moduleName):\(type.canonicalName)"
        ))
    }
}
