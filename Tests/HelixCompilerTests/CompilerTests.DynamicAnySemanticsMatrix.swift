import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Recursive Swift Any semantics")
struct DynamicAnySemanticsMatrix {
    @Test("Dynamic type parsing is bounded before descriptor construction")
    func rejectsOverdeepDynamicType() {
        var spelling = "Int"
        var storage = Bytecode.ValueType.int64
        for _ in 0...Bytecode.DynamicType.maximumNestingDepthV1 {
            spelling = "Optional<\(spelling)>"
            storage = .optional(storage)
        }

        do {
            _ = try CanonicalSIL.DynamicType.parse(spelling) { _ in storage }
            Issue.record("expected an overdeep dynamic type to be rejected")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected lowering error: \(error)")
                return
            }
            #expect(detail.contains("nesting depth"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Dynamic casts distinguish scalar and text types that share storage")
    func distinguishesSharedScalarStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func distinguishesSharedScalarStorage(
                _ int: Int,
                _ int64: Int64,
                _ uint: UInt,
                _ uint64: UInt64,
                _ character: Character,
                _ string: String,
                _ cgFloat: CGFloat,
                _ double: Double
            ) -> (
                Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool,
                Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool
            ) {
                let values: [Any] = [
                    int, int64, uint, uint64,
                    character, string, cgFloat, double,
                ]
                return (
                    values[0] is Int,
                    values[0] is Int64,
                    values[1] is Int,
                    values[1] is Int64,
                    values[2] is UInt,
                    values[2] is UInt64,
                    values[3] is UInt,
                    values[3] is UInt64,
                    values[4] is Character,
                    values[4] is String,
                    values[5] is Character,
                    values[5] is String,
                    values[6] is CGFloat,
                    values[6] is Double,
                    values[7] is CGFloat,
                    values[7] is Double
                )
            }
            """,
            functionName: "distinguishesSharedScalarStorage",
            moduleName: "HelixDynamicAnySharedScalars"
        )

        #expect(
            invoke(
                fixture,
                arguments: [
                    try integer(1),
                    try integer(2),
                    try unsignedInteger(3),
                    try unsignedInteger(4),
                    .string("👩🏽‍💻"),
                    .string("👩🏽‍💻"),
                    .float(.init(3.5)),
                    .float(.init(4.5)),
                ]
            ) == .returned(
                .tuple([
                    .bool(true), .bool(false),
                    .bool(false), .bool(true),
                    .bool(true), .bool(false),
                    .bool(false), .bool(true),
                    .bool(true), .bool(false),
                    .bool(false), .bool(true),
                    .bool(true), .bool(false),
                    .bool(false), .bool(true),
                ])
            )
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Nested text and concrete collection families retain dynamic identity")
    func distinguishesRepresentedContainers() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func distinguishesRepresentedContainers(
                _ characters: [Character],
                _ strings: [String],
                _ substring: Substring,
                _ set: Set<Character>,
                _ slice: ArraySlice<Int>
            ) -> (
                Bool, Bool, Bool, Bool, Bool, Bool,
                Bool, Bool, Bool, Bool, Bool, Bool
            ) {
                let characterValue: Any = characters
                let stringValue: Any = strings
                let substringValue: Any = substring
                let setValue: Any = set
                let sliceValue: Any = slice
                let widened = characterValue as! [Any]
                return (
                    characterValue is [Character],
                    characterValue is [String],
                    stringValue is [Character],
                    stringValue is [String],
                    widened[0] is Character,
                    widened[0] is String,
                    substringValue is Substring,
                    substringValue is [Character],
                    setValue is Set<Character>,
                    setValue is Set<String>,
                    sliceValue is ArraySlice<Int>,
                    sliceValue is [Int]
                )
            }
            """,
            functionName: "distinguishesRepresentedContainers",
            moduleName: "HelixDynamicAnyContainers"
        )
        let character = VM.Value.string("e\u{301}")
        let integer = try integer(7)

