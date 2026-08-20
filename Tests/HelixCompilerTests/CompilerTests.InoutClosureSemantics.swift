import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift inout closure semantics")
struct InoutClosureSemantics {
    @Test("Ordinary closures mutate represented aggregate storage")
    func lowersOrdinaryInoutClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct Summary {
                var total: Int
                var values: [Int]
            }

            @inline(never)
            func applyMutation(
                _ summary: inout Summary,
                _ mutation: (inout Summary) -> Void
            ) {
                mutation(&summary)
            }

            public func ordinaryInoutClosure(_ seed: Int) -> (Int, [Int]) {
                var summary = Summary(total: seed, values: [])
                applyMutation(&summary) { value in
                    value.total += 3
                    value.values.append(seed)
                }
                return (summary.total, summary.values)
            }
            """,
            functionName: "ordinaryInoutClosure",
            moduleName: "HelixOrdinaryInoutClosure"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(4)]
            ) == .returned(.tuple([
                try integer(7), try integers([4]),
            ]))
        )
    }

    @Test("Throwing closures close inout access on both continuations")
    func lowersThrowingInoutClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct Summary {
                var total: Int
                var visits: [Int]
            }

            enum MutationFailure: Error { case negative }

            @inline(never)
            func applyMutation(
                _ summary: inout Summary,
                _ mutation: (inout Summary) throws -> Void
            ) rethrows {
                try mutation(&summary)
            }

            public func throwingInoutClosure(
                _ values: [Int]
            ) -> (Int, [Int]) {
                var summary = Summary(total: 10, visits: [])
                do {
                    for value in values {
                        try applyMutation(&summary) { summary in
                            summary.visits.append(value)
                            if value < 0 { throw MutationFailure.negative }
                            summary.total += value
                        }
                    }
                    return (summary.total, summary.visits)
                } catch {
                    return (-1, summary.visits)
                }
            }
            """,
            functionName: "throwingInoutClosure",
            moduleName: "HelixThrowingInoutClosure"
        )

        let scenarios: [([Int64], Int64, [Int64])] = [
            ([1, 2], 13, [1, 2]),
            ([1, -2, 3], -1, [1, -2]),
        ]
        for (input, expectedTotal, expectedVisits) in scenarios {
            #expect(
                VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: [try integers(input)]
                ) == .returned(.tuple([
                    try integer(expectedTotal),
                    try integers(expectedVisits),
                ]))
            )
        }
    }

    @Test("Throwing inout closures preserve non-Void normal results")
    func lowersThrowingReturningInoutClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum MutationFailure: Error { case rejected }

            @inline(never)
            func mutateAndRead(
                _ value: inout Int,
                _ mutation: (inout Int) throws -> Int
            ) rethrows -> Int {
                try mutation(&value)
            }

            public func throwingReturningInoutClosure(
                _ seed: Int,
                _ shouldThrow: Bool
            ) -> (Int, Int) {
                var value = seed
                do {
                    let result = try mutateAndRead(&value) { value in
                        value += 2
                        if shouldThrow { throw MutationFailure.rejected }
                        return value * 3
                    }
                    return (value, result)
                } catch {
                    return (value, -1)
                }
            }
            """,
            functionName: "throwingReturningInoutClosure",
            moduleName: "HelixThrowingReturningInout"
        )

        for (shouldThrow, expectedResult) in [
            (false, Int64(18)),
            (true, Int64(-1)),
        ] {
            #expect(
                VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: [try integer(4), .bool(shouldThrow)]
                ) == .returned(.tuple([
                    try integer(6), try integer(expectedResult),
                ]))
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }
}
}
