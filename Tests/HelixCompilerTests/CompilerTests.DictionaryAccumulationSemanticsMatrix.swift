import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Dictionary accumulation semantics")
struct DictionaryAccumulationSemanticsMatrix {
    @Test("Merging, uniquing, and grouping share verified accumulation")
    func accumulatesAcrossDictionaryAPIs() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func accumulatesAcrossDictionaryAPIs(
                _ lhs: [String: Int],
                _ rhs: [String: Int],
                _ pairs: [(String, Int)],
                _ values: [Int]
            ) -> (
                [String: Int], [String: Int],
                [String: Int], [String: Int],
                [String: Int], [Int: [Int]]
            ) {
                let mergedDictionary = lhs.merging(rhs) { $0 + $1 }
                let mergedPairs = lhs.merging(pairs) { $0 + $1 }
                var mutableDictionary = lhs
                mutableDictionary.merge(rhs) { $0 + $1 }
                var mutablePairs = lhs
                mutablePairs.merge(pairs) { $0 + $1 }
                let unique = Dictionary(pairs, uniquingKeysWith: { $0 + $1 })
                let grouped = Dictionary(grouping: values, by: { $0 % 2 })
                return (
                    mergedDictionary, mergedPairs,
                    mutableDictionary, mutablePairs,
                    unique, grouped
                )
            }
            """,
            functionName: "accumulatesAcrossDictionaryAPIs",
            moduleName: "HelixDictionaryAccumulation"
        )
        let lhs = try stringDictionary([("a", 1), ("b", 10)])
        let rhs = try stringDictionary([("a", 2), ("c", 3)])
        let pairs = try pairArray([
            ("b", 5), ("d", 4), ("b", 7),
        ])
        let grouped = VM.Value.dictionary(
            [
                .init(key: try integer(1), value: try integerArray([1, 3, 5])),
                .init(key: try integer(0), value: try integerArray([2, 4])),
            ],
            keyType: .int64,
            valueType: .array(.int64)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [lhs, rhs, pairs, try integerArray([1, 2, 3, 4, 5])]
            ) == .returned(.tuple([
                try stringDictionary([("a", 3), ("b", 10), ("c", 3)]),
                try stringDictionary([("a", 1), ("b", 22), ("d", 4)]),
                try stringDictionary([("a", 3), ("b", 10), ("c", 3)]),
                try stringDictionary([("a", 1), ("b", 22), ("d", 4)]),
                try stringDictionary([("b", 12), ("d", 4)]),
                grouped,
            ]))
        )

        let instructions = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)
        #expect(instructions.contains { instruction in
            if case .dictionaryBuilderGet = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .dictionaryBuilderSet = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .dictionaryBuilderAppendArrayElement = instruction {
                return true
            }
            return false
        })
        #expect(fixture.image.module.imports.isEmpty)

        let emptyGrouped = VM.Value.dictionary(
            [],
            keyType: .int64,
            valueType: .array(.int64)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    lhs,
                    try stringDictionary([]),
                    try pairArray([]),
                    try integerArray([]),
                ]
            ) == .returned(.tuple([
                lhs, lhs, lhs, lhs,
                try stringDictionary([]),
                emptyGrouped,
            ]))
        )
    }

    @Test("Combine callbacks run only for duplicate keys")
    func invokesCombineOnlyForDuplicates() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func combinesOnlyDuplicates(
                _ pairs: [(String, Int)],
                _ divisor: Int
            ) -> [String: Int] {
                Dictionary(pairs, uniquingKeysWith: {
                    ($0 * 10) + ($1 / divisor)
                })
            }
            """,
            functionName: "combinesOnlyDuplicates",
            moduleName: "HelixDictionaryLazyCombine"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try pairArray([("a", 4), ("b", 6)]),
                    try integer(0),
                ]
            ) == .returned(try stringDictionary([("a", 4), ("b", 6)]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try pairArray([("a", 4), ("a", 6), ("a", 8)]),
                    try integer(2),
                ]
            ) == .returned(try stringDictionary([("a", 434)]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try pairArray([("a", 4), ("a", 6)]),
                    try integer(0),
                ]
            ) == .trapped(.divisionByZero)
        )
    }

    @Test("Accumulation preserves the first equivalent key and its position")
    func preservesFirstKeyIdentityAndPosition() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func preservesFirstKeyIdentityAndPosition(
                _ initial: [Double: Int],
                _ pairs: [(Double, Int)]
            ) -> [Double: Int] {
                initial.merging(pairs) { ($0 * 10) + $1 }
            }
            """,
            functionName: "preservesFirstKeyIdentityAndPosition",
            moduleName: "HelixDictionaryKeyIdentity"
        )
        let initial = VM.Value.dictionary(
            [
                .init(key: .float64(-0.0), value: try integer(1)),
                .init(key: .float64(2.0), value: try integer(2)),
            ],
            keyType: .float(bitWidth: 64),
            valueType: .int64
        )
        let pairType = Bytecode.ValueType.tuple([
            .float(bitWidth: 64), .int64,
        ])
        let pairs = VM.Value.array(
            [
                .tuple([.float64(0.0), try integer(3)]),
                .tuple([.float64(1.0), try integer(4)]),
                .tuple([.float64(2.0), try integer(5)]),
            ],
            elementType: pairType
        )
        let outcome = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [initial, pairs]
        )
        guard case let .returned(
            .dictionary(entries, keyType, valueType)
        ) = outcome else {
            Issue.record("unexpected key-identity result: \(outcome)")
            return
        }

        #expect(keyType == .float(bitWidth: 64))
        #expect(valueType == .int64)
        #expect(entries.compactMap { entry in
            guard case let .float(key) = entry.key else { return nil }
            return key.bitPattern
        } == [(-0.0).bitPattern, 2.0.bitPattern, 1.0.bitPattern])
        let values: [Int64] = entries.compactMap { entry in
            guard case let .integer(value) = entry.value else { return nil }
            return value.signedValue
        }
        #expect(values == [13, 25, 4])
    }

    @Test("Throwing accumulation preserves Swift partial-mutation boundaries")
    func preservesThrowingMutationBoundaries() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum AccumulationFailure: Error { case stopped }

            @inline(never)
            func combineOrThrow(
                _ old: Int,
                _ new: Int,
                _ shouldThrow: Bool
            ) throws -> Int {
                if shouldThrow && new == 99 {
                    throw AccumulationFailure.stopped
                }
                return old + new
            }

            public func observesThrowingAccumulation(
                _ lhs: [String: Int],
                _ pairs: [(String, Int)],
                _ values: [Int],
                _ shouldThrow: Bool
            ) -> (
                [String: Int], [String: Int], [Int: [Int]],
                Bool, Bool, Bool
            ) {
                var mutable = lhs
                var mergeFailed = false
                do {
                    try mutable.merge(pairs) {
                        try combineOrThrow($0, $1, shouldThrow)
                    }
                } catch {
                    mergeFailed = true
                }

                var merged = lhs
                var mergingFailed = false
                do {
                    merged = try lhs.merging(pairs) {
                        try combineOrThrow($0, $1, shouldThrow)
                    }
                } catch {
                    mergingFailed = true
                }

                var grouped: [Int: [Int]] = [:]
                var groupingFailed = false
                do {
                    grouped = try Dictionary(grouping: values) { value in
                        if shouldThrow && value == 99 {
                            throw AccumulationFailure.stopped
                        }
                        return value % 2
                    }
                } catch {
                    groupingFailed = true
                }
                return (
                    mutable, merged, grouped,
                    mergeFailed, mergingFailed, groupingFailed
                )
            }
            """,
            functionName: "observesThrowingAccumulation",
            moduleName: "HelixDictionaryThrowingAccumulation"
        )
        let lhs = try stringDictionary([("a", 1)])
        let pairs = try pairArray([
            ("b", 2), ("a", 99), ("c", 3),
        ])
        let values = try integerArray([1, 99, 2])

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [lhs, pairs, values, .bool(true)]
            ) == .returned(.tuple([
                try stringDictionary([("a", 1), ("b", 2)]),
                lhs,
                .dictionary(
                    [],
                    keyType: .int64,
                    valueType: .array(.int64)
                ),
                .bool(true), .bool(true), .bool(true),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [lhs, pairs, values, .bool(false)]
            ) == .returned(.tuple([
                try stringDictionary([("a", 100), ("b", 2), ("c", 3)]),
                try stringDictionary([("a", 100), ("b", 2), ("c", 3)]),
                .dictionary(
                    [
                        .init(
                            key: try integer(1),
                            value: try integerArray([1, 99])
                        ),
                        .init(
                            key: try integer(0),
                            value: try integerArray([2])
                        ),
                    ],
                    keyType: .int64,
                    valueType: .array(.int64)
                ),
                .bool(false), .bool(false), .bool(false),
            ]))
        )
    }

    @Test("Dictionary accumulation preserves imported-reference ownership")
    func verifiesLinearImportedValues() throws {
        let objectType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func accumulatesObjects(
                _ lhs: [String: NSObject],
                _ pairs: [(String, NSObject)],
                _ values: [NSObject]
            ) -> (
                [String: NSObject],
                [String: NSObject],
                [String: [NSObject]]
            ) {
                let merged = lhs.merging(pairs) { _, new in new }
                var mutable = lhs
                mutable.merge(pairs) { _, new in new }
                let grouped = Dictionary(grouping: values) { _ in "all" }
                return (merged, mutable, grouped)
            }
            """,
            functionName: "accumulatesObjects",
            moduleName: "HelixDictionaryLinearAccumulation",
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
            if case .dictionaryBuilderSet = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .dictionaryBuilderAppendArrayElement = instruction {
                return true
            }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .destroyValue = instruction { return true }
            return false
        })
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Grouping traverses every represented managed Collection")
    func groupsManagedCollections() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func groupsManagedCollections(
                _ values: Set<Int>,
                _ keyed: [String: Int]
            ) -> ([Int: [Int]], [Int: [(key: String, value: Int)]]) {
                let groupedSet = Dictionary(grouping: values) { $0 % 2 }
                let groupedDictionary = Dictionary(grouping: keyed) {
                    $0.value % 2
                }
                return (groupedSet, groupedDictionary)
            }
            """,
            functionName: "groupsManagedCollections",
            moduleName: "HelixDictionaryManagedGrouping"
        )
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        let groupedPairType = Bytecode.ValueType.array(pairType)
        let inputSet = VM.Value.set(
            .init(
                elements: try [1, 2, 3, 4].map(integer),
                elementType: .int64
            )
        )
        let inputDictionary = try stringDictionary([
            ("a", 1), ("b", 2), ("c", 3),
        ])

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [inputSet, inputDictionary]
            ) == .returned(.tuple([
                .dictionary(
                    [
                        .init(
                            key: try integer(1),
                            value: try integerArray([1, 3])
                        ),
                        .init(
                            key: try integer(0),
                            value: try integerArray([2, 4])
                        ),
                    ],
                    keyType: .int64,
                    valueType: .array(.int64)
                ),
                .dictionary(
                    [
                        .init(
                            key: try integer(1),
                            value: .array(
                                [
                                    .tuple([.string("a"), try integer(1)]),
                                    .tuple([.string("c"), try integer(3)]),
                                ],
                                elementType: pairType
                            )
                        ),
                        .init(
                            key: try integer(0),
                            value: .array(
                                [
                                    .tuple([.string("b"), try integer(2)]),
                                ],
                                elementType: pairType
                            )
                        ),
                    ],
                    keyType: .int64,
                    valueType: groupedPairType
                ),
            ]))
        )
    }

    @Test("Accumulation accepts represented Sequence adapters")
    func accumulatesSequenceAdapters() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func accumulatesSequenceAdapters(
                _ pairs: [(String, Int)],
                _ values: [Int]
            ) -> ([String: Int], [Int: [Int]]) {
                let unique = Dictionary(
                    pairs.dropFirst(),
                    uniquingKeysWith: { $0 + $1 }
                )
                let grouped = Dictionary(
                    grouping: values.reversed(),
                    by: { $0 % 2 }
                )
                return (unique, grouped)
            }
            """,
            functionName: "accumulatesSequenceAdapters",
            moduleName: "HelixDictionaryAdapterAccumulation"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try pairArray([("skip", 1), ("a", 2), ("a", 3)]),
                    try integerArray([1, 2, 3, 4]),
                ]
            ) == .returned(.tuple([
                try stringDictionary([("a", 5)]),
                .dictionary(
                    [
                        .init(
                            key: try integer(0),
                            value: try integerArray([4, 2])
                        ),
                        .init(
                            key: try integer(1),
                            value: try integerArray([3, 1])
                        ),
                    ],
                    keyType: .int64,
                    valueType: .array(.int64)
                ),
            ]))
        )
    }

    @Test("Opaque Sequence implementations remain fail-closed")
    func rejectsOpaqueSequences() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public struct Pairs: Sequence {
                    public var storage: [(String, Int)]

                    public init(_ storage: [(String, Int)]) {
                        self.storage = storage
                    }

                    public func makeIterator() -> IndexingIterator<[(String, Int)]> {
                        storage.makeIterator()
                    }
                }

                public func rejectsOpaqueSequences(
                    _ pairs: Pairs
                ) -> [String: Int] {
                    Dictionary(pairs, uniquingKeysWith: { $0 + $1 })
                }
                """,
                functionName: "rejectsOpaqueSequences",
                moduleName: "HelixDictionaryOpaqueSequence"
            )
            Issue.record("opaque Sequence unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected opaque Sequence diagnostic: \(error)")
                return
            }
            #expect(detail.contains("represented managed Collection"))
        } catch {
            Issue.record("unexpected opaque Sequence diagnostic: \(error)")
        }
    }

    private func stringDictionary(
        _ pairs: [(String, Int64)]
    ) throws -> VM.Value {
        .dictionary(
            try pairs.map {
                .init(key: .string($0.0), value: try integer($0.1))
            },
            keyType: .string,
            valueType: .int64
        )
    }

    private func pairArray(
        _ pairs: [(String, Int64)]
    ) throws -> VM.Value {
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        return .array(
            try pairs.map {
                .tuple([.string($0.0), try integer($0.1)])
            },
            elementType: pairType
        )
    }

    private func integerArray(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
