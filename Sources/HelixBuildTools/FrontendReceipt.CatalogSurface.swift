import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
enum CatalogSurface {}
}

extension FrontendReceipt.CatalogSurface {
    struct Resolution: Sendable {
        var documents: [NativeAPICatalog.Document]
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
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
        var projectionsByModule: [
            String: NativeAPICatalog.Projector.ProjectionResult
        ] = [:]
        for snapshot in snapshots {
            let document = snapshot.document
            let identity = document.identity
            do {
                try document.validate()
                try snapshot.compilerProjection.validate(
                    moduleName: identity.moduleName
                )
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
            let projected: NativeAPICatalog.Projector.ProjectionResult
            do {
                projected = try NativeAPICatalog.Projector.project(
                    projection: snapshot.compilerProjection,
                    identity: identity,
                    invocation: request.metadata.frontendInvocation
                )
            } catch {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog \(identity.moduleName) cannot reproduce its compiler projection: \(error)"
                )
            }
            guard projected.entries == document.entries,
                  projected.importedTypes
                    == snapshot.compilerProjection.importedTypes,
                  projected.operations == snapshot.compilerProjection.operations
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog \(identity.moduleName) document and compiler projection disagree"
                )
            }
            snapshotsByModule[identity.moduleName] = snapshot
            projectionsByModule[identity.moduleName] = projected
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
            _ = try NativeAPICatalog.Registry(documents: documents)
        } catch {
            throw FrontendReceipt.Error.invalidRequest(
                "Native API Catalog snapshots conflict: \(error)"
            )
        }
        var modulesByDeclarationUSR: [String: String] = [:]
        for snapshot in consumed {
            for (usr, module) in snapshot.compilerProjection
                .modulesByDeclarationUSR {
                if let existing = modulesByDeclarationUSR[usr],
                   existing != module {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog declaration \(usr) has conflicting module ownership"
                    )
                }
                modulesByDeclarationUSR[usr] = module
            }
        }
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
            guard let projected = projectionsByModule[module] else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Native API Catalog \(module) has no validated projection"
                )
            }
            for original in snapshot.compilerProjection.operations {
                guard let entry = projected.entriesByOperation[original] else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "Native API Catalog \(module) operation has no published entry"
                    )
                }
                var operation = original
                operation.catalogEntry = entry
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
            modulesByDeclarationUSR: modulesByDeclarationUSR,
            hitModules: hitModules,
            missingModules: missingModules
        )
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
