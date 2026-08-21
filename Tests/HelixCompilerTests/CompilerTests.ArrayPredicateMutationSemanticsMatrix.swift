import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Array predicate mutation semantics")
struct ArrayPredicateMutationSemanticsMatrix {
    @Test("Reverse reuses the generic Array adapter for scalar and owned values")
    func lowersReverse() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func reverseValues(
                _ numbers: [Int],
                _ words: [String]
            ) -> ([Int], [String]) {
                var reversedNumbers = numbers
                reversedNumbers.reverse()
                var reversedWords = words
                reversedWords.reverse()
                return (reversedNumbers, reversedWords)
            }
            """,
            functionName: "reverseValues",
            moduleName: "HelixArrayReverse"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3, 4]),
                    strings(["alpha", "beta", "gamma"]),
                ]
            ) == .returned(.tuple([
                try integers([4, 3, 2, 1]),
                strings(["gamma", "beta", "alpha"]),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([]), strings([])]
            ) == .returned(.tuple([
                try integers([]),
                strings([]),
            ]))
        )
    }

    @Test("removeAll(where:) preserves order and evaluates each input once")
    func lowersHalfStableRemoval() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func removeMatching(
                _ numbers: [Int],
                _ words: [String]
            ) -> ([Int], [Int], [String]) {
                var visits: [Int] = []
                var remainingNumbers = numbers
                remainingNumbers.removeAll { value in
                    visits.append(value)
                    return value % 2 == 0
                }
                var remainingWords = words
                remainingWords.removeAll { $0.hasPrefix("x") }
                return (remainingNumbers, visits, remainingWords)
            }
            """,
            functionName: "removeMatching",
            moduleName: "HelixArrayRemoveMatching"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3, 4, 5]),
                    strings(["x-ray", "alpha", "xylophone", "beta"]),
                ]
            ) == .returned(.tuple([
                try integers([1, 3, 5]),
                try integers([1, 2, 3, 4, 5]),
                strings(["alpha", "beta"]),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([]),
                    strings(["alpha", "beta"]),
                ]
            ) == .returned(.tuple([
                try integers([]),
                try integers([]),
                strings(["alpha", "beta"]),
            ]))
        )
    }

    @Test("removeAll(where:) matches Swift across every predicate pattern through length eight")
    func matchesRemovalReferenceMatrix() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func removalMatrix(
                _ values: [Int]
            ) -> ([Int], [Int]) {
                var result = values
                var visits: [Int] = []
                result.removeAll { value in
                    visits.append(value)
                    return value % 2 == 0
                }
                return (result, visits)
            }
            """,
            functionName: "removalMatrix",
            moduleName: "HelixRemovalMatrix"
        )

        for length in 0...8 {
            for pattern in 0..<(1 << length) {
                let input = (0..<length).map { index in
                    let isEven = pattern & (1 << index) != 0
                    return Int64(index * 2 + (isEven ? 0 : 1))
                }
                var expected = input
                var visits: [Int64] = []
                expected.removeAll { value in
                    visits.append(value)
                    return value.isMultiple(of: 2)
                }

                #expect(
                    VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: [try integers(input)]
                    ) == .returned(.tuple([
                        try integers(expected),
                        try integers(visits),
                    ]))
                )
            }
        }
    }

    @Test("Throwing removal writes back only swaps completed before the error")
    func preservesPartialThrowingRemoval() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum RemovalFailure: Error { case stop }

            public func partialRemoval(
                _ values: [Int],
                stop: Int
            ) -> ([Int], [Int], Bool) {
                var result = values
                var visits: [Int] = []
                do {
                    try result.removeAll { value in
                        visits.append(value)
                        if value == stop { throw RemovalFailure.stop }
                        return value % 2 == 0
                    }
                    return (result, visits, false)
                } catch {
                    return (result, visits, true)
                }
            }
            """,
            functionName: "partialRemoval",
            moduleName: "HelixArrayPartialRemoval"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3, 4, 5]),
                    try integer(5),
                ]
            ) == .returned(.tuple([
                try integers([1, 3, 2, 4, 5]),
                try integers([1, 2, 3, 4, 5]),
                .bool(true),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3, 4, 5]),
                    try integer(1),
                ]
            ) == .returned(.tuple([
                try integers([1, 2, 3, 4, 5]),
                try integers([1]),
                .bool(true),
            ]))
        )
    }

    @Test("ArraySlice reverse preserves its represented index base")
    func reversesArraySlice() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
                public func reverseSlice(_ values: [Int]) -> [Int] {
                    var slice = values.dropFirst()
                    slice.reverse()
                    return Array(slice)
                }
                """,
            functionName: "reverseSlice",
            moduleName: "HelixArraySliceReverse"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([1, 2, 3])]
            ) == .returned(try integers([3, 2]))
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }
}
}
