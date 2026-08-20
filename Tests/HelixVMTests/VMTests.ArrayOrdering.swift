import HelixBytecode
import HelixCore
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Array ordering state")
struct ArrayOrdering {
    @Test("Merge state is stable across duplicate represented values")
    func sortsStably() throws {
        let itemType = Bytecode.ValueType.tuple([.int64, .int64])
        let values = try [
            item(key: 2, tag: 20),
            item(key: 1, tag: 10),
            item(key: 2, tag: 21),
            item(key: 1, tag: 11),
        ]
        let state = try VM.ArraySortState(
            elementType: itemType,
            elements: values
        )
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
        )
        var comparisons = 0
        while let pair = try state.nextComparison(budget: budget) {
            comparisons += 1
            try state.acceptComparison(
                rightPrecedesLeft: try key(of: pair.right) < key(of: pair.left),
                budget: budget
            )
        }

        #expect(comparisons == 5)
        #expect(try state.finish() == [values[1], values[3], values[0], values[2]])
    }

    @Test("State protocol rejects invalid transitions and type mismatches")
    func rejectsInvalidTransitions() throws {
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
        )
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            _ = try VM.ArraySortState(
                elementType: .int64,
                elements: [.bool(true)]
            )
        }

        let pending = try VM.ArraySortState(
            elementType: .int64,
            elements: [try integer(2), try integer(1)]
        )
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array sort state has no pending comparison"
            )
        ) {
            try pending.acceptComparison(
                rightPrecedesLeft: true,
                budget: budget
            )
        }
        #expect(
            throws: VM.RuntimeTrap.explicit("Array sort state is incomplete")
        ) {
            _ = try pending.finish()
        }
        let firstPending = try pending.nextComparison(budget: budget)
        _ = try #require(firstPending)
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array sort comparison result is still pending"
            )
        ) {
            _ = try pending.nextComparison(budget: budget)
        }
        try pending.acceptComparison(
            rightPrecedesLeft: true,
            budget: budget
        )
        #expect(try pending.nextComparison(budget: budget) == nil)
        _ = try pending.finish()
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array sort state is already finished"
            )
        ) {
            _ = try pending.nextComparison(budget: budget)
        }
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "Array sort state is already finished"
            )
        ) {
            _ = try pending.finish()
        }
    }

    @Test("Empty and singleton states finish without comparisons")
    func handlesBoundaries() throws {
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
        )
        let empty = try VM.ArraySortState(
            elementType: .string,
            elements: []
        )
        #expect(try empty.nextComparison(budget: budget) == nil)
        #expect(try empty.nextComparison(budget: budget) == nil)
        #expect(try empty.finish().isEmpty)

        let singleton = try VM.ArraySortState(
            elementType: .string,
            elements: [.string("only")]
        )
        #expect(try singleton.nextComparison(budget: budget) == nil)
        #expect(try singleton.finish() == [.string("only")])
    }

    @Test("Merge passes agree with Swift ordering across irregular lengths")
    func matchesReferenceOrdering() throws {
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        var cases: [[Int64]] = [
            [3, 1, 2],
            [5, 1, 4, 2, 3],
            [7, -1, 7, 0, -3, 2, 2],
            Array((0..<33).reversed()).map(Int64.init),
        ]
        for length in 0...48 {
            var values: [Int64] = []
            values.reserveCapacity(length)
            for _ in 0..<length {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                values.append(Int64(seed % 17) - 8)
            }
            cases.append(values)
        }

        for values in cases {
            let state = try VM.ArraySortState(
                elementType: .int64,
                elements: try values.map(integer)
            )
            let budget = VM.InvocationBudget(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
            )
            while let pair = try state.nextComparison(budget: budget) {
                try state.acceptComparison(
                    rightPrecedesLeft: try key(of: pair.right) < key(of: pair.left),
                    budget: budget
                )
            }
            let actual = try state.finish().map(key)
            #expect(actual == values.sorted())
        }
    }

    @Test("Sorting work is charged to invocation fuel")
    func chargesWorkBudget() throws {
        let values = try (0..<32).reversed().map { value in
            try integer(Int64(value))
        }
        let state = try VM.ArraySortState(
            elementType: .int64,
            elements: values
        )
        let budget = VM.InvocationBudget(
            limits: .init(
                instructionFuelPerEntry: 0,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        let firstComparison = try state.nextComparison(budget: budget)
        let first = try #require(firstComparison)
        #expect(try key(of: first.right) == 30)
        #expect(throws: VM.RuntimeTrap.instructionFuelExhausted) {
            try state.acceptComparison(
                rightPrecedesLeft: true,
                budget: budget
            )
        }
    }

    private func item(key: Int64, tag: Int64) throws -> VM.Value {
        .tuple([try integer(key), try integer(tag)])
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func key(of value: VM.Value) throws -> Int64 {
        if case let .integer(integer) = value {
            return integer.signedValue
        }
        guard case let .tuple(fields) = value,
              let first = fields.first,
              case let .integer(integer) = first
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .tuple([.int64, .int64]),
                actual: value.type
            )
        }
        return integer.signedValue
    }
}
}
