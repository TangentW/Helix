import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Contextual runtime value types")
struct ContextualRuntimeTypes {
    @Test("Static context recovers payload-free Optional types recursively")
    func recoversPayloadFreeOptionalTypes() throws {
        let optionalInteger = Bytecode.ValueType.optional(.int64)
        let nilValue = VM.Value.optional(nil)

        #expect(nilValue.hasRuntimeType(optionalInteger))
        #expect(!nilValue.hasRuntimeType(.int64))
        #expect(
            VM.Value.tuple([
                nilValue,
                .optional(nilValue),
                .array([], elementType: optionalInteger),
            ]).hasRuntimeType(
                .tuple([
                    optionalInteger,
                    .optional(optionalInteger),
                    .array(optionalInteger),
                ])
            )
        )
        #expect(
            !VM.Value.tuple([nilValue]).hasRuntimeType(
                .tuple([.optional(.string), .bool])
            )
        )
        #expect(
            !VM.Value.optional(.string("wrong")).hasRuntimeType(
                optionalInteger
            )
        )
    }

    @Test("Collection construction states accept context-typed nil values")
    func collectionStatesAcceptPayloadFreeOptionals() throws {
        let elementType = Bytecode.ValueType.optional(.int64)
        let nilValue = VM.Value.optional(nil)
        let one = VM.Value.optional(try integer(1))

        let arrayBuilder = VM.ArrayBuilder(elementType: elementType)
        try arrayBuilder.append(nilValue)
        try arrayBuilder.append(contentsOf: [one, nilValue])
        #expect(try arrayBuilder.finish() == [nilValue, one, nilValue])

        let dictionaryBuilder = VM.DictionaryBuilder(
            keyType: .optional(.string),
            valueType: elementType
        )
        try dictionaryBuilder.set(
            key: nilValue,
            value: nilValue,
            matchingIndex: nil
        )
        #expect(
            try dictionaryBuilder.finish() == [
                .init(key: nilValue, value: nilValue),
            ]
        )

        let groupedBuilder = VM.DictionaryBuilder(
            keyType: .string,
            valueType: .array(elementType)
        )
        try groupedBuilder.appendArrayElement(
            key: .string("nil"),
            element: nilValue,
            matchingIndex: nil
        )
        #expect(
            try groupedBuilder.finish() == [
                .init(
                    key: .string("nil"),
                    value: .array([nilValue], elementType: elementType)
                ),
            ]
        )

        let mutation = try VM.ArrayMutationState(
            elementType: elementType,
            elements: [nilValue, one]
        )
        try mutation.swapAt(0, 1, budget: generousBudget())
        #expect(try mutation.finish() == [one, nilValue])

        let sort = try VM.ArraySortState(
            elementType: elementType,
            elements: [one, nilValue]
        )
        let sortBudget = generousBudget()
        while let comparison = try sort.nextComparison(budget: sortBudget) {
            try sort.acceptComparison(
                rightPrecedesLeft: try precedes(
                    comparison.right,
                    comparison.left
                ),
                budget: sortBudget
            )
        }
        #expect(try sort.finish() == [nilValue, one])

        let split = try VM.ArraySplitState(
            elementType: elementType,
            elements: [nilValue, one, nilValue],
            maximumSplits: 3,
            omitsEmptySubsequences: true
        )
        let splitBudget = generousBudget()
        while let element = try split.nextElement() {
            try split.acceptElement(
                isSeparator: try optionalInteger(element) == nil,
                budget: splitBudget
            )
        }
        #expect(
            try split.finish(budget: splitBudget) == [
                .array([one], elementType: elementType),
            ]
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func optionalInteger(_ value: VM.Value) throws -> Int64? {
        guard case let .optional(payload) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .optional(.int64),
                actual: value.type
            )
        }
        guard let payload else { return nil }
        guard case let .integer(integer) = payload else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: payload.type
            )
        }
        return integer.signedValue
    }

    private func precedes(_ lhs: VM.Value, _ rhs: VM.Value) throws -> Bool {
        switch (try optionalInteger(lhs), try optionalInteger(rhs)) {
        case (nil, .some(_)): true
        case let (.some(left), .some(right)): left < right
        case (.some(_), nil), (nil, nil): false
        }
    }

    private func generousBudget() -> VM.InvocationBudget {
        .init(
            limits: .init(
                instructionFuelPerEntry: 1_000,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
    }
}
}
