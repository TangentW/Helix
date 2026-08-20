import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Dictionary semantics")
struct DictionarySemanticsMatrix {
    @Test("Default lookup evaluates its autoclosure only for a missing key")
    func readsLazyDefaults() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func readsLazyDefaults(
                _ input: [String: Int],
                _ key: String,
                _ divisor: Int
            ) -> Int {
                input[key, default: 10 / divisor]
            }
            """,
            functionName: "readsLazyDefaults",
            moduleName: "HelixDictionaryLazyDefault"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try dictionary([("present", 7)]),
                    .string("present"),
                    try integer(0),
                ]
            ) == .returned(try integer(7))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try dictionary([]),
                    .string("missing"),
                    try integer(2),
                ]
            ) == .returned(try integer(5))
        )
        let reabstractionThunk = try #require(
            fixture.image.module.functions.first {
                $0.name.hasSuffix("_TR")
            }
        )
        #expect(
            ReleaseCompiler.ImplementationFingerprint
                .isReabstractionThunk(reabstractionThunk.name)
        )
        // This thunk is partially applied, so its executable image role is a
        // closure body even though its compiler-generated eligibility is the
        // same classification used for concrete specializations.
        #expect(reabstractionThunk.kind == .closureBody)
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Default mutation supports scalar and nested collection writeback")
    func mutatesDefaultValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutatesDefaultValues(
                _ counters: [String: Int],
                _ lists: [String: [Int]],
                _ key: String,
                _ value: Int,
                _ divisor: Int
            ) -> ([String: Int], [String: [Int]]) {
                var updatedCounters = counters
                updatedCounters[key, default: 10 / divisor] += value
                var updatedLists = lists
                updatedLists[key, default: []].append(value)
                return (updatedCounters, updatedLists)
            }
            """,
            functionName: "mutatesDefaultValues",
            moduleName: "HelixDictionaryDefaultMutation"
        )
        let listDictionary = Bytecode.ValueType.dictionary(
            key: .string,
            value: .array(.int64)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try dictionary([("present", 4)]),
                    .dictionary(
                        [
                            .init(
                                key: .string("present"),
                                value: try integers([1, 2])
                            ),
                        ],
                        keyType: .string,
                        valueType: .array(.int64)
                    ),
                    .string("present"),
                    try integer(3),
                    try integer(0),
                ]
            ) == .returned(.tuple([
                try dictionary([("present", 7)]),
                .dictionary(
                    [
                        .init(
                            key: .string("present"),
                            value: try integers([1, 2, 3])
                        ),
                    ],
                    keyType: .string,
                    valueType: .array(.int64)
                ),
            ]))
        )
        #expect(
            fixture.image.module.functions.flatMap(\.registerTypes)
                .contains(listDictionary)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try dictionary([]),
                    .dictionary([], keyType: .string, valueType: .array(.int64)),
                    .string("missing"),
                    try integer(3),
                    try integer(2),
                ]
            ) == .returned(.tuple([
                try dictionary([("missing", 8)]),
                .dictionary(
                    [
                        .init(
                            key: .string("missing"),
                            value: try integers([3])
                        ),
                    ],
                    keyType: .string,
                    valueType: .array(.int64)
                ),
            ]))
        )
    }

    @Test("Default mutation distinguishes an Optional value from a missing key")
    func mutatesOptionalDefaultValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutatesOptionalDefaultValues(
                _ input: [String: Int?],
                _ key: String,
                _ replacement: Int?
            ) -> [String: Int?] {
                var result = input
                result[key, default: nil] = replacement
                return result
            }
            """,
            functionName: "mutatesOptionalDefaultValues",
            moduleName: "HelixDictionaryOptionalDefaultMutation"
        )
        let dictionaryType = Bytecode.ValueType.dictionary(
            key: .string,
            value: .optional(.int64)
        )
        let presentNil = VM.Value.dictionary(
            [.init(key: .string("present"), value: .optional(nil))],
            keyType: .string,
            valueType: .optional(.int64)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    presentNil,
                    .string("present"),
                    .optional(try integer(7)),
                ]
            ) == .returned(.dictionary(
                [
                    .init(
                        key: .string("present"),
                        value: .optional(try integer(7))
                    ),
                ],
                keyType: .string,
                valueType: .optional(.int64)
            ))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .dictionary([], keyType: .string, valueType: .optional(.int64)),
                    .string("missing"),
                    .optional(nil),
                ]
            ) == .returned(.dictionary(
                [.init(key: .string("missing"), value: .optional(nil))],
                keyType: .string,
                valueType: .optional(.int64)
            ))
        )
        #expect(
            fixture.image.module.functions.flatMap(\.registerTypes)
                .contains(dictionaryType)
        )
    }

    @Test("Nested default mutations compose through overlapping collection loans")
    func mutatesNestedDefaultValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutatesNestedDefaultValues(
                _ input: [String: [String: Int]],
                _ outerKey: String,
                _ innerKey: String
            ) -> [String: [String: Int]] {
                var result = input
                result[outerKey, default: [:]][innerKey, default: 0] += 1
                return result
            }
            """,
            functionName: "mutatesNestedDefaultValues",
            moduleName: "HelixDictionaryNestedDefaultMutation"
        )
        let innerType = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        let empty = VM.Value.dictionary(
            [],
            keyType: .string,
            valueType: innerType
        )
        let existing = VM.Value.dictionary(
            [
                .init(
                    key: .string("group"),
                    value: try dictionary([("count", 4)])
                ),
            ],
            keyType: .string,
            valueType: innerType
        )

        let cases: [(input: VM.Value, expectedValue: Int64)] = [
            (empty, 1), (existing, 5),
        ]
        for (input, expectedValue) in cases {
            #expect(
                VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: [
                        input,
                        .string("group"),
                        .string("count"),
                    ]
                ) == .returned(.dictionary(
                    [
                        .init(
                            key: .string("group"),
                            value: try dictionary([("count", expectedValue)])
                        ),
                    ],
                    keyType: .string,
                    valueType: innerType
                ))
            )
        }
    }

    @Test("Collection coroutine writeback runs on normal and throwing exits")
    func writesBackCoroutineElementsOnEveryExit() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum MutationFailure: Error { case stopped }

            @inline(never)
            func mutateOrThrow(
                _ value: inout Int,
                _ shouldThrow: Bool
            ) throws {
                value += 3
                if shouldThrow { throw MutationFailure.stopped }
            }

            public func writesBackCoroutineElementsOnEveryExit(
                _ input: [String: Int],
                _ values: [Int],
                _ key: String,
                _ shouldThrow: Bool
            ) -> ([String: Int], [Int]) {
                var dictionary = input
                do {
                    try mutateOrThrow(
                        &dictionary[key, default: 5],
                        shouldThrow
                    )
                } catch {}

                var array = values
                do {
                    try mutateOrThrow(&array[0], shouldThrow)
                } catch {}
                return (dictionary, array)
            }
            """,
            functionName: "writesBackCoroutineElementsOnEveryExit",
            moduleName: "HelixCollectionCoroutineWriteback"
        )

        for shouldThrow in [false, true] {
            for (input, key, expected) in [
                (try dictionary([]), "missing", try dictionary([("missing", 8)])),
                (
                    try dictionary([("present", 4)]),
                    "present",
                    try dictionary([("present", 7)])
                ),
            ] {
                #expect(
                    VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: [
                            input,
                            try integers([2]),
                            .string(key),
                            .bool(shouldThrow),
                        ]
                    ) == .returned(.tuple([
                        expected,
                        try integers([5]),
                    ]))
                )
            }
        }
    }

    @Test("Collection element writeback preserves imported reference ownership")
    func verifiesLinearElementWriteback() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            @inline(never)
            func replaceObject(
                _ value: inout NSObject,
                _ replacement: NSObject
            ) {
                value = replacement
            }

            public func writesBackObjects(
                _ values: [NSObject],
                _ keyed: [String: NSObject],
                _ key: String,
                _ fallback: NSObject,
                _ replacement: NSObject
            ) -> ([NSObject], [String: NSObject]) {
                var array = values
                replaceObject(&array[0], replacement)
                var dictionary = keyed
                replaceObject(
                    &dictionary[key, default: fallback],
                    replacement
                )
                return (array, dictionary)
            }
            """,
            functionName: "writesBackObjects",
            moduleName: "HelixCollectionLinearElementWriteback",
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

        #expect(instructions.contains { instruction in
            if case .arrayUpdate = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .dictionarySet = instruction { return true }
            return false
        })
        #expect(instructions.filter { instruction in
            if case .loadAddress(_, _, .take) = instruction { return true }
            return false
        }.count >= 2)
    }

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

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }
}
}
