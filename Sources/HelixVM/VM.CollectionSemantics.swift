#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Index-search algorithms shared by the interpreter's concrete Array
/// instruction. Equality stays injected so quota accounting and recursive
/// Swift value semantics remain centralized in the interpreter.
enum CollectionSemantics {
    static func searchIndex(
        in values: [VM.Value],
        matching needle: VM.Value,
        operation: Bytecode.ArraySearchOperation,
        areEqual: (VM.Value, VM.Value) throws -> Bool
    ) rethrows -> Int? {
        switch operation {
        case .firstIndex:
            for index in values.indices
            where try areEqual(values[index], needle) {
                return index
            }
        case .lastIndex:
            for index in values.indices.reversed()
            where try areEqual(values[index], needle) {
                return index
            }
        }
        return nil
    }
}
}
