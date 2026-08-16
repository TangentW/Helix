import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift reverse higher-order traversal semantics")
struct HigherOrderReverseTraversalSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("last predicates traverse from the end with exact visit order")
    func lowersReversePredicates() throws {
        try run([
            .init(
                name: "lastVisited",
                source: """
                public func lastVisited(_ values: [Int]) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    let result = values.last { value in
                        visits.append(value)
                        return value.isMultiple(of: 2)
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, 1, 2, 1])],
                        expected: .returned(.tuple([
                            .optional(try integer(2)),
                            try integers([1, 2]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([3, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([1, 3]),
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
                name: "lastIndexVisited",
                source: """
                public func lastIndexVisited(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    let result = values.lastIndex { value in
                        visits.append(value)
                        return value.isMultiple(of: 2)
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, 1, 2, 1])],
                        expected: .returned(.tuple([
                            .optional(try integer(2)),
                            try integers([1, 2]),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([3, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([1, 3]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "lastNil",
                source: """
                public func lastNil(_ values: [Int?]) -> Int?? {
                    values.last { $0 == nil }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try optionalIntegers([1, nil, 2, nil]),
                        ],
                        expected: .returned(
                            .optional(.optional(nil))
                        )
                    ),
                    .init(
                        arguments: [try optionalIntegers([1, 2])],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
        ])
    }

    @Test("throwing last predicates preserve reverse order and cleanup")
    func lowersThrowingReversePredicates() throws {
        try run([
            .init(
                name: "safeLast",
                source: """
                enum ReverseError: Error { case stop }

                public func safeLast(_ values: [Int]) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    do {
                        let result = try values.last { value in
                            visits.append(value)
                            if value == 2 { throw ReverseError.stop }
                            return false
                        }
                        return (result, visits)
                    } catch {
                        return (nil, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, 1, 2, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([1, 2]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "safeLastIndex",
                source: """
                enum ReverseIndexError: Error { case stop }

                public func safeLastIndex(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    do {
                        let result = try values.lastIndex { value in
                            visits.append(value)
                            if value == 2 { throw ReverseIndexError.stop }
                            return false
                        }
                        return (result, visits)
                    } catch {
                        return (nil, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, 1, 2, 1])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try integers([1, 2]),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("Array-backed bidirectional adapters share reverse traversal")
    func lowersReverseAdapterTraversal() throws {
        try run([
            .init(
                name: "slicedLast",
                source: """
                public func slicedLast(_ values: [Int]) -> Int? {
                    values.dropFirst().last { $0 < 3 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([9, 1, 2, 4])],
                        expected: .returned(.optional(try integer(2)))
                    ),
                ]
            ),
            .init(
                name: "reversedLastVisited",
                source: """
                public func reversedLastVisited(
                    _ values: [Int]
                ) -> (Int?, [Int]) {
                    var visits: [Int] = []
                    let result = values.reversed().last { value in
                        visits.append(value)
                        return value.isMultiple(of: 2)
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 4])],
                        expected: .returned(.tuple([
                            .optional(try integer(2)),
                            try integers([1, 2]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "repeatedLastIndex",
                source: """
                public func repeatedLastIndex(_ value: Int) -> Int? {
                    repeatElement(value, count: 3).lastIndex { $0 == 7 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(.optional(try integer(2)))
                    ),
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
        ])
    }

    @Test("lastIndex rejects normalized collections whose index identity is lost")
    func rejectsUnrepresentedLastIndices() {
        let probes = [
            (
                name: "slicedLastIndex",
                source: """
                public func slicedLastIndex(_ values: [Int]) -> Int? {
                    values.dropFirst().lastIndex { $0 > 0 }
                }
                """,
                expectedType: "ArraySlice<Int>"
            ),
            (
                name: "reversedLastIndex",
                source: """
                public func reversedLastIndex(_ values: [Int]) -> Bool {
                    values.reversed().lastIndex { $0 > 0 } != nil
                }
                """,
                expectedType: "ReversedCollection<Array<Int>>"
            ),
        ]
        for probe in probes {
            do {
                _ = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixReverseTraversal_\(probe.name)"
                )
                Issue.record("\(probe.name) unexpectedly erased its index identity")
            } catch let error as CanonicalSIL.LoweringError {
                guard case let .unsupportedType(detail) = error else {
                    Issue.record("unexpected \(probe.name) diagnostic: \(error)")
                    continue
                }
                #expect(detail.contains(probe.expectedType))
            } catch {
                Issue.record("unexpected \(probe.name) error: \(error)")
            }
        }
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixReverseTraversal_\(probe.name)"
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
                    rawValue: "reverse higher-order traversal gaps:\n"
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
