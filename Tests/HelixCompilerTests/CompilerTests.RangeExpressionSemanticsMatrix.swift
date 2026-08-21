import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift RangeExpression semantics")
struct RangeExpressionSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
        var optimization = "-Onone"
    }

    @Test("Range intrinsics are exact and owned by their semantic layer")
    func classifiesRangeIntrinsicsExactly() {
        let constructor = "$ss16PartialRangeFromVyAByxGxcfC"
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(mangledName: constructor)
                == .partialRangeConstructor(.from)
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(mangledName: constructor) == nil
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: CanonicalSIL.RangeExpression
                    .patternMatchMangledName
            ) == .rangeExpressionContains
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: CanonicalSIL.RangeExpression
                    .unboundedCollectionSubscriptMangledName
            ) == .adapter(.fullRangeSlice)
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: constructor + "forged"
            ) == nil
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: CanonicalSIL.RangeExpression
                    .unboundedCollectionSubscriptMangledName + "forged"
            ) == nil
        )
    }

    @Test("Destroyed partial-range storage cannot be read")
    func rejectsPartialRangeUseAfterDestroy() {
        let function = CanonicalSIL.Function(
            mangledName: "$sRangeUseAfterDestroy",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = alloc_stack $PartialRangeFrom<Int>
              %1 = integer_literal $Builtin.Int64, 0
              %2 = struct $Int (%1)
              %3 = metatype $@thin PartialRangeFrom<Int>.Type
              %4 = alloc_stack $Int
              store %2 to %4
              %5 = function_ref @$ss16PartialRangeFromVyAByxGxcfC : $@convention(method) <τ_0_0 where τ_0_0 : Comparable> (@in τ_0_0, @thin PartialRangeFrom<τ_0_0>.Type) -> @out PartialRangeFrom<τ_0_0>
              %6 = apply %5<Int>(%0, %4, %3) : $@convention(method) <τ_0_0 where τ_0_0 : Comparable> (@in τ_0_0, @thin PartialRangeFrom<τ_0_0>.Type) -> @out PartialRangeFrom<τ_0_0>
              dealloc_stack %4
              destroy_addr %0
              %7 = load %0
              destroy_value %7
              dealloc_stack %0
              %8 = tuple ()
              return %8
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "rangeUseAfterDestroy"
            )
        }
    }

    @Test("One-sided containment reuses typed scalar comparison")
    func lowersOneSidedContainment() throws {
        try run([
            .init(
                name: "numericPartialContains",
                source: """
                public func numericPartialContains(
                    _ integer: Int,
                    _ double: Double
                ) -> (Bool, Bool, Bool, Bool, Bool, Bool) {
                    (
                        (0...).contains(integer),
                        (..<3).contains(integer),
                        (...3).contains(integer),
                        (0.5...).contains(double),
                        (..<2.5).contains(double),
                        (...2.5).contains(double)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(-1), .float64(.nan)],
                        expected: .returned(
                            .tuple([
                                .bool(false), .bool(true), .bool(true),
                                .bool(false), .bool(false), .bool(false),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try integer(3), .float64(2.5)],
                        expected: .returned(
                            .tuple([
                                .bool(true), .bool(false), .bool(true),
                                .bool(true), .bool(false), .bool(true),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "narrowPartialContains",
                source: """
                public func narrowPartialContains(
                    _ lower: UInt8,
                    _ upper: UInt8,
                    _ value: UInt8
                ) -> (Bool, Bool, Bool) {
                    (
                        (lower...).contains(value),
                        (..<upper).contains(value),
                        (...upper).contains(value)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsignedInteger(2, width: 8),
                            try unsignedInteger(4, width: 8),
                            try unsignedInteger(4, width: 8),
                        ],
                        expected: .returned(
                            .tuple([.bool(true), .bool(false), .bool(true)])
                        )
                    ),
                ]
            ),
            .init(
                name: "stringPartialContains",
                source: """
                public func stringPartialContains(
                    _ value: String
                ) -> (Bool, Bool) {
                    ((..."m").contains(value), ("n"...).contains(value))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.string("m")],
                        expected: .returned(.tuple([.bool(true), .bool(false)]))
                    ),
                    .init(
                        arguments: [.string("n")],
                        expected: .returned(.tuple([.bool(false), .bool(true)]))
                    ),
                    .init(
                        arguments: [.string("z")],
                        expected: .returned(.tuple([.bool(false), .bool(true)]))
                    ),
                ]
            ),
            .init(
                name: "dynamicPartialFrom",
                source: """
                public func dynamicPartialFrom(
                    _ bound: Double,
                    _ value: Double
                ) -> Bool {
                    (bound...).contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(1), .float64(2)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.float64(.nan), .float64(2)],
                        expected: .trapped(
                            .explicit(
                                "Range cannot have an unordered lower bound."
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "dynamicPartialThrough",
                source: """
                public func dynamicPartialThrough(
                    _ bound: Double,
                    _ value: Double
                ) -> Bool {
                    (...bound).contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(1), .float64(2)],
                        expected: .returned(.bool(false))
                    ),
                    .init(
                        arguments: [.float64(.nan), .float64(2)],
                        expected: .trapped(
                            .explicit(
                                "Range cannot have an unordered upper bound."
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "storedPartialContains",
                source: """
                public func storedPartialContains(
                    _ lower: Int,
                    _ upper: Int,
                    _ first: Int,
                    _ second: Int
                ) -> (Bool, Bool, Bool, Bool) {
                    let suffix = lower...
                    let prefix = ..<upper
                    let inclusivePrefix = ...upper
                    return (
                        suffix.contains(first),
                        suffix ~= second,
                        prefix ~= first,
                        inclusivePrefix.contains(second)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integer(2), try integer(4),
                            try integer(3), try integer(4),
                        ],
                        expected: .returned(
                            .tuple([
                                .bool(true), .bool(true),
                                .bool(true), .bool(true),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "reassignedStringPartial",
                source: """
                public func reassignedStringPartial(
                    _ initial: String,
                    _ replacement: String,
                    _ value: String
                ) -> Bool {
                    var range = initial...
                    range = replacement...
                    return range.contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .string("z"), .string("m"), .string("n"),
                        ],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [
                            .string("a"), .string("z"), .string("n"),
                        ],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            .init(
                name: "optimizedDynamicPartial",
                source: """
                public func optimizedDynamicPartial(
                    _ lower: Double,
                    _ upper: Double,
                    _ value: Double
                ) -> (Bool, Bool) {
                    (
                        (lower...).contains(value),
                        (...upper).contains(value)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(1), .float64(3), .float64(2)],
                        expected: .returned(.tuple([.bool(true), .bool(true)]))
                    ),
                    .init(
                        arguments: [
                            .float64(.nan), .float64(3), .float64(2),
                        ],
                        expected: .trapped(
                            .explicit(
                                "Range cannot have an unordered lower bound."
                            )
                        )
                    ),
                    .init(
                        arguments: [
                            .float64(1), .float64(.nan), .float64(2),
                        ],
                        expected: .trapped(
                            .explicit(
                                "Range cannot have an unordered upper bound."
                            )
                        )
                    ),
                ],
                optimization: "-O"
            ),
        ])
    }

    @Test("Range patterns share one RangeExpression containment plan")
    func lowersRangePatterns() throws {
        let source = """
        public func rangePatterns(_ value: Int) -> Int {
            switch value {
            case ...0: -2
            case 1..<3: -1
            case 3...4: 1
            case 5...: 2
            default: 0
            }
        }
        """
        let scenarios: [Scenario] = [
            .init(arguments: [try integer(-8)], expected: .returned(try integer(-2))),
            .init(arguments: [try integer(0)], expected: .returned(try integer(-2))),
            .init(arguments: [try integer(1)], expected: .returned(try integer(-1))),
            .init(arguments: [try integer(2)], expected: .returned(try integer(-1))),
            .init(arguments: [try integer(3)], expected: .returned(try integer(1))),
            .init(arguments: [try integer(4)], expected: .returned(try integer(1))),
            .init(arguments: [try integer(5)], expected: .returned(try integer(2))),
            .init(arguments: [try integer(99)], expected: .returned(try integer(2))),
        ]
        try run([
            .init(
                name: "rangePatterns",
                source: source,
                scenarios: scenarios
            ),
            .init(
                name: "rangePatterns",
                source: source,
                scenarios: scenarios,
                optimization: "-O"
            ),
            .init(
                name: "floatingPartialPattern",
                source: """
                public func floatingPartialPattern(_ value: Double) -> Int {
                    switch value {
                    case ...0: -1
                    case 1...: 1
                    default: 0
                    }
                }
                """,
                scenarios: [
                    .init(arguments: [.float64(-0.0)], expected: .returned(try integer(-1))),
                    .init(arguments: [.float64(2)], expected: .returned(try integer(1))),
                    .init(arguments: [.float64(.nan)], expected: .returned(try integer(0))),
                ]
            ),
            .init(
                name: "stringPartialPattern",
                source: """
                public func stringPartialPattern(_ value: String) -> Int {
                    switch value {
                    case ..."m": -1
                    case "n"...: 1
                    default: 0
                    }
                }
                """,
                scenarios: [
                    .init(arguments: [.string("a")], expected: .returned(try integer(-1))),
                    .init(arguments: [.string("m")], expected: .returned(try integer(-1))),
                    .init(arguments: [.string("n")], expected: .returned(try integer(1))),
                    .init(arguments: [.string("z")], expected: .returned(try integer(1))),
                ]
            ),
            .init(
                name: "characterPartialPattern",
                source: """
                public func characterPartialPattern(
                    _ value: Character
                ) -> Bool {
                    switch value {
                    case ..."m": true
                    default: false
                    }
                }
                """,
                scenarios: [
                    .init(arguments: [.string("a")], expected: .returned(.bool(true))),
                    .init(arguments: [.string("m")], expected: .returned(.bool(true))),
                    .init(arguments: [.string("z")], expected: .returned(.bool(false))),
                ]
            ),
            .init(
                name: "explicitPatternOperator",
                source: """
                public func explicitPatternOperator(
                    _ lower: Int,
                    _ upper: Int,
                    _ value: Int
                ) -> (Bool, Bool) {
                    ((lower..<upper) ~= value, (lower...upper) ~= value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integer(1), try integer(3), try integer(3),
                        ],
                        expected: .returned(
                            .tuple([.bool(false), .bool(true)])
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Unrepresented RangeExpression bounds fail closed")
    func rejectsUnrepresentedRangeExpressionBounds() {
        expectUnsupported(
            name: "customPartialContains",
            source: """
            public struct Token: Comparable {
                public var raw: Int

                public static func < (lhs: Token, rhs: Token) -> Bool {
                    lhs.raw < rhs.raw
                }
            }

            public func customPartialContains(_ value: Token) -> Bool {
                (Token(raw: 0)...).contains(value)
            }
            """,
            diagnostic: "PartialRangeFrom<Token>"
        )
        expectUnsupported(
            name: "stringIndexPartialSlice",
            source: """
            public func stringIndexPartialSlice(_ value: String) -> String {
                String(value[value.startIndex...])
            }
            """,
            diagnostic: "String.Index"
        )
        expectUnsupported(
            name: "derivedArraySlicePartial",
            source: """
            public func derivedArraySlicePartial(_ values: [Int]) -> [Int] {
                let tail = values.dropFirst()
                return Array(tail[2...])
            }
            """,
            diagnostic: "ArraySlice<Int>"
        )
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
                moduleName: "HelixRangeExpressionNegative_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected \(name) diagnostic: \(error)")
                return
            }
            #expect(detail.contains(diagnostic))
        } catch {
            Issue.record("unexpected \(name) diagnostic: \(error)")
        }
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for (probeIndex, probe) in probes.enumerated() {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixRangeExpression_\(probeIndex)_\(probe.name)",
                    optimization: probe.optimization
                )
                let disassembly = Bytecode.Disassembler.disassemble(
                    fixture.image.module
                )
                if disassembly.contains("native_apply") {
                    failures.append("\(probe.name): emitted native_apply")
                }
                for (scenarioIndex, scenario) in probe.scenarios.enumerated() {
                    let actual = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if actual != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(scenarioIndex)]: expected "
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
                "RangeExpression semantic gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func unsignedInteger(
        _ value: UInt64,
        width: UInt16
    ) throws -> VM.Value {
        .integer(try .init(rawBits: value, bitWidth: width, isSigned: false))
    }
}
}
