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

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }
}
}
