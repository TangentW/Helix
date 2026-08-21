import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Array splitting state")
struct ArraySplitting {
    @Test("Split state matches Swift across limits and empty-segment policies")
    func matchesSwiftReference() throws {
        var inputs: [[Int]] = []
        for length in 0...8 {
            for bits in 0..<(1 << length) {
                inputs.append(
                    (0..<length).map { offset in
                        bits & (1 << offset) == 0 ? 0 : 1
                    }
                )
            }
        }
        for input in inputs {
            for maximumSplits in 0...(input.count + 2) {
                for omitsEmpty in [false, true] {
                    let state = try makeState(
                        input,
                        maximumSplits: maximumSplits,
                        omitsEmpty: omitsEmpty
                    )
                    let budget = generousBudget()
                    while let value = try state.nextElement() {
                        try state.acceptElement(
                            isSeparator: try integer(value) == 0,
                            budget: budget
                        )
                    }
                    let actual = try arrays(
                        state.finish(budget: budget)
                    )
                    let expected = input.split(
                        separator: 0,
                        maxSplits: maximumSplits,
                        omittingEmptySubsequences: omitsEmpty
                    ).map(Array.init)
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test("Empty separators do not consume an omitted split budget")
    func stopsPredicateAtTheExactSplitBoundary() throws {
        let input = [0, 0, 1, 0, 2]

        let omitting = try makeState(
            input,
            maximumSplits: 1,
            omitsEmpty: true
        )
        let omittingBudget = generousBudget()
        var omittingVisits: [Int] = []
        while let value = try omitting.nextElement() {
            let decoded = try integer(value)
            omittingVisits.append(decoded)
            try omitting.acceptElement(
                isSeparator: decoded == 0,
                budget: omittingBudget
            )
        }
        #expect(omittingVisits == [0, 0, 1, 0])
        #expect(
            try arrays(omitting.finish(budget: omittingBudget))
                == [[1], [2]]
        )

        let retaining = try makeState(
            input,
            maximumSplits: 1,
            omitsEmpty: false
        )
        let retainingBudget = generousBudget()
        var retainingVisits: [Int] = []
        while let value = try retaining.nextElement() {
            let decoded = try integer(value)
            retainingVisits.append(decoded)
            try retaining.acceptElement(
                isSeparator: decoded == 0,
                budget: retainingBudget
            )
        }
        #expect(retainingVisits == [0])
        #expect(
            try arrays(retaining.finish(budget: retainingBudget))
                == [[], [0, 1, 0, 2]]
        )
    }

    @Test("Split segments retain their source logical ranges")
    func preservesSegmentIndexBases() throws {
        let state = try VM.ArraySplitState(
            elementType: .int64,
            elements: [try value(1), try value(0), try value(2)],
            indexBase: 5,
            maximumSplits: 1,
            omitsEmptySubsequences: true
        )
        let budget = generousBudget()
        while let element = try state.nextElement() {
            try state.acceptElement(
                isSeparator: try integer(element) == 0,
                budget: budget
            )
        }
        let segments = try state.finish(budget: budget)
        guard segments.count == 2,
              case let .array(first) = segments[0],
              case let .array(second) = segments[1]
        else {
            Issue.record("split did not produce two Array-backed segments")
            return
        }

        #expect(first.indexBase == 5)
        #expect(second.indexBase == 7)
        #expect(try arrays(segments) == [[1], [2]])
    }

    @Test("Split state rejects invalid transitions and element types")
    func rejectsInvalidTransitions() throws {
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "maximum split count cannot be negative"
            )
        ) {
            _ = try VM.ArraySplitState(
                elementType: .int64,
                elements: [],
                maximumSplits: -1,
                omitsEmptySubsequences: true
            )
        }
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            _ = try VM.ArraySplitState(
                elementType: .int64,
                elements: [.bool(true)],
                maximumSplits: 1,
                omitsEmptySubsequences: true
            )
        }
        #expect(throws: VM.RuntimeTrap.integerOverflow) {
            _ = try VM.ArraySplitState(
                elementType: .int64,
                elements: [try value(1)],
                indexBase: .max,
                maximumSplits: 1,
                omitsEmptySubsequences: true
            )
        }

        let state = try makeState(
            [1, 0],
            maximumSplits: 1,
            omitsEmpty: true
        )
        let budget = generousBudget()
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array split state has no pending predicate"
            )
        ) {
            try state.acceptElement(isSeparator: false, budget: budget)
        }
        #expect(
            throws: VM.RuntimeTrap.explicit("Array split state is incomplete")
        ) {
            _ = try state.finish(budget: budget)
        }
        let first = try state.nextElement()
        _ = try #require(first)
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array split predicate result is still pending"
            )
        ) {
            _ = try state.nextElement()
        }
        try state.acceptElement(isSeparator: false, budget: budget)
        let second = try state.nextElement()
        _ = try #require(second)
        try state.acceptElement(isSeparator: true, budget: budget)
        #expect(try state.nextElement() == nil)
        _ = try state.finish(budget: budget)
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array split state is already finished"
            )
        ) {
            _ = try state.nextElement()
        }
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array split state is already finished"
            )
        ) {
            _ = try state.finish(budget: budget)
        }
    }

    @Test("Predicate acceptance and materialization are fuel bounded")
    func chargesWorkBudget() throws {
        let state = try makeState(
            [1],
            maximumSplits: 1,
            omitsEmpty: true
        )
        let first = try state.nextElement()
        _ = try #require(first)
        let exhausted = VM.InvocationBudget(
            limits: .init(
                instructionFuelPerEntry: 0,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(throws: VM.RuntimeTrap.instructionFuelExhausted) {
            try state.acceptElement(isSeparator: false, budget: exhausted)
        }
    }

    private func makeState(
        _ values: [Int],
        maximumSplits: Int,
        omitsEmpty: Bool
    ) throws -> VM.ArraySplitState {
        try .init(
            elementType: .int64,
            elements: try values.map(value),
            maximumSplits: maximumSplits,
            omitsEmptySubsequences: omitsEmpty
        )
    }

    private func value(_ number: Int) throws -> VM.Value {
        .integer(
            try .init(
                signed: Int64(number),
                bitWidth: 64,
                isSigned: true
            )
        )
    }

    private func integer(_ value: VM.Value) throws -> Int {
        guard case let .integer(number) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: value.type
            )
        }
        return Int(number.signedValue)
    }

    private func arrays(_ values: [VM.Value]) throws -> [[Int]] {
        try values.map { value in
            guard case let .array(storage) = value,
                  storage.elementType == .int64
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .array(.int64),
                    actual: value.type
                )
            }
            return try storage.elements.map(integer)
        }
    }

    private func generousBudget() -> VM.InvocationBudget {
        .init(
            limits: .init(
                instructionFuelPerEntry: 100_000,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
    }
}
}
