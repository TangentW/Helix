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

    init(
        document: NativeAPICatalog.Document,
        compilerProjection: CompilerProjection
    ) {
        self.document = document
        self.compilerProjection = compilerProjection
    }

    /// Stable opaque identity for frontend/build-cache keys. Callers can bind
    /// cached compiler facts without gaining access to their private schema.
    public func compilerProjectionDigest() throws -> Core.Digest {
        .sha256(try Core.CanonicalJSON.encode(compilerProjection))
    }

    /// Modules referenced through reexports, overlays, protocol defaults, or
    /// foreign declarations while this module was measured. Prepare follows
    /// this list automatically to construct the complete Catalog closure.
    public var referencedModules: [String] {
        compilerProjection.referencedModules
    }
}

struct CompilerProjection: Codable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var sourceFileLogicalID: String
    var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
    var operations: [FrontendReceipt.Adapter.ImportedOperation]
    var modulesByDeclarationUSR: [String: String]
    var referencedModules: [String] = []
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
        var publishedOperationIndices = Set<Int>()
        var referencedModules = Set(projection.referencedModules)
        for candidate in discovery.candidates {
            let record = candidate.record
            if record.descriptor.target.module != identity.moduleName {
                // Reexports and overlays can surface Swift, Objective-C, or C
                // declarations owned by another module. They cannot enter
                // this document, but Prepare must follow their owning module
                // so the overall Catalog closure remains complete.
                referencedModules.insert(record.descriptor.target.module)
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
            referencedModules: try NativeAPICatalog.ModuleSelection
                .catalogModules(
                    Array(referencedModules),
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

    private static func placeholderTypeID(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        moduleName: String
    ) -> Core.TypeID {
        Core.TypeID(rawValue: .sha256(
            "HLX.APICatalogType.v1:\(moduleName):\(type.canonicalName)"
        ))
    }
}
