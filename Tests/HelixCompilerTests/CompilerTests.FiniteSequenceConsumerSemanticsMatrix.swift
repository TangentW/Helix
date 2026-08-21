import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Finite Sequence consumer semantics")
struct FiniteSequenceConsumerSemanticsMatrix {
    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    @Test("Finite progressions share natural and comparator ordering")
    func lowersProgressionOrdering() throws {
        try execute([
            .init(
                name: "rangeNaturalSorted",
                source: """
                public func rangeNaturalSorted(
                    _ lower: Int,
                    _ upper: Int
                ) -> [Int] {
                    (lower..<upper).sorted()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2), try integer(6)],
                        expected: .returned(try integers([2, 3, 4, 5]))
                    ),
                    .init(
                        arguments: [try integer(4), try integer(4)],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
            .init(
                name: "strideComparatorSorted",
                source: """
                public func strideComparatorSorted(_ end: Int) -> [Int] {
                    stride(from: 0, to: end, by: 1).sorted {
                        ($0 % 2) < ($1 % 2)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(6)],
                        expected: .returned(try integers([0, 2, 4, 1, 3, 5]))
                    ),
                ]
            ),
            .init(
                name: "descendingStrideNaturalSorted",
                source: """
                public func descendingStrideNaturalSorted(
                    _ start: Int,
                    _ end: Int
                ) -> [Int] {
                    stride(from: start, through: end, by: -2).sorted()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7), try integer(1)],
                        expected: .returned(try integers([1, 3, 5, 7]))
                    ),
                ]
            ),
            .init(
                name: "throwingRangeSorted",
                source: """
                private enum SortFailure: Error { case stop }

                public func throwingRangeSorted(_ upper: Int) -> Int {
                    do {
                        return try (0..<upper).sorted { lhs, rhs in
                            if lhs == 2 || rhs == 2 { throw SortFailure.stop }
                            return lhs > rhs
                        }.count
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(try integer(-1))
                    ),
                    .init(
                        arguments: [try integer(1)],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
        ])
    }

    @Test("Natural extrema preserve empty, descending, and closed boundaries")
    func lowersProgressionExtrema() throws {
        try execute([
            .init(
                name: "strideNaturalExtrema",
                source: """
                public func strideNaturalExtrema(
                    _ start: Int,
                    _ end: Int,
                    _ step: Int
                ) -> (Int?, Int?) {
                    let values = stride(
                        from: start,
                        through: end,
                        by: step
                    )
                    return (values.min(), values.max())
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integer(5),
                            try integer(1),
                            try integer(-2),
                        ],
                        expected: .returned(.tuple([
                            .optional(try integer(1)),
                            .optional(try integer(5)),
                        ]))
                    ),
                    .init(
                        arguments: [
                            try integer(1),
                            try integer(5),
                            try integer(-1),
                        ],
                        expected: .returned(.tuple([
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "maximumClosedRangeElement",
                source: """
                public func maximumClosedRangeElement(_ value: Int) -> Int? {
                    (value...value).max()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(.max)],
                        expected: .returned(.optional(try integer(.max)))
                    ),
                ]
            ),
        ])
    }

    @Test("Sequence relations accept mixed and paired finite progressions")
    func lowersProgressionRelations() throws {
        try execute([
            .init(
                name: "rangeRelations",
                source: """
                public func rangeRelations(
                    _ values: [Int],
                    upper: Int
                ) -> (Bool, Bool, Bool) {
                    let range = 0..<upper
                    return (
                        range.elementsEqual(values),
                        range.starts(with: values),
                        range.lexicographicallyPrecedes(values)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2]), try integer(3)],
                        expected: .returned(.tuple([
                            .bool(true),
                            .bool(true),
                            .bool(false),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([0, 1]), try integer(4)],
                        expected: .returned(.tuple([
                            .bool(false),
                            .bool(true),
                            .bool(false),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([0, 1, 9]), try integer(3)],
                        expected: .returned(.tuple([
                            .bool(false),
                            .bool(false),
                            .bool(true),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([]), try integer(3)],
                        expected: .returned(.tuple([
                            .bool(false),
                            .bool(true),
                            .bool(false),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([0]), try integer(0)],
                        expected: .returned(.tuple([
                            .bool(false),
                            .bool(false),
                            .bool(true),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([]), try integer(0)],
                        expected: .returned(.tuple([
                            .bool(true),
                            .bool(true),
                            .bool(false),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([9]), try integer(.max)],
                        expected: .returned(.tuple([
                            .bool(false),
                            .bool(false),
                            .bool(true),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "pairedProgressionRelations",
                source: """
                public func pairedProgressionRelations(_ upper: Int) -> Bool {
                    (0..<upper).elementsEqual(
                        stride(from: 0, to: upper, by: 1)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(.bool(true))
                    ),
                ]
            ),
        ])
    }

