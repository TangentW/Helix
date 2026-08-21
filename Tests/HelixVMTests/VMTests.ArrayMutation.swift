import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Array mutation state")
struct ArrayMutation {
    @Test("Indexed reads and swaps share one mutable snapshot")
    func mutatesSnapshot() throws {
        let state = try makeState([10, 20, 30])
        let budget = generousBudget()

        #expect(try integer(state.element(at: 1, budget: budget)) == 20)
        try state.swapAt(0, 2, budget: budget)
        try state.swapAt(1, 1, budget: budget)

        #expect(try state.finish().elements.map(integer) == [30, 20, 10])
    }

    @Test("State validates element types, indices, and terminal transitions")
    func rejectsInvalidOperations() throws {
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            _ = try VM.ArrayMutationState(
                elementType: .int64,
                elements: [.bool(true)]
            )
        }

        let state = try makeState([1, 2])
        let budget = generousBudget()
        #expect(
            throws: VM.RuntimeTrap.arrayIndexOutOfBounds(index: -1, count: 2)
        ) {
            _ = try state.element(at: -1, budget: budget)
        }
        #expect(
            throws: VM.RuntimeTrap.arrayIndexOutOfBounds(index: 2, count: 2)
        ) {
            try state.swapAt(0, 2, budget: budget)
        }

        _ = try state.finish()
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array mutation state is already finished"
            )
        ) {
            _ = try state.element(at: 0, budget: budget)
        }
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array mutation state is already finished"
            )
        ) {
            try state.swapAt(0, 0, budget: budget)
        }
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array mutation state is already finished"
            )
        ) {
            _ = try state.finish()
        }
    }

    @Test("Reads and swaps consume invocation fuel before exposing work")
    func chargesWorkBudget() throws {
        let readState = try makeState([1])
        let exhaustedRead = exhaustedBudget()
        #expect(throws: VM.RuntimeTrap.instructionFuelExhausted) {
            _ = try readState.element(at: 0, budget: exhaustedRead)
        }

        let swapState = try makeState([1, 2])
        let exhaustedSwap = exhaustedBudget()
        #expect(throws: VM.RuntimeTrap.instructionFuelExhausted) {
            try swapState.swapAt(0, 1, budget: exhaustedSwap)
        }
        #expect(try swapState.finish().elements.map(integer) == [1, 2])
    }

    @Test("Mutation state retains the source view's index base")
    func preservesIndexBase() throws {
        let state = try VM.ArrayMutationState(
            elementType: .int64,
            elements: [try value(1), try value(2)],
            indexBase: 9
        )
        try state.swapAt(0, 1, budget: generousBudget())
        let storage = try state.finish()

        #expect(storage.indexBase == 9)
        #expect(try storage.elements.map(integer) == [2, 1])
        #expect(try storage.endIndex() == 11)
    }

    private func makeState(_ values: [Int64]) throws -> VM.ArrayMutationState {
        try .init(
            elementType: .int64,
            elements: try values.map(value)
        )
    }

    private func value(_ number: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: number, bitWidth: 64, isSigned: true)
        )
    }

    private func integer(_ value: VM.Value) throws -> Int64 {
        guard case let .integer(number) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: value.type
            )
        }
        return number.signedValue
    }

    private func generousBudget() -> VM.InvocationBudget {
        .init(
            limits: .init(
                instructionFuelPerEntry: 100,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
    }

    private func exhaustedBudget() -> VM.InvocationBudget {
        .init(
            limits: .init(
                instructionFuelPerEntry: 0,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
    }
}
}
