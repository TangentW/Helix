import HelixBytecode
import HelixCore
import HelixInterface

extension NativeImportCatalog {
/// Framework-provided imports that require no App catalog entry or allowlist.
enum Builtins {
    private struct Definition {
        var descriptor: Bytecode.StandardLibraryImports.Descriptor
        var invokerFactory: String
        var importedModules: [String]
    }

    private static let definitions = [
        Definition(
            descriptor: Bytecode.StandardLibraryImports.swiftPrint,
            invokerFactory: "Runtime.StandardLibraryImports.makePrint",
            importedModules: ["HelixRuntime"]
        ),
    ]

    static let automaticCallees = Set(
        definitions.map(\.descriptor.canonicalCallee)
    )

    static func records(
        metadata: InterfaceArchive.ReleaseMetadata
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        try definitions.map(\.descriptor).map { descriptor in
            try descriptor.contract.validate(effects: descriptor.effects)
            return InterfaceArchive.NativeImportRecord(
                id: nil,
                key: try Core.NativeImportKey.derive(
                    namespace: metadata.shellNamespaceID,
                    canonicalCallee: descriptor.canonicalCallee,
                    signature: descriptor.signature,
                    effects: descriptor.effects,
                    contract: descriptor.contract
                ),
                canonicalCallee: descriptor.canonicalCallee,
                silMangledNames: descriptor.silMangledNames,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                signature: descriptor.signature,
                effects: descriptor.effects,
                contract: descriptor.contract,
                capability: descriptor.capability,
                isEmittedToDevice: true
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    static func merging(
        _ records: [InterfaceArchive.NativeImportRecord],
        metadata: InterfaceArchive.ReleaseMetadata
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        let builtins = try self.records(metadata: metadata)
        let merged = records + builtins
        guard Set(merged.map(\.key)).count == merged.count,
              Set(merged.map(\.canonicalCallee)).count == merged.count,
              Set(merged.flatMap(\.silMangledNames)).count
                == merged.reduce(0, { $0 + $1.silMangledNames.count })
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "NativeImport Catalog conflicts with a Helix standard-library import"
            )
        }
        return merged.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    static func bindings(
        archive: InterfaceArchive.Archive
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        let byCallee = Dictionary(
            uniqueKeysWithValues: archive.nativeImports.map {
                ($0.canonicalCallee, $0)
            }
        )
        return try definitions.compactMap { definition in
            let descriptor = definition.descriptor
            guard let record = byCallee[descriptor.canonicalCallee],
                  record.isEmittedToDevice
            else { return nil }
            guard let id = record.id,
                  record.silMangledNames == descriptor.silMangledNames,
                  record.parameterTypes == descriptor.parameterTypes,
                  record.resultType == descriptor.resultType,
                  record.signature == descriptor.signature,
                  record.effects == descriptor.effects,
                  record.contract == descriptor.contract,
                  record.capability == descriptor.capability
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "standard-library NativeImport descriptor changed during indexing"
                )
            }
            return ShellBuildReceipt.NativeImportBinding(
                key: record.key,
                invokerExpression: definition.invokerFactory + "("
                    + "id: Core.NativeImportID(rawValue: \(id.rawValue)), "
                    + "key: Core.NativeImportKey(rawValue: try! Core.Digest(hex: "
                    + "\(String(reflecting: record.key.rawValue.hex)))))",
                importedModules: definition.importedModules
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }
}
}
