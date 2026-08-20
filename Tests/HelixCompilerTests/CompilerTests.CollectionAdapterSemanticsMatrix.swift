import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift collection adapter semantics")
struct CollectionAdapterSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Enumerated, reversed, and repeated adapters are type-driven")
    func lowersCommonAdapters() throws {
        try run([
            .init(
                name: "enumeratedTotal",
                source: """
                public func enumeratedTotal(_ values: [Int]) -> Int {
                    values.enumerated().reduce(0) {
                        $0 + $1.offset + $1.element
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integers([4, 7, 9])],
                        expected: .returned(try integer(23))
                    ),
                ]
            ),
            .init(
                name: "enumeratedLoop",
                source: """
                public func enumeratedLoop(_ values: [Int]) -> Int {
                    var result = 0
                    for (offset, value) in values.enumerated() {
                        result += offset * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([3, 4, 5])],
                        expected: .returned(try integer(42))
                    ),
                ]
            ),
            .init(
                name: "reversedValues",
                source: """
                public func reversedValues(_ values: [String]) -> [String] {
                    Array(values.reversed())
                }
                """,
                scenarios: [
                    .init(
                        arguments: [strings(["a", "b", "c"])],
                        expected: .returned(strings(["c", "b", "a"]))
                    ),
                    .init(
                        arguments: [strings([])],
                        expected: .returned(strings([]))
                    ),
                ]
            ),
            .init(
                name: "reversedLoop",
                source: """
                public func reversedLoop(_ values: [Int]) -> Int {
                    var result = 0
                    for value in values.reversed() {
                        result = result * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(321))
                    ),
                ]
            ),
            .init(
                name: "sliceLoop",
                source: """
                public func sliceLoop(_ values: [Int]) -> Int {
                    var result = 0
                    for value in values.dropFirst() {
                        result = result * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(23))
                    ),
                ]
            ),
            .init(
                name: "composedViewLoop",
                source: """
                public func composedViewLoop(_ values: [Int]) -> Int {
                    var result = 0
                    for value in values.dropFirst().reversed() {
                        result = result * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(32))
                    ),
                ]
            ),
            .init(
                name: "repeatedBytes",
                source: """
                public func repeatedBytes(_ value: UInt8, _ count: Int) -> [UInt8] {
                    Array(repeating: value, count: count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try uint8(7), try integer(3)],
                        expected: .returned(try uint8s([7, 7, 7]))
                    ),
                    .init(
                        arguments: [try uint8(7), try integer(0)],
                        expected: .returned(try uint8s([]))
                    ),
                ]
            ),
            .init(
                name: "repeatLoop",
                source: """
                public func repeatLoop(_ value: Int, _ count: Int) -> Int {
                    var result = 0
                    for item in repeatElement(value, count: count) {
                        result += item
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(6), try integer(4)],
                        expected: .returned(try integer(24))
                    ),
                ]
            ),
            .init(
                name: "repeatedOptional",
                source: """
                public func repeatedOptional(_ present: Bool) -> [Int?] {
                    Array(repeating: present ? 1 : nil, count: 2)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(
                            .array(
                                [.optional(nil), .optional(nil)],
                                elementType: .optional(.int64)
                            )
                        )
                    ),
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(
                            .array(
                                [
                                    .optional(try integer(1)),
                                    .optional(try integer(1)),
                                ],
                                elementType: .optional(.int64)
                            )
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Managed Collection adapters share materialization semantics")
    func lowersManagedCollectionAdapters() throws {
        try run([
            .init(
                name: "arrayFromSet",
                source: """
                public func arrayFromSet(_ values: Set<Int>) -> [Int] {
                    Array(values)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7])],
                        expected: .returned(try integers([4, 1, 7]))
                    ),
                ]
            ),
            .init(
                name: "arrayFromDictionary",
                source: """
                public func arrayFromDictionary(
                    _ values: [String: Int]
                ) -> [(key: String, value: Int)] {
                    Array(values)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try dictionary([("a", 4), ("b", 7)]),
                        ],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([.string("a"), try integer(4)]),
                                    .tuple([.string("b"), try integer(7)]),
                                ],
                                elementType: .tuple([.string, .int64])
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "setEnumerated",
                source: """
                public func setEnumerated(
                    _ values: Set<Int>
                ) -> [(Int, Int)] {
                    Array(values.enumerated())
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7])],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([try integer(0), try integer(4)]),
                                    .tuple([try integer(1), try integer(1)]),
                                    .tuple([try integer(2), try integer(7)]),
                                ],
                                elementType: .tuple([.int64, .int64])
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "dictionaryEnumerated",
                source: """
                public func dictionaryEnumerated(
                    _ values: [String: Int]
                ) -> [(Int, String, Int)] {
                    values.enumerated().map {
                        ($0.offset, $0.element.key, $0.element.value)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try dictionary([("a", 4), ("b", 7)]),
                        ],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([
                                        try integer(0),
                                        .string("a"),
                                        try integer(4),
                                    ]),
                                    .tuple([
                                        try integer(1),
                                        .string("b"),
                                        try integer(7),
                                    ]),
                                ],
                                elementType: .tuple([
                                    .int64, .string, .int64,
                                ])
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "managedZip",
                source: """
                public func managedZip(
                    _ lhs: Set<Int>,
                    _ rhs: [String: Int]
                ) -> [(Int, String, Int)] {
                    zip(lhs, rhs).map {
                        ($0.0, $0.1.key, $0.1.value)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try set([2, 3, 4]),
                            try dictionary([("x", 8), ("y", 9)]),
                        ],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([
                                        try integer(2),
                                        .string("x"),
                                        try integer(8),
                                    ]),
                                    .tuple([
                                        try integer(3),
                                        .string("y"),
                                        try integer(9),
                                    ]),
                                ],
                                elementType: .tuple([
                                    .int64, .string, .int64,
                                ])
                            )
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Imported-reference adapters preserve borrowed and transferred owners")
    func verifiesImportedReferenceAdapterOwnership() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let nativeType = InterfaceArchive.TypeRecord(
            id: typeID,
            canonicalName: "Foundation.NSObject",
            kind: .reference,
            layoutFingerprint: .sha256("Foundation.NSObject.layout.v1"),
            isCopyable: true,
            isEmittedToDevice: true,
            estimatedSize: 8
        )
        for probe in [
            (
                name: "copyImportedArray",
                source: """
                import Foundation

                public func copyImportedArray(
                    _ values: [NSObject]
                ) -> [NSObject] {
                    Array(values)
                }
                """
            ),
            (
                name: "enumerateImportedArray",
                source: """
                import Foundation

                public func enumerateImportedArray(
                    _ values: [NSObject]
                ) -> [(Int, NSObject)] {
                    Array(values.enumerated())
                }
                """
            ),
            (
                name: "importedArrayEndIndex",
                source: """
                import Foundation

                public func importedArrayEndIndex(
                    _ values: [NSObject]
                ) -> Int {
                    values.endIndex
                }
                """
            ),
        ] {
            _ = try FrontendExecutionHarness.compile(
                source: probe.source,
                functionName: probe.name,
                moduleName: "HelixAdapters_\(probe.name)",
                nativeTypes: [nativeType]
            )
        }
    }

    @Test("Array-backed subsequences preserve clamping and index traps")
    func lowersSubsequences() throws {
        try run([
            .init(
                name: "sliceFamilies",
                source: """
                public func sliceFamilies(_ values: [Int]) -> [[Int]] {
                    [
                        Array(values.dropFirst(2)),
                        Array(values.dropLast(2)),
                        Array(values.prefix(2)),
                        Array(values.suffix(2)),
                        Array(values.prefix(upTo: 2)),
                        Array(values.prefix(through: 1)),
                        Array(values.suffix(from: 2)),
                        Array(values.dropFirst())
                    ]
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3, 4])],
                        expected: .returned(
                            try integerArrays([
                                [3, 4], [1, 2], [1, 2], [3, 4],
                                [1, 2], [1, 2], [3, 4], [2, 3, 4],
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "clampedSlices",
                source: """
                public func clampedSlices(_ values: [Int]) -> [[Int]] {
                    [
                        Array(values.dropFirst(99)),
                        Array(values.dropLast(99)),
                        Array(values.prefix(99)),
                        Array(values.suffix(99))
                    ]
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(
                            try integerArrays([[], [], [1, 2], [1, 2]])
                        )
                    ),
                ]
            ),
            .init(
                name: "dynamicRangeSlice",
                source: """
                public func dynamicRangeSlice(
                    _ values: [Int],
                    _ lower: Int,
                    _ upper: Int
                ) -> [Int] {
                    Array(values[lower..<upper])
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([1, 2, 3, 4]),
                            try integer(1),
                            try integer(3),
                        ],
                        expected: .returned(try integers([2, 3]))
                    ),
                    .init(
                        arguments: [
                            try integers([1, 2, 3]),
                            try integer(3),
                            try integer(3),
                        ],
                        expected: .returned(try integers([]))
                    ),
                    .init(
                        arguments: [
                            try integers([1, 2, 3]),
                            try integer(0),
                            try integer(4),
                        ],
                        expected: .trapped(
                            .arrayIndexOutOfBounds(index: 4, count: 3)
                        )
                    ),
                ]
            ),
            .init(
                name: "negativeDrop",
                source: """
                public func negativeDrop(_ values: [Int], _ count: Int) -> [Int] {
                    Array(values.dropFirst(count))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1]), try integer(-1)],
                        expected: .trapped(
                            .explicit(
                                "collection subsequence count must not be negative"
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "fullSliceSharesStorage",
                source: """
                public func fullSliceSharesStorage(_ values: [Double]) -> Bool {
                    values == Array(values.prefix(99))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [doubles([.nan])],
                        expected: .returned(.bool(true))
                    ),
                ]
            ),
        ])
    }

    @Test("zip and joined normalize heterogeneous and nested sequences")
    func lowersZipAndJoined() throws {
        try run([
            .init(
                name: "zipProducts",
                source: """
                public func zipProducts(
                    _ lhs: [Int],
                    _ rhs: [Int]
                ) -> [(Int, Int)] {
                    Array(zip(lhs, rhs))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([2, 3, 4]), try integers([5, 6])],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([try integer(2), try integer(5)]),
                                    .tuple([try integer(3), try integer(6)]),
                                ],
                                elementType: .tuple([.int64, .int64])
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "zipLoop",
                source: """
                public func zipLoop(_ lhs: [Int], _ rhs: [Int]) -> Int {
                    var result = 0
                    for (left, right) in zip(lhs, rhs) {
                        result += left + right
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2]), try integers([10, 20, 30])],
                        expected: .returned(try integer(33))
                    ),
                ]
            ),
            .init(
                name: "heterogeneousZip",
                source: """
                public func heterogeneousZip(
                    _ numbers: [Int],
                    _ labels: [String]
                ) -> [(Int, String)] {
                    Array(zip(numbers, labels))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([1, 2]),
                            strings(["one", "two", "extra"]),
                        ],
                        expected: .returned(
                            .array(
                                [
                                    .tuple([try integer(1), .string("one")]),
                                    .tuple([try integer(2), .string("two")]),
                                ],
                                elementType: .tuple([.int64, .string])
                            )
                        )
                    ),
                ]
            ),
            .init(
                name: "joinedValues",
                source: """
                public func joinedValues(_ values: [[Int]]) -> [[Int]] {
                    [
                        Array(values.joined()),
                        Array(values.joined(separator: [0]))
                    ]
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integerArrays([[1, 2], [], [3]])],
                        expected: .returned(
                            try integerArrays([[1, 2, 3], [1, 2, 0, 0, 3]])
                        )
                    ),
                    .init(
                        arguments: [try integerArrays([])],
                        expected: .returned(try integerArrays([[], []]))
                    ),
                ]
            ),
            .init(
                name: "joinedLoop",
                source: """
                public func joinedLoop(_ values: [[Int]]) -> Int {
                    var result = 0
                    for value in values.joined() {
                        result = result * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integerArrays([[1, 2], [], [3]])],
                        expected: .returned(try integer(123))
                    ),
                ]
            ),
            .init(
                name: "joinedSeparatorLoop",
                source: """
                public func joinedSeparatorLoop(_ values: [[Int]]) -> Int {
                    var result = 0
                    for value in values.joined(separator: [9]) {
                        result = result * 10 + value
                    }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integerArrays([[1], [], [2]])],
                        expected: .returned(try integer(1992))
                    ),
                ]
            ),
        ])
    }

    @Test("Adapter preconditions fail before allocation")
    func rejectsInvalidRepeatAndIndexBounds() throws {
        try run([
            .init(
                name: "invalidRepeat",
                source: """
                public func invalidRepeat(_ value: Int, _ count: Int) -> [Int] {
                    Array(repeating: value, count: count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(1), try integer(-1)],
                        expected: .trapped(
                            .explicit("Array repeat count must not be negative")
                        )
                    ),
                ]
            ),
            .init(
                name: "invalidPrefixThrough",
                source: """
                public func invalidPrefixThrough(
                    _ values: [Int],
                    _ index: Int
                ) -> [Int] {
                    Array(values.prefix(through: index))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([]), try integer(0)],
                        expected: .trapped(
                            .arrayIndexOutOfBounds(index: 0, count: 0)
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("ArraySlice index wrappers are not silently treated as zero-based")
    func rejectsUnmodeledSliceIndices() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public func slicedIndex(_ values: [Int]) -> [Int] {
                    let slice = values.dropFirst()
                    return Array(slice.prefix(upTo: 2))
                }
                """,
                functionName: "slicedIndex",
                moduleName: "HelixAdapterNegativeFixture"
            )
            Issue.record("ArraySlice index semantics unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected ArraySlice diagnostic: \(error)")
                return
            }
            #expect(detail.contains("ArraySlice<Int>"))
        } catch {
            Issue.record("unexpected ArraySlice diagnostic: \(error)")
        }
    }

    @Test("Composed slices normalize only an Array-backed base")
    func resolvesComposedSliceTypes() throws {
        let environment = CanonicalSIL.TypeEnvironment()
        #expect(
            try environment.resolve(
                "Slice<ReversedCollection<Array<Int>>>"
            ) == .array(.int64)
        )
        #expect(
            environment.collectionIndexModel(
                for: "Slice<ReversedCollection<Array<Int>>>"
            ) == .opaque
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try environment.resolve("Slice<Set<Int>>")
        }
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixAdapters_\(probe.name)"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let actual = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if actual != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
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
                Comment(
                    rawValue: "collection adapter gaps:\n"
                        + failures.joined(separator: "\n")
                )
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func set(_ values: [Int64]) throws -> VM.Value {
        .set(
            try .init(
                elements: values.map(integer),
                elementType: .int64
            )
        )
    }

    private func dictionary(
        _ entries: [(String, Int64)]
    ) throws -> VM.Value {
        .dictionary(
            try entries.map { key, value in
                .init(key: .string(key), value: try integer(value))
            },
            keyType: .string,
            valueType: .int64
        )
    }

    private func integerArrays(_ values: [[Int64]]) throws -> VM.Value {
        .array(
            try values.map(integers),
            elementType: .array(.int64)
        )
    }

    private func uint8(_ value: UInt8) throws -> VM.Value {
        .integer(
            try .init(rawBits: UInt64(value), bitWidth: 8, isSigned: false)
        )
    }

    private func uint8s(_ values: [UInt8]) throws -> VM.Value {
        .array(
            try values.map(uint8),
            elementType: .integer(bitWidth: 8, signed: false)
        )
    }

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func doubles(_ values: [Double]) -> VM.Value {
        .array(values.map(VM.Value.float64), elementType: .float(bitWidth: 64))
    }
}
}
