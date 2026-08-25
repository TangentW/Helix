import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Progression Sequence semantics")
struct ProgressionSequenceSemanticsMatrix {
    private struct Probe: Sendable {
        var name: String
        var source: String
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult

        init(
            name: String,
            source: String,
            arguments: [VM.Value],
            expected: VM.Value
        ) {
            self.name = name
            self.source = source
            self.arguments = arguments
            self.expected = .returned(expected)
        }

        init(
            name: String,
            source: String,
            arguments: [VM.Value],
            expected: VM.ExecutionResult
        ) {
            self.name = name
            self.source = source
            self.arguments = arguments
            self.expected = expected
        }
    }

    @Test("Range and stride values compose with common Sequence APIs")
    func lowersProgressionSequenceAPIs() throws {
        try execute([
            Probe(
                name: "rangeArray",
                source: """
                public func rangeArray(_ upper: Int) -> [Int] {
                    Array(0..<upper)
                }
                """,
                arguments: [try integer(4)],
                expected: try integers([0, 1, 2, 3])
            ),
            Probe(
                name: "rangeMap",
                source: """
                public func rangeMap(_ upper: Int) -> [Int] {
                    (0..<upper).map { $0 * 2 }
                }
                """,
                arguments: [try integer(4)],
                expected: try integers([0, 2, 4, 6])
            ),
            Probe(
                name: "closedRangeFilter",
                source: """
                public func closedRangeFilter(_ upper: Int) -> [Int] {
                    (0...upper).filter { $0.isMultiple(of: 2) }
                }
                """,
                arguments: [try integer(5)],
                expected: try integers([0, 2, 4])
            ),
            Probe(
                name: "rangeReduce",
                source: """
                public func rangeReduce(_ upper: Int) -> Int {
                    (0..<upper).reduce(0, +)
                }
                """,
                arguments: [try integer(5)],
                expected: try integer(10)
            ),
            Probe(
                name: "strideArray",
                source: """
                public func strideArray(_ upper: Int) -> [Int] {
                    Array(stride(from: 0, to: upper, by: 2))
                }
                """,
                arguments: [try integer(7)],
                expected: try integers([0, 2, 4, 6])
            ),
            Probe(
                name: "rangeZip",
                source: """
                public func rangeZip(_ values: [Int]) -> [Int] {
                    zip(0..<values.count, values).map { $0 + $1 }
                }
                """,
                arguments: [try integers([3, 4, 5])],
                expected: try integers([3, 5, 7])
            ),
        ])
    }

