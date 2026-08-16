#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Operation-driven algorithms shared by the interpreter's concrete Array
/// instructions. Equality and ordering stay injected so quota accounting and
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

    static func extremum(
        in values: [VM.Value],
        operation: Bytecode.ArrayExtremumOperation,
        isOrderedBefore: (VM.Value, VM.Value) throws -> Bool
    ) rethrows -> VM.Value? {
        guard var selected = values.first else { return nil }
        for candidate in values.dropFirst() {
            let replacesSelection = switch operation {
            case .minimum:
                try isOrderedBefore(candidate, selected)
            case .maximum:
                try isOrderedBefore(selected, candidate)
            }
            if replacesSelection { selected = candidate }
        }
        return selected
    }

    static func relation(
        _ operation: Bytecode.ArrayRelationOperation,
        lhs: [VM.Value],
        rhs: [VM.Value],
        areEqual: (VM.Value, VM.Value) throws -> Bool,
        isOrderedBefore: (VM.Value, VM.Value) throws -> Bool
    ) rethrows -> Bool {
        switch operation {
        case .elementsEqual:
            guard lhs.count == rhs.count else { return false }
            for (left, right) in zip(lhs, rhs) {
                guard try areEqual(left, right) else { return false }
            }
            return true
        case .startsWith:
            guard rhs.count <= lhs.count else { return false }
            for (left, right) in zip(lhs, rhs) {
                guard try areEqual(left, right) else { return false }
            }
            return true
        case .lexicographicallyPrecedes:
            for (left, right) in zip(lhs, rhs) {
                if try isOrderedBefore(left, right) { return true }
                if try isOrderedBefore(right, left) { return false }
            }
            return lhs.count < rhs.count
        }
    }
}
}
