import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Invocation-local state shared by separator- and predicate-driven Array
/// splitting. It retains one owned source copy and records ranges, so elements
/// are materialized exactly once when the linear state is consumed.
public final class ArraySplitState: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    private let lock = NSLock()
    let elementType: Bytecode.ValueType
    private var elements: [VM.Value]
    private let maximumSplits: Int
    private let omitsEmptySubsequences: Bool
    private var completedRanges: [Range<Int>] = []
    private var cursor = 0
    private var segmentStart = 0
    private var splitCount = 0
    private var awaitingPredicate = false
    private var reportedCompletion = false
    private var isFinished = false

    init(
        elementType: Bytecode.ValueType,
        elements: [VM.Value],
        maximumSplits: Int,
        omitsEmptySubsequences: Bool
    ) throws {
        guard maximumSplits >= 0 else {
            throw VM.RuntimeTrap.explicit(
                "maximum split count cannot be negative"
            )
        }
        if let mismatched = elements.first(where: { !$0.hasRuntimeType(elementType) }) {
            throw VM.RuntimeTrap.typeMismatch(
                expected: elementType,
                actual: mismatched.type
            )
        }
        self.elementType = elementType
        self.elements = elements
        self.maximumSplits = maximumSplits
        self.omitsEmptySubsequences = omitsEmptySubsequences
    }

    /// Returns one element for predicate evaluation. Once the split limit is
    /// reached, the untouched suffix becomes the final segment without any
    /// additional predicate calls, matching Swift's `Collection.split`.
    func nextElement() throws -> VM.Value? {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array split state is already finished"
                )
            }
            guard !awaitingPredicate else {
                throw VM.RuntimeTrap.explicit(
                    "Array split predicate result is still pending"
                )
            }
            guard !reportedCompletion else { return nil }
            guard cursor < elements.count, splitCount < maximumSplits else {
                reportedCompletion = true
                return nil
            }
            awaitingPredicate = true
            return elements[cursor]
        }
    }

    func acceptElement(
        isSeparator: Bool,
        budget: VM.InvocationBudget
    ) throws {
        try lock.withLock {
            guard !isFinished, awaitingPredicate, cursor < elements.count else {
                throw VM.RuntimeTrap.explicit(
                    "Array split state has no pending predicate"
                )
            }
            try budget.consumeWork(units: 1)
            if isSeparator {
                let range = segmentStart..<cursor
                if !range.isEmpty || !omitsEmptySubsequences {
                    try budget.consumeAggregateElementStorage(elementCount: 1)
                    completedRanges.append(range)
                    splitCount += 1
                }
                segmentStart = cursor + 1
            }
            cursor += 1
            awaitingPredicate = false
        }
    }

    func finish(budget: VM.InvocationBudget) throws -> [VM.Value] {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Array split state is already finished"
                )
            }
            guard reportedCompletion, !awaitingPredicate else {
                throw VM.RuntimeTrap.explicit("Array split state is incomplete")
            }

            var ranges = completedRanges
            let finalRange = segmentStart..<elements.count
            if !finalRange.isEmpty || !omitsEmptySubsequences {
                try budget.consumeAggregateElementStorage(elementCount: 1)
                ranges.append(finalRange)
            }
            var includedElementCount = 0
            for range in ranges {
                let sum = includedElementCount.addingReportingOverflow(
                    range.count
                )
                guard !sum.overflow else {
                    throw VM.RuntimeTrap.vmHeapLimitExceeded
                }
                includedElementCount = sum.partialValue
            }
            try budget.consumeLinearWork(elementCount: includedElementCount)
            try budget.consumeAggregateStorage(elementCount: ranges.count)
            for range in ranges {
                try budget.consumeAggregateStorage(elementCount: range.count)
            }

            isFinished = true
            let result = ranges.map {
                VM.Value.array(Array(elements[$0]), elementType: elementType)
            }
            elements = []
            completedRanges = []
            return result
        }
    }

    public static func == (
        lhs: VM.ArraySplitState,
        rhs: VM.ArraySplitState
    ) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "ArraySplitState<\(elementType)>"
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