    @Test("Progressions reuse adapters, forward traversal, and closure semantics")
    func lowersProgressionSequenceComposition() throws {
        try execute([
            Probe(
                name: "enumeratedRange",
                source: """
                public func enumeratedRange(_ upper: Int) -> [(Int, Int)] {
                    Array((2..<upper).enumerated())
                }
                """,
                arguments: [try integer(5)],
                expected: .array(
                    [
                        .tuple([try integer(0), try integer(2)]),
                        .tuple([try integer(1), try integer(3)]),
                        .tuple([try integer(2), try integer(4)]),
                    ],
                    elementType: .tuple([.int64, .int64])
                )
            ),
            Probe(
                name: "reversedRange",
                source: """
                public func reversedRange(_ upper: Int) -> [Int] {
                    Array((1...upper).reversed())
                }
                """,
                arguments: [try integer(4)],
                expected: try integers([4, 3, 2, 1])
            ),
            Probe(
                name: "rangeFlatMap",
                source: """
                public func rangeFlatMap(_ upper: Int) -> [Int] {
                    (1...upper).flatMap { [$0, -$0] }
                }
                """,
                arguments: [try integer(3)],
                expected: try integers([1, -1, 2, -2, 3, -3])
            ),
            Probe(
                name: "rangeCompactMap",
                source: """
                public func rangeCompactMap(_ upper: Int) -> [Int] {
                    (0..<upper).compactMap { $0.isMultiple(of: 2) ? $0 : nil }
                }
                """,
                arguments: [try integer(6)],
                expected: try integers([0, 2, 4])
            ),
            Probe(
                name: "rangeReduceInto",
                source: """
                public func rangeReduceInto(_ upper: Int) -> Int {
                    (0..<upper).reduce(into: 0) { $0 += $1 }
                }
                """,
                arguments: [try integer(5)],
                expected: try integer(10)
            ),
            Probe(
                name: "rangeForEach",
                source: """
                public func rangeForEach(_ upper: Int) -> Int {
                    var total = 0
                    (0..<upper).forEach { total += $0 }
                    return total
                }
                """,
                arguments: [try integer(5)],
                expected: try integer(10)
            ),
            Probe(
                name: "rangePredicateIndices",
                source: """
                public func rangePredicateIndices(
                    _ lower: Int,
                    _ upper: Int
                ) -> (Int?, Int?) {
                    let values = lower..<upper
                    return (
                        values.firstIndex { $0.isMultiple(of: 3) },
                        values.lastIndex { $0.isMultiple(of: 3) }
                    )
                }
                """,
                arguments: [try integer(5), try integer(12)],
                expected: .tuple([
                    .optional(try integer(6)),
                    .optional(try integer(9)),
                ])
            ),
            Probe(
                name: "rangeLastShortCircuit",
                source: """
                public func rangeLastShortCircuit(
                    _ upper: Int
                ) -> (Int?, Int) {
                    var visits = 0
                    let last = (0..<upper).last { value in
                        visits += 1
                        return value.isMultiple(of: 3)
                    }
                    return (last, visits)
                }
                """,
                arguments: [try integer(8)],
                expected: .tuple([
                    .optional(try integer(6)),
                    try integer(2),
                ])
            ),
            Probe(
                name: "emptyRangeLastShortCircuit",
                source: """
                public func emptyRangeLastShortCircuit(
                    _ bound: Int
                ) -> (Int?, Int) {
                    var visits = 0
                    let last = (bound..<bound).last { value in
                        visits += 1
                        return value == bound
                    }
                    return (last, visits)
                }
                """,
                arguments: [try integer(8)],
                expected: .tuple([
                    .optional(nil),
                    try integer(0),
                ])
            ),
            Probe(
                name: "closedRangeLastBoundary",
                source: """
                public func closedRangeLastBoundary(_ bound: Int) -> Int? {
                    ((bound - 1)...bound).last { $0 == bound }
                }
                """,
                arguments: [try integer(.max)],
                expected: .optional(try integer(.max))
            ),
            Probe(
                name: "rangeFirst",
                source: """
                public func rangeFirst(_ upper: Int) -> Int? {
                    (1...upper).first { $0.isMultiple(of: 3) }
                }
                """,
                arguments: [try integer(8)],
                expected: .optional(try integer(3))
            ),
            Probe(
                name: "rangePredicates",
                source: """
                public func rangePredicates(_ upper: Int) -> (Bool, Bool) {
                    let values = 1...upper
                    return (
                        values.contains { $0 > 4 },
                        values.allSatisfy { $0 > 0 }
                    )
                }
                """,
                arguments: [try integer(6)],
                expected: .tuple([.bool(true), .bool(true)])
            ),
            Probe(
                name: "rangeComparatorExtrema",
                source: """
                public func rangeComparatorExtrema(_ upper: Int) -> (Int?, Int?) {
                    let values = 1...upper
                    return (
                        values.min(by: >),
                        values.max(by: <)
                    )
                }
                """,
                arguments: [try integer(4)],
                expected: .tuple([
                    .optional(try integer(4)),
                    .optional(try integer(4)),
                ])
            ),
            Probe(
                name: "doubleStrideMap",
                source: """
                public func doubleStrideMap(_ end: Double) -> [Double] {
                    stride(from: 0.0, to: end, by: 0.5).map { $0 * 2 }
                }
                """,
                arguments: [.float64(1.5)],
                expected: .array(
                    [.float64(0), .float64(1), .float64(2)],
                    elementType: .float(bitWidth: 64)
                )
            ),
            Probe(
                name: "stridePrefixWhile",
                source: """
                public func stridePrefixWhile(_ end: Int) -> [Int] {
                    stride(from: 0, to: end, by: 2).prefix { $0 < 5 }
                }
                """,
                arguments: [try integer(10)],
                expected: try integers([0, 2, 4])
            ),
            Probe(
                name: "throwingRangeMap",
                source: """
                private enum RangeStop: Error { case stop }
                public func throwingRangeMap(_ upper: Int) -> Int {
                    do {
                        return try (0..<upper).map { value in
                            if value == 2 { throw RangeStop.stop }
                            return value
                        }.count
                    } catch {
                        return -1
                    }
                }
                """,
                arguments: [try integer(5)],
                expected: try integer(-1)
            ),
        ])
    }

