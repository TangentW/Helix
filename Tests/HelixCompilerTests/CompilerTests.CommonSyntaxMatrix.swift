import HelixBytecode
import HelixVM
import Testing

extension CompilerTests {
@Suite("Common Swift syntax matrix")
struct CommonSyntaxMatrix {
    private struct Probe: Sendable {
        var name: String
        var source: String
        var arguments: [VM.Value]
        var expected: VM.Value
    }

    @Test("Common structured expressions lower from the real Swift frontend")
    func lowersStructuredExpressionMatrix() throws {
        let probes = [
            Probe(
                name: "ternaryValue",
                source: "public func ternaryValue(_ value: Int) -> Int { value > 0 ? value : -value }",
                arguments: [try integer(-3)],
                expected: try integer(3)
            ),
            Probe(
                name: "guardedValue",
                source: "public func guardedValue(_ value: Int?) -> Int { guard let value else { return 0 }; return value }",
                arguments: [.optional(nil)],
                expected: try integer(0)
            ),
            Probe(
                name: "optionalCount",
                source: "public func optionalCount(_ value: String?) -> Int { value?.count ?? 0 }",
                arguments: [.optional(.string("abc"))],
                expected: try integer(3)
            ),
            Probe(
                name: "repeatSum",
                source: """
                public func repeatSum(_ limit: Int) -> Int {
                    var index = 0
                    var total = 0
                    repeat {
                        total += index
                        index += 1
                    } while index < limit
                    return total
                }
                """,
                arguments: [try integer(4)],
                expected: try integer(6)
            ),
            Probe(
                name: "labeledLoop",
                source: """
                public func labeledLoop(_ limit: Int) -> Int {
                    var total = 0
                    outer: for left in 0..<limit {
                        for right in 0..<limit {
                            if right == 2 { continue }
                            if left + right > 6 { break outer }
                            total += 1
                        }
                    }
                    return total
                }
                """,
                arguments: [try integer(2)],
                expected: try integer(4)
            ),
            Probe(
                name: "tupleDestructure",
                source: """
                public func tupleDestructure(_ first: Int, _ second: Int) -> Int {
                    let pair = (first, second)
                    let (left, right) = pair
                    return left * 10 + right
                }
                """,
                arguments: [try integer(3), try integer(4)],
                expected: try integer(34)
            ),
            Probe(
                name: "switchWhere",
                source: """
                public func switchWhere(_ value: Int) -> Int {
                    switch value {
                    case let number where number < 0: return -1
                    case 0: return 0
                    default: return 1
                    }
                }
                """,
                arguments: [try integer(-2)],
                expected: try integer(-1)
            ),
            Probe(
                name: "ifCaseValue",
                source: """
                public func ifCaseValue(_ value: Int?) -> Int {
                    if case let .some(number) = value { return number }
                    return 0
                }
                """,
                arguments: [.optional(try integer(7))],
                expected: try integer(7)
            ),
            Probe(
                name: "whileLetValue",
                source: """
                public func whileLetValue(_ input: Int?) -> Int {
                    var current = input
                    var total = 0
                    while let value = current {
                        total += value
                        current = nil
                    }
                    return total
                }
                """,
                arguments: [.optional(try integer(5))],
                expected: try integer(5)
            ),
            Probe(
                name: "forCaseValues",
                source: """
                public func forCaseValues(_ values: [Int?]) -> Int {
                    var total = 0
                    for case let value? in values { total += value }
                    return total
                }
                """,
                arguments: [try optionalIntegers([1, nil, 3])],
                expected: try integer(4)
            ),
            Probe(
                name: "fallthroughValue",
                source: """
                public func fallthroughValue(_ value: Int) -> Int {
                    var result = 0
                    switch value {
                    case 0:
                        result += 1
                        fallthrough
                    case 1:
                        result += 2
                    default:
                        result += 4
                    }
                    return result
                }
                """,
                arguments: [try integer(0)],
                expected: try integer(3)
            ),
            Probe(
                name: "deferredReturn",
                source: """
                public func deferredReturn(_ value: Int) -> Int {
                    var result = value
                    defer { result += 1 }
                    if value < 0 { return result - 1 }
                    return result + 1
                }
                """,
                arguments: [try integer(2)],
                expected: try integer(3)
            ),
            Probe(
                name: "labeledArrayLoop",
                source: """
                public func labeledArrayLoop(_ values: [Int]) -> Int {
                    var total = 0
                    values: for value in values {
                        if value < 0 { break values }
                        if value == 0 { continue }
                        total += value
                    }
                    return total
                }
                """,
                arguments: [try integers([2, 0, 3, -1, 9])],
                expected: try integer(5)
            ),
            Probe(
                name: "earlyDictionaryReturn",
                source: """
                public func earlyDictionaryReturn(_ values: [String: Int]) -> Int {
                    for (key, value) in values {
                        if key.isEmpty { return value }
                    }
                    return 0
                }
                """,
                arguments: [try stringIntegerDictionary(["": 7])],
                expected: try integer(7)
            ),
            Probe(
                name: "deferInsideLoop",
                source: """
                public func deferInsideLoop(_ values: [Int]) -> Int {
                    var total = 0
                    for value in values {
                        defer { total += 1 }
                        if value < 0 { break }
                        total += value
                    }
                    return total
                }
                """,
                arguments: [try integers([2, -1, 5])],
                expected: try integer(4)
            ),
        ]

        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name
                )
                let result = VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: probe.arguments
                )
                guard result == .returned(probe.expected) else {
                    failures.append(
                        "\(probe.name): expected \(probe.expected), got \(result)"
                    )
                    continue
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record("common syntax gaps:\n\(failures.joined(separator: "\n"))")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func optionalIntegers(_ values: [Int64?]) throws -> VM.Value {
        .array(
            try values.map { value in
                try .optional(value.map(integer))
            },
            elementType: .optional(.int64)
        )
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
}
}
