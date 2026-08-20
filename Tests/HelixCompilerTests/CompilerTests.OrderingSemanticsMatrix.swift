import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Array ordering semantics")
struct OrderingSemanticsMatrix {
    @Test("Natural sorted and sort cover scalar Comparable values")
    func lowersNaturalOrdering() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func naturalOrdering(
                _ values: [Int],
                _ words: [String],
                _ decimals: [Double]
            ) -> ([Int], [Int], [String], [Double]) {
                let copied = values.sorted()
                var mutated = values
                mutated.sort()
                return (copied, mutated, words.sorted(), decimals.sorted())
            }
            """,
            functionName: "naturalOrdering",
            moduleName: "HelixNaturalOrdering"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    try integers([3, -1, 3, 0, -7]),
                    .array(
                        [.string("beta"), .string("alpha"), .string("beta")],
                        elementType: .string
                    ),
                    doubles([2.5, -3.25, 0, 2.5]),
                ]
            ) == .returned(.tuple([
                try integers([-7, -1, 0, 3, 3]),
                try integers([-7, -1, 0, 3, 3]),
                .array(
                    [.string("alpha"), .string("beta"), .string("beta")],
                    elementType: .string
                ),
                doubles([-3.25, 0, 2.5, 2.5]),
            ]))
        )
    }

    @Test("Comparator sorting is generic, stable, and capture-aware")
    func lowersComparatorOrdering() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct OrderingItem {
                var key: Int
                var tag: Int
            }

            public func comparatorOrdering() -> ([Int], [Int], Int) {
                let values = [
                    OrderingItem(key: 2, tag: 20),
                    OrderingItem(key: 1, tag: 10),
                    OrderingItem(key: 2, tag: 21),
                    OrderingItem(key: 1, tag: 11),
                ]
                var comparisons = 0
                let sorted = values.sorted { lhs, rhs in
                    comparisons += 1
                    return lhs.key < rhs.key
                }
                var mutated = values
                mutated.sort { lhs, rhs in lhs.key > rhs.key }
                return (
                    sorted.map { $0.tag },
                    mutated.map { $0.tag },
                    comparisons
                )
            }
            """,
            functionName: "comparatorOrdering",
            moduleName: "HelixComparatorOrdering"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: []
            ) == .returned(.tuple([
                try integers([10, 11, 20, 21]),
                try integers([20, 21, 10, 11]),
                try integer(5),
            ]))
        )
    }

    @Test("Array-backed adapters participate in Sequence sorting")
    func lowersAdapterOrdering() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func adapterOrdering(
                _ values: [Int]
            ) -> ([Int], [Int]) {
                let ascending = values.reversed().sorted()
                let descending = values.dropFirst().sorted { $0 > $1 }
                return (ascending, descending)
            }
            """,
            functionName: "adapterOrdering",
            moduleName: "HelixAdapterOrdering"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([8, 1, 5, 3])]
            ) == .returned(.tuple([
                try integers([1, 3, 5, 8]),
                try integers([5, 3, 1]),
            ]))
        )
    }

    @Test("Throwing mutating sort commits only a completed ordering")
    func rollsBackThrowingSort() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum OrderingFailure: Error { case stop }

            public func rollbackSort(
                _ values: [Int]
            ) -> ([Int], [Int], Bool) {
                var result = values
                var visits: [Int] = []
                do {
                    try result.sort { lhs, rhs in
                        visits.append(lhs)
                        visits.append(rhs)
                        if lhs == 0 || rhs == 0 {
                            throw OrderingFailure.stop
                        }
                        return lhs < rhs
                    }
                    return (result, visits, false)
                } catch {
                    return (result, visits, true)
                }
            }
            """,
            functionName: "rollbackSort",
            moduleName: "HelixThrowingSortRollback"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([4, 2, 0, 1])]
            ) == .returned(.tuple([
                try integers([4, 2, 0, 1]),
                try integers([2, 4, 1, 0]),
                .bool(true),
            ]))
        )
    }

    @Test("Partition preserves the false/true boundary and stable groups")
    func lowersPartition() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func stablePartition(_ values: [Int]) -> (Int, [Int]) {
                var result = values
                let boundary = result.partition { value in
                    value % 2 == 0
                }
                return (boundary, result)
            }
            """,
            functionName: "stablePartition",
            moduleName: "HelixStablePartition"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([2, 1, 4, 3, 5, 6])]
            ) == .returned(.tuple([
                try integer(3),
                try integers([1, 3, 5, 2, 4, 6]),
            ]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([])]
            ) == .returned(.tuple([
                try integer(0),
                try integers([]),
            ]))
        )
    }

    @Test("Ordering callbacks handle empty and one-sided boundaries")
    func lowersOrderingBoundaries() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func orderingBoundaries(
                _ values: [Int]
            ) -> (Int, [Int], Int, [Int], [Int], [Int], Int) {
                var allFalse = values
                let falseBoundary = allFalse.partition { _ in false }
                var allTrue = values
                let trueBoundary = allTrue.partition { _ in true }
                var visits = 0
                let empty = [Int]().sorted {
                    visits += 1
                    return $0 < $1
                }
                let singleton = [7].sorted {
                    visits += 1
                    return $0 < $1
                }
                return (
                    falseBoundary,
                    allFalse,
                    trueBoundary,
                    allTrue,
                    empty,
                    singleton,
                    visits
                )
            }
            """,
            functionName: "orderingBoundaries",
            moduleName: "HelixOrderingBoundaries"
        )

        let input = try integers([3, 1, 2])
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [input]
            ) == .returned(.tuple([
                try integer(3),
                input,
                try integer(0),
                input,
                try integers([]),
                try integers([7]),
                try integer(0),
            ]))
        )
    }

    @Test("Throwing partition preserves original inout storage")
    func rollsBackThrowingPartition() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum PartitionFailure: Error { case stop }

            public func rollbackPartition(
                _ values: [Int]
            ) -> ([Int], [Int], Bool) {
                var result = values
                var visits: [Int] = []
                do {
                    _ = try result.partition { value in
                        visits.append(value)
                        if value == 0 { throw PartitionFailure.stop }
                        return value < 0
                    }
                    return (result, visits, false)
                } catch {
                    return (result, visits, true)
                }
            }
            """,
            functionName: "rollbackPartition",
            moduleName: "HelixThrowingPartitionRollback"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integers([3, -1, 0, -2])]
            ) == .returned(.tuple([
                try integers([3, -1, 0, -2]),
                try integers([3, -1, 0]),
                .bool(true),
            ]))
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func doubles(_ values: [Double]) -> VM.Value {
        .array(values.map(VM.Value.float64), elementType: .float(bitWidth: 64))
    }
}
}
