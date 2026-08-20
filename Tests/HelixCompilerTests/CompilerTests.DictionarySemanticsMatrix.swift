import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Dictionary semantics")
struct DictionarySemanticsMatrix {
    @Test("Value updates and removals share one value-semantic mutation path")
    func updatesAndRemovesValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func updatesAndRemovesValues(
                _ input: [String: Int],
                _ key: String,
                _ value: Int
            ) -> (Int?, Int?, [String: Int]) {
                var result = input
                let previous = result.updateValue(value, forKey: key)
                let removed = result.removeValue(forKey: "drop")
                return (previous, removed, result)
            }
            """,
            functionName: "updatesAndRemovesValues",
            moduleName: "HelixDictionaryUpdatesAndRemovals"
        )

        #expect(
            try invoke(
                fixture,
                input: [("keep", 1), ("drop", 2)],
                key: "keep",
                value: 9
            ) == .returned(.tuple([
                .optional(try integer(1)),
                .optional(try integer(2)),
                try dictionary([("keep", 9)]),
            ]))
        )
        #expect(
            try invoke(
                fixture,
                input: [("keep", 1), ("drop", 2)],
                key: "new",
                value: 9
            ) == .returned(.tuple([
                .optional(nil),
                .optional(try integer(2)),
                try dictionary([("keep", 1), ("new", 9)]),
            ]))
        )
        #expect(
            try invoke(
                fixture,
                input: [("keep", 1)],
                key: "new",
                value: 9
            ) == .returned(.tuple([
                .optional(nil),
                .optional(nil),
                try dictionary([("keep", 1), ("new", 9)]),
            ]))
        )
    }

    @Test("An Optional Dictionary value remains distinct from key removal")
    func updatesOptionalValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func updatesOptionalValues(
                _ input: [String: Int?],
                _ key: String,
                _ value: Int?
            ) -> (Int??, [String: Int?]) {
                var result = input
                let previous = result.updateValue(value, forKey: key)
                return (previous, result)
            }
            """,
            functionName: "updatesOptionalValues",
            moduleName: "HelixDictionaryOptionalValues"
        )
        let existing = VM.Value.dictionary(
            [
                .init(key: .string("presentNil"), value: .optional(nil)),
            ],
            keyType: .string,
            valueType: .optional(.int64)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    existing, .string("presentNil"), .optional(try integer(7)),
                ]
            ) == .returned(.tuple([
                .optional(.optional(nil)),
                .dictionary(
                    [
                        .init(
                            key: .string("presentNil"),
                            value: .optional(try integer(7))
                        ),
                    ],
                    keyType: .string,
                    valueType: .optional(.int64)
                ),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [existing, .string("new"), .optional(nil)]
            ) == .returned(.tuple([
                .optional(nil),
                .dictionary(
                    [
                        .init(key: .string("presentNil"), value: .optional(nil)),
                        .init(key: .string("new"), value: .optional(nil)),
                    ],
                    keyType: .string,
                    valueType: .optional(.int64)
                ),
            ]))
        )
    }

    @Test("Capacity-preserving removal has the same observable empty result")
    func removesAllValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func removesAllValues(
                _ input: [String: Int],
                _ keepingCapacity: Bool
            ) -> [String: Int] {
                var result = input
                result.removeAll(keepingCapacity: keepingCapacity)
                return result
            }
            """,
            functionName: "removesAllValues",
            moduleName: "HelixDictionaryRemoveAll"
        )

        for keepingCapacity in [false, true] {
            #expect(
                VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: [
                        try dictionary([("one", 1), ("two", 2)]),
                        .bool(keepingCapacity),
                    ]
                ) == .returned(try dictionary([]))
            )
        }
    }

    @Test("Keys and values preserve the Dictionary iteration pairing and order")
    func projectsKeysAndValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func projectsKeysAndValues(
                _ input: [String: Int]
            ) -> ([String], [Int]) {
                (Array(input.keys), Array(input.values))
            }
            """,
            functionName: "projectsKeysAndValues",
            moduleName: "HelixDictionaryProjection"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try dictionary([("alpha", 4), ("beta", 7)])]
            ) == .returned(.tuple([
                .array([.string("alpha"), .string("beta")], elementType: .string),
                .array(
                    [try integer(4), try integer(7)],
                    elementType: .int64
                ),
            ]))
        )
    }

    @Test("Unique-key construction accepts supported sequences and traps duplicates")
    func constructsFromUniquePairs() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func constructsFromUniquePairs(
                _ pairs: [(String, Int)]
            ) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: pairs)
            }
            """,
            functionName: "constructsFromUniquePairs",
            moduleName: "HelixDictionaryUniquePairs"
        )
        let pairType = Bytecode.ValueType.tuple([.string, .int64])

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .array(
                        [
                            .tuple([.string("one"), try integer(1)]),
                            .tuple([.string("two"), try integer(2)]),
                        ],
                        elementType: pairType
                    ),
                ]
            ) == .returned(try dictionary([("one", 1), ("two", 2)]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .array(
                        [
                            .tuple([.string("same"), try integer(1)]),
                            .tuple([.string("same"), try integer(2)]),
                        ],
                        elementType: pairType
                    ),
                ]
            ) == .trapped(.explicit("Dictionary construction contains duplicate keys"))
        )
    }

    @Test("Dictionary operations preserve imported reference ownership")
    func verifiesLinearImportedValues() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func ownsDictionaryObjects(
                _ input: [String: NSObject],
                _ pairs: [(String, NSObject)],
                _ key: String,
                _ replacement: NSObject
            ) -> (
                NSObject?, NSObject?, [NSObject],
                [String: NSObject], [String: NSObject]
            ) {
                var result = input
                let previous = result.updateValue(replacement, forKey: key)
                let removed = result.removeValue(forKey: "drop")
                let projected = Array(result.values)
                let rebuilt = Dictionary(uniqueKeysWithValues: pairs)
                let literal: [String: NSObject] = ["literal": replacement]
                return (previous, removed, projected, rebuilt, literal)
            }
            """,
            functionName: "ownsDictionaryObjects",
            moduleName: "HelixDictionaryLinearOwnership",
            nativeTypes: [
                .init(
                    id: objectType,
                    canonicalName: "Foundation.NSObject",
                    kind: .reference,
                    layoutFingerprint: .sha256("Foundation.NSObject.layout"),
                    isCopyable: true,
                    isEmittedToDevice: true,
                    estimatedSize: 8
                ),
            ]
        )
        let instructions = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)

        #expect(instructions.filter { instruction in
            if case .dictionarySet = instruction { return true }
            return false
        }.count == 2)
        #expect(instructions.contains { instruction in
            if case .dictionaryProject(_, _, .values) = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .makeDictionary = instruction { return true }
            return false
        })
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        input: [(String, Int64)],
        key: String,
        value: Int64
    ) throws -> VM.ExecutionResult {
        VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [
                try dictionary(input), .string(key), try integer(value),
            ]
        )
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

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
