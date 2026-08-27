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
}

struct CompilerProjection: Codable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var sourceFileLogicalID: String
    var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
    var operations: [FrontendReceipt.Adapter.ImportedOperation]
    var modulesByDeclarationUSR: [String: String]
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
              importedTypes == importedTypes.sorted(by: {
                  ($0.canonicalName, $0.swiftType)
                      < ($1.canonicalName, $1.swiftType)
              }),
              Set(importedTypes.map(\.canonicalName)).count
                == importedTypes.count,
              importedTypes.allSatisfy({ type in
                  type.sourceFileLogicalID == sourceFileLogicalID
                      && type.importedModules == Array(
                          Set(type.importedModules)
                      ).sorted()
                      && type.importedModules.contains(moduleName)
              }),
              operations.allSatisfy({ operation in
                  operation.sourceFileLogicalID == sourceFileLogicalID
                      && operation.importedModules == Array(
                          Set(operation.importedModules)
                      ).sorted()
                      && operation.importedModules.contains(moduleName)
                      && !operation.isEmittedToDevice
              }),
              modulesByDeclarationUSR.allSatisfy({ usr, module in
                  !usr.isEmpty && usr.utf8.count <= 4_096
                      && module == moduleName
              })
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
    static func sourceFileLogicalID(moduleName: String) -> String {
        "NativeAPICatalog/\(moduleName).swift"
    }

    static func entries(
        projection: NativeAPICatalog.CompilerProjection,
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [NativeAPICatalog.Entry] {
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
        for operation in projection.operations {
            let projected = try FrontendReceipt.Adapter()
                .makeImportedOperationDeclarations(
                    [operation],
                    moduleName: invocation.moduleName,
                    nativeTypes: nativeTypes
                )
            declarations += projected
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
        for candidate in discovery.candidates {
            let record = candidate.record
            if record.descriptor.target.module != identity.moduleName {
                // Symbol Graphs can surface a protocol-extension default from
                // another Swift module on a concrete local type. It is not a
                // declaration owned by this module and cannot enter this
                // module's Catalog merely because its probe compiled here.
                guard record.descriptor.target.backend == .swiftAdapter else {
                    throw NativeAPICatalog.Error.invalid(
                        "compiler projection emitted a call owned by another module"
                    )
                }
                continue
            }
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
            entries.append(try .init(
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
            ))
        }
        return entries.sorted { $0.key < $1.key }
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
