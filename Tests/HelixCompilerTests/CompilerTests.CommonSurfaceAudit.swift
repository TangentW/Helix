import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Common Swift surface audit")
struct CommonSurfaceAudit {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult

        init(arguments: [VM.Value] = [], expected: VM.Value) {
            self.arguments = arguments
            self.expected = .returned(expected)
        }
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]

        init(
            name: String,
            source: String,
            scenarios: [Scenario]
        ) {
            self.name = name
            self.source = source
            self.scenarios = scenarios
        }

        init(
            name: String,
            source: String,
            arguments: [VM.Value] = [],
            expected: VM.Value
        ) {
            self.init(
                name: name,
                source: source,
                scenarios: [.init(arguments: arguments, expected: expected)]
            )
        }
    }

    @Test("Common language and standard-library forms execute from real SIL")
    func executesCommonSurface() throws {
        try execute([
            Probe(
                name: "toggledBool",
                source: """
                public func toggledBool(_ value: Bool) -> Bool {
                    var result = value
                    result.toggle()
                    return result
                }
                """,
                scenarios: [
                    .init(arguments: [.bool(false)], expected: .bool(true)),
                    .init(arguments: [.bool(true)], expected: .bool(false)),
                ]
            ),
            Probe(
                name: "capturedToggle",
                source: """
                public func capturedToggle(_ value: Bool) -> Bool {
                    var result = value
                    let apply = { result.toggle() }
                    apply()
                    return result
                }
                """,
                arguments: [.bool(true)],
                expected: .bool(false)
            ),
            Probe(
                name: "swappedValues",
                source: """
                public func swappedValues(
                    _ first: Int,
                    _ second: Int
                ) -> (Int, Int) {
                    var left = first
                    var right = second
                    swap(&left, &right)
                    return (left, right)
                }
                """,
                arguments: [try integer(3), try integer(9)],
                expected: .tuple([try integer(9), try integer(3)])
            ),
            Probe(
                name: "swappedTupleFields",
                source: """
                public func swappedTupleFields(
                    _ first: Int,
                    _ second: Int
                ) -> (Int, Int) {
                    var pair = (first, second)
                    swap(&pair.0, &pair.1)
                    return pair
                }
                """,
                arguments: [try integer(4), try integer(8)],
                expected: .tuple([try integer(8), try integer(4)])
            ),
            Probe(
                name: "capturedSwap",
                source: """
                public func capturedSwap(
                    _ first: String,
                    _ second: String
                ) -> String {
                    var left = first
                    var right = second
                    let apply = { swap(&left, &right) }
                    apply()
                    return left + ":" + right
                }
                """,
                arguments: [.string("left"), .string("right")],
                expected: .string("right:left")
            ),
            Probe(
                name: "swappedOptionalText",
                source: """
                public func swappedOptionalText(
                    _ first: String?,
                    _ second: String?
                ) -> (String?, String?) {
                    var left = first
                    var right = second
                    swap(&left, &right)
                    return (left, right)
                }
                """,
                arguments: [.optional(.string("value")), .optional(nil)],
                expected: .tuple([
                    .optional(nil),
                    .optional(.string("value")),
                ])
            ),
            Probe(
                name: "swappedLocalValues",
                source: """
                private struct AuditBox {
                    var number: Int
                    var text: String
                }
                public func swappedLocalValues(
                    _ first: Int,
                    _ second: Int
                ) -> (Int, String, Int, String) {
                    var left = AuditBox(number: first, text: "left")
                    var right = AuditBox(number: second, text: "right")
                    swap(&left, &right)
                    return (left.number, left.text, right.number, right.text)
                }
                """,
                arguments: [try integer(2), try integer(7)],
                expected: .tuple([
                    try integer(7), .string("right"),
                    try integer(2), .string("left"),
                ])
            ),
            Probe(
                name: "rawEnumValue",
                source: """
                private enum AuditState: Int {
                    case idle = 2
                    case running = 7
                }
                public func rawEnumValue(_ raw: Int) -> Int {
                    AuditState(rawValue: raw)?.rawValue ?? -1
                }
                """,
                scenarios: [
                    .init(arguments: [try integer(7)], expected: try integer(7)),
                    .init(arguments: [try integer(3)], expected: try integer(-1)),
                ]
            ),
            Probe(
                name: "allEnumCases",
                source: """
                private enum AuditDirection: Int, CaseIterable {
                    case north, east, south, west
                }
                public func allEnumCases() -> Int {
                    AuditDirection.allCases.map(\\.rawValue).reduce(0, +)
                }
                """,
                expected: try integer(6)
            ),
            Probe(
                name: "commaEnumPayload",
                source: """
                private enum AuditPayload {
                    case number(Int), text(label: String), `default`
                }
                public func commaEnumPayload(_ selector: Int) -> Int {
                    let payload: AuditPayload
                    if selector == 0 { payload = .number(5) }
                    else if selector == 1 { payload = .text(label: "swift") }
                    else { payload = .default }
                    switch payload {
                    case let .number(value): return value
                    case let .text(label): return label.count
                    case .default: return -1
                    }
                }
                """,
                scenarios: [
                    .init(arguments: [try integer(0)], expected: try integer(5)),
                    .init(arguments: [try integer(1)], expected: try integer(5)),
                    .init(arguments: [try integer(2)], expected: try integer(-1)),
                ]
            ),
            Probe(
                name: "customSubscript",
                source: """
                private struct AuditPair {
                    var first: Int
                    var second: Int
                    subscript(index: Int) -> Int {
                        get { index == 0 ? first : second }
                        set {
                            if index == 0 { first = newValue }
                            else { second = newValue }
                        }
                    }
                }
                public func customSubscript(_ value: Int) -> Int {
                    var pair = AuditPair(first: 1, second: 2)
                    pair[1] = value
                    return pair[0] + pair[1]
                }
                """,
                arguments: [try integer(9)],
                expected: try integer(10)
            ),
            Probe(
                name: "observedProperty",
                source: """
                private struct AuditObserved {
                    var changes: Int = 0
                    var value: Int {
                        willSet { changes += newValue }
                        didSet { changes += oldValue }
                    }
                }
                public func observedProperty(_ value: Int) -> Int {
                    var observed = AuditObserved(value: 2)
                    observed.value = value
                    return observed.changes
                }
                """,
                arguments: [try integer(5)],
                expected: try integer(7)
            ),
            Probe(
                name: "variadicSum",
                source: """
                private func auditSum(_ values: Int...) -> Int {
                    values.reduce(0, +)
                }
                public func variadicSum(_ value: Int) -> Int {
                    auditSum(value, 2, 3)
                }
                """,
                arguments: [try integer(4)],
                expected: try integer(9)
            ),
            Probe(
                name: "autoclosureValue",
                source: """
                private func auditChoose(
                    _ condition: Bool,
                    _ value: @autoclosure () -> Int
                ) -> Int {
                    condition ? value() : 0
                }
                public func autoclosureValue(
                    _ condition: Bool,
                    _ value: Int
                ) -> Int {
                    auditChoose(condition, value + 1)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true), try integer(4)],
                        expected: try integer(5)
                    ),
                    .init(
                        arguments: [.bool(false), try integer(4)],
                        expected: try integer(0)
                    ),
                ]
            ),
            Probe(
                name: "optionalChainMutation",
                source: """
                private struct AuditCounter { var value: Int }
                public func optionalChainMutation(_ present: Bool) -> Int {
                    var counter: AuditCounter? = present
                        ? AuditCounter(value: 1) : nil
                    counter?.value += 2
                    return counter?.value ?? -1
                }
                """,
                scenarios: [
                    .init(arguments: [.bool(true)], expected: try integer(3)),
                    .init(arguments: [.bool(false)], expected: try integer(-1)),
                ]
            ),
            Probe(
                name: "sourceLiteralValue",
                source: """
                public func sourceLiteralValue() -> Int {
                    #function.count
                }
                """,
                expected: try integer(20)
            ),
            Probe(
                name: "memoryLayoutValue",
                source: """
                public func memoryLayoutValue() -> Int {
                    MemoryLayout<Int>.size + MemoryLayout<Int>.alignment
                }
                """,
                expected: try integer(16)
            ),
            Probe(
                name: "overlappingRanges",
                source: """
                public func overlappingRanges(
                    _ firstLower: Int,
                    _ firstUpper: Int,
                    _ secondLower: Int,
                    _ secondUpper: Int
                ) -> Bool {
                    (firstLower..<firstUpper)
                        .overlaps(secondLower..<secondUpper)
                }
                """,
                scenarios: [
                    .init(
                        arguments: try integers([0, 2, 2, 4]),
                        expected: .bool(false)
                    ),
                    .init(
                        arguments: try integers([0, 3, 2, 5]),
                        expected: .bool(true)
                    ),
                    .init(
                        arguments: try integers([2, 2, 1, 4]),
                        expected: .bool(false)
                    ),
                ]
            ),
            Probe(
                name: "textRangeOverlap",
                source: """
                public func textRangeOverlap(
                    _ firstLower: String,
                    _ firstUpper: String,
                    _ secondLower: String,
                    _ secondUpper: String
                ) -> Bool {
                    (firstLower..<firstUpper)
                        .overlaps(secondLower..<secondUpper)
                }
                """,
                arguments: [
                    .string("ant"), .string("fox"),
                    .string("cat"), .string("yak"),
                ],
                expected: .bool(true)
            ),
            Probe(
                name: "clampedRange",
                source: """
                public func clampedRange(
                    _ lower: Int,
                    _ upper: Int,
                    _ boundLower: Int,
                    _ boundUpper: Int
                ) -> Int {
                    (lower..<upper)
                        .clamped(to: boundLower..<boundUpper).count
                }
                """,
                scenarios: [
                    .init(
                        arguments: try integers([0, 2, 5, 8]),
                        expected: try integer(0)
                    ),
                    .init(
                        arguments: try integers([9, 12, 5, 8]),
                        expected: try integer(0)
                    ),
                    .init(
                        arguments: try integers([3, 10, 5, 8]),
                        expected: try integer(3)
                    ),
                ]
            ),
            Probe(
                name: "clampedTextRange",
                source: """
                public func clampedTextRange(
                    _ lower: String,
                    _ upper: String,
                    _ boundLower: String,
                    _ boundUpper: String
                ) -> String {
                    let result = (lower..<upper)
                        .clamped(to: boundLower..<boundUpper)
                    return result.lowerBound + ":" + result.upperBound
                }
                """,
                arguments: [
                    .string("ant"), .string("yak"),
                    .string("cat"), .string("fox"),
                ],
                expected: .string("cat:fox")
            ),
            Probe(
                name: "equatableLocalValue",
                source: """
                private struct AuditPoint: Equatable {
                    var x: Int
                    var y: Int
                }
                public func equatableLocalValue(_ x: Int, _ y: Int) -> Bool {
                    AuditPoint(x: x, y: y) == AuditPoint(x: y, y: x)
                }
                """,
                scenarios: [
                    .init(
                        arguments: try integers([1, 2]),
                        expected: .bool(false)
                    ),
                    .init(
                        arguments: try integers([3, 3]),
                        expected: .bool(true)
                    ),
                ]
            ),
            Probe(
                name: "anyLocalValue",
                source: """
                private struct AuditPayload { var value: Int }
                public func anyLocalValue(_ value: Int) -> Int {
                    let erased: Any = AuditPayload(value: value)
                    return (erased as? AuditPayload)?.value ?? -1
                }
                """,
                arguments: [try integer(13)],
                expected: try integer(13)
            ),
        ])
    }

    @Test("Floating Range clamping preserves a bound selected on equality")
    func preservesSignedZeroWhileClamping() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func clampedFloatingLower(_ lower: Double) -> Double {
                (lower..<1.0).clamped(to: 0.0..<2.0).lowerBound
            }
            """,
            functionName: "clampedFloatingLower",
            moduleName: "HelixCommonSurface_ClampedFloatingLower"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [.float(.init(-0.0))]
        )
        guard case let .returned(.float(value)) = result else {
            Issue.record("expected a floating result, got \(result)")
            return
        }
        #expect(value.bitPattern == (-0.0 as Double).bitPattern)
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Comma enum declarations are bounded and fail closed")
    func validatesCommaEnumDeclarations() throws {
        let environment = try CanonicalSIL.TypeEnvironment(
            text: """
            enum Payload {
              indirect case number(Int), labeled(value: String), `default`
            }
            """,
            functions: []
        )
        let key = Bytecode.LocalTypeKey(rawValue: "Payload")
        #expect(try environment.enumCaseIndex(type: key, name: "number") == 0)
        #expect(try environment.enumCaseIndex(type: key, name: "labeled") == 1)
        #expect(try environment.enumCaseIndex(type: key, name: "`default`") == 2)

        expectMalformedEnum(
            """
            enum Duplicate {
              case first, first
            }
            """,
            diagnostic: "duplicate enum case Duplicate.first"
        )
        expectMalformedEnum(
            """
            enum EmptyPayload {
              case value(Int,, String)
            }
            """,
            diagnostic: "empty associated value"
        )
    }

    @Test("Concrete generic helpers compile while opaque stateful values fail closed")
    func preservesCurrentFrontierDiagnostics() throws {
        let specializedGeneric = try FrontendExecutionHarness.compile(
            source: """
            private func auditIdentity<T>(_ value: T) -> T { value }
            public func specializedGeneric(_ value: Int) -> Int {
                auditIdentity(value) + auditIdentity(1)
            }
            """,
            functionName: "specializedGeneric",
            moduleName: "HelixCommonSurface_specializedGeneric"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: specializedGeneric.entry,
                image: specializedGeneric.image,
                arguments: [try integer(5)]
            ) == .returned(try integer(6))
        )
        expectUnsupported(
            name: "appliedDifference",
            source: """
            public func appliedDifference(
                _ old: [Int],
                _ new: [Int]
            ) -> [Int] {
                old.applying(new.difference(from: old)) ?? []
            }
            """,
            diagnostic: "CollectionDifference<Int>"
        )
        expectUnsupported(
            name: "lazyMappedValues",
            source: """
            public func lazyMappedValues(_ values: [Int]) -> [Int] {
                Array(values.lazy.map { $0 * 2 })
            }
            """,
            diagnostic: "LazyMapSequence<Array<Int>, Int>"
        )
        expectUnsupported(
            name: "generatedSequence",
            source: """
            public func generatedSequence(_ start: Int) -> [Int] {
                Array(sequence(first: start) {
                    $0 < start + 2 ? $0 + 1 : nil
                })
            }
            """,
            diagnostic: "UnfoldSequence<Int, (Optional<Int>, Bool)>"
        )
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixCommonSurface_\(probe.name)"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
                                + "\(scenario.expected), got \(result)"
                        )
                    }
                }
                if !fixture.image.module.imports.isEmpty {
                    failures.append(
                        "\(probe.name): unexpectedly required NativeImport"
                    )
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "common Swift execution gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func expectMalformedEnum(
        _ text: String,
        diagnostic: String
    ) {
        do {
            _ = try CanonicalSIL.TypeEnvironment(text: text, functions: [])
            Issue.record("malformed enum unexpectedly parsed")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains(diagnostic))
        } catch {
            Issue.record("malformed enum produced an unexpected error: \(error)")
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
                moduleName: "HelixCommonSurface_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch {
            #expect(String(describing: error).contains(diagnostic))
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> [VM.Value] {
        try values.map(integer)
    }
}
}
