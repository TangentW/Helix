import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift inout sequence reduction semantics")
struct HigherOrderReduceIntoSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("reduce(into:) mutates arbitrary represented accumulator shapes")
    func lowersRepresentedAccumulators() throws {
        try run([
            .init(
                name: "tupleSummary",
                source: """
                public func tupleSummary(_ values: [Int]) -> (Int, Int) {
                    values.reduce(into: (0, 0)) { summary, value in
                        summary.0 += value
                        summary.1 += 1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            try integer(0), try integer(0),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1, -2, 5])],
                        expected: .returned(.tuple([
                            try integer(4), try integer(3),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "structSummary",
                source: """
                struct Summary {
                    var total: Int
                    var last: Int?
                }

                public func structSummary(_ values: [Int]) -> (Int, Int?) {
                    let summary = values.reduce(
                        into: Summary(total: 10, last: nil)
                    ) { summary, value in
                        summary.total += value
                        summary.last = value
                    }
                    return (summary.total, summary.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            try integer(10), .optional(nil),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([2, 4])],
                        expected: .returned(.tuple([
                            try integer(16), .optional(try integer(4)),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "optionalTotal",
                source: """
                public func optionalTotal(_ values: [Int]) -> Int? {
                    values.reduce(into: Int?.none) { total, value in
                        total = (total ?? 0) + value
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.optional(nil))
                    ),
                    .init(
                        arguments: [try integers([3, 4])],
                        expected: .returned(.optional(try integer(7)))
                    ),
                ]
            ),
        ])
    }

    @Test("collection accumulators and adapters share the generic inout path")
    func lowersCollectionsAndAdapters() throws {
        try run([
            .init(
                name: "collectionSummary",
                source: """
                public func collectionSummary(
                    _ values: [Int]
                ) -> ([Int], Int, Int) {
                    let result = values.reduce(
                        into: ([Int](), [Int: Int]())
                    ) { result, value in
                        result.0.append(value * 2)
                        result.1[value] = (result.1[value] ?? 0) + 1
                    }
                    return (
                        result.0,
                        result.1[1] ?? 0,
                        result.1[2] ?? 0
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 1])],
                        expected: .returned(.tuple([
                            try integers([2, 4, 2]),
                            try integer(2),
                            try integer(1),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "adapterReduction",
                source: """
                public func adapterReduction(_ values: [Int]) -> [Int] {
                    values.reversed().dropFirst().reduce(into: []) {
                        result, value in
                        result.append(value)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 4])],
                        expected: .returned(try integers([3, 2, 1]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
        ])
    }

    @Test("throwing mutation preserves visits and releases the partial result")
    func lowersThrowingReduction() throws {
        try run([
            .init(
                name: "safeReduction",
                source: """
                enum ReductionFailure: Error { case negative }

                public func safeReduction(
                    _ values: [Int]
                ) -> (Int, [Int]) {
                    var visits: [Int] = []
                    do {
                        let total = try values.reduce(into: 10) {
                            total, value in
                            visits.append(value)
                            if value < 0 {
                                throw ReductionFailure.negative
                            }
                            total += value
                        }
                        return (total, visits)
                    } catch {
                        return (-1, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            try integer(16), try integers([1, 2, 3]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(.tuple([
                            try integer(-1), try integers([1, -2]),
                        ]))
                    ),
                ]
            ),
        ])
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixReduceInto_\(probe.name)"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let actual = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if actual != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
                                + "\(scenario.expected), got \(actual)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                Comment(
                    rawValue: "reduce(into:) semantic gaps:\n"
                        + failures.joined(separator: "\n")
                )
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
