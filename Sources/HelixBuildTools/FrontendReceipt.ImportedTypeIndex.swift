import Foundation

extension FrontendReceipt {
/// Resolves complete nominal tokens in compiler spellings back to the exact
/// imported type records that established their runtime representation.
struct ImportedTypeIndex: Sendable {
    private var types: [FrontendReceipt.Adapter.ImportedNativeType]
    private var indicesByName: [String: Set<Int>]

    init(types: [FrontendReceipt.Adapter.ImportedNativeType]) {
        self.types = types
        var indicesByName: [String: Set<Int>] = [:]
        for (index, type) in types.enumerated() {
            var names = Set(
                [type.canonicalName, type.swiftType] + type.aliases
            )
            if let runtimeName = type.objectiveCRuntimeName {
                names.insert(runtimeName)
                names.insert("__C.\(runtimeName)")
            }
            let relativeNames = names
            for module in type.importedModules {
                for name in relativeNames where !name.hasPrefix(module + ".") {
                    names.insert(module + "." + name)
                }
            }
            for name in names where !name.isEmpty {
                indicesByName[name, default: []].insert(index)
            }
        }
        self.indicesByName = indicesByName
    }

    func matching(
        spellings: [String]
    ) -> [FrontendReceipt.Adapter.ImportedNativeType] {
        var indices = Set<Int>()
        for spelling in spellings {
            for token in FrontendReceipt.SwiftTypeSpelling.nominalTokens(
                in: spelling
            ) {
                var prefix = token
                while true {
                    indices.formUnion(indicesByName[prefix] ?? [])
                    guard let separator = prefix.lastIndex(of: ".") else {
                        break
                    }
                    prefix = String(prefix[..<separator])
                }
            }
        }
        return indices.sorted().map { types[$0] }
    }

    /// TypeOps are needed only for values that cross the stable logical call
    /// boundary. Owner-only and physical adapter spellings remain compiler
    /// implementation details and must not inflate every consuming project.
    func logicalBoundaryTypes(
        for operations: [FrontendReceipt.Adapter.ImportedOperation]
    ) -> [FrontendReceipt.Adapter.ImportedNativeType] {
        matching(spellings: operations.flatMap {
            $0.parameterSwiftTypes + [$0.resultSwiftType]
        })
    }
}
}