        #expect(
            invoke(
                fixture,
                arguments: [
                    .array([character], elementType: .string),
                    .array([.string("e\u{301}")], elementType: .string),
                    .array([character], elementType: .string),
                    .set(
                        .init(elements: [character], elementType: .string)
                    ),
                    .array([integer], elementType: .int64, indexBase: 4),
                ]
            ) == .returned(
                .tuple([
                    .bool(true), .bool(false),
                    .bool(false), .bool(true),
                    .bool(true), .bool(false),
                    .bool(true), .bool(false),
                    .bool(true), .bool(false),
                    .bool(true), .bool(false),
                ])
            )
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Set casts recursively preserve Optional and integer identities")
    func castsDynamicSetsRecursively() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func castsDynamicSetsRecursively(
                _ values: Set<Int?>
            ) -> (Bool, Bool, Bool) {
                let erased: Any = values
                return (
                    erased is Set<Int?>,
                    erased is Set<Int??>,
                    erased is Set<Int64?>
                )
            }
            """,
            functionName: "castsDynamicSetsRecursively",
            moduleName: "HelixDynamicAnySets"
        )
        let elementType = Bytecode.ValueType.optional(.int64)
        let values = VM.Value.set(
            .init(
                elements: [
                    .optional(try integer(1)),
                    .optional(nil),
                ],
                elementType: elementType
            )
        )

        #expect(
            invoke(fixture, arguments: [values]) == .returned(
                .tuple([.bool(true), .bool(true), .bool(false)])
            )
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Set cast collisions become a controlled Swift-semantic trap")
    func trapsOnDynamicSetCollisions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func trapsOnDynamicSetCollisions(
                _ values: Set<Int??>
            ) -> Bool {
                let erased: Any = values
                return erased is Set<Int?>
            }
            """,
            functionName: "trapsOnDynamicSetCollisions",
            moduleName: "HelixDynamicAnySetCollisions"
        )
        let sourceElement = Bytecode.ValueType.optional(.optional(.int64))
        let values = VM.Value.set(
            .init(
                elements: [
                    .optional(nil),
                    .optional(.optional(nil)),
                ],
                elementType: sourceElement
            )
        )

        #expect(
            invoke(fixture, arguments: [values]) == .trapped(
                .dynamicCastProducedDuplicateSetElement
            )
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Tuple dynamic casts follow Swift label compatibility")
    func preservesTupleLabelIdentity() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func preservesTupleLabelIdentity(
                _ value: Int,
                _ text: String
            ) -> (Bool, Bool, Bool, Bool, Bool) {
                let erased: Any = (x: value, y: text)
                let unlabeled: Any = (value, text)
                return (
                    erased is (x: Int, y: String),
                    erased is (Int, String),
                    erased is (a: Int, b: String),
                    erased is (x: Int, String),
                    unlabeled is (x: Int, y: String)
                )
            }
            """,
            functionName: "preservesTupleLabelIdentity",
            moduleName: "HelixDynamicAnyTupleLabels"
        )

        let result = invoke(
            fixture,
            arguments: [try integer(3), .string("three")]
        )
        #expect(
            result == .returned(
                .tuple([
                    .bool(true), .bool(true), .bool(false), .bool(true),
                    .bool(true),
                ])
            )
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Tuple existential initialization remains path-sensitive")
    func initializesTupleExistentialsAcrossBranches() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func initializesTupleExistentialsAcrossBranches(
                _ first: Bool
            ) -> Int {
                let erased: Any
                if first {
                    erased = (x: 1, y: 2)
                } else {
                    erased = (x: 3, y: 4)
                }
                if let value = erased as? (x: Int, y: Int) {
                    return value.x + value.y
                }
                return -1
            }
            """,
            functionName: "initializesTupleExistentialsAcrossBranches",
            moduleName: "HelixDynamicAnyTupleBranches"
        )

        #expect(
            invoke(fixture, arguments: [.bool(true)])
                == .returned(try integer(3))
        )
        #expect(
            invoke(fixture, arguments: [.bool(false)])
                == .returned(try integer(7))
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        arguments: [VM.Value]
    ) -> VM.ExecutionResult {
        VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func unsignedInteger(_ value: UInt64) throws -> VM.Value {
        .integer(
            try .init(rawBits: value, bitWidth: 64, isSigned: false)
        )
    }
}
}
