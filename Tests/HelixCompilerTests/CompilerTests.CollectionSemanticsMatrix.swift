import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift collection value semantics")
struct CollectionSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Array and Dictionary equality use recursive Swift value semantics")
    func lowersRecursiveCollectionEquality() throws {
        let ordered = try dictionary([("one", 1), ("two", 2)])
        let reordered = try dictionary([("two", 2), ("one", 1)])
        let different = try dictionary([("one", 1), ("two", 3)])
        let sharedNaN = doubles([Double.nan])
        try run([
            Probe(
                name: "arraysEqual",
                source: """
                public func arraysEqual(_ lhs: [Int], _ rhs: [Int]) -> Bool {
                    lhs == rhs
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([]), try integers([])],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integers([1, 2]), try integers([1, 2])],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integers([1, 2]), try integers([2, 1])],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "floatingArraysEqual",
                source: """
                public func floatingArraysEqual(
                    _ lhs: [Double],
                    _ rhs: [Double]
                ) -> Bool { lhs == rhs }
                """,
                scenarios: [
                    .init(
                        arguments: [sharedNaN, sharedNaN],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [doubles([.nan]), doubles([.nan])],
                        expected: .returned(.bool(false))
                    ),
                    .init(
                        arguments: [doubles([-0.0]), doubles([0.0])],
                        expected: .returned(.bool(true))
                    ),
                ]
            ),
            Probe(
                name: "dictionariesEqual",
                source: """
                public func dictionariesEqual(
                    _ lhs: [String: Int],
                    _ rhs: [String: Int]
                ) -> Bool { lhs == rhs }
                """,
                scenarios: [
                    .init(
                        arguments: [ordered, reordered],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [ordered, different],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "collectionsNotEqual",
                source: """
                public func collectionsNotEqual(
                    _ lhs: [Int],
                    _ rhs: [Int],
                    _ first: [String: Int],
                    _ second: [String: Int]
                ) -> (Bool, Bool) {
                    (lhs != rhs, first != second)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([1, 2]),
                            try integers([1, 2]),
                            ordered,
                            reordered,
                        ],
                        expected: .returned(.tuple([.bool(false), .bool(false)]))
                    ),
                    .init(
                        arguments: [
                            try integers([1, 2]),
                            try integers([2, 1]),
                            ordered,
                            different,
                        ],
                        expected: .returned(.tuple([.bool(true), .bool(true)]))
                    ),
                ]
            ),
            Probe(
                name: "dictionaryArraysEqual",
                source: """
                public func dictionaryArraysEqual(
                    _ lhs: [[String: Int]],
                    _ rhs: [[String: Int]]
                ) -> Bool { lhs == rhs }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            dictionaries([ordered]),
                            dictionaries([reordered]),
                        ],
                        expected: .returned(.bool(true))
                    ),
                ]
            ),
            Probe(
                name: "containsDictionary",
                source: """
                public func containsDictionary(
                    _ values: [[String: Int]],
                    _ needle: [String: Int]
                ) -> Bool { values.contains(needle) }
                """,
                scenarios: [
                    .init(
                        arguments: [dictionaries([ordered]), reordered],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [dictionaries([ordered]), different],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
        ])
    }

    @Test("Collection searches and extrema preserve Swift boundary behavior")
    func lowersSearchAndExtrema() throws {
        try run([
            Probe(
                name: "matchingIndices",
                source: """
                public func matchingIndices(
                    _ values: [Int],
                    _ needle: Int
                ) -> (Int?, Int?) {
                    (values.firstIndex(of: needle), values.lastIndex(of: needle))
                }
                """,
                scenarios: [
                    try indexScenario([], needle: 1),
                    try indexScenario([4, 2, 4, 3, 4], needle: 4),
                    try indexScenario([1, 2, 3], needle: 9),
                ]
            ),
            Probe(
                name: "integerExtrema",
                source: """
                public func integerExtrema(_ values: [Int]) -> (Int?, Int?) {
                    (values.min(), values.max())
                }
                """,
                scenarios: [
                    try integerExtremaScenario([]),
                    try integerExtremaScenario([3, -4, 8, -4]),
                ]
            ),
            Probe(
                name: "unsignedSearchAndExtrema",
                source: """
                public func unsignedSearchAndExtrema(
                    _ values: [UInt8],
                    _ needle: UInt8
                ) -> (Int?, Int?, UInt8?, UInt8?) {
                    (
                        values.firstIndex(of: needle),
                        values.lastIndex(of: needle),
                        values.min(),
                        values.max()
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try uint8s([]), try uint8(7)],
                        expected: .returned(
                            .tuple([
                                .optional(nil),
                                .optional(nil),
                                .optional(nil),
                                .optional(nil),
                            ])
                        )
                    ),
                    .init(
                        arguments: [
                            try uint8s([255, 7, 0, 7]),
                            try uint8(7),
                        ],
                        expected: .returned(
                            .tuple([
                                .optional(try integer(1)),
                                .optional(try integer(3)),
                                .optional(try uint8(0)),
                                .optional(try uint8(255)),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "stringExtrema",
                source: """
                public func stringExtrema(
                    _ values: [String]
                ) -> (String?, String?) { (values.min(), values.max()) }
                """,
                scenarios: [
                    stringExtremaScenario([]),
                    stringExtremaScenario(["éclair", "apple", "香蕉"]),
                ]
            ),
            Probe(
                name: "floatingExtrema",
                source: """
                public func floatingExtrema(
                    _ values: [Double]
                ) -> (Double?, Double?) { (values.min(), values.max()) }
                """,
                scenarios: [
                    floatingExtremaScenario([]),
                    floatingExtremaScenario([0.0, -0.0]),
                    floatingExtremaScenario([.nan, 1, -2]),
                    floatingExtremaScenario([1, .nan, -2]),
                ]
            ),
        ])
    }

    @Test("Sequence relations distinguish value, prefix, and lexicographic rules")
    func lowersSequenceRelations() throws {
        let first = try dictionary([("a", 1), ("b", 2)])
        let same = try dictionary([("b", 2), ("a", 1)])
        let sharedNaN = doubles([.nan])
        try run([
            Probe(
                name: "sequenceRelations",
                source: """
                public func sequenceRelations(
                    _ lhs: [Int],
                    _ rhs: [Int]
                ) -> (Bool, Bool, Bool) {
                    (
                        lhs.elementsEqual(rhs),
                        lhs.starts(with: rhs),
                        lhs.lexicographicallyPrecedes(rhs)
                    )
                }
                """,
                scenarios: [
                    try relationScenario([], []),
                    try relationScenario([1, 2, 3], [1, 2]),
                    try relationScenario([1, 2], [1, 2, 3]),
                    try relationScenario([1, 4], [2]),
                    try relationScenario([2], [1, 9]),
                ]
            ),
            Probe(
                name: "nestedSequenceRelations",
                source: """
                public func nestedSequenceRelations(
                    _ lhs: [[String: Int]],
                    _ rhs: [[String: Int]]
                ) -> (Bool, Bool) {
                    (lhs.elementsEqual(rhs), lhs.starts(with: rhs))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            dictionaries([first, first]),
                            dictionaries([same]),
                        ],
                        expected: .returned(
                            .tuple([.bool(false), .bool(true)])
                        )
                    ),
                ]
            ),
            Probe(
                name: "floatingSequenceRelations",
                source: """
                public func floatingSequenceRelations(
                    _ lhs: [Double],
                    _ rhs: [Double]
                ) -> (Bool, Bool, Bool) {
                    (
                        lhs.elementsEqual(rhs),
                        lhs.starts(with: rhs),
                        lhs.lexicographicallyPrecedes(rhs)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [sharedNaN, sharedNaN],
                        expected: .returned(
                            .tuple([.bool(false), .bool(false), .bool(false)])
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Array indices and distance lower to checked Int progressions")
    func lowersArrayIndexAPIs() throws {
        try run([
            Probe(
                name: "indexFacts",
                source: """
                public func indexFacts(_ values: [Int]) -> (Int, Int, Int) {
                    (
                        values.startIndex,
                        values.endIndex,
                        values.distance(
                            from: values.startIndex,
                            to: values.endIndex
                        )
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(
                            .tuple([
                                try integer(0),
                                try integer(0),
                                try integer(0),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try integers([5, 6, 7])],
                        expected: .returned(
                            .tuple([
                                try integer(0),
                                try integer(3),
                                try integer(3),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "distanceBetween",
                source: """
                public func distanceBetween(
                    _ values: [Int],
                    _ from: Int,
                    _ to: Int
                ) -> Int { values.distance(from: from, to: to) }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([1, 2, 3]),
                            try integer(3),
                            try integer(0),
                        ],
                        expected: .returned(try integer(-3))
                    ),
                    .init(
                        arguments: [
                            try integers([1]),
                            try integer(-1),
                            try integer(0),
                        ],
                        expected: .returned(try integer(1))
                    ),
                    .init(
                        arguments: [
                            try integers([1]),
                            try integer(0),
                            try integer(2),
                        ],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [
                            try integers([]),
                            try integer(.min),
                            try integer(.max),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            Probe(
                name: "indexedSum",
                source: """
                public func indexedSum(_ values: [Int]) -> Int {
                    var result = 0
                    for index in values.indices { result += values[index] }
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integers([4, -2, 9])],
                        expected: .returned(try integer(11))
                    ),
                ]
            ),
            Probe(
                name: "indexMovement",
                source: """
                public func indexMovement(
                    _ values: [Int],
                    _ index: Int
                ) -> (Int, Int) {
                    (values.index(after: index), values.index(before: index))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3]), try integer(0)],
                        expected: .returned(
                            .tuple([try integer(1), try integer(-1)])
                        )
                    ),
                    .init(
                        arguments: [try integers([]), try integer(-1)],
                        expected: .returned(
                            .tuple([try integer(0), try integer(-2)])
                        )
                    ),
                    .init(
                        arguments: [try integers([]), try integer(.max)],
                        expected: .trapped(.integerOverflow)
                    ),
                    .init(
                        arguments: [try integers([]), try integer(.min)],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            Probe(
                name: "offsetIndex",
                source: """
                public func offsetIndex(
                    _ values: [Int],
                    _ index: Int,
                    _ distance: Int
                ) -> Int {
                    values.index(index, offsetBy: distance)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([1, 2, 3]),
                            try integer(-1),
                            try integer(2),
                        ],
                        expected: .returned(try integer(1))
                    ),
                    .init(
                        arguments: [
                            try integers([]),
                            try integer(.min),
                            try integer(-1),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
            Probe(
                name: "limitedOffset",
                source: """
                public func limitedOffset(
                    _ values: [Int],
                    _ index: Int,
                    _ distance: Int,
                    _ limit: Int
                ) -> Int? {
                    values.index(
                        index,
                        offsetBy: distance,
                        limitedBy: limit
                    )
                }
                """,
                scenarios: [
                    try limitedOffsetScenario(0, 2, limit: 1, expected: nil),
                    try limitedOffsetScenario(0, 2, limit: 2, expected: 2),
                    try limitedOffsetScenario(2, -2, limit: 1, expected: nil),
                    try limitedOffsetScenario(2, -2, limit: 0, expected: 0),
                    try limitedOffsetScenario(2, 1, limit: 0, expected: 3),
                    try limitedOffsetScenario(0, -1, limit: 2, expected: -1),
                    try limitedOffsetScenario(0, 0, limit: 0, expected: 0),
                    try limitedOffsetScenario(
                        .max,
                        1,
                        limit: .max,
                        expected: nil
                    ),
                    try limitedOffsetScenario(
                        0,
                        .max,
                        limit: 1,
                        expected: nil
                    ),
                    try limitedOffsetScenario(
                        .min,
                        -1,
                        limit: .min,
                        expected: nil
                    ),
                    try limitedOffsetScenario(
                        0,
                        .min,
                        limit: -1,
                        expected: nil
                    ),
                    .init(
                        arguments: [
                            try integers([]),
                            try integer(.max),
                            try integer(1),
                            try integer(.min),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
        ])
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixCollection_\(probe.name)"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let actual = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if !exactlyMatches(actual, scenario.expected) {
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
                    rawValue: "collection semantic gaps:\n"
                        + failures.joined(separator: "\n")
                )
            )
        }
    }

    private func exactlyMatches(
        _ actual: VM.ExecutionResult,
        _ expected: VM.ExecutionResult
    ) -> Bool {
        switch (actual, expected) {
        case let (.returned(actual), .returned(expected)):
            switch (actual, expected) {
            case (nil, nil): true
            case let (actual?, expected?): exactlyMatches(actual, expected)
            default: false
            }
        default:
            actual == expected
        }
    }

    /// Test expectations compare IEEE storage, not `FloatingPoint.==`, so a
    /// preserved NaN payload and the sign of zero remain observable.
    private func exactlyMatches(_ actual: VM.Value, _ expected: VM.Value) -> Bool {
        switch (actual, expected) {
        case let (.float(actual), .float(expected)):
            actual.bitWidth == expected.bitWidth
                && actual.bitPattern == expected.bitPattern
        case let (.tuple(actual), .tuple(expected)):
            actual.count == expected.count
                && zip(actual, expected).allSatisfy(exactlyMatches)
        case let (.optional(actual), .optional(expected)):
            switch (actual, expected) {
            case (nil, nil): true
            case let (actual?, expected?): exactlyMatches(actual, expected)
            default: false
            }
        default:
            actual == expected
        }
    }

    private func indexScenario(
        _ values: [Int64],
        needle: Int64
    ) throws -> Scenario {
        .init(
            arguments: [try integers(values), try integer(needle)],
            expected: .returned(
                .tuple([
                    try optionalInteger(values.firstIndex(of: needle)),
                    try optionalInteger(values.lastIndex(of: needle)),
                ])
            )
        )
    }

    private func integerExtremaScenario(
        _ values: [Int64]
    ) throws -> Scenario {
        .init(
            arguments: [try integers(values)],
            expected: .returned(
                .tuple([
                    try optionalInteger(values.min()),
                    try optionalInteger(values.max()),
                ])
            )
        )
    }

    private func stringExtremaScenario(_ values: [String]) -> Scenario {
        .init(
            arguments: [strings(values)],
            expected: .returned(
                .tuple([
                    .optional(values.min().map(VM.Value.string)),
                    .optional(values.max().map(VM.Value.string)),
                ])
            )
        )
    }

    private func floatingExtremaScenario(_ values: [Double]) -> Scenario {
        .init(
            arguments: [doubles(values)],
            expected: .returned(
                .tuple([
                    .optional(values.min().map(VM.Value.float64)),
                    .optional(values.max().map(VM.Value.float64)),
                ])
            )
        )
    }

    private func relationScenario(
        _ lhs: [Int64],
        _ rhs: [Int64]
    ) throws -> Scenario {
        .init(
            arguments: [try integers(lhs), try integers(rhs)],
            expected: .returned(
                .tuple([
                    .bool(lhs.elementsEqual(rhs)),
                    .bool(lhs.starts(with: rhs)),
                    .bool(lhs.lexicographicallyPrecedes(rhs)),
                ])
            )
        )
    }

    private func limitedOffsetScenario(
        _ index: Int64,
        _ distance: Int64,
        limit: Int64,
        expected: Int64?
    ) throws -> Scenario {
        .init(
            arguments: [
                try integers([1, 2, 3]),
                try integer(index),
                try integer(distance),
                try integer(limit),
            ],
            expected: .returned(try optionalInteger(expected))
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func optionalInteger<T: BinaryInteger>(
        _ value: T?
    ) throws -> VM.Value {
        .optional(try value.map { try integer(Int64($0)) })
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
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

    private func doubles(_ values: [Double]) -> VM.Value {
        .array(values.map(VM.Value.float64), elementType: .float(bitWidth: 64))
    }

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func dictionary(
        _ entries: [(String, Int64)]
    ) throws -> VM.Value {
        .dictionary(
            try entries.map {
                .init(
                    key: .string($0.0),
                    value: .integer(
                        try .init(
                            signed: $0.1,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            },
            keyType: .string,
            valueType: .int64
        )
    }

    private func dictionaries(_ values: [VM.Value]) -> VM.Value {
        .array(
            values,
            elementType: .dictionary(key: .string, value: .int64)
        )
    }
}
}