    @Test("Materialization preserves progression boundaries and short-circuiting")
    func verifiesProgressionSequenceBoundaries() throws {
        try execute([
            Probe(
                name: "emptyRangeArray",
                source: """
                public func emptyRangeArray(_ bound: Int) -> [Int] {
                    Array(bound..<bound)
                }
                """,
                arguments: [try integer(7)],
                expected: try integers([])
            ),
            Probe(
                name: "singleMaximumClosedRange",
                source: """
                public func singleMaximumClosedRange(_ bound: Int) -> [Int] {
                    Array(bound...bound)
                }
                """,
                arguments: [try integer(.max)],
                expected: try integers([.max])
            ),
            Probe(
                name: "descendingStrideArray",
                source: """
                public func descendingStrideArray(
                    _ start: Int,
                    _ end: Int,
                    _ step: Int
                ) -> [Int] {
                    Array(stride(from: start, through: end, by: step))
                }
                """,
                arguments: [try integer(5), try integer(1), try integer(-2)],
                expected: try integers([5, 3, 1])
            ),
            Probe(
                name: "zeroStrideArray",
                source: """
                public func zeroStrideArray(_ step: Int) -> [Int] {
                    Array(stride(from: 0, to: 5, by: step))
                }
                """,
                arguments: [try integer(0)],
                expected: .trapped(
                    .explicit("Stride size must not be zero")
                )
            ),
            Probe(
                name: "uint8RangeArray",
                source: """
                public func uint8RangeArray(
                    _ lower: UInt8,
                    _ upper: UInt8
                ) -> [UInt8] {
                    Array(lower...upper)
                }
                """,
                arguments: [
                    try unsignedInteger(253, width: 8),
                    try unsignedInteger(255, width: 8),
                ],
                expected: .array(
                    [
                        try unsignedInteger(253, width: 8),
                        try unsignedInteger(254, width: 8),
                        try unsignedInteger(255, width: 8),
                    ],
                    elementType: .integer(bitWidth: 8, signed: false)
                )
            ),
            Probe(
                name: "rangeFirstShortCircuit",
                source: """
                public func rangeFirstShortCircuit(
                    _ upper: Int
                ) -> (Int?, Int) {
                    var visits = 0
                    let first = (0..<upper).first { value in
                        visits += 1
                        return value == 2
                    }
                    return (first, visits)
                }
                """,
                arguments: [try integer(8)],
                expected: .tuple([
                    .optional(try integer(2)),
                    try integer(3),
                ])
            ),
            Probe(
                name: "emptyRangeFirst",
                source: """
                public func emptyRangeFirst(_ bound: Int) -> (Int?, Int) {
                    var visits = 0
                    let first = (bound..<bound).first { value in
                        visits += 1
                        return value == bound
                    }
                    return (first, visits)
                }
                """,
                arguments: [try integer(8)],
                expected: .tuple([
                    .optional(nil),
                    try integer(0),
                ])
            ),
            Probe(
                name: "twoProgressionZip",
                source: """
                public func twoProgressionZip(_ upper: Int) -> [Int] {
                    zip(0..<upper, 1...upper).map { $0 + $1 }
                }
                """,
                arguments: [try integer(3)],
                expected: try integers([1, 3, 5])
            ),
        ])
    }

