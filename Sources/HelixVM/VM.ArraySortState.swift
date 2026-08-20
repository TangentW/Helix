import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Invocation-local state for a stable bottom-up merge sort. The VM owns the
/// index machine while comparator evaluation remains ordinary HLBC control
/// flow, so captures, throws, and call-depth accounting need no special path.
/// Every mutable protocol field and owned buffer is guarded by `lock`.
public final class ArraySortState: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    struct Comparison {
        var right: VM.Value
        var left: VM.Value
    }

    private let lock = NSLock()
    let elementType: Bytecode.ValueType
    private var elements: [VM.Value]
    private var sourceOrder: [Int]
    private var destinationOrder: [Int]
    private var width = 1
    private var runStart = 0
    private var left = 0
    private var middle = 0
    private var right = 0
    private var end = 0
    private var output = 0
    private var hasActiveRun = false
    private var awaitingComparison = false
    private var reportedCompletion = false
    private var isFinished = false

    init(elementType: Bytecode.ValueType, elements: [VM.Value]) throws {
        if let mismatched = elements.first(where: { $0.type != elementType }) {
            throw VM.RuntimeTrap.typeMismatch(
                expected: elementType,
                actual: mismatched.type
            )
        }
        self.elementType = elementType
        self.elements = elements
        sourceOrder = Array(elements.indices)
        destinationOrder = Array(repeating: 0, count: elements.count)
    }

    var elementCount: Int {
        lock.withLock { elements.count }
    }

    /// Returns the right and left merge candidates in that order. Asking
    /// whether `right` precedes `left` preserves the left element on ties.
    func nextComparison(
        budget: VM.InvocationBudget
    ) throws -> Comparison? {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit("Array sort state is already finished")
            }
            guard !awaitingComparison else {
                throw VM.RuntimeTrap.explicit(
                    "Array sort comparison result is still pending"
                )
            }
            guard !reportedCompletion else { return nil }

            while width < elements.count {
                if runStart >= elements.count {
                    swap(&sourceOrder, &destinationOrder)
                    runStart = 0
                    hasActiveRun = false
                    width = width >= elements.count - width
                        ? elements.count : width + width
                    continue
                }
                if !hasActiveRun {
                    left = runStart
                    middle = runStart + min(width, elements.count - runStart)
                    right = middle
                    end = middle + min(width, elements.count - middle)
                    output = runStart
                    hasActiveRun = true
                }
                if left < middle, right < end {
                    awaitingComparison = true
                    return .init(
                        right: elements[sourceOrder[right]],
                        left: elements[sourceOrder[left]]
                    )
                }
                while left < middle {
                    try budget.consumeWork(units: 1)
                    destinationOrder[output] = sourceOrder[left]
                    left += 1
                    output += 1
                }
                while right < end {
                    try budget.consumeWork(units: 1)
                    destinationOrder[output] = sourceOrder[right]
                    right += 1
                    output += 1
                }
                runStart = end
                hasActiveRun = false
            }
            reportedCompletion = true
            return nil
        }
    }

    func acceptComparison(
        rightPrecedesLeft: Bool,
        budget: VM.InvocationBudget
    ) throws {
        try lock.withLock {
            guard !isFinished, awaitingComparison,
                  left < middle, right < end
            else {
                throw VM.RuntimeTrap.explicit(
                    "Array sort state has no pending comparison"
                )
            }
            try budget.consumeWork(units: 1)
            if rightPrecedesLeft {
                destinationOrder[output] = sourceOrder[right]
                right += 1
            } else {
                destinationOrder[output] = sourceOrder[left]
                left += 1
            }
            output += 1
            awaitingComparison = false
        }
    }

    func finish() throws -> [VM.Value] {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array sort state is already finished"
                )
            }
            guard reportedCompletion, !awaitingComparison else {
                throw VM.RuntimeTrap.explicit("Array sort state is incomplete")
            }
            isFinished = true
            let result = sourceOrder.map { elements[$0] }
            elements = []
            sourceOrder = []
            destinationOrder = []
            return result
        }
    }

    public static func == (lhs: VM.ArraySortState, rhs: VM.ArraySortState) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "ArraySortState<\(elementType)>"
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
