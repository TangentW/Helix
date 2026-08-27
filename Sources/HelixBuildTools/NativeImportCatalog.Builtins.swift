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
        Definition(
            descriptor: Bytecode.StandardLibraryImports.swiftDebugPrint,
            invokerFactory: "Runtime.StandardLibraryImports.makeDebugPrint",
            importedModules: ["HelixRuntime"]
        ),
        Definition(
            descriptor: Bytecode.StandardLibraryImports.swiftStringDescribing,
            invokerFactory: "Runtime.StandardLibraryImports.makeStringDescribing",
            importedModules: ["HelixRuntime"]
        ),
        Definition(
            descriptor: Bytecode.StandardLibraryImports.swiftStringReflecting,
            invokerFactory: "Runtime.StandardLibraryImports.makeStringReflecting",
            importedModules: ["HelixRuntime"]
        ),
    ]

    static let automaticCallees = Set(
        definitions.map(\.descriptor.canonicalCallee)
    )

    static func records() throws -> [InterfaceArchive.NativeImportRecord] {
        try definitions.map(\.descriptor).map { descriptor in
            return InterfaceArchive.NativeImportRecord(
                id: nil,
                key: try Core.NativeCall.Key.derive(
                    descriptor: descriptor.nativeCall
                ),
                descriptor: descriptor.nativeCall,
                silMangledNames: descriptor.silMangledNames,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                contract: descriptor.contract,
                capability: descriptor.capability,
                isEmittedToDevice: true
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    static func merging(
        _ records: [InterfaceArchive.NativeImportRecord]
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        let builtins = try self.records()
        let merged = records + builtins
        let conflicts = records.flatMap { record in
            builtins.compactMap { builtin -> String? in
                var fields: [String] = []
                if record.key == builtin.key { fields.append("key") }
                if record.canonicalCallee == builtin.canonicalCallee {
                    fields.append("callee")
                }
                if !Set(record.silMangledNames).isDisjoint(
                    with: builtin.silMangledNames
                ) {
                    fields.append("compiler symbol")
                }
                guard !fields.isEmpty else { return nil }
                return "\(record.canonicalCallee) conflicts with "
                    + "\(builtin.canonicalCallee) by "
                    + fields.joined(separator: ", ")
            }
        }
        guard conflicts.isEmpty else {
            throw FrontendReceipt.Error.invalidRequest(
                "NativeImport Catalog conflicts with a Helix standard-library import: "
                    + conflicts.prefix(8).joined(separator: "; ")
            )
        }
        return merged.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    static func bindings(
        archive: InterfaceArchive.Archive
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        var byKey: [Core.NativeCall.Key: InterfaceArchive.NativeImportRecord] = [:]
        for record in archive.nativeImports {
            guard byKey.updateValue(record, forKey: record.key) == nil else {
                throw FrontendReceipt.Error.invalidRequest(
                    "indexed NativeImport keys are not unique"
                )
            }
        }
        return try definitions.compactMap { definition in
            let descriptor = definition.descriptor
            let key = try Core.NativeCall.Key.derive(
                descriptor: descriptor.nativeCall
            )
            guard let record = byKey[key],
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
                strategy: .factory,
                factoryReference: definition.invokerFactory,
                importedModules: definition.importedModules
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }
}
}
