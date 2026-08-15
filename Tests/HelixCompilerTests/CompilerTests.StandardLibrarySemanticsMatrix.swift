import HelixBytecode
import HelixVM
import Testing

extension CompilerTests {
@Suite("Common Swift standard-library semantics")
struct StandardLibrarySemanticsMatrix {
    private enum HarnessError: Error {
        case unexpectedResult
    }

    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Scalar, String, and collection APIs preserve Swift semantics")
    func lowersCommonStandardLibraryAPIs() throws {
        let probes = [
            Probe(
                name: "boundedValue",
                source: """
                public func boundedValue(_ value: Int, lower: Int, upper: Int) -> Int {
                    min(max(value, lower), upper)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(-5), try integer(0), try integer(10)],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integer(5), try integer(0), try integer(10)],
                        expected: .returned(try integer(5))
                    ),
                    .init(
                        arguments: [try integer(15), try integer(0), try integer(10)],
                        expected: .returned(try integer(10))
                    ),
                ]
            ),
            Probe(
                name: "unsignedExtrema",
                source: """
                public func unsignedExtrema(_ left: UInt8, _ right: UInt8) -> (UInt8, UInt8) {
                    (min(left, right), max(left, right))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try unsignedInteger(250), try unsignedInteger(7)],
                        expected: .returned(.tuple([
                            try unsignedInteger(7),
                            try unsignedInteger(250),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "stringExtrema",
                source: """
                public func stringExtrema(_ left: String, _ right: String) -> (String, String) {
                    (min(left, right), max(left, right))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.string("zebra"), .string("apple")],
                        expected: .returned(.tuple([
                            .string("apple"),
                            .string("zebra"),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "absoluteValue",
                source: "public func absoluteValue(_ value: Int) -> Int { abs(value) }",
                scenarios: [
                    .init(
                        arguments: [try integer(-7)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [try integer(.min)],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            Probe(
                name: "absoluteInt8",
                source: "public func absoluteInt8(_ value: Int8) -> Int8 { abs(value) }",
                scenarios: [
                    .init(
                        arguments: [try signedInteger(-127, bitWidth: 8)],
                        expected: .returned(try signedInteger(127, bitWidth: 8))
                    ),
                    .init(
                        arguments: [try signedInteger(-128, bitWidth: 8)],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            Probe(
                name: "absoluteDouble",
                source: "public func absoluteDouble(_ value: Double) -> Double { abs(value) }",
                scenarios: [
                    .init(
                        arguments: [.float64(-3.5)],
                        expected: .returned(.float64(3.5))
                    ),
                    .init(
                        arguments: [.float64(-0.0)],
                        expected: .returned(.float64(0.0))
                    ),
                ]
            ),
            Probe(
                name: "caseTransforms",
                source: """
                public func caseTransforms(_ value: String) -> (String, String) {
                    (value.uppercased(), value.lowercased())
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.string("Helix 123")],
                        expected: .returned(.tuple([
                            .string("HELIX 123"),
                            .string("helix 123"),
                        ]))
                    ),
                    .init(
                        arguments: [.string("Straße")],
                        expected: .returned(.tuple([
                            .string("STRASSE"),
                            .string("straße"),
                        ]))
                    ),
                    .init(
                        arguments: [.string("İﬃ")],
                        expected: .returned(.tuple([
                            .string("İFFI"),
                            .string("i\u{307}ﬃ"),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "boundaryValues",
                source: """
                public func boundaryValues(_ values: [Int]) -> (Int?, Int?) {
                    (values.first, values.last)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            .optional(try integer(1)),
                            .optional(try integer(3)),
                        ]))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.tuple([
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "popLastValue",
                source: """
                public func popLastValue(_ values: [Int]) -> (Int?, [Int]) {
                    var result = values
                    let removed = result.popLast()
                    return (removed, result)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            .optional(try integer(3)),
                            try integers([1, 2]),
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
            Probe(
                name: "removeDictionaryValue",
                source: """
                public func removeDictionaryValue(
                    _ values: [String: Int],
                    key: String
                ) -> (Int?, [String: Int]) {
                    var result = values
                    let removed = result.removeValue(forKey: key)
                    return (removed, result)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try stringIntegerDictionary(["a": 1, "b": 2]),
                            .string("a"),
                        ],
                        expected: .returned(.tuple([
                            .optional(try integer(1)),
                            try stringIntegerDictionary(["b": 2]),
                        ]))
                    ),
                    .init(
                        arguments: [
                            try stringIntegerDictionary(["a": 1]),
                            .string("missing"),
                        ],
                        expected: .returned(.tuple([
                            .optional(nil),
                            try stringIntegerDictionary(["a": 1]),
                        ]))
                    ),
                ]
            ),
        ]

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
                "common standard-library gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    @Test("Floating extrema preserve Comparable order and IEEE sign bits")
    func preservesFloatingExtremaSemantics() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func floatingExtrema(
                _ left: Double,
                _ right: Double
            ) -> (Double, Double, Double) {
                (min(left, right), max(left, right), abs(left))
            }
            """,
            functionName: "floatingExtrema"
        )

        let zeroResult = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [
                .float64(0.0),
                .float64(-0.0),
            ]
        )
        let zeroValues = try tupleResult(zeroResult)
        #expect(try float(zeroValues[0]).bitPattern == 0.0.bitPattern)
        #expect(try float(zeroValues[1]).bitPattern == (-0.0).bitPattern)
        #expect(try float(zeroValues[2]).bitPattern == 0.0.bitPattern)

        let leftNaNResult = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [
                .float64(.nan),
                .float64(1),
            ]
        )
        let leftNaNValues = try tupleResult(leftNaNResult)
        #expect(try float(leftNaNValues[0]).isNaN)
        #expect(try float(leftNaNValues[1]).isNaN)
        #expect(try float(leftNaNValues[2]).isNaN)

        let rightNaNResult = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [
                .float64(1),
                .float64(.nan),
            ]
        )
        let rightNaNValues = try tupleResult(rightNaNResult)
        #expect(try float(rightNaNValues[0]) == 1)
        #expect(try float(rightNaNValues[1]) == 1)
        #expect(try float(rightNaNValues[2]) == 1)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }

    private func signedInteger(_ value: Int64, bitWidth: UInt16) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: bitWidth, isSigned: true))
    }

    private func unsignedInteger(_ value: UInt8) throws -> VM.Value {
        .integer(
            try VM.Integer(
                rawBits: UInt64(value),
                bitWidth: 8,
                isSigned: false
            )
        )
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func stringIntegerDictionary(
        _ values: [String: Int64]
    ) throws -> VM.Value {
        .dictionary(
            try values.sorted(by: { $0.key < $1.key }).map {
                .init(key: .string($0.key), value: try integer($0.value))
            },
            keyType: .string,
            valueType: .int64
        )
    }

    private func tupleResult(_ result: VM.ExecutionResult) throws -> [VM.Value] {
        guard case let .returned(.some(.tuple(values))) = result,
              values.count == 3
        else {
            Issue.record("expected tuple result, got \(result)")
            throw HarnessError.unexpectedResult
        }
        return values
    }

    private func float(_ value: VM.Value) throws -> Double {
        guard case let .float(number) = value, number.bitWidth == 64 else {
            Issue.record("expected Float64, got \(value)")
            throw HarnessError.unexpectedResult
        }
        return number.doubleValue
    }
}
}
