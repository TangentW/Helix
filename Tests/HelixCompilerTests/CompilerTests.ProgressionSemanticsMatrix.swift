import HelixBytecode
import HelixVM
import Testing

extension CompilerTests {
@Suite("Range and stride progression semantics")
struct ProgressionSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Common integer and floating progressions lower from the real Swift frontend")
    func lowersProgressionMatrix() throws {
        let probes = [
            Probe(
                name: "int8RangeCount",
                source: """
                public func int8RangeCount(_ upper: Int8) -> Int {
                    var count = 0
                    for _ in Int8(0)..<upper { count += 1 }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4, width: 8, signed: true)],
                        expected: .returned(try integer(4))
                    ),
                    .init(
                        arguments: [try integer(0, width: 8, signed: true)],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integer(-1, width: 8, signed: true)],
                        expected: .trapped(
                            .explicit("Range requires lowerBound <= upperBound")
                        )
                    ),
                ]
            ),
            Probe(
                name: "uintRangeSum",
                source: """
                public func uintRangeSum(_ upper: UInt) -> UInt {
                    var total: UInt = 0
                    for value in UInt(0)..<upper { total += value }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try unsignedInteger(5)],
                        expected: .returned(try unsignedInteger(10))
                    ),
                    .init(
                        arguments: [try unsignedInteger(0)],
                        expected: .returned(try unsignedInteger(0))
                    ),
                ]
            ),
            Probe(
                name: "int16StrideCount",
                source: """
                public func int16StrideCount(
                    _ start: Int16,
                    _ end: Int16,
                    _ step: Int
                ) -> Int {
                    var count = 0
                    for _ in stride(from: start, through: end, by: step) {
                        count += 1
                    }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integer(-3, width: 16),
                            try integer(3, width: 16),
                            try integer(2),
                        ],
                        expected: .returned(try integer(4))
                    ),
                    .init(
                        arguments: [
                            try integer(3, width: 16),
                            try integer(-3, width: 16),
                            try integer(-2),
                        ],
                        expected: .returned(try integer(4))
                    ),
                ]
            ),
            Probe(
                name: "uint8ClosedRangeCount",
                source: """
                public func uint8ClosedRangeCount(
                    _ lower: UInt8,
                    _ upper: UInt8
                ) -> Int {
                    var count = 0
                    for _ in lower...upper { count += 1 }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsignedInteger(253, width: 8),
                            try unsignedInteger(255, width: 8),
                        ],
                        expected: .returned(try integer(3))
                    ),
                ]
            ),
            Probe(
                name: "closedRangeCount",
                source: """
                public func closedRangeCount(_ lower: Int, _ upper: Int) -> Int {
                    var count = 0
                    for _ in lower...upper { count += 1 }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(-2), try integer(2)],
                        expected: .returned(try integer(5))
                    ),
                    .init(
                        arguments: [try integer(.max), try integer(.max)],
                        expected: .returned(try integer(1))
                    ),
                    .init(
                        arguments: [try integer(2), try integer(1)],
                        expected: .trapped(
                            .explicit("Range requires lowerBound <= upperBound")
                        )
                    ),
                ]
            ),
            Probe(
                name: "strideToSum",
                source: """
                public func strideToSum(_ start: Int, _ end: Int, _ step: Int) -> Int {
                    var total = 0
                    for value in stride(from: start, to: end, by: step) {
                        total += value
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(0), try integer(7), try integer(2)],
                        expected: .returned(try integer(12))
                    ),
                    .init(
                        arguments: [try integer(7), try integer(0), try integer(-2)],
                        expected: .returned(try integer(16))
                    ),
                    .init(
                        arguments: [try integer(0), try integer(7), try integer(-2)],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integer(0), try integer(7), try integer(0)],
                        expected: .trapped(.explicit("Stride size must not be zero"))
                    ),
                ]
            ),
            Probe(
                name: "strideThroughCount",
                source: """
                public func strideThroughCount(
                    _ start: Int,
                    _ end: Int,
                    _ step: Int
                ) -> Int {
                    var count = 0
                    for _ in stride(from: start, through: end, by: step) {
                        count += 1
                    }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integer(.max - 1),
                            try integer(.max),
                            try integer(1),
                        ],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [
                            try integer(.max - 1),
                            try integer(.max),
                            try integer(2),
                        ],
                        expected: .returned(try integer(1))
                    ),
                    .init(
                        arguments: [
                            try integer(.min + 1),
                            try integer(.min),
                            try integer(-2),
                        ],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            Probe(
                name: "unsignedStrideCount",
                source: """
                public func unsignedStrideCount(
                    _ start: UInt,
                    _ end: UInt,
                    _ step: Int
                ) -> Int {
                    var count = 0
                    for _ in stride(from: start, through: end, by: step) {
                        count += 1
                    }
                    return count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsignedInteger(5),
                            try unsignedInteger(0),
                            try integer(-2),
                        ],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [
                            try unsignedInteger(.max - 1),
                            try unsignedInteger(.max),
                            try integer(2),
                        ],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            Probe(
                name: "doubleStrideSum",
                source: """
                public func doubleStrideSum(
                    _ start: Double,
                    _ end: Double,
                    _ step: Double
                ) -> Double {
                    var total = 0.0
                    for value in stride(from: start, to: end, by: step) {
                        total += value
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .float(0, bitWidth: 64),
                            .float(1, bitWidth: 64),
                            .float(0.25, bitWidth: 64),
                        ],
                        expected: .returned(.float(1.5, bitWidth: 64))
                    ),
                    .init(
                        arguments: [
                            .float(0, bitWidth: 64),
                            .float(1, bitWidth: 64),
                            .float(.nan, bitWidth: 64),
                        ],
                        expected: .returned(.float(0, bitWidth: 64))
                    ),
                ]
            ),
            Probe(
                name: "floatStrideSum",
                source: """
                public func floatStrideSum(
                    _ start: Float,
                    _ end: Float,
                    _ step: Float
                ) -> Float {
                    var total: Float = 0
                    for value in stride(from: start, through: end, by: step) {
                        total += value
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .float(1, bitWidth: 32),
                            .float(0, bitWidth: 32),
                            .float(-0.25, bitWidth: 32),
                        ],
                        expected: .returned(.float(2.5, bitWidth: 32))
                    ),
                    .init(
                        arguments: [
                            .float(1, bitWidth: 32),
                            .float(10, bitWidth: 32),
                            .float(.infinity, bitWidth: 32),
                        ],
                        expected: .returned(.float(1, bitWidth: 32))
                    ),
                    .init(
                        arguments: [
                            .float(1, bitWidth: 32),
                            .float(10, bitWidth: 32),
                            .float(0, bitWidth: 32),
                        ],
                        expected: .trapped(
                            .explicit("Stride size must not be zero")
                        )
                    ),
                ]
            ),
            Probe(
                name: "cgFloatStrideSum",
                source: """
                import CoreGraphics

                public func cgFloatStrideSum(
                    _ start: CGFloat,
                    _ end: CGFloat,
                    _ step: CGFloat
                ) -> CGFloat {
                    var total: CGFloat = 0
                    for value in stride(from: start, through: end, by: step) {
                        total += value
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .float(0, bitWidth: 64),
                            .float(1, bitWidth: 64),
                            .float(0.5, bitWidth: 64),
                        ],
                        expected: .returned(.float(1.5, bitWidth: 64))
                    ),
                ]
            ),
        ]

        try execute(probes)
    }

    @Test("Range predicates share one scalar comparison lowering")
    func lowersRangePredicateMatrix() throws {
        let probes = [
            Probe(
                name: "integerRangeContains",
                source: """
                public func integerRangeContains(
                    _ lower: Int,
                    _ upper: Int,
                    _ value: Int
                ) -> (Bool, Bool) {
                    ((lower..<upper).contains(value), (lower...upper).contains(value))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(1), try integer(3), try integer(3)],
                        expected: .returned(.tuple([.bool(false), .bool(true)]))
                    ),
                    .init(
                        arguments: [try integer(1), try integer(3), try integer(2)],
                        expected: .returned(.tuple([.bool(true), .bool(true)]))
                    ),
                ]
            ),
            Probe(
                name: "doubleClosedRangeContains",
                source: """
                public func doubleClosedRangeContains(
                    _ lower: Double,
                    _ upper: Double,
                    _ value: Double
                ) -> Bool {
                    (lower...upper).contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .float(-1, bitWidth: 64),
                            .float(1, bitWidth: 64),
                            .float(1, bitWidth: 64),
                        ],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [
                            .float(-1, bitWidth: 64),
                            .float(1, bitWidth: 64),
                            .float(.nan, bitWidth: 64),
                        ],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "stringClosedRangeContains",
                source: """
                public func stringClosedRangeContains(_ value: String) -> Bool {
                    let accepted = "a"..."m"
                    return accepted.contains(value)
                }
                """,
                scenarios: [
                    .init(arguments: [.string("m")], expected: .returned(.bool(true))),
                    .init(arguments: [.string("z")], expected: .returned(.bool(false))),
                ]
            ),
        ]

        try execute(probes)
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected \(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "progression semantic gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func integer(
        _ value: Int64,
        width: UInt16 = 64,
        signed: Bool = true
    ) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: width, isSigned: signed)
        )
    }

    private func unsignedInteger(
        _ value: UInt64,
        width: UInt16 = 64
    ) throws -> VM.Value {
        .integer(
            try .init(rawBits: value, bitWidth: width, isSigned: false)
        )
    }
}
}
