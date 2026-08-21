import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Invocation-local, single-owner Array storage for compiler-expanded
/// mutating algorithms. The initial Array is copied once; indexed reads and
/// swaps then remain linear-time overall instead of rebuilding the whole value
/// after every mutation. Every mutable field is guarded by `lock`.
public final class ArrayMutationState: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    private let lock = NSLock()
    let elementType: Bytecode.ValueType
    // Algorithms address dense physical slots; finish reattaches this base to
    // the completed value exposed to Swift collection semantics.
    private let indexBase: Int64
    private var elements: [VM.Value]
    private var isFinished = false

    init(
        elementType: Bytecode.ValueType,
        elements: [VM.Value],
        indexBase: Int64 = 0
    ) throws {
        if let mismatched = elements.first(where: { !$0.hasRuntimeType(elementType) }) {
            throw VM.RuntimeTrap.typeMismatch(
                expected: elementType,
                actual: mismatched.type
            )
        }
        self.elementType = elementType
        self.elements = elements
        self.indexBase = indexBase
        _ = try VM.ArrayStorage(
            elements: elements,
            elementType: elementType,
            indexBase: indexBase
        ).endIndex()
    }

    func element(
        at index: Int64,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array mutation state is already finished"
                )
            }
            let offset = try validatedIndex(index)
            try budget.consumeWork(units: 1)
            return elements[offset]
        }
    }

    func swapAt(
        _ lhsIndex: Int64,
        _ rhsIndex: Int64,
        budget: VM.InvocationBudget
    ) throws {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array mutation state is already finished"
                )
            }
            let lhs = try validatedIndex(lhsIndex)
            let rhs = try validatedIndex(rhsIndex)
            try budget.consumeWork(units: 1)
            elements.swapAt(lhs, rhs)
        }
    }

    func finish() throws -> VM.ArrayStorage {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array mutation state is already finished"
                )
            }
            isFinished = true
            let result = VM.ArrayStorage(
                elements: elements,
                elementType: elementType,
                indexBase: indexBase
            )
            elements = []
            return result
        }
    }

    func valuesForInspection() -> [VM.Value] {
        lock.withLock { elements }
    }

    private func validatedIndex(_ index: Int64) throws -> Int {
        guard index >= 0,
              let exact = Int(exactly: index),
              elements.indices.contains(exact)
        else {
            throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                index: index,
                count: elements.count
            )
        }
        return exact
    }

    public static func == (
        lhs: VM.ArrayMutationState,
        rhs: VM.ArrayMutationState
    ) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "ArrayMutationState<\(elementType)>"
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
