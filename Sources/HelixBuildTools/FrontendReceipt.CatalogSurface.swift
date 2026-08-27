import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
enum CatalogSurface {}
}

extension FrontendReceipt.CatalogSurface {
    struct MaterializedCapability: Sendable {
        var record: InterfaceArchive.NativeImportRecord
        var binding: ShellBuildReceipt.NativeImportBinding
    }

    struct Resolution: Sendable {
        var documents: [NativeAPICatalog.Document]
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
        var capabilities: [
            NativeAPICatalog.CompilerProjection.PublishedCapability
        ]
        var nativeTypeNamesByPlaceholder: [Core.TypeID: String]
        var modulesByDeclarationUSR: [String: String]
        var hitModules: [String]
        var missingModules: [String]
    }

    static func resolve(
        snapshots: [NativeAPICatalog.Snapshot],
        request: FrontendReceipt.Request,
        importedModules: [String],
        toolchain: ReleaseCompiler.ToolchainIdentity
    ) throws -> Resolution {
        guard request.callingSurfacePolicy.expandsImportedModules else {
            guard snapshots.isEmpty else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog snapshots require a managed calling-surface policy"
                )
            }
            return .init(
                documents: [],
                importedTypes: [],
                operations: [],
                capabilities: [],
                nativeTypeNamesByPlaceholder: [:],
                modulesByDeclarationUSR: [:],
                hitModules: [],
                missingModules: []
            )
        }

        let moduleName = request.metadata.frontendInvocation.moduleName
        var requiredModules = try NativeAPICatalog.ModuleSelection
            .catalogModules(importedModules, excluding: moduleName)
        let languageMode = try NativeAPICatalog.Planner.swiftLanguageMode(
            in: request.metadata.frontendInvocation.semanticArguments
        )
        let order = snapshots.map {
            $0.document.identity.moduleName + "\u{0}"
                + $0.document.identity.cacheKey.hex
        }
        guard snapshots.count <= 256,
              order == order.sorted(by: <),
              Set(snapshots.map { $0.document.identity.moduleName }).count
                == order.count
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "Native API Catalog snapshots are duplicated or noncanonical"
            )
        }

        var snapshotsByModule: [String: NativeAPICatalog.Snapshot] = [:]
        for snapshot in snapshots {
            let document = snapshot.document
            let identity = document.identity
            do {
                try snapshot.validateIfNeeded()
            } catch {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog \(identity.moduleName) is invalid: \(error)"
                )
            }
            guard identity.xcodeProductBuild == request.metadata.xcodeBuild,
                  identity.sdkProductBuild == request.metadata.sdkBuild,
                  identity.compilerFingerprint == toolchain.fingerprint,
                  identity.targetTriple == request.metadata.targetTriple,
                  identity.minimumDeployment == request.metadata.minimumOS,
                  identity.swiftLanguageMode == languageMode,
                  identity.moduleName != moduleName
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog \(identity.moduleName) disagrees with the current compiler, SDK, target, deployment, or language mode"
                )
            }
            snapshotsByModule[identity.moduleName] = snapshot
        }

        var requiredModuleSet = Set(requiredModules)
        while true {
            let referenced = requiredModuleSet.compactMap {
                snapshotsByModule[$0]
            }.flatMap(\.referencedModules)
            let expanded = try NativeAPICatalog.ModuleSelection.catalogModules(
                Array(requiredModuleSet) + referenced,
                excluding: moduleName
            )
            guard expanded.count <= 256 else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog dependency closure exceeds 256 modules"
                )
            }
            let expandedSet = Set(expanded)
            if expandedSet == requiredModuleSet { break }
            requiredModuleSet = expandedSet
        }
        requiredModules = requiredModuleSet.sorted()

        let consumed = requiredModules.compactMap { snapshotsByModule[$0] }
        let documents = consumed.map(\.document)
        do {
            _ = try NativeAPICatalog.Registry(validatedDocuments: documents)
        } catch {
            throw FrontendReceipt.Error.invalidRequest(
                "Native API Catalog snapshots conflict: \(error)"
            )
        }
        // Clang USRs identify the declaring method, not the concrete class
        // through which an inherited initializer or member was measured. Its
        // Catalog entry remains exact through the owner and descriptor; the
        // USR-only module hint is authoritative only when the complete
        // Catalog closure agrees on one module.
        let modulesByDeclarationUSR = uniqueDeclarationModules(
            consumed.map { $0.compilerProjection.modulesByDeclarationUSR }
        )
        let hitModules = consumed.map { $0.document.identity.moduleName }
            .sorted()
        let missingModules = requiredModules.filter {
            snapshotsByModule[$0] == nil
        }
        if request.callingSurfacePolicy == .managedProductionModule,
           !missingModules.isEmpty {
            throw FrontendReceipt.Error.invalidRequest(
                "production Native API Catalog coverage is incomplete; missing modules: "
                    + missingModules.joined(separator: ", ")
            )
        }
        var operations: [FrontendReceipt.Adapter.ImportedOperation] = []
        for snapshot in consumed {
            let module = snapshot.document.identity.moduleName
            let entriesByKey = Dictionary(uniqueKeysWithValues:
                snapshot.document.entries.map { ($0.key, $0) }
            )
            for (original, key) in zip(
                snapshot.compilerProjection.operations,
                snapshot.compilerProjection.publishedEntryKeys
            ) {
                guard let entry = entriesByKey[key] else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog \(module) operation has no indexed entry"
                    )
                }
                var operation = original
                operation.catalogEntry = entry
                operation.catalogAuthorityKey = entry.key
                operations.append(operation)
            }
        }
        return .init(
            documents: documents,
            importedTypes: consumed.flatMap { snapshot in
                snapshot.compilerProjection.importedTypes.map { type in
                    var type = type
                    type.nativeModuleName = snapshot.document.identity.moduleName
                    return type
                }
            },
            operations: operations,
            capabilities: consumed.flatMap {
                $0.compilerProjection.publishedCapabilities
            }.sorted { $0.entryKey < $1.entryKey },
            nativeTypeNamesByPlaceholder: try nativeTypeNamesByPlaceholder(
                consumed
            ),
            modulesByDeclarationUSR: modulesByDeclarationUSR,
            hitModules: hitModules,
            missingModules: missingModules
        )
    }

    private static func nativeTypeNamesByPlaceholder(
        _ snapshots: [NativeAPICatalog.Snapshot]
    ) throws -> [Core.TypeID: String] {
        var result: [Core.TypeID: String] = [:]
        for snapshot in snapshots {
            let module = snapshot.document.identity.moduleName
            for type in snapshot.compilerProjection.importedTypes {
                let placeholder = NativeAPICatalog.Projector.placeholderTypeID(
                    type,
                    moduleName: module
                )
                if let existing = result[placeholder],
                   existing != type.canonicalName {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog placeholder TypeID collision"
                    )
                }
                result[placeholder] = type.canonicalName
            }
        }
        return result
    }

    static func materializeCapabilities(
        _ resolution: Resolution,
        nativeTypes: [String: Core.TypeID],
        emittedSymbols: Set<String>,
        emitCompleteSurface: Bool
    ) throws -> [MaterializedCapability] {
        var typeRemapping: [Core.TypeID: Core.TypeID] = [:]
        for (placeholder, canonicalName) in
            resolution.nativeTypeNamesByPlaceholder
        {
            guard let concrete = nativeTypes[canonicalName] else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog type \(canonicalName) has no project TypeID"
                )
            }
            typeRemapping[placeholder] = concrete
        }
        let typeHexRemapping = Dictionary(uniqueKeysWithValues:
            typeRemapping.map {
                ($0.key.rawValue.hex, $0.value.rawValue.hex)
            }
        )
        var materialized = try resolution.capabilities.map { capability in
            var record = capability.record
            var binding = capability.binding
            record.parameterTypes = try record.parameterTypes.map {
                try remap($0, nativeTypes: typeRemapping)
            }
            record.resultType = try remap(
                record.resultType,
                nativeTypes: typeRemapping
            )
            record.silMangledNames = record.silMangledNames.map {
                remapNativeBridgeSymbol($0, typeHex: typeHexRemapping)
            }.sorted()
            if var generated = binding.generated {
                generated.declarationMangledName = remapNativeBridgeSymbol(
                    generated.declarationMangledName,
                    typeHex: typeHexRemapping
                )
                binding.generated = generated
            }
            return MaterializedCapability(
                record: record,
                binding: binding
            )
        }

        // Every physical symbol variant must share one publication state.
        // Grow from source-observed symbols so default-argument and generic
        // projections backed by the same SIL implementation move together.
        var activeSymbols = emittedSymbols
        if !emitCompleteSurface {
            var changed = true
            while changed {
                changed = false
                for capability in materialized
                where !Set(capability.record.silMangledNames)
                    .isDisjoint(with: activeSymbols) {
                    let previous = activeSymbols.count
                    activeSymbols.formUnion(capability.record.silMangledNames)
                    changed = changed || activeSymbols.count != previous
                }
            }
        }
        for index in materialized.indices {
            materialized[index].record.isEmittedToDevice =
                emitCompleteSurface
                || !Set(materialized[index].record.silMangledNames)
                    .isDisjoint(with: activeSymbols)
        }
        return materialized.sorted { $0.record.key < $1.record.key }
    }

    private static func remap(
        _ type: Bytecode.ValueType,
        nativeTypes: [Core.TypeID: Core.TypeID]
    ) throws -> Bytecode.ValueType {
        switch type {
        case let .native(placeholder):
            guard let concrete = nativeTypes[placeholder] else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog capability references an unknown placeholder TypeID"
                )
            }
            return .native(concrete)
        case let .array(element):
            return .array(try remap(element, nativeTypes: nativeTypes))
        case let .dictionary(key, value):
            return .dictionary(
                key: try remap(key, nativeTypes: nativeTypes),
                value: try remap(value, nativeTypes: nativeTypes)
            )
        case let .set(element):
            return .set(try remap(element, nativeTypes: nativeTypes))
        case let .address(element):
            return .address(try remap(element, nativeTypes: nativeTypes))
        case let .mutableCell(element):
            return .mutableCell(try remap(element, nativeTypes: nativeTypes))
        case let .nonOwningReference(kind, element):
            return .nonOwningReference(
                kind: kind,
                pointee: try remap(element, nativeTypes: nativeTypes)
            )
        case let .arrayState(kind, element):
            return .arrayState(
                kind: kind,
                element: try remap(element, nativeTypes: nativeTypes)
            )
        case let .dictionaryState(key, value):
            return .dictionaryState(
                key: try remap(key, nativeTypes: nativeTypes),
                value: try remap(value, nativeTypes: nativeTypes)
            )
        case let .closure(signature):
            return .closure(.init(
                parameters: try signature.parameters.map {
                    try remap($0, nativeTypes: nativeTypes)
                },
                parameterConventions: signature.parameterConventions,
                result: try remap(
                    signature.result,
                    nativeTypes: nativeTypes
                ),
                thrownType: try signature.thrownType.map {
                    try remap($0, nativeTypes: nativeTypes)
                },
                effects: signature.effects
            ))
        case let .tuple(elements):
            return .tuple(try elements.map {
                try remap($0, nativeTypes: nativeTypes)
            })
        case let .optional(element):
            return .optional(try remap(element, nativeTypes: nativeTypes))
        case .void, .never, .bool, .integer, .float, .string, .any,
             .local, .error:
            return type
        }
    }

    private static func remapNativeBridgeSymbol(
        _ symbol: String,
        typeHex: [String: String]
    ) -> String {
        let unaryPrefixes = [
            "$hlx_native_raw_init_",
            "$hlx_native_any_object_bridge_",
            "$hlx_native_option_set_literal_",
            "$hlx_native_selector_init_",
        ]
        for prefix in unaryPrefixes where symbol.hasPrefix(prefix) {
            let value = String(symbol.dropFirst(prefix.count))
            guard let replacement = typeHex[value] else { return symbol }
            return prefix + replacement
        }
        let upcastPrefix = "$hlx_native_upcast_"
        guard symbol.hasPrefix(upcastPrefix) else { return symbol }
        let components = symbol.dropFirst(upcastPrefix.count).split(
            separator: "_",
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else { return symbol }
        let source = String(components[0])
        let target = String(components[1])
        guard let remappedSource = typeHex[source],
              let remappedTarget = typeHex[target]
        else { return symbol }
        return upcastPrefix + remappedSource + "_" + remappedTarget
    }

    static func uniqueDeclarationModules(
        _ mappings: [[String: String]]
    ) -> [String: String] {
        var candidates: [String: Set<String>] = [:]
        for mapping in mappings {
            for (usr, module) in mapping {
                candidates[usr, default: []].insert(module)
            }
        }
        return Dictionary(uniqueKeysWithValues: candidates.compactMap {
            usr, modules in
            guard modules.count == 1, let module = modules.first else {
                return nil
            }
            return (usr, module)
        })
    }

    static func operationsRelevantToSource(
        _ catalog: [FrontendReceipt.Adapter.ImportedOperation],
        source: [FrontendReceipt.Adapter.ImportedOperation]
    ) -> [FrontendReceipt.Adapter.ImportedOperation] {
        guard !source.isEmpty else { return [] }
        let sourceUSRs = Set(source.compactMap(declarationUSR))
        let sourceSymbols = Set(source.flatMap(\.silReferences))
        let sourceObjectiveCTargets = Set(source.compactMap { operation in
            operation.objectiveC.map {
                ObjectiveCTarget(
                    runtimeClassName: $0.runtimeClassName,
                    selector: $0.selector,
                    dispatch: operation.dispatch
                )
            }
        })
        let sourceCTargets = Set(source.compactMap { operation in
            operation.c.map {
                CTarget(symbol: $0.symbol, dispatch: operation.dispatch)
            }
        })
        let sourceCompilerOperations = Set(source.compactMap { operation in
            operation.compilerOperation.map {
                CompilerOperationTarget(
                    operation: $0,
                    dispatch: operation.dispatch,
                    baseName: operation.baseName
                )
            }
        })
        return catalog.filter { operation in
            if let usr = declarationUSR(operation),
               sourceUSRs.contains(usr) {
                return true
            }
            if !Set(operation.silReferences).isDisjoint(
                with: sourceSymbols
            ) {
                return true
            }
            if let evidence = operation.objectiveC,
               sourceObjectiveCTargets.contains(.init(
                    runtimeClassName: evidence.runtimeClassName,
                    selector: evidence.selector,
                    dispatch: operation.dispatch
               )) {
                return true
            }
            if let evidence = operation.c,
               sourceCTargets.contains(.init(
                    symbol: evidence.symbol,
                    dispatch: operation.dispatch
               )) {
                return true
            }
            if let compilerOperation = operation.compilerOperation,
               sourceCompilerOperations.contains(.init(
                    operation: compilerOperation,
                    dispatch: operation.dispatch,
                    baseName: operation.baseName
               )) {
                return true
            }
            return false
        }
    }

    private struct ObjectiveCTarget: Hashable {
        var runtimeClassName: String
        var selector: String
        var dispatch: NativeImportDiscovery.Dispatch
    }

    private struct CTarget: Hashable {
        var symbol: String
        var dispatch: NativeImportDiscovery.Dispatch
    }

    private struct CompilerOperationTarget: Hashable {
        var operation: FrontendReceipt.Adapter.ImportedOperation
            .CompilerOperation
        var dispatch: NativeImportDiscovery.Dispatch
        var baseName: String
    }

    private static func declarationUSR(
        _ operation: FrontendReceipt.Adapter.ImportedOperation
    ) -> String? {
        operation.declarationUSR
            ?? operation.objectiveC?.declarationUSR
            ?? operation.c?.declarationUSR
    }

    static func validatePublishedEntries(
        _ documents: [NativeAPICatalog.Document],
        receipt: ShellBuildReceipt.Document,
        policy: FrontendReceipt.CallingSurfacePolicy,
        diagnostics: [Core.Diagnostic] = [],
        discoveredCandidates: [NativeImportDiscovery.Candidate] = []
    ) throws {
        guard !documents.isEmpty else { return }
        let records = Dictionary(
            uniqueKeysWithValues: receipt.nativeImportCandidates.map {
                ($0.key, $0)
            }
        )
        let bindings = Dictionary(
            uniqueKeysWithValues: receipt.nativeImportBindings.map {
                ($0.key, $0)
            }
        )
        for document in documents {
            for entry in document.entries
            where entry.support.state == .supported {
                let context = "\(entry.descriptor.canonicalCallee) "
                    + "[\(entry.key)]"
                guard let record = records[entry.key] else {
                    let sameNameRecords = records.values.filter {
                        $0.descriptor.canonicalCallee
                            == entry.descriptor.canonicalCallee
                    }
                    let alternatives = sameNameRecords.map {
                        let differences = descriptorDifferenceFields(
                            entry.descriptor,
                            $0.descriptor
                        ).joined(separator: ", ")
                        return "\($0.key) (different: \(differences))"
                    }.sorted()
                    let detail = alternatives.isEmpty
                        ? "no call with the same canonical name exists"
                        : "same-name calls use keys: "
                            + alternatives.joined(separator: ", ")
                    let rejectionDetails = diagnostics.filter {
                        $0.message.hasPrefix(
                            entry.descriptor.canonicalCallee + ":"
                        )
                    }.map { "\($0.code): \($0.message)" }
                    let relevantDiagnostics = rejectionDetails.isEmpty
                        ? diagnostics.prefix(16).map {
                            "\($0.code): \($0.message)"
                        } : rejectionDetails
                    let rejection = relevantDiagnostics.isEmpty
                        ? "" : "; discovery reported "
                            + relevantDiagnostics.joined(separator: " | ")
                    let discovered = discoveredCandidates.filter {
                        $0.record.descriptor.canonicalCallee
                            == entry.descriptor.canonicalCallee
                    }.map { $0.record.key.description }.sorted()
                    let modulePrefix = document.identity.moduleName + "."
                    let moduleCandidates = discoveredCandidates.filter {
                        $0.record.descriptor.canonicalCallee.hasPrefix(
                            modulePrefix
                        )
                    }.map { $0.record.descriptor.canonicalCallee }.sorted()
                    let discoveryDetail: String
                    if !discovered.isEmpty {
                        discoveryDetail = "; discovery produced keys: "
                            + discovered.joined(separator: ", ")
                    } else if !moduleCandidates.isEmpty {
                        discoveryDetail = "; discovery produced other module calls: "
                            + moduleCandidates.joined(separator: ", ")
                    } else if !discoveredCandidates.isEmpty {
                        discoveryDetail = "; discovery produced calls: "
                            + discoveredCandidates.prefix(16).map {
                                $0.record.descriptor.canonicalCallee
                            }.joined(separator: ", ")
                    } else {
                        discoveryDetail = ""
                    }
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog entry \(context) was not published; "
                            + detail + rejection + discoveryDetail
                    )
                }
                guard record.descriptor == entry.descriptor else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog entry \(context) was published with a different call descriptor"
                    )
                }
                guard record.contract == entry.contract else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog entry \(context) was published with a different callback or effect contract"
                    )
                }
                guard let binding = bindings[entry.key] else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog entry \(context) has no executable binding"
                    )
                }
                guard bindingMatches(
                    entry: entry,
                    binding: binding,
                    moduleName: document.identity.moduleName
                ) else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog entry \(context) has a mismatched Invoker or Adapter binding"
                    )
                }
                guard policy != .managedProductionModule
                        || record.isEmittedToDevice
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "production Native API Catalog entry \(context) was not emitted into the Release capability baseline"
                    )
                }
            }
        }
    }

    private static func bindingMatches(
        entry: NativeAPICatalog.Entry,
        binding: ShellBuildReceipt.NativeImportBinding,
        moduleName: String
    ) -> Bool {
        switch entry.binding?.strategy {
        case .objectiveCInvoker:
            return binding.strategy == .objectiveCInvoker
                && binding.generated == nil
                && binding.cFunction == nil
        case .cInvoker:
            return binding.strategy == .cInvoker
                && binding.generated == nil
                && binding.cFunction?.moduleName == moduleName
        case .swiftAdapter:
            return binding.strategy == .generatedSwiftAdapter
                && binding.generated?.nativeModuleName == moduleName
        case .builtin:
            return binding.strategy == .factory
        case nil:
            return false
        }
    }

    private static func descriptorDifferenceFields(
        _ expected: Core.NativeCall.Descriptor,
        _ actual: Core.NativeCall.Descriptor
    ) -> [String] {
        var fields: [String] = []
        if expected.target != actual.target { fields.append("target") }
        if expected.logicalSignature != actual.logicalSignature {
            fields.append("logical signature")
        }
        if expected.physicalSignature != actual.physicalSignature {
            fields.append("physical signature")
        }
        if expected.objectiveC != actual.objectiveC {
            fields.append("Objective-C metadata")
        }
        if expected.effects != actual.effects { fields.append("effects") }
        if expected.availability != actual.availability {
            fields.append("availability")
        }
        return fields.isEmpty ? ["unknown field"] : fields
    }
}
