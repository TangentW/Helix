import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM Array adapter bounds")
struct ArrayAdapters {
    @Test("Counted subsequences clamp and reject negative counts")
    func validatesCountedBounds() throws {
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 4,
                bound: 2,
                operation: .dropFirst
            ) == 2..<4
        )
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 4,
                bound: 99,
                operation: .dropLast
            ) == 0..<0
        )
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 4,
                bound: 99,
                operation: .prefix
            ) == 0..<4
        )
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 4,
                bound: 2,
                operation: .suffix
            ) == 2..<4
        )
        #expect(throws: VM.RuntimeTrap.explicit(
            "collection subsequence count must not be negative"
        )) {
            try VM.ArrayAdapters.subsequenceBounds(
                count: 4,
                bound: -1,
                operation: .prefix
            )
        }
    }

    @Test("Index subsequences distinguish endIndex from element indices")
    func validatesIndexBounds() throws {
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 3,
                bound: 3,
                operation: .prefixUpTo
            ) == 0..<3
        )
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 3,
                bound: 3,
                operation: .suffixFrom
            ) == 3..<3
        )
        #expect(
            try VM.ArrayAdapters.subsequenceBounds(
                count: 3,
                bound: 2,
                operation: .prefixThrough
            ) == 0..<3
        )
        #expect(throws: VM.RuntimeTrap.arrayIndexOutOfBounds(
            index: 3,
            count: 3
        )) {
            try VM.ArrayAdapters.subsequenceBounds(
                count: 3,
                bound: 3,
                operation: .prefixThrough
            )
        }
    }

    @Test("Range slices accept empty end ranges and reject malformed bounds")
    func validatesRangeBounds() throws {
        #expect(
            try VM.ArrayAdapters.rangeBounds(
                count: 3,
                lowerBound: 3,
                upperBound: 3
            ) == 3..<3
        )
        #expect(throws: VM.RuntimeTrap.explicit(
            "Array range lower bound exceeds its upper bound"
        )) {
            try VM.ArrayAdapters.rangeBounds(
                count: 3,
                lowerBound: 2,
                upperBound: 1
            )
        }
        #expect(throws: VM.RuntimeTrap.arrayIndexOutOfBounds(
            index: -1,
            count: 3
        )) {
            try VM.ArrayAdapters.rangeBounds(
                count: 3,
                lowerBound: -1,
                upperBound: 1
            )
        }
    }

    @Test("Derived views preserve logical integer-index bounds")
    func preservesViewBases() throws {
        let storage = VM.ArrayStorage(
            elements: [.bool(false), .bool(true), .bool(false)],
            elementType: .bool,
            indexBase: 7
        )

        #expect(
            try VM.ArrayAdapters.subsequence(
                storage: storage,
                bound: 1,
                operation: .dropFirst
            ) == .init(bounds: 1..<3, indexBase: 8)
        )
        #expect(
            try VM.ArrayAdapters.subsequence(
                storage: storage,
                bound: 8,
                operation: .prefixThrough
            ) == .init(bounds: 0..<2, indexBase: 7)
        )
        #expect(
            try VM.ArrayAdapters.rangeSlice(
                storage: storage,
                lowerBound: 8,
                upperBound: 10
            ) == .init(bounds: 1..<3, indexBase: 8)
        )
        #expect(try storage.endIndex() == 10)

        let overflowing = VM.ArrayStorage(
            elements: [.bool(true)],
            elementType: .bool,
            indexBase: .max
        )
        #expect(throws: VM.RuntimeTrap.integerOverflow) {
            _ = try overflowing.endIndex()
        }
    }
}
}