    @Test("Integer Range count subsequences retain finite progression semantics")
    func lowersIntegerRangeSubsequences() throws {
        try execute([
            Probe(
                name: "rangeCountSubsequences",
                source: """
                public func rangeCountSubsequences(
                    _ lower: Int,
                    _ upper: Int,
                    _ count: Int
                ) -> ([Int], [Int], [Int], [Int]) {
                    let values = lower..<upper
                    return (
                        Array(values.dropFirst(count)),
                        Array(values.dropLast(count)),
                        Array(values.prefix(count)),
                        Array(values.suffix(count))
                    )
                }
                """,
                arguments: [
                    try integer(2), try integer(7), try integer(2),
                ],
                expected: .tuple([
                    try integers([4, 5, 6]),
                    try integers([2, 3, 4]),
                    try integers([2, 3]),
                    try integers([5, 6]),
                ])
            ),
            Probe(
                name: "clampedRangeCountSubsequences",
                source: """
                public func clampedRangeCountSubsequences(
                    _ count: Int
                ) -> ([Int], [Int], [Int], [Int]) {
                    let values = 2..<5
                    return (
                        Array(values.dropFirst(count)),
                        Array(values.dropLast(count)),
                        Array(values.prefix(count)),
                        Array(values.suffix(count))
                    )
                }
                """,
                arguments: [try integer(20)],
                expected: .tuple([
                    try integers([]),
                    try integers([]),
                    try integers([2, 3, 4]),
                    try integers([2, 3, 4]),
                ])
            ),
            Probe(
                name: "overflowClampedRangeCountSubsequences",
                source: """
                public func overflowClampedRangeCountSubsequences(
                    _ count: Int
                ) -> (Bool, Bool, Int, Int) {
                    let values = 2..<5
                    return (
                        values.dropFirst(count).isEmpty,
                        values.dropLast(count).isEmpty,
                        values.prefix(count).count,
                        values.suffix(count).count
                    )
                }
                """,
                arguments: [try integer(.max)],
                expected: .tuple([
                    .bool(true), .bool(true),
                    try integer(3), try integer(3),
                ])
            ),
            Probe(
                name: "wideRangePrefix",
                source: """
                public func wideRangePrefix(_ count: Int) -> [Int] {
                    Array((Int.min..<Int.max).prefix(count))
                }
                """,
                arguments: [try integer(2)],
                expected: try integers([.min, .min + 1])
            ),
            Probe(
                name: "wideRangeSuffix",
                source: """
                public func wideRangeSuffix(_ count: Int) -> [Int] {
                    Array((Int.min..<Int.max).suffix(count))
                }
                """,
                arguments: [try integer(2)],
                expected: try integers([.max - 2, .max - 1])
            ),
            Probe(
                name: "uint8RangeSuffix",
                source: """
                public func uint8RangeSuffix(
                    _ lower: UInt8,
                    _ upper: UInt8,
                    _ count: Int
                ) -> [UInt8] {
                    Array((lower..<upper).suffix(count))
                }
                """,
                arguments: [
                    try unsignedInteger(250, width: 8),
                    try unsignedInteger(255, width: 8),
                    try integer(2),
                ],
                expected: .array(
                    [
                        try unsignedInteger(253, width: 8),
                        try unsignedInteger(254, width: 8),
                    ],
                    elementType: .integer(bitWidth: 8, signed: false)
                )
            ),
            Probe(
                name: "uint64ExtremeRangeEdges",
                source: """
                public func uint64ExtremeRangeEdges(
                    _ count: Int
                ) -> ([UInt64], [UInt64]) {
                    let values = UInt64.min..<UInt64.max
                    return (
                        Array(values.prefix(count)),
                        Array(values.suffix(count))
                    )
                }
                """,
                arguments: [try integer(2)],
                expected: .tuple([
                    .array(
                        [
                            try unsignedInteger(0, width: 64),
                            try unsignedInteger(1, width: 64),
                        ],
                        elementType: .integer(bitWidth: 64, signed: false)
                    ),
                    .array(
                        [
                            try unsignedInteger(.max - 2, width: 64),
                            try unsignedInteger(.max - 1, width: 64),
                        ],
                        elementType: .integer(bitWidth: 64, signed: false)
                    ),
                ])
            ),
            Probe(
                name: "int8RangePrefixPastElementMaximum",
                source: """
                public func int8RangePrefixPastElementMaximum(
                    _ count: Int
                ) -> Int8? {
                    (Int8.min..<Int8.max).prefix(count).last
                }
                """,
                arguments: [try integer(128)],
                expected: .optional(try signedInteger(-1, width: 8))
            ),
            Probe(
                name: "negativeRangeSubsequenceCount",
                source: """
                public func negativeRangeSubsequenceCount(
                    _ count: Int
                ) -> [Int] {
                    Array((0..<4).dropFirst(count))
                }
                """,
                arguments: [try integer(-1)],
                expected: .trapped(
                    .explicit(
                        "collection subsequence count must not be negative"
                    )
                )
            ),
        ])
    }

    @Test("Unrepresented Sequence semantics fail closed")
    func rejectsUnsupportedSequenceSources() {
        expectUnsupported(
            name: "closedRangeFirstIndex",
            source: """
            public func closedRangeFirstIndex(
                _ lower: Int,
                _ upper: Int
            ) -> Bool {
                let values = lower...upper
                return values.firstIndex { $0 == lower }
                    == values.startIndex
            }
            """,
            diagnostic: "ClosedRange<Int>.Index"
        )
        expectUnsupported(
            name: "unboundedRangeArray",
            source: """
            public func unboundedRangeArray() -> [Int] {
                Array(0...)
            }
            """,
            diagnostic: "PartialRangeFrom<Int>"
        )
        expectUnsupported(
            name: "customSequenceMap",
            source: """
            public struct CounterSequence: Sequence, IteratorProtocol {
                public var current: Int
                public let end: Int

                public mutating func next() -> Int? {
                    guard current < end else { return nil }
                    defer { current += 1 }
                    return current
                }

                public func makeIterator() -> CounterSequence { self }
            }

            public func customSequenceMap(_ upper: Int) -> [Int] {
                CounterSequence(current: 0, end: upper).map { $0 * 2 }
            }
            """,
            diagnostic: "CounterSequence"
        )
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name
                )
                let result = VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: probe.arguments
                )
                if result != probe.expected {
                    failures.append(
                        "\(probe.name): expected \(probe.expected), "
                            + "got \(result)"
                    )
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "progression Sequence gaps:\n\(failures.joined(separator: "\n"))"
            )
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
                moduleName: "HelixProgressionSequence_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains(diagnostic))
        } catch {
            Issue.record("\(name) produced an unexpected error: \(error)")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func unsignedInteger(
        _ value: UInt64,
        width: UInt16
    ) throws -> VM.Value {
        .integer(
            try .init(rawBits: value, bitWidth: width, isSigned: false)
        )
    }

    private func signedInteger(
        _ value: Int64,
        width: UInt16
    ) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: width, isSigned: true)
        )
    }
}
}
