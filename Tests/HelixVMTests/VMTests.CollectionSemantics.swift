import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM collection value semantics")
struct CollectionSemantics {
    @Test("Index search preserves direction and short-circuits")
    func searchesInTheRequestedDirection() throws {
        let values = try [4, 2, 4, 3, 4].map(integer)
        let needle = try integer(4)
        var comparisons = 0

        let first = VM.CollectionSemantics.searchIndex(
            in: values,
            matching: needle,
            operation: .firstIndex
        ) { lhs, rhs in
            comparisons += 1
            return VM.HashableValue.equal(lhs, rhs)
        }
        #expect(first == 0)
        #expect(comparisons == 1)

        comparisons = 0
        let last = VM.CollectionSemantics.searchIndex(
            in: values,
            matching: needle,
            operation: .lastIndex
        ) { lhs, rhs in
            comparisons += 1
            return VM.HashableValue.equal(lhs, rhs)
        }
        #expect(last == 4)
        #expect(comparisons == 1)

        #expect(
            VM.CollectionSemantics.searchIndex(
                in: [],
                matching: needle,
                operation: .firstIndex,
                areEqual: VM.HashableValue.equal
            ) == nil
        )
    }

    @Test("Extrema retain the first element when ordering considers values tied")
    func extremaPreserveStableTies() throws {
        let negativeZero = VM.Value.float64(-0.0)
        let positiveZero = VM.Value.float64(0.0)
        let values = [negativeZero, positiveZero]
        let ordered: (VM.Value, VM.Value) -> Bool = { lhs, rhs in
            guard case let .float(lhs) = lhs,
                  case let .float(rhs) = rhs
            else { return false }
            return lhs.doubleValue < rhs.doubleValue
        }

        let minimum = VM.CollectionSemantics.extremum(
            in: values,
            operation: .minimum,
            isOrderedBefore: ordered
        )
        let maximum = VM.CollectionSemantics.extremum(
            in: values,
            operation: .maximum,
            isOrderedBefore: ordered
        )
        guard case let .some(.float(minimumValue)) = minimum,
              case let .some(.float(maximumValue)) = maximum
        else {
            Issue.record("floating extrema did not return scalar values")
            return
        }
        #expect(minimumValue.bitPattern == (-0.0 as Double).bitPattern)
        #expect(maximumValue.bitPattern == (-0.0 as Double).bitPattern)
        #expect(
            VM.CollectionSemantics.extremum(
                in: [],
                operation: .minimum,
                isOrderedBefore: ordered
            ) == nil
        )
    }

    @Test("Relations use recursive equality and lexicographic prefix rules")
    func comparesRelationsByTheirOwnSemantics() throws {
        let one = try integer(1)
        let two = try integer(2)
        let ordered = dictionary([("one", one), ("two", two)])
        let reordered = dictionary([("two", two), ("one", one)])
        let equality = VM.HashableValue.equal
        let neverOrdered: (VM.Value, VM.Value) -> Bool = { _, _ in false }

        #expect(
            VM.CollectionSemantics.relation(
                .startsWith,
                lhs: [ordered, ordered],
                rhs: [reordered],
                areEqual: equality,
                isOrderedBefore: neverOrdered
            )
        )
        #expect(
            !VM.CollectionSemantics.relation(
                .elementsEqual,
                lhs: [ordered, ordered],
                rhs: [reordered],
                areEqual: equality,
                isOrderedBefore: neverOrdered
            )
        )

        let integers = try [1, 2, 3].map(integer)
        let prefix = try [1, 2].map(integer)
        #expect(
            VM.CollectionSemantics.relation(
                .lexicographicallyPrecedes,
                lhs: prefix,
                rhs: integers,
                areEqual: equality,
                isOrderedBefore: integerLess
            )
        )
        #expect(
            !VM.CollectionSemantics.relation(
                .elementsEqual,
                lhs: [.float64(.nan)],
                rhs: [.float64(.nan)],
                areEqual: equality,
                isOrderedBefore: neverOrdered
            )
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func integerLess(_ lhs: VM.Value, _ rhs: VM.Value) -> Bool {
        guard case let .integer(lhs) = lhs,
              case let .integer(rhs) = rhs
        else { return false }
        return lhs.signedValue < rhs.signedValue
    }

    private func dictionary(
        _ entries: [(String, VM.Value)]
    ) -> VM.Value {
        .dictionary(
            entries.map { .init(key: .string($0.0), value: $0.1) },
            keyType: .string,
            valueType: .int64
        )
    }
}
}
