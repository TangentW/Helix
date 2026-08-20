import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Finite Sequence query semantics")
struct SequenceQuerySemanticsMatrix {
    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    @Test("Represented Collections and integer Ranges share typed queries")
    func lowersManagedAndRangeQueries() throws {
        try execute([
            .init(
                name: "arrayQueries",
                source: """
                public func arrayQueries(
                    _ values: [String]
                ) -> (Int, Bool, String?, String?) {
                    (values.count, values.isEmpty, values.first, values.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [strings(["a", "b"])],
                        expected: .returned(.tuple([
                            try integer(2),
                            .bool(false),
                            .optional(.string("a")),
                            .optional(.string("b")),
                        ]))
                    ),
                    .init(
                        arguments: [strings([])],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "dictionaryQueries",
                source: """
                public func dictionaryQueries(
                    _ values: [String: Int]
                ) -> (Int, Bool, (key: String, value: Int)?) {
                    (values.count, values.isEmpty, values.first)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try dictionary([("a", 4), ("b", 7)])],
                        expected: .returned(.tuple([
                            try integer(2),
                            .bool(false),
                            .optional(.tuple([.string("a"), try integer(4)])),
                        ]))
                    ),
                    .init(
                        arguments: [try dictionary([])],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "setQueries",
                source: """
                public func setQueries(_ values: Set<Int>) -> (Int, Bool, Int?) {
                    (values.count, values.isEmpty, values.first)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([8, 3])],
                        expected: .returned(.tuple([
                            try integer(2),
                            .bool(false),
                            .optional(try integer(8)),
                        ]))
                    ),
                    .init(
                        arguments: [try set([])],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "rangeQueries",
                source: """
                public func rangeQueries(
                    _ lower: Int,
                    _ upper: Int
                ) -> (Int, Bool, Int?, Int?) {
                    let values = lower..<upper
                    return (values.count, values.isEmpty, values.first, values.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2), try integer(6)],
                        expected: .returned(.tuple([
                            try integer(4),
                            .bool(false),
                            .optional(try integer(2)),
                            .optional(try integer(5)),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(.min), try integer(.min)],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "closedRangeQueries",
                source: """
                public func closedRangeQueries(
                    _ lower: Int,
                    _ upper: Int
                ) -> (Int, Bool, Int?, Int?) {
                    let values = lower...upper
                    return (values.count, values.isEmpty, values.first, values.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7), try integer(7)],
                        expected: .returned(.tuple([
                            try integer(1),
                            .bool(false),
                            .optional(try integer(7)),
                            .optional(try integer(7)),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(.max), try integer(.max)],
                        expected: .returned(.tuple([
                            try integer(1),
                            .bool(false),
                            .optional(try integer(.max)),
                            .optional(try integer(.max)),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "normalizedSliceQueries",
                source: """
                public func normalizedSliceQueries(
                    _ values: [Int]
                ) -> (Int, Bool, Int?, Int?) {
                    let slice = values.dropFirst()
                    return (slice.count, slice.isEmpty, slice.first, slice.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            try integer(2),
                            .bool(false),
                            .optional(try integer(2)),
                            .optional(try integer(3)),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([1])],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "normalizedRepeatedQueries",
                source: """
                public func normalizedRepeatedQueries(
                    _ value: Int,
                    count: Int
                ) -> (Int, Bool, Int?, Int?) {
                    let values = repeatElement(value, count: count)
                    return (
                        values.count,
                        values.isEmpty,
                        values.first,
                        values.last
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7), try integer(3)],
                        expected: .returned(.tuple([
                            try integer(3),
                            .bool(false),
                            .optional(try integer(7)),
                            .optional(try integer(7)),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(7), try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "normalizedReversedQueries",
                source: """
                public func normalizedReversedQueries(
                    _ source: [Int]
                ) -> (Int, Bool, Int?, Int?) {
                    let values = source.reversed()
                    return (
                        values.count,
                        values.isEmpty,
                        values.first,
                        values.last
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            try integer(3),
                            .bool(false),
                            .optional(try integer(3)),
                            .optional(try integer(1)),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            try integer(0),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "comparableRangeEmptiness",
                source: """
                public func comparableRangeEmptiness(
                    _ textLower: String,
                    _ textUpper: String,
                    _ floatLower: Double,
                    _ floatUpper: Double
                ) -> (Bool, Bool) {
                    (
                        (textLower..<textUpper).isEmpty,
                        (floatLower..<floatUpper).isEmpty
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .string("a"), .string("z"),
                            .float64(2.5), .float64(2.5),
                        ],
                        expected: .returned(.tuple([
                            .bool(false), .bool(true),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("Range cardinality is exact across widths and Int overflow")
    func preservesRangeCardinalityBoundaries() throws {
        try execute([
            .init(
                name: "signedRangeCount",
                source: """
                public func signedRangeCount(_ lower: Int, _ upper: Int) -> Int {
                    (lower..<upper).count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(.min), try integer(-1)],
                        expected: .returned(try integer(.max))
                    ),
                    .init(
                        arguments: [try integer(.min), try integer(.max)],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            .init(
                name: "signedClosedRangeCount",
                source: """
                public func signedClosedRangeCount(
                    _ lower: Int,
                    _ upper: Int
                ) -> Int {
                    (lower...upper).count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(.min), try integer(-2)],
                        expected: .returned(try integer(.max))
                    ),
                    .init(
                        arguments: [try integer(.min), try integer(-1)],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            .init(
                name: "unsignedRangeCount",
                source: """
                public func unsignedRangeCount(
                    _ lower: UInt64,
                    _ upper: UInt64
                ) -> Int {
                    (lower..<upper).count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsignedInteger(0),
                            try unsignedInteger(UInt64(Int64.max)),
                        ],
                        expected: .returned(try integer(.max))
                    ),
                    .init(
                        arguments: [
                            try unsignedInteger(0),
                            try unsignedInteger(UInt64(Int64.max) + 1),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            .init(
                name: "narrowClosedRangeCounts",
                source: """
                public func narrowClosedRangeCounts() -> (Int, Int) {
                    ((Int8.min...Int8.max).count, (UInt8.min...UInt8.max).count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [],
                        expected: .returned(.tuple([
                            try integer(256), try integer(256),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("count(where:) streams every represented finite source")
    func lowersCountWhere() throws {
        try execute([
            .init(
                name: "arrayCountWhere",
                source: """
                public func arrayCountWhere(_ values: [Int], above: Int) -> Int {
                    values.count { $0 > above }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 5, 8]), try integer(4)],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [try integers([]), try integer(4)],
                        expected: .returned(try integer(0))
                    ),
                ]
            ),
            .init(
                name: "dictionaryCountWhere",
                source: """
                public func dictionaryCountWhere(
                    _ values: [String: Int]
                ) -> Int {
                    values.count { $0.key.hasPrefix("a") && $0.value > 0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try dictionary([("alpha", 1), ("beta", 2), ("also", -1)]),
                        ],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            .init(
                name: "setCountWhere",
                source: """
                public func setCountWhere(_ values: Set<Int>) -> Int {
                    values.count { $0 % 2 == 0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2, 4, 7])],
                        expected: .returned(try integer(2))
                    ),
                ]
            ),
            .init(
                name: "progressionCountWhere",
                source: """
                public func progressionCountWhere(_ upper: Int) -> (Int, Int) {
                    (
                        (0..<upper).count { $0 % 2 == 0 },
                        stride(from: 0, to: upper, by: 3).count { $0 > 2 }
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(10)],
                        expected: .returned(.tuple([
                            try integer(5), try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0), try integer(0),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "throwingCountWhere",
                source: """
                private enum CountFailure: Error { case negative }

                public func throwingCountWhere(_ values: [Int]) -> Int {
                    do {
                        return try values.count {
                            if $0 < 0 { throw CountFailure.negative }
                            return $0 % 2 == 0
                        }
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([2, 4, 7])],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [try integers([2, -1, 4])],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            .init(
                name: "throwingLinearCountWhere",
                source: """
                private enum LinearCountFailure: Error { case marker }

                public func throwingLinearCountWhere(_ values: [String]) -> Int {
                    do {
                        return try values.count {
                            if $0 == "!" { throw LinearCountFailure.marker }
                            return $0.hasPrefix("a")
                        }
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [strings(["alpha", "beta", "also"])],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [strings(["alpha", "!", "also"])],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            .init(
                name: "capturedCountWhere",
                source: """
                public func capturedCountWhere(_ upper: Int) -> (Int, Int) {
                    var visits = 0
                    let matches = (0..<upper).count {
                        visits += 1
                        return $0 < 2
                    }
                    return (matches, visits)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(5)],
                        expected: .returned(.tuple([
                            try integer(2), try integer(5),
                        ]))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0), try integer(0),
                        ]))
                    ),
                ]
            ),
        ])
    }

    @Test("Boundary queries stay constant-time and predicates stay streaming")
    func preservesQueryExecutionStrategies() throws {
        let boundary = try FrontendExecutionHarness.compile(
            source: """
            public func constantTimeRangeQueries(
                _ lower: Int,
                _ upper: Int
            ) -> (Int, Int?) {
                let values = lower..<upper
                return (values.count, values.last)
            }
            """,
            functionName: "constantTimeRangeQueries",
            moduleName: "HelixConstantTimeRangeQueries"
        )
        let boundaryDisassembly = Bytecode.Disassembler.disassemble(
            boundary.image.module
        )
        #expect(boundaryDisassembly.contains("checked_subtract"))
        #expect(!boundaryDisassembly.contains("progression_next"))
        #expect(
            VM.Interpreter().invoke(
                entry: boundary.entry,
                image: boundary.image,
                arguments: [try integer(.min), try integer(-1)]
            ) == .returned(.tuple([
                try integer(.max), .optional(try integer(-2)),
            ]))
        )

        let predicate = try FrontendExecutionHarness.compile(
            source: """
            public func streamingCountWhere(_ upper: Int) -> Int {
                (0..<upper).count { $0 % 2 == 0 }
            }
            """,
            functionName: "streamingCountWhere",
            moduleName: "HelixStreamingCountWhere"
        )
        let predicateDisassembly = Bytecode.Disassembler.disassemble(
            predicate.image.module
        )
        #expect(predicateDisassembly.contains("progression_next"))
        #expect(predicateDisassembly.contains("checked_add"))
        #expect(!predicateDisassembly.contains("make_array_builder"))
        #expect(!predicateDisassembly.contains("collection_materialize"))
    }

    @Test("Opaque iteration and representation-dependent queries fail closed")
    func rejectsUnrepresentedQueries() {
        expectUnsupported(
            name: "customSequenceCount",
            source: """
            private struct Values: Sequence, IteratorProtocol {
                var value: Int

                mutating func next() -> Int? {
                    guard value < 4 else { return nil }
                    defer { value += 1 }
                    return value
                }

                func makeIterator() -> Values { self }
            }

            public func customSequenceCount() -> Int {
                Values(value: 0).count { $0 > 1 }
            }
            """,
            diagnostic: "represented managed Collection or supported finite progression"
        )
        expectUnsupported(
            name: "arrayCapacity",
            source: """
            public func arrayCapacity(_ values: [Int]) -> Int {
                values.capacity
            }
            """,
            diagnostic: "unsupported SIL type"
        )
        expectUnsupported(
            name: "randomElement",
            source: """
            public func randomElement(_ values: [Int]) -> Int? {
                values.randomElement()
            }
            """,
            diagnostic: "unsupported SIL type"
        )
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixSequenceQuery_\(probe.name)"
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
                "finite Sequence query gaps:\n\(failures.joined(separator: "\n"))"
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
                moduleName: "HelixSequenceQuery_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains(diagnostic))
        } catch {
            Issue.record("\(name) produced an unexpected error: \(error)")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func unsignedInteger(_ value: UInt64) throws -> VM.Value {
        .integer(try .init(rawBits: value, bitWidth: 64, isSigned: false))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func dictionary(
        _ values: [(String, Int64)]
    ) throws -> VM.Value {
        .dictionary(
            try values.map {
                .init(key: .string($0.0), value: try integer($0.1))
            },
            keyType: .string,
            valueType: .int64
        )
    }

    private func set(_ values: [Int64]) throws -> VM.Value {
        .set(
            VM.SetValue(
                elements: try values.map(integer),
                elementType: .int64
            )
        )
    }
}
}
