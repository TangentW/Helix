import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift higher-order traversal semantics")
struct HigherOrderTraversalSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("flatMap accepts Array-backed returned sequences generically")
    func lowersFlatMapSequences() throws {
        try run([
            .init(
                name: "flattenedArrays",
                source: """
                public func flattenedArrays(_ values: [Int]) -> [Int] {
                    values.flatMap { value in
                        value > 0 ? [value, -value] : []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([2, 0, 3])],
                        expected: .returned(try integers([2, -2, 3, -3]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
            .init(
                name: "flattenedRepeated",
                source: """
                public func flattenedRepeated(_ values: [Int]) -> [Int] {
                    values.flatMap { repeatElement($0, count: 2) }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([4, 7])],
                        expected: .returned(try integers([4, 4, 7, 7]))
                    ),
                ]
            ),
            .init(
                name: "flattenedSlice",
                source: """
                public func flattenedSlice(_ values: [Int]) -> [Int] {
                    values.dropFirst().flatMap { [$0] }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integers([2, 3]))
                    ),
                ]
            ),
        ])
    }

    @Test("throwing flatMap preserves its error edge and partial builder cleanup")
    func lowersThrowingFlatMap() throws {
        try run([
            .init(
                name: "safelyFlattened",
                source: """
                enum FlattenError: Error { case negative }

                public func safelyFlattened(_ values: [Int]) -> [Int] {
                    do {
                        return try values.flatMap { value in
                            if value < 0 { throw FlattenError.negative }
                            return [value, value + 1]
                        }
                    } catch {
                        return []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 3])],
                        expected: .returned(try integers([1, 2, 3, 4]))
                    ),
                    .init(
                        arguments: [try integers([1, -1, 3])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
        ])
    }

    @Test("forward predicates short-circuit with exact visit counts")
    func lowersForwardPredicateTraversal() throws {
        try run([
            .init(
                name: "prefixVisited",
                source: """
                public func prefixVisited(_ values: [Int]) -> ([Int], Int) {
                    var visits = 0
                    let result = values.prefix { value in
                        visits += 1
                        return value < 3
                    }
                    return (Array(result), visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 0])],
                        expected: .returned(.tuple([
                            try integers([1, 2]), try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(.tuple([
                            try integers([1, 2]), try integer(2),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([3, 1])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(1),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(0),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "dropVisited",
                source: """
                public func dropVisited(_ values: [Int]) -> ([Int], Int) {
                    var visits = 0
                    let result = values.drop { value in
                        visits += 1
                        return value < 3
                    }
                    return (Array(result), visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 0])],
                        expected: .returned(.tuple([
                            try integers([3, 0]), try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([3, 1, 2])],
                        expected: .returned(.tuple([
                            try integers([3, 1, 2]), try integer(1),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(2),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(0),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "firstIndexVisited",
                source: """
                public func firstIndexVisited(_ values: [Int]) -> (Int?, Int) {
                    var visits = 0
                    let result = values.firstIndex { value in
                        visits += 1
                        return value == 3
                    }
                    return (result, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 3, 3])],
                        expected: .returned(.tuple([
                            .optional(try integer(1)), try integer(2),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(.tuple([
                            .optional(nil), try integer(2),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            .optional(nil), try integer(0),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "repeatedFirstIndex",
                source: """
                public func repeatedFirstIndex(_ value: Int) -> Int? {
                    repeatElement(value, count: 3).firstIndex { $0 == 7 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(.optional(try integer(0)))
                    ),
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
        ])
    }

    @Test("Sequence.prefix uses the direct Array result ABI")
    func lowersSequencePrefix() throws {
        try run([
            .init(
                name: "zippedPrefix",
                source: """
                public func zippedPrefix(_ values: [Int]) -> [Int] {
                    zip(values, values)
                        .prefix { $0.0 < 3 }
                        .map { $0.0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 0])],
                        expected: .returned(try integers([1, 2]))
                    ),
                ]
            ),
        ])
    }

    @Test("throwing forward predicates discard partial state and preserve visits")
    func lowersThrowingForwardPredicates() throws {
        try run([
            .init(
                name: "safePrefix",
                source: """
                enum TraversalError: Error { case stop }

                public func safePrefix(_ values: [Int]) -> ([Int], Int) {
                    var visits = 0
                    do {
                        let result = try values.prefix { value in
                            visits += 1
                            if value < 0 { throw TraversalError.stop }
                            return value < 3
                        }
                        return (Array(result), visits)
                    } catch {
                        return ([], visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, -1, 2])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(2),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "safeDrop",
                source: """
                enum TraversalError: Error { case stop }

                public func safeDrop(_ values: [Int]) -> ([Int], Int) {
                    var visits = 0
                    do {
                        let result = try values.drop { value in
                            visits += 1
                            if value < 0 { throw TraversalError.stop }
                            return value < 3
                        }
                        return (Array(result), visits)
                    } catch {
                        return ([], visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, -1, 3])],
                        expected: .returned(.tuple([
                            try integers([]), try integer(2),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "safeFirstIndex",
                source: """
                enum TraversalError: Error { case stop }

                public func safeFirstIndex(_ values: [Int]) -> (Int?, Int) {
                    var visits = 0
                    do {
                        let result = try values.firstIndex { value in
                            visits += 1
                            if value < 0 { throw TraversalError.stop }
                            return value == 3
                        }
                        return (result, visits)
                    } catch {
                        return (nil, visits)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, -1, 3])],
                        expected: .returned(.tuple([
                            .optional(nil), try integer(2),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("firstIndex rejects slices until their base index is represented")
    func rejectsFirstIndexOnNormalizedSlice() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public func slicedFirstIndex(_ values: [Int]) -> Int? {
                    values.dropFirst().firstIndex { $0 > 0 }
                }
                """,
                functionName: "slicedFirstIndex",
                moduleName: "HelixTraversal_slicedFirstIndex"
            )
        }
    }

    @Test("lazy Sequence.drop remains rejected instead of becoming eager")
    func rejectsLazySequenceDrop() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public func lazySequenceDrop(_ values: [Int]) -> [Int] {
                    zip(values, values)
                        .drop { $0.0 < 3 }
                        .map { $0.0 }
                }
                """,
                functionName: "lazySequenceDrop",
                moduleName: "HelixTraversal_lazySequenceDrop"
            )
            Issue.record("lazy Sequence.drop unexpectedly compiled eagerly")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("DropWhileSequence<"))
        } catch {
            Issue.record("unexpected lazy Sequence.drop error: \(error)")
        }
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixTraversal_\(probe.name)"
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
                    rawValue: "higher-order traversal gaps:\n"
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
