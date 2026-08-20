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
            Probe(
                name: "ifExpression",
                source: """
                public func ifExpression(_ value: Int) -> Int {
                    let magnitude = if value >= 0 { value } else { -value }
                    return magnitude
                }
                """,
                arguments: [try integer(-8)],
                expected: try integer(8)
            ),
            Probe(
                name: "switchExpression",
                source: """
                public func switchExpression(_ value: Int) -> String {
                    let description = switch value {
                    case -1: "negative one"
                    case 0: "zero"
                    default: "other"
                    }
                    return description
                }
                """,
                arguments: [try integer(-1)],
                expected: .string("negative one")
            ),
            Probe(
                name: "multipleOptionalBindings",
                source: """
                public func multipleOptionalBindings(
                    _ first: Int?,
                    _ second: Int?
                ) -> Int {
                    if let first, let second, first < second {
                        return second - first
                    }
                    return 0
                }
                """,
                arguments: [
                    .optional(try integer(3)),
                    .optional(try integer(9)),
                ],
                expected: try integer(6)
            ),
            Probe(
                name: "filteredForLoop",
                source: """
                public func filteredForLoop(_ values: [Int]) -> Int {
                    var total = 0
                    for value in values where value > 0 {
                        total += value
                    }
                    return total
                }
                """,
                arguments: [try integers([-2, 3, 0, 5])],
                expected: try integer(8)
            ),
            Probe(
                name: "tuplePatternSwitch",
                source: """
                public func tuplePatternSwitch(
                    _ first: Int?,
                    _ second: Int?
                ) -> Int {
                    switch (first, second) {
                    case let (.some(left), .some(right)):
                        return left + right
                    case (.some, .none):
                        return 1
                    default:
                        return 0
                    }
                }
                """,
                arguments: [
                    .optional(try integer(4)),
                    .optional(try integer(7)),
                ],
                expected: try integer(11)
            ),
            Probe(
                name: "localFunctionValue",
                source: """
                public func localFunctionValue(_ value: Int) -> Int {
                    func adjusted(_ input: Int) -> Int {
                        input * 2 + value
                    }
                    return adjusted(3)
                }
                """,
                arguments: [try integer(4)],
                expected: try integer(10)
            ),
            Probe(
                name: "closureValue",
                source: """
                public func closureValue(_ value: Int) -> Int {
                    let transform: (Int) -> Int = { input in
                        input * 2 + value
                    }
                    return transform(3)
                }
                """,
                arguments: [try integer(4)],
                expected: try integer(10)
            ),
            Probe(
                name: "guardCaseValue",
                source: """
                public func guardCaseValue(_ value: Int?) -> Int {
                    guard case let .some(number) = value else { return 0 }
                    return number
                }
                """,
                arguments: [.optional(try integer(12))],
                expected: try integer(12)
            ),
            Probe(
                name: "whileCaseValue",
                source: """
                public func whileCaseValue(_ input: Int?) -> Int {
                    var current = input
                    var result = 0
                    while case let value? = current {
                        result += value
                        current = nil
                    }
                    return result
                }
                """,
                arguments: [.optional(try integer(6))],
                expected: try integer(6)
            ),
            Probe(
                name: "operatorReduction",
                source: """
                public func operatorReduction(_ values: [Int]) -> Int {
                    values.reduce(0, +)
                }
                """,
                arguments: [try integers([2, 3, 5])],
                expected: try integer(10)
            ),
            Probe(
                name: "operatorComparator",
                source: """
                public func operatorComparator(_ values: [Int]) -> [Int] {
                    values.sorted(by: >)
                }
                """,
                arguments: [try integers([2, 5, 3])],
                expected: try integers([5, 3, 2])
            ),
            Probe(
                name: "localFunctionTransform",
                source: """
                public func localFunctionTransform(_ values: [Int]) -> [Int] {
                    func adjusted(_ value: Int) -> Int { value * 2 + 1 }
                    return values.map(adjusted)
                }
                """,
                arguments: [try integers([2, 4])],
                expected: try integers([5, 9])
            ),
            Probe(
                name: "sdkPropertyKeyPath",
                source: """
                public func sdkPropertyKeyPath(_ values: [String]) -> Int {
                    values.map(\\.count).reduce(0, +)
                }
                """,
                arguments: [strings(["ab", "cde"])],
                expected: try integer(5)
            ),
            Probe(
                name: "storedPropertyKeyPath",
                source: """
                private struct KeyPathItem { let value: Int }
                public func storedPropertyKeyPath(
                    _ first: Int,
                    _ second: Int
                ) -> Int {
                    [KeyPathItem(value: first), KeyPathItem(value: second)]
                        .map(\\.value)
                        .reduce(0, +)
                }
                """,
                arguments: [try integer(4), try integer(7)],
                expected: try integer(11)
            ),
            Probe(
                name: "composedStoredKeyPath",
                source: """
                private struct KeyPathLeaf { let value: Int }
                private struct KeyPathContainer { let leaf: KeyPathLeaf }
                public func composedStoredKeyPath(
                    _ first: Int,
                    _ second: Int
                ) -> Int {
                    let values = [
                        KeyPathContainer(leaf: KeyPathLeaf(value: first)),
                        KeyPathContainer(leaf: KeyPathLeaf(value: second)),
                    ]
                    return values.map(\\.leaf.value).reduce(0, +)
                }
                """,
                arguments: [try integer(3), try integer(8)],
                expected: try integer(11)
            ),
            Probe(
                name: "computedPropertyKeyPath",
                source: """
                private struct KeyPathMeasure {
                    let value: Int
                    var doubled: Int { value * 2 }
                }
                public func computedPropertyKeyPath(_ value: Int) -> Int {
                    [KeyPathMeasure(value: value)].map(\\.doubled)[0]
                }
                """,
                arguments: [try integer(6)],
                expected: try integer(12)
            ),
            Probe(
                name: "mixedPropertyKeyPath",
                source: """
                private struct KeyPathName { let text: String }
                public func mixedPropertyKeyPath(_ values: [String]) -> Int {
                    values.map(KeyPathName.init(text:))
                        .map(\\.text.count)
                        .reduce(0, +)
                }
                """,
                arguments: [strings(["swift", "ui"])],
                expected: try integer(7)
            ),
            Probe(
                name: "classStoredPropertyKeyPath",
                source: """
                private final class KeyPathBox {
                    let value: Int
                    init(value: Int) { self.value = value }
                }
                public func classStoredPropertyKeyPath(_ value: Int) -> Int {
                    [KeyPathBox(value: value)].map(\\.value)[0]
                }
                """,
                arguments: [try integer(13)],
                expected: try integer(13)
            ),
            Probe(
                name: "directStoredKeyPath",
                source: """
                private struct DirectKeyPathItem { let value: Int }
                public func directStoredKeyPath(_ value: Int) -> Int {
                    let item = DirectKeyPathItem(value: value)
                    return item[keyPath: \\DirectKeyPathItem.value]
                }
                """,
                arguments: [try integer(17)],
                expected: try integer(17)
            ),
            Probe(
                name: "localKeyPathBinding",
                source: """
                public func localKeyPathBinding(_ value: String) -> Int {
                    let path = \\String.count
                    return value[keyPath: path]
                }
                """,
                arguments: [.string("helix")],
                expected: try integer(5)
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

    @Test("Force unwrap preserves Optional payloads and nil traps")
    func lowersForceUnwrap() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func forcedOptionals(
                _ number: Int?,
                _ text: String?
            ) -> (Int, String) {
                (number!, text!)
            }
            """,
            functionName: "forcedOptionals",
            moduleName: "HelixForcedOptionalsFixture"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .optional(try integer(7)),
                    .optional(.string("value")),
                ]
            ) == .returned(.tuple([try integer(7), .string("value")]))
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.optional(nil), .optional(.string("value"))]
            ) == .trapped(.optionalUnwrapOfNil)
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.optional(try integer(7)), .optional(nil)]
            ) == .trapped(.optionalUnwrapOfNil)
        )
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

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
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
