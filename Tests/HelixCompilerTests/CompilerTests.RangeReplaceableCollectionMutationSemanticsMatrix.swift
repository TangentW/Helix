import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift represented RangeReplaceableCollection mutation semantics")
struct RangeReplaceableCollectionMutationSemanticsMatrix {
    @Test("String edge edits use extended grapheme clusters")
    func mutatesStringGraphemeEdges() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutateStringEdges(
                _ input: String
            ) -> (Character, Character, Character?, String) {
                var value = input
                let first = value.removeFirst()
                let last = value.removeLast()
                value.removeFirst(1)
                value.removeLast(1)
                let popped = value.popLast()
                return (first, last, popped, value)
            }
            """,
            functionName: "mutateStringEdges",
            moduleName: "HelixStringEdgeMutation"
        )

        #expect(
            invoke(fixture, arguments: [.string("A👩🏽‍💻B🇨🇳CéZ")])
                == .returned(.tuple([
                    .string("A"),
                    .string("Z"),
                    .optional(.string("C")),
                    .string("B🇨🇳"),
                ]))
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.character"))
        #expect(disassembly.contains("array_replace "))
        #expect(disassembly.contains("array_pop_last"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Substring uses the same mutation plan without rebuilding String")
    func mutatesNormalizedSubstringStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutateSubstringEdges(
                _ input: Substring
            ) -> (Character, Character?, Substring) {
                var value = input
                let first = value.removeFirst()
                value.removeLast(1)
                let popped = value.popLast()
                return (first, popped, value)
            }
            """,
            functionName: "mutateSubstringEdges",
            moduleName: "HelixSubstringEdgeMutation"
        )

        #expect(
            invoke(
                fixture,
                arguments: [characters(["A", "👩🏽‍💻", "B", "🇨🇳"])]
            ) == .returned(.tuple([
                .string("A"),
                .optional(.string("B")),
                characters(["👩🏽‍💻"]),
            ]))
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(!disassembly.contains("string_characters"))
        #expect(!disassembly.contains("string_join"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Counted String edge edits match Swift across grapheme boundaries")
    func matchesCountedStringReferenceMatrix() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func trimString(
                _ input: String,
                first: Int,
                last: Int
            ) -> String {
                var value = input
                value.removeFirst(first)
                value.removeLast(last)
                return value
            }
            """,
            functionName: "trimString",
            moduleName: "HelixStringCountedEdgeMatrix"
        )
        let graphemes = ["A", "👩🏽‍💻", "é", "🇨🇳", "क्‍ष", "Z"]

        for length in 0...graphemes.count {
            let input = graphemes.prefix(length).joined()
            for first in 0...length {
                for last in 0...(length - first) {
                    var expected = input
                    expected.removeFirst(first)
                    expected.removeLast(last)
                    #expect(
                        invoke(
                            fixture,
                            arguments: [
                                .string(input),
                                try integer(Int64(first)),
                                try integer(Int64(last)),
                            ]
                        ) == .returned(.string(expected))
                    )
                }
            }
        }
    }

    @Test("popLast preserves empty collections and counted edits trap at bounds")
    func handlesEmptyAndInvalidBounds() throws {
        let popFixture = try FrontendExecutionHarness.compile(
            source: """
            public func popString(_ input: String) -> (Character?, String) {
                var value = input
                return (value.popLast(), value)
            }
            """,
            functionName: "popString",
            moduleName: "HelixStringPopLast"
        )
        #expect(
            invoke(popFixture, arguments: [.string("")])
                == .returned(.tuple([.optional(nil), .string("")]))
        )
        #expect(
            invoke(popFixture, arguments: [.string("👨‍👩‍👧‍👦")])
                == .returned(.tuple([
                    .optional(.string("👨‍👩‍👧‍👦")), .string(""),
                ]))
        )

        let countFixture = try FrontendExecutionHarness.compile(
            source: """
            public func removeStringPrefix(
                _ input: String,
                _ count: Int
            ) -> String {
                var value = input
                value.removeFirst(count)
                return value
            }
            """,
            functionName: "removeStringPrefix",
            moduleName: "HelixStringRemovalBounds"
        )
        #expect(
            invoke(
                countFixture,
                arguments: [.string("A🇨🇳"), try integer(-1)]
            ) == .trapped(
                .explicit("Collection removal count must not be negative")
            )
        )
        #expect(
            invoke(
                countFixture,
                arguments: [.string("A🇨🇳"), try integer(3)]
            ) == .trapped(.arrayIndexOutOfBounds(index: 3, count: 2))
        )

        let suffixFixture = try FrontendExecutionHarness.compile(
            source: """
            public func removeStringSuffix(
                _ input: String,
                _ count: Int
            ) -> String {
                var value = input
                value.removeLast(count)
                return value
            }
            """,
            functionName: "removeStringSuffix",
            moduleName: "HelixStringRemovalSuffixBounds"
        )
        #expect(
            invoke(
                suffixFixture,
                arguments: [.string("A🇨🇳"), try integer(-1)]
            ) == .trapped(
                .explicit("Collection removal count must not be negative")
            )
        )
        #expect(
            invoke(
                suffixFixture,
                arguments: [.string("A🇨🇳"), try integer(3)]
            ) == .trapped(.arrayIndexOutOfBounds(index: -1, count: 2))
        )
    }

    @Test("Clear and capacity hints retain only observable semantics")
    func clearsAndReservesRepresentedStorage() throws {
        let stringFixture = try FrontendExecutionHarness.compile(
            source: """
            public func clearString(
                _ input: String,
                capacity: Int,
                keepingCapacity: Bool
            ) -> String {
                var value = input
                value.reserveCapacity(capacity)
                value.removeAll(keepingCapacity: keepingCapacity)
                return value
            }
            """,
            functionName: "clearString",
            moduleName: "HelixStringClear"
        )
        #expect(
            invoke(
                stringFixture,
                arguments: [.string("A👩🏽‍💻B"), try integer(64), .bool(true)]
            ) == .returned(.string(""))
        )
        #expect(
            invoke(
                stringFixture,
                arguments: [.string("A"), try integer(-1), .bool(false)]
            ) == .trapped(
                .explicit("Collection capacity must not be negative")
            )
        )
        let stringDisassembly = Bytecode.Disassembler.disassemble(
            stringFixture.image.module
        )
        #expect(!stringDisassembly.contains("string_characters"))
        #expect(!stringDisassembly.contains("native_apply"))

        let substringFixture = try FrontendExecutionHarness.compile(
            source: """
            public func clearSubstring(
                _ input: Substring,
                capacity: Int,
                _ keepingCapacity: Bool
            ) -> Substring {
                var value = input
                value.reserveCapacity(capacity)
                value.removeAll(keepingCapacity: keepingCapacity)
                return value
            }
            """,
            functionName: "clearSubstring",
            moduleName: "HelixSubstringClear"
        )
        #expect(
            invoke(
                substringFixture,
                arguments: [
                    characters(["A", "👩🏽‍💻"]),
                    try integer(16),
                    .bool(false),
                ]
            ) == .returned(characters([]))
        )
        #expect(
            invoke(
                substringFixture,
                arguments: [characters(["A"]), try integer(-1), .bool(true)]
            ) == .trapped(
                .explicit("Collection capacity must not be negative")
            )
        )
    }

    @Test("Normalized ArraySlice values reuse the generic edge plan")
    func mutatesArraySliceByElementOrder() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutateSlice(_ input: [Int]) -> [Int] {
                var value = input[1..<(input.count - 1)]
                _ = value.removeFirst()
                _ = value.popLast()
                return Array(value)
            }
            """,
            functionName: "mutateSlice",
            moduleName: "HelixArraySliceEdgeMutation"
        )

        #expect(
            invoke(
                fixture,
                arguments: [try integers([0, 1, 2, 3, 4, 5])]
            ) == .returned(try integers([2, 3]))
        )
    }

    @Test("ArraySlice clear and capacity use represented storage semantics")
    func clearsAndReservesArraySlice() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func clearSlice(
                _ input: [Int],
                capacity: Int,
                keepingCapacity: Bool
            ) -> ArraySlice<Int> {
                var value = input[1..<input.count]
                value.reserveCapacity(capacity)
                value.removeAll(keepingCapacity: keepingCapacity)
                return value
            }
            """,
            functionName: "clearSlice",
            moduleName: "HelixArraySliceClear"
        )

        #expect(
            invoke(
                fixture,
                arguments: [try integers([0, 1, 2]), try integer(8), .bool(true)]
            ) == .returned(try integers([]))
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integers([0, 1]), try integer(-1), .bool(false)]
            ) == .trapped(
                .explicit("Collection capacity must not be negative")
            )
        )
    }

    @Test("Shared popLast preserves imported-reference ownership")
    func verifiesLinearElementOwnership() throws {
        let objectType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func popObject(
                _ input: [NSObject]
            ) -> (NSObject?, [NSObject]) {
                var value = input
                return (value.popLast(), value)
            }
            """,
            functionName: "popObject",
            moduleName: "HelixLinearCollectionPopLast",
            nativeTypes: [
                .init(
                    id: objectType,
                    canonicalName: "Foundation.NSObject",
                    kind: .reference,
                    layoutFingerprint: .sha256(
                        "Foundation.NSObject.layout"
                    ),
                    isCopyable: true,
                    isEmittedToDevice: true,
                    estimatedSize: 8
                ),
            ]
        )

        let instructions = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)
        #expect(instructions.contains { instruction in
            if case .arrayPopLast = instruction { return true }
            return false
        })
    }

    @Test("Mutation representation rejects unordered and finite-only sources")
    func rejectsIneligibleRepresentations() {
        #expect(
            CanonicalSIL.RangeReplaceableCollectionRepresentation(
                sequence: .managedCollection(type: .set(.int64), element: .int64)
            ) == nil
        )
        #expect(
            CanonicalSIL.RangeReplaceableCollectionRepresentation(
                sequence: .progression(
                    .init(
                        family: .range,
                        element: .int64
                    )
                )
            ) == nil
        )
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

    private func characters(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }
}
}