    @Test("Contains and Set consumers reuse finite Sequence strategies")
    func lowersProgressionMembershipAndSets() throws {
        try execute([
            .init(
                name: "strideContains",
                source: """
                public func strideContains(
                    _ end: Int,
                    value: Int
                ) -> Bool {
                    stride(from: 0, to: end, by: 2).contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(9), try integer(6)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integer(9), try integer(7)],
                        expected: .returned(.bool(false))
                    ),
                    .init(
                        arguments: [try integer(0), try integer(0)],
                        expected: .returned(.bool(false))
                    ),
                    .init(
                        arguments: [try integer(.max), try integer(0)],
                        expected: .returned(.bool(true))
                    ),
                ]
            ),
            .init(
                name: "rangeSetSummary",
                source: """
                public func rangeSetSummary(_ upper: Int) -> (Int, Bool, Bool) {
                    let values = Set(0..<upper)
                    return (
                        values.count,
                        values.contains(0),
                        values.contains(upper - 1)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.tuple([
                            try integer(5),
                            .bool(true),
                            .bool(true),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(false),
                            .bool(false),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "strideSetSummary",
                source: """
                public func strideSetSummary(_ end: Int) -> (Int, Bool) {
                    let values = Set(stride(from: 0, to: end, by: 2))
                    return (values.count, values.contains(4))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(.tuple([
                            try integer(4),
                            .bool(true),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "rangeSetAlgebra",
                source: """
                public func rangeSetAlgebra(_ upper: Int) -> (Int, Int, Bool) {
                    let base: Set<Int> = [0, upper]
                    let united = base.union(1..<upper)
                    var formed = base
                    formed.formUnion(stride(from: 1, to: upper, by: 2))
                    return (
                        united.count,
                        formed.count,
                        formed.contains(3)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.tuple([
                            try integer(6),
                            try integer(4),
                            .bool(true),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "zeroStrideSet",
                source: """
                public func zeroStrideSet(_ step: Int) -> Set<Int> {
                    Set(stride(from: 0, to: 5, by: step))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(0)],
                        expected: .trapped(
                            .explicit("Stride size must not be zero")
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Element-only consumers remain streaming compiler control flow")
    func keepsElementConsumersStreaming() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func streamingSequenceConsumers(
                _ upper: Int
            ) -> (Bool, Int?, Bool) {
                let values = stride(from: 0, to: upper, by: 1)
                return (
                    values.contains(0),
                    values.max(),
                    values.starts(with: [0, 1])
                )
            }
            """,
            functionName: "streamingSequenceConsumers",
            moduleName: "HelixStreamingSequenceConsumers"
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("progression_next"))
        #expect(!disassembly.contains("make_array_builder"))
        #expect(!disassembly.contains("collection_materialize"))

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(4)]
            ) == .returned(.tuple([
                .bool(true),
                .optional(try integer(3)),
                .bool(true),
            ]))
        )
    }

    @Test("Opaque and unbounded Sequences remain fail-closed")
    func rejectsUnrepresentedSequenceConsumers() {
        expectUnsupported(
            name: "customSequenceSorted",
            source: """
            private struct Values: Sequence, IteratorProtocol {
                var value: Int

                mutating func next() -> Int? {
                    guard value < 3 else { return nil }
                    defer { value += 1 }
                    return value
                }

                func makeIterator() -> Values { self }
            }

            public func customSequenceSorted() -> [Int] {
                Values(value: 0).sorted()
            }
            """,
            diagnostic: "represented String/Collection storage"
        )
        expectUnsupported(
            name: "unboundedSequenceSet",
            source: """
            public func unboundedSequenceSet() -> Set<Int> {
                Set(0...)
            }
            """,
            diagnostic: "PartialRangeFrom<Int>"
        )
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixFiniteSequence_\(probe.name)"
                )
                for scenario in probe.scenarios {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name): expected \(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "finite Sequence consumer gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func expectUnsupported(
        name: String,
        source: String,
        diagnostic: String
    ) {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: source,
                functionName: name,
                moduleName: "HelixFiniteSequence_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains(diagnostic))
        } catch {
            Issue.record("\(name) produced an unexpected error: \(error)")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try VM.Integer(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }
}
}
