import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift comparator selection semantics")
struct HigherOrderComparatorSelectionSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("min and max comparators preserve argument order, visits, and ties")
    func lowersComparatorSelectionOrder() throws {
        try run([
            .init(
                name: "minimumVisited",
                source: """
                public func minimumVisited(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    let result = values.min { lhs, rhs in
                        visits.append(lhs)
                        visits.append(rhs)
                        return lhs.magnitude < rhs.magnitude
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, -2, 2, -1])],
                        expected: .returned(.tuple([
                            .optional(try integer(-1)),
                            try integers([-2, 3, 2, -2, -1, -2]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([-2, 2])],
                        expected: .returned(.tuple([
                            .optional(try integer(-2)),
                            try integers([2, -2]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([7])],
                        expected: .returned(.tuple([
                            .optional(try integer(7)),
                            try integers([]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "maximumVisited",
                source: """
                public func maximumVisited(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    let result = values.max { lhs, rhs in
                        visits.append(lhs)
                        visits.append(rhs)
                        return lhs.magnitude < rhs.magnitude
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, -2, 2, -1])],
                        expected: .returned(.tuple([
                            .optional(try integer(3)),
                            try integers([3, -2, 3, 2, 3, -1]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([2, -2])],
                        expected: .returned(.tuple([
                            .optional(try integer(2)),
                            try integers([2, -2]),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("comparator selection supports represented values and nested Optional results")
    func lowersGenericComparatorSelection() throws {
        try run([
            .init(
                name: "selectedItems",
                source: """
                struct Item {
                    var key: Int
                    var tag: Int
                }

                public func selectedItems() -> (Int?, Int?) {
                    let values = [
                        Item(key: 2, tag: 10),
                        Item(key: 1, tag: 20),
                        Item(key: 1, tag: 30),
                    ]
                    return (
                        values.min { $0.key < $1.key }?.tag,
                        values.max { $0.key < $1.key }?.tag
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [],
                        expected: .returned(.tuple([
                            .optional(try integer(20)),
                            .optional(try integer(10)),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "selectedNil",
                source: """
                public func selectedNil(_ values: [Int?]) -> Int?? {
                    values.min { lhs, rhs in
                        (lhs ?? Int.min) < (rhs ?? Int.min)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try optionalIntegers([1, nil, 2])],
                        expected: .returned(.optional(.optional(nil)))
                    ),
                    .init(
                        arguments: [try optionalIntegers([])],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
        ])
    }

    @Test("Array-backed adapters retain their concrete traversal order")
    func lowersComparatorSelectionAdapters() throws {
        try run([
            .init(
                name: "reversedMinimum",
                source: """
                public func reversedMinimum(_ values: [Int]) -> Int? {
                    values.reversed().min {
                        $0.magnitude < $1.magnitude
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([-2, 2, 5])],
                        expected: .returned(.optional(try integer(2)))
                    ),
                ]
            ),
            .init(
                name: "slicedMaximum",
                source: """
                public func slicedMaximum(_ values: [Int]) -> Int? {
                    values.dropFirst().max { $0 < $1 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([100, 3, 9, 4])],
                        expected: .returned(.optional(try integer(9)))
                    ),
                ]
            ),
        ])
    }

    @Test("throwing comparators clean candidates and preserve exact visits")
    func lowersThrowingComparatorSelection() throws {
        try run([
            .init(
                name: "safeMinimum",
                source: """
                enum SelectionError: Error { case stop }

                public func safeMinimum(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    do {
                        let result = try values.min { lhs, rhs in
                            visits.append(lhs)
                            visits.append(rhs)
                            if lhs == 0 || rhs == 0 {
                                throw SelectionError.stop
                            }
                            return lhs < rhs
                        }
                        return (result, visits)
                    } catch {
                        return (nil, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([4, 2, 0, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([2, 4, 0, 2]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "safeMaximum",
                source: """
                enum MaximumSelectionError: Error { case stop }

                public func safeMaximum(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    do {
                        let result = try values.max { lhs, rhs in
                            visits.append(lhs)
                            visits.append(rhs)
                            if lhs == 0 || rhs == 0 {
                                throw MaximumSelectionError.stop
                            }
                            return lhs < rhs
                        }
                        return (result, visits)
                    } catch {
                        return (nil, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([4, 2, 0, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([4, 2, 4, 0]),
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
                    moduleName: "HelixComparatorSelection_\(probe.name)"
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
                    rawValue: "comparator selection gaps:\n"
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

    private func optionalIntegers(_ values: [Int64?]) throws -> VM.Value {
        .array(
            try values.map { .optional(try $0.map(integer)) },
            elementType: .optional(.int64)
        )
    }
}
}
