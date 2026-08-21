import Foundation
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Array structural edit semantics")
struct ArrayStructuralEditSemanticsMatrix {
    @Test("Concatenation and insertion share Array-backed range replacement")
    func concatenatesAndInserts() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func concatenatesAndInserts(
                _ lhs: [Int],
                _ rhs: [Int],
                _ value: Int
            ) -> [Int] {
                var result = lhs + rhs
                result += [value]
                result.append(contentsOf: rhs.reversed())
                result.insert(-1, at: 0)
                result.insert(contentsOf: [7, 8], at: 2)
                return result
            }
            """,
            functionName: "concatenatesAndInserts",
            moduleName: "HelixArrayConcatenatesAndInserts"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2]),
                    try integers([3, 4]),
                    try integer(5),
                ]
            ) == .returned(
                try integers([-1, 1, 7, 8, 2, 3, 4, 5, 4, 3])
            )
        )
    }

    @Test("Position, edge, range, and swap edits preserve removed values")
    func removesAndSwaps() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func removesAndSwaps(
                _ values: [Int]
            ) -> (Int, Int, Int, [Int]) {
                var result = values
                let first = result.removeFirst()
                let last = result.removeLast()
                let middle = result.remove(at: 1)
                result.replaceSubrange(1..<2, with: [41, 42])
                result.removeSubrange(2..<3)
                result.removeFirst(1)
                result.removeLast(1)
                result.swapAt(0, result.count - 1)
                return (first, last, middle, result)
            }
            """,
            functionName: "removesAndSwaps",
            moduleName: "HelixArrayRemovesAndSwaps"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([10, 20, 30, 40, 50, 60, 70, 80]),
                ]
            ) == .returned(.tuple([
                try integer(10),
                try integer(80),
                try integer(30),
                try integers([60, 50, 41]),
            ]))
        )
    }

    @Test("Structural edits snapshot self-aliased sources")
    func editsWithAliasedSourceAndDestination() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func editAliases(_ values: [Int]) -> [Int] {
                var result = values
                result += result
                result.insert(contentsOf: result, at: 1)
                result.replaceSubrange(2..<4, with: result)
                return result
            }
            """,
            functionName: "editAliases",
            moduleName: "HelixArrayAliasedStructuralEdits"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([1, 2])]
            ) == .returned(
                try integers([
                    1, 1, 1, 1, 2, 1, 2,
                    2, 1, 2, 2, 2, 1, 2,
                ])
            )
        )
    }

    @Test("Clear and capacity hints preserve Swift-visible semantics")
    func clearsAndReservesCapacity() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func clearsAndReservesCapacity(
                _ values: [Int],
                _ capacity: Int,
                _ keepCapacity: Bool
            ) -> [Int] {
                var result = values
                result.reserveCapacity(capacity)
                result.removeAll(keepingCapacity: keepCapacity)
                return result
            }
            """,
            functionName: "clearsAndReservesCapacity",
            moduleName: "HelixArrayClearsAndReserves"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3]), try integer(16), .bool(true),
                ]
            ) == .returned(try integers([]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([1, 2, 3]), try integer(.max), .bool(false),
                ]
            ) == .returned(try integers([]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([1]), try integer(-1), .bool(true)]
            ) == .trapped(
                .explicit("Collection capacity must not be negative")
            )
        )
    }

    @Test("Structural edits are type-driven across common value shapes")
    func editsStringsOptionalsAndTuples() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func editsCommonShapes(
                _ words: [String],
                _ optionals: [Int?]
            ) -> ([String], [Int?], [(Int, String)]) {
                var editedWords = words
                editedWords.insert(contentsOf: ["middle", "tail"], at: 1)
                editedWords.replaceSubrange(0..<1, with: ["head"])

                var editedOptionals = optionals
                editedOptionals.append(contentsOf: [nil, 7])
                editedOptionals.swapAt(0, editedOptionals.count - 1)

                var pairs = [(1, "one"), (2, "two")]
                _ = pairs.removeFirst()
                pairs.insert((3, "three"), at: 0)
                return (editedWords, editedOptionals, pairs)
            }
            """,
            functionName: "editsCommonShapes",
            moduleName: "HelixArrayCommonStructuralShapes"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .array(
                        [.string("first"), .string("last")],
                        elementType: .string
                    ),
                    .array(
                        [
                            .optional(try integer(1)),
                            .optional(nil),
                        ],
                        elementType: .optional(.int64)
                    ),
                ]
            ) == .returned(
                .tuple([
                    .array(
                        [
                            .string("head"), .string("middle"),
                            .string("tail"), .string("last"),
                        ],
                        elementType: .string
                    ),
                    .array(
                        [
                            .optional(try integer(7)), .optional(nil),
                            .optional(nil), .optional(try integer(1)),
                        ],
                        elementType: .optional(.int64)
                    ),
                    .array(
                        [
                            .tuple([try integer(3), .string("three")]),
                            .tuple([try integer(2), .string("two")]),
                        ],
                        elementType: .tuple([.int64, .string])
                    ),
                ])
            )
        )
    }

    @Test("Structural edits reject invalid indices and counts")
    func rejectsInvalidBounds() throws {
        let removeFixture = try FrontendExecutionHarness.compile(
            source: """
            public func removeAt(_ values: [Int], _ index: Int) -> [Int] {
                var result = values
                _ = result.remove(at: index)
                return result
            }
            """,
            functionName: "removeAt",
            moduleName: "HelixArrayRemoveBounds"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: removeFixture.entry,
                image: removeFixture.image,
                arguments: [try integers([1, 2]), try integer(2)]
            ) == .trapped(.arrayIndexOutOfBounds(index: 2, count: 2))
        )

        let countFixture = try FrontendExecutionHarness.compile(
            source: """
            public func removePrefix(
                _ values: [Int],
                _ count: Int
            ) -> [Int] {
                var result = values
                result.removeFirst(count)
                return result
            }
            """,
            functionName: "removePrefix",
            moduleName: "HelixArrayRemoveCountBounds"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: countFixture.entry,
                image: countFixture.image,
                arguments: [try integers([1, 2]), try integer(3)]
            ) == .trapped(.arrayIndexOutOfBounds(index: 3, count: 2))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: countFixture.entry,
                image: countFixture.image,
                arguments: [try integers([1, 2]), try integer(-1)]
            ) == .trapped(
                .explicit("Collection removal count must not be negative")
            )
        )
    }

    @Test("Structural edits preserve linear imported reference ownership")
    func verifiesLinearImportedElements() throws {
        let objectType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func editsObjects(
                _ values: [NSObject],
                _ extra: NSObject
            ) -> ([NSObject], NSObject) {
                var result = values + [extra]
                result.insert(contentsOf: [extra], at: 0)
                let removed = result.removeLast()
                result.replaceSubrange(0..<0, with: [extra])
                result.swapAt(0, result.count - 1)
                return (result, removed)
            }
            """,
            functionName: "editsObjects",
            moduleName: "HelixArrayLinearStructuralEdits",
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
            if case .arrayReplaceSubrange = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .arraySwap = instruction { return true }
            return false
        })
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }
}
}
