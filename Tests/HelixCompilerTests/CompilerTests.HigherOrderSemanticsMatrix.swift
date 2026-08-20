import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import HelixVerifier
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift higher-order standard-library semantics")
struct HigherOrderSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Array and Sequence higher-order APIs lower through generic closure CFGs")
    func lowersArrayHigherOrderAPIs() throws {
        let probes = [
            Probe(
                name: "mappedValues",
                source: """
                public func mappedValues(_ values: [Int]) -> [Int] {
                    values.map { $0 * 2 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integers([]))
                    ),
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(try integers([2, -4, 6]))
                    ),
                ]
            ),
            Probe(
                name: "mappedStrings",
                source: """
                public func mappedStrings(_ values: [Int]) -> [String] {
                    values.map { $0 > 0 ? "positive" : "other" }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([-1, 2])],
                        expected: .returned(
                            strings(["other", "positive"])
                        )
                    ),
                ]
            ),
            Probe(
                name: "filteredValues",
                source: """
                public func filteredValues(_ values: [Int]) -> [Int] {
                    values.filter { $0 % 2 == 0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integers([]))
                    ),
                    .init(
                        arguments: [try integers([1, 2, 3, 4])],
                        expected: .returned(try integers([2, 4]))
                    ),
                ]
            ),
            Probe(
                name: "compactedValues",
                source: """
                public func compactedValues(_ values: [Int?]) -> [Int] {
                    values.compactMap { $0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try optionalIntegers([1, nil, -2])],
                        expected: .returned(try integers([1, -2]))
                    ),
                ]
            ),
            Probe(
                name: "reducedValues",
                source: """
                public func reducedValues(_ values: [Int]) -> Int {
                    values.reduce(10) { $0 + $1 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(10))
                    ),
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(16))
                    ),
                ]
            ),
            Probe(
                name: "visitedCount",
                source: """
                public func visitedCount(_ values: [Int]) -> Int {
                    values.forEach { _ in }
                    return values.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(3))
                    ),
                ]
            ),
            Probe(
                name: "firstLargeValue",
                source: """
                public func firstLargeValue(_ values: [Int]) -> Int? {
                    values.first { $0 > 2 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 4, 3])],
                        expected: .returned(.optional(try integer(4)))
                    ),
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
            Probe(
                name: "containsEvenValue",
                source: """
                public func containsEvenValue(_ values: [Int]) -> Bool {
                    values.contains { $0 % 2 == 0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 3, 4, 6])],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integers([1, 3])],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "allPositive",
                source: """
                public func allPositive(_ values: [Int]) -> Bool {
                    values.allSatisfy { $0 > 0 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integers([1, 0, 2])],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
        ]

        try run(probes)
    }

    @Test("Dictionary and Set reuse generic Sequence higher-order lowering")
    func lowersManagedCollectionHigherOrderAPIs() throws {
        try run([
            Probe(
                name: "dictionaryTransforms",
                source: """
                public func dictionaryTransforms(
                    _ source: [String: Int]
                ) -> ([Int], [Int], [Int]) {
                    let mapped = source.map { $0.value * 2 }
                    let flattened = source.flatMap {
                        [$0.value, $0.value + 1]
                    }
                    let compacted = source.compactMap {
                        $0.value > 0 ? $0.value : nil
                    }
                    return (mapped, flattened, compacted)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try dictionary([
                            ("a", 1), ("bb", 4), ("c", -2),
                        ])],
                        expected: .returned(.tuple([
                            try integers([2, 8, -4]),
                            try integers([1, 2, 4, 5, -2, -1]),
                            try integers([1, 4]),
                        ]))
                    ),
                    .init(
                        arguments: [try dictionary([])],
                        expected: .returned(.tuple([
                            try integers([]),
                            try integers([]),
                            try integers([]),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "dictionaryQueries",
                source: """
                public func dictionaryQueries(
                    _ source: [String: Int],
                    _ threshold: Int
                ) -> (
                    Int, Int, Bool, Bool,
                    (key: String, value: Int)?,
                    (key: String, value: Int)?
                ) {
                    let reduced = source.reduce(0) {
                        $0 + $1.key.count + $1.value
                    }
                    var visited = 0
                    source.forEach { visited += $0.value }
                    let contains = source.contains { $0.value > threshold }
                    let all = source.allSatisfy { !$0.key.isEmpty }
                    let first = source.first { $0.value < 0 }
                    let minimum = source.min { $0.value < $1.value }
                    return (reduced, visited, contains, all, first, minimum)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try dictionary([
                                ("a", 1), ("bb", 4), ("c", -2),
                            ]),
                            try integer(3),
                        ],
                        expected: .returned(.tuple([
                            try integer(7),
                            try integer(3),
                            .bool(true),
                            .bool(true),
                            .optional(.tuple([.string("c"), try integer(-2)])),
                            .optional(.tuple([.string("c"), try integer(-2)])),
                        ]))
                    ),
                    .init(
                        arguments: [try dictionary([]), try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0),
                            try integer(0),
                            .bool(false),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "dictionaryAccumulates",
                source: """
                public func dictionaryAccumulates(
                    _ source: [String: Int]
                ) -> [Int] {
                    source.reduce(into: [Int]()) {
                        $0.append($1.value)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try dictionary([
                            ("a", 1), ("bb", 4), ("c", -2),
                        ])],
                        expected: .returned(try integers([1, 4, -2]))
                    ),
                    .init(
                        arguments: [try dictionary([])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
            Probe(
                name: "setTransforms",
                source: """
                public func setTransforms(
                    _ source: Set<Int>,
                    _ threshold: Int
                ) -> ([Int], [Int], [Int]) {
                    let mapped = source.map { $0 * 2 }
                    let flattened = source.flatMap { [$0, $0 + 1] }
                    let compacted = source.compactMap {
                        $0 > threshold ? $0 : nil
                    }
                    return (mapped, flattened, compacted)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7]), try integer(4)],
                        expected: .returned(.tuple([
                            try integers([8, 2, 14]),
                            try integers([4, 5, 1, 2, 7, 8]),
                            try integers([7]),
                        ]))
                    ),
                    .init(
                        arguments: [try set([]), try integer(0)],
                        expected: .returned(.tuple([
                            try integers([]),
                            try integers([]),
                            try integers([]),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "setQueries",
                source: """
                public func setQueries(
                    _ source: Set<Int>,
                    _ threshold: Int
                ) -> (Int, Int, Bool, Bool, Int?, Int?) {
                    let reduced = source.reduce(0, +)
                    var visited = 0
                    source.forEach { visited += $0 }
                    let contains = source.contains { $0 > threshold }
                    let all = source.allSatisfy { $0 > 0 }
                    let first = source.first { $0 > threshold }
                    let minimum = source.min { $0 < $1 }
                    return (reduced, visited, contains, all, first, minimum)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7]), try integer(4)],
                        expected: .returned(.tuple([
                            try integer(12),
                            try integer(12),
                            .bool(true),
                            .bool(true),
                            .optional(try integer(7)),
                            .optional(try integer(1)),
                        ]))
                    ),
                    .init(
                        arguments: [try set([]), try integer(0)],
                        expected: .returned(.tuple([
                            try integer(0),
                            try integer(0),
                            .bool(false),
                            .bool(true),
                            .optional(nil),
                            .optional(nil),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "setAccumulates",
                source: """
                public func setAccumulates(_ source: Set<Int>) -> [Int] {
                    source.reduce(into: [Int]()) { $0.append($1) }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7])],
                        expected: .returned(try integers([4, 1, 7]))
                    ),
                    .init(
                        arguments: [try set([])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
            Probe(
                name: "dictionaryPreservingTransforms",
                source: """
                public func dictionaryPreservingTransforms(
                    _ source: [String: Int],
                    _ threshold: Int
                ) -> ([String: Int], [String: Int], [String: Int]) {
                    let filtered = source.filter { $0.value > threshold }
                    let mapped = source.mapValues { $0 + 10 }
                    let compacted = source.compactMapValues {
                        $0 > threshold ? $0 * 2 : nil
                    }
                    return (filtered, mapped, compacted)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try dictionary([
                                ("a", 1), ("bb", 4), ("c", -2),
                            ]),
                            try integer(0),
                        ],
                        expected: .returned(.tuple([
                            try dictionary([("a", 1), ("bb", 4)]),
                            try dictionary([
                                ("a", 11), ("bb", 14), ("c", 8),
                            ]),
                            try dictionary([("a", 2), ("bb", 8)]),
                        ]))
                    ),
                    .init(
                        arguments: [try dictionary([]), try integer(0)],
                        expected: .returned(.tuple([
                            try dictionary([]),
                            try dictionary([]),
                            try dictionary([]),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "setFilterPreservesValueSemantics",
                source: """
                public func setFilterPreservesValueSemantics(
                    _ source: Set<Int>,
                    _ threshold: Int
                ) -> (Set<Int>, Int) {
                    (source.filter { $0 > threshold }, source.count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7]), try integer(3)],
                        expected: .returned(.tuple([
                            try set([4, 7]),
                            try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [try set([]), try integer(0)],
                        expected: .returned(.tuple([
                            try set([]),
                            try integer(0),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "filterStringSet",
                source: """
                public func filterStringSet(
                    _ source: Set<String>
                ) -> (Set<String>, Int) {
                    (source.filter { $0.count > 1 }, source.count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [stringSet(["a", "beta", "cc"])],
                        expected: .returned(.tuple([
                            stringSet(["beta", "cc"]),
                            try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [stringSet([])],
                        expected: .returned(.tuple([
                            stringSet([]),
                            try integer(0),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "transformStringDictionary",
                source: """
                enum StringTransformError: Error { case empty }

                public func transformStringDictionary(
                    _ source: [String: String]
                ) -> (
                    [String: String], [String: String],
                    [String: String], [String: String]
                ) {
                    let filtered = source.filter { !$0.value.isEmpty }
                    let mapped = source.mapValues { $0 + "!" }
                    let compacted = source.compactMapValues {
                        $0.isEmpty ? nil : $0
                    }
                    let safelyMapped: [String: String]
                    do {
                        safelyMapped = try source.mapValues {
                            if $0.isEmpty { throw StringTransformError.empty }
                            return $0 + "?"
                        }
                    } catch {
                        safelyMapped = [:]
                    }
                    return (filtered, mapped, compacted, safelyMapped)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [stringDictionary([
                            ("a", "one"), ("b", ""),
                        ])],
                        expected: .returned(.tuple([
                            stringDictionary([("a", "one")]),
                            stringDictionary([
                                ("a", "one!"), ("b", "!"),
                            ]),
                            stringDictionary([("a", "one")]),
                            stringDictionary([]),
                        ]))
                    ),
                    .init(
                        arguments: [stringDictionary([("a", "one")])],
                        expected: .returned(.tuple([
                            stringDictionary([("a", "one")]),
                            stringDictionary([("a", "one!")]),
                            stringDictionary([("a", "one")]),
                            stringDictionary([("a", "one?")]),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "safeDictionaryPreservingTransforms",
                source: """
                enum DictionaryTransformError: Error { case negative }

                public func safeDictionaryPreservingTransforms(
                    _ source: [String: Int]
                ) -> ([String: Int], [String: Int], [String: Int]) {
                    let filtered: [String: Int]
                    do {
                        filtered = try source.filter {
                            if $0.value < 0 {
                                throw DictionaryTransformError.negative
                            }
                            return true
                        }
                    } catch {
                        filtered = [:]
                    }

                    let mapped: [String: Int]
                    do {
                        mapped = try source.mapValues {
                            if $0 < 0 {
                                throw DictionaryTransformError.negative
                            }
                            return $0 * 2
                        }
                    } catch {
                        mapped = [:]
                    }

                    let compacted: [String: Int]
                    do {
                        compacted = try source.compactMapValues {
                            if $0 < 0 {
                                throw DictionaryTransformError.negative
                            }
                            return $0 > 1 ? $0 : nil
                        }
                    } catch {
                        compacted = [:]
                    }
                    return (filtered, mapped, compacted)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try dictionary([("a", 1), ("b", 3)])],
                        expected: .returned(.tuple([
                            try dictionary([("a", 1), ("b", 3)]),
                            try dictionary([("a", 2), ("b", 6)]),
                            try dictionary([("b", 3)]),
                        ]))
                    ),
                    .init(
                        arguments: [try dictionary([("a", 1), ("b", -3)])],
                        expected: .returned(.tuple([
                            try dictionary([]),
                            try dictionary([]),
                            try dictionary([]),
                        ]))
                    ),
                ]
            ),
            Probe(
                name: "safeSetFilter",
                source: """
                enum SetFilterError: Error { case negative }

                public func safeSetFilter(_ source: Set<Int>) -> Set<Int> {
                    do {
                        return try source.filter {
                            if $0 < 0 { throw SetFilterError.negative }
                            return $0 > 1
                        }
                    } catch {
                        return []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7])],
                        expected: .returned(try set([4, 7]))
                    ),
                    .init(
                        arguments: [try set([4, -1, 7])],
                        expected: .returned(try set([]))
                    ),
                ]
            ),
            Probe(
                name: "safeDictionaryMap",
                source: """
                enum DictionaryMapError: Error { case negative }

                public func safeDictionaryMap(
                    _ source: [String: Int]
                ) -> [Int] {
                    do {
                        return try source.map {
                            if $0.value < 0 {
                                throw DictionaryMapError.negative
                            }
                            return $0.value * 2
                        }
                    } catch {
                        return []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try dictionary([("a", 1), ("b", 3)])],
                        expected: .returned(try integers([2, 6]))
                    ),
                    .init(
                        arguments: [try dictionary([("a", 1), ("b", -3)])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
        ])
    }

    @Test("Throwing map propagates its indirect Error channel")
    func lowersThrowingMap() throws {
        try run([
            Probe(
                name: "safelyMapped",
                source: """
                enum MappingError: Error { case negative }

                public func safelyMapped(_ values: [Int]) -> [Int] {
                    do {
                        return try values.map { value in
                            if value < 0 { throw MappingError.negative }
                            return value + 1
                        }
                    } catch {
                        return []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .returned(try integers([2, 3]))
                    ),
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
        ])
    }

    @Test("Captures and rethrowing variants share the generic closure path")
    func lowersCapturedAndRethrowingOperations() throws {
        try run([
            Probe(
                name: "offsetValues",
                source: """
                public func offsetValues(_ values: [Int], by offset: Int) -> [Int] {
                    values.map { $0 + offset }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2]), try integer(10)],
                        expected: .returned(try integers([11, 12]))
                    ),
                ]
            ),
            Probe(
                name: "safelyFiltered",
                source: """
                enum FilterError: Error { case negative }

                public func safelyFiltered(_ values: [Int]) -> [Int] {
                    do {
                        return try values.filter {
                            if $0 < 0 { throw FilterError.negative }
                            return $0 % 2 == 0
                        }
                    } catch {
                        return []
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 4])],
                        expected: .returned(try integers([2, 4]))
                    ),
                    .init(
                        arguments: [try integers([2, -1, 4])],
                        expected: .returned(try integers([]))
                    ),
                ]
            ),
            Probe(
                name: "safelyReduced",
                source: """
                enum ReduceError: Error { case negative }

                public func safelyReduced(_ values: [Int]) -> Int {
                    do {
                        return try values.reduce(0) { partial, value in
                            if value < 0 { throw ReduceError.negative }
                            return partial + value
                        }
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(6))
                    ),
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
        ])
    }

    @Test("Optional, Result, and mutation-oriented closures remain covered")
    func lowersValueContainerOperations() throws {
        try run([
            Probe(
                name: "doubledOptional",
                source: """
                public func doubledOptional(_ value: Int?) -> Int? {
                    value.map { $0 * 2 }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.optional(try integer(3))],
                        expected: .returned(.optional(try integer(6)))
                    ),
                    .init(
                        arguments: [.optional(nil)],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
            Probe(
                name: "optionalMappedVoid",
                source: """
                public func optionalMappedVoid(_ value: Int?) -> Bool {
                    let mapped = value.map { _ in () }
                    switch mapped {
                    case .some: return true
                    case .none: return false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.optional(try integer(3))],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.optional(nil)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "arrayMappedVoid",
                source: """
                public func arrayMappedVoid(_ values: [Int]) -> Int {
                    values.map { _ in () }.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(3))
                    ),
                ]
            ),
            Probe(
                name: "resultMappedVoid",
                source: """
                enum UnitFailure: Error { case rejected }

                public func resultMappedVoid(_ value: Int) -> Bool {
                    let source: Result<Int, UnitFailure> = value >= 0
                        ? .success(value)
                        : .failure(.rejected)
                    switch source.map({ _ in () }) {
                    case .success: return true
                    case .failure: return false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "storedUnitValues",
                source: """
                private struct UnitBox {
                    var marker: Void
                    var value: Int
                }

                public func storedUnitValues(_ input: Int) -> Int {
                    let pair: (Void, Int) = ((), input)
                    let box = UnitBox(marker: (), value: pair.1)
                    let dictionary: [Int: Void] = [box.value: box.marker]
                    return dictionary.count + box.value
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4)],
                        expected: .returned(try integer(5))
                    ),
                ]
            ),
            Probe(
                name: "compactMappedUnitValues",
                source: """
                public func compactMappedUnitValues(_ values: [Int]) -> Int {
                    values.compactMap { $0 > 0 ? () : nil }.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([-1, 2, 0, 3])],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                ]
            ),
            Probe(
                name: "reducedUnitVisits",
                source: """
                public func reducedUnitVisits(_ values: [Int]) -> Int {
                    var visits = 0
                    let _: Void = values.reduce(()) { _, _ in
                        visits += 1
                    }
                    return visits
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                ]
            ),
            Probe(
                name: "mappedOptionalUnitInput",
                source: """
                public func mappedOptionalUnitInput(_ present: Bool) -> Int {
                    let value: Void? = present ? () : nil
                    return value.map { _ in 7 } ?? -1
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "mappedResultUnitInput",
                source: """
                enum UnitInputFailure: Error { case rejected }

                public func mappedResultUnitInput(_ succeeds: Bool) -> Int {
                    let value: Result<Void, UnitInputFailure> = succeeds
                        ? .success(())
                        : .failure(.rejected)
                    switch value.map({ _ in 9 }) {
                    case let .success(output): return output
                    case .failure: return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(9))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "storedUnitArray",
                source: """
                public func storedUnitArray(_ shouldAppend: Bool) -> Int {
                    var values: [Void] = [()]
                    if shouldAppend { values.append(()) }
                    return values.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            Probe(
                name: "mappedEmptyAggregate",
                source: """
                private struct EmptyMarker {}

                private struct NestedEmptyMarker {
                    var first: EmptyMarker
                    var second: (Void, EmptyMarker)
                }

                public func mappedEmptyAggregate(_ values: [Int]) -> Int {
                    values.map { _ in
                        NestedEmptyMarker(
                            first: EmptyMarker(),
                            second: ((), EmptyMarker())
                        )
                    }.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                ]
            ),
            Probe(
                name: "storedEmptyDictionaryValue",
                source: """
                private struct EmptyDictionaryValue {}

                public func storedEmptyDictionaryValue(_ key: Int) -> Int {
                    let values: [Int: EmptyDictionaryValue] = [
                        key: EmptyDictionaryValue()
                    ]
                    return values.count
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4)],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            Probe(
                name: "reconstructedTupleField",
                source: """
                private struct TupleFieldBox {
                    var payload: (Int, (Void, String))
                    var enabled: Bool
                }

                public func reconstructedTupleField(_ input: Int) -> Int {
                    let box = TupleFieldBox(
                        payload: (input, ((), "marker")),
                        enabled: true
                    )
                    return box.payload.0
                        + (box.payload.1.1 == "marker" ? 10 : 0)
                        + (box.enabled ? 1 : 0)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4)],
                        expected: .returned(try integer(15))
                    ),
                ]
            ),
            Probe(
                name: "reconstructedExistentialTupleField",
                source: """
                private struct ExistentialTupleFieldBox {
                    var payload: (Any, (Void, Int))
                }

                public func reconstructedExistentialTupleField(
                    _ input: Int
                ) -> Int {
                    let box = ExistentialTupleFieldBox(
                        payload: (input, ((), input + 1))
                    )
                    return box.payload.1.1
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4)],
                        expected: .returned(try integer(5))
                    ),
                ]
            ),
            Probe(
                name: "mappedResultValue",
                source: """
                enum LocalFailure: Error { case rejected }

                public func mappedResultValue(_ value: Int) -> Int {
                    let source: Result<Int, LocalFailure> = value >= 0
                        ? .success(value)
                        : .failure(.rejected)
                    switch source.map({ $0 + 1 }) {
                    case let .success(output): return output
                    case .failure: return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "mappedFloatingResult",
                source: """
                enum FloatingFailure: Error { case rejected }

                public func mappedFloatingResult(_ value: Double) -> Double {
                    let source: Result<Double, FloatingFailure> = .success(value)
                    switch source.map({ $0 * 2 }) {
                    case let .success(output): return output
                    case .failure: return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(1.5)],
                        expected: .returned(.float64(3))
                    ),
                ]
            ),
            Probe(
                name: "summedWithForEach",
                source: """
                public func summedWithForEach(_ values: [Int]) -> Int {
                    var total = 0
                    values.forEach { total += $0 }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(6))
                    ),
                ]
            ),
            Probe(
                name: "collectedWithForEach",
                source: """
                public func collectedWithForEach(_ values: [Int]) -> [Int] {
                    var output: [Int] = []
                    values.forEach { output.append($0 * 2) }
                    return output
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(try integers([2, -4, 6]))
                    ),
                ]
            ),
            Probe(
                name: "updatedArrayElementWithForEach",
                source: """
                public func updatedArrayElementWithForEach(_ values: [Int]) -> Int {
                    var output = [10]
                    values.forEach { output[0] += $0 }
                    return output[0]
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(16))
                    ),
                ]
            ),
            Probe(
                name: "joinedSignsWithForEach",
                source: """
                public func joinedSignsWithForEach(_ values: [Int]) -> String {
                    var output = ""
                    values.forEach { output += $0 > 0 ? "p" : "n" }
                    return output
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, -2, 3])],
                        expected: .returned(.string("pnp"))
                    ),
                ]
            ),
            Probe(
                name: "lastLargeValueWithForEach",
                source: """
                public func lastLargeValueWithForEach(_ values: [Int]) -> Int {
                    var found: Int?
                    values.forEach {
                        if $0 > 1 { found = $0 }
                    }
                    return found ?? -1
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 4, 2])],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [try integers([0, 1])],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "mutatedStructWithForEach",
                source: """
                struct Accumulator {
                    var total: Int
                    var bias: Int
                }

                public func mutatedStructWithForEach(_ values: [Int]) -> Int {
                    var accumulator = Accumulator(total: 0, bias: 10)
                    values.forEach { accumulator.total += $0 }
                    return accumulator.total + accumulator.bias
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(16))
                    ),
                ]
            ),
            Probe(
                name: "countedValuesWithForEach",
                source: """
                public func countedValuesWithForEach(_ values: [Int]) -> Int {
                    var counts: [Int: Int] = [:]
                    values.forEach { value in
                        counts[value] = (counts[value] ?? 0) + 1
                    }
                    return (counts[1] ?? 0) * 10 + (counts[2] ?? 0)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 1, 1])],
                        expected: .returned(try integer(31))
                    ),
                    .init(
                        arguments: [try integers([])],
                        expected: .returned(try integer(0))
                    ),
                ]
            ),
            Probe(
                name: "nestedMutableCapture",
                source: """
                public func nestedMutableCapture(_ values: [Int]) -> Int {
                    var total = 0
                    values.forEach { value in
                        [value, 1].forEach { total += $0 }
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([2, 3])],
                        expected: .returned(try integer(7))
                    ),
                ]
            ),
            Probe(
                name: "mutatedTupleWithForEach",
                source: """
                public func mutatedTupleWithForEach(_ values: [Int]) -> Int {
                    var state = (total: 0, visits: 10)
                    values.forEach {
                        state.total += $0
                        state.visits += 1
                    }
                    return state.total + state.visits
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(19))
                    ),
                ]
            ),
            Probe(
                name: "conditionallyCapturedWithForEach",
                source: """
                public func conditionallyCapturedWithForEach(
                    _ values: [Int],
                    _ shouldApply: Bool
                ) -> Int {
                    var total = 1
                    if shouldApply {
                        values.forEach { total += $0 }
                    } else {
                        total += 10
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([2, 3]), .bool(true)],
                        expected: .returned(try integer(6))
                    ),
                    .init(
                        arguments: [try integers([2, 3]), .bool(false)],
                        expected: .returned(try integer(11))
                    ),
                ]
            ),
            Probe(
                name: "branchInitializedCapture",
                source: """
                public func branchInitializedCapture(_ flag: Bool) -> Int {
                    var value: Int
                    if flag {
                        value = 1
                    } else {
                        value = 2
                    }
                    let increment = { value += 1 }
                    increment()
                    return value
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(2))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(3))
                    ),
                ]
            ),
            Probe(
                name: "conditionallyReinitializedCapture",
                source: """
                public func conditionallyReinitializedCapture(
                    _ flag: Bool
                ) -> String {
                    var value: String
                    if flag {
                        value = "first"
                    }
                    value = "final"
                    let decorate = { value + "!" }
                    return decorate()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(.string("final!"))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(.string("final!"))
                    ),
                ]
            ),
            Probe(
                name: "branchInitializedTupleCapture",
                source: """
                public func branchInitializedTupleCapture(_ flag: Bool) -> Int {
                    var state: (total: Int, visits: Int)
                    if flag {
                        state.total = 1
                    } else {
                        state.total = 2
                    }
                    state.visits = 10
                    let update = { state.visits += 1 }
                    update()
                    return state.total + state.visits
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(12))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(13))
                    ),
                ]
            ),
            Probe(
                name: "capturedStructWholeValue",
                source: """
                private struct CapturePair {
                    var first: Int
                    var second: Int
                }

                public func capturedStructWholeValue(_ input: Int) -> Int {
                    var pair = CapturePair(first: input, second: 10)
                    let update = { pair.first += pair.second }
                    update()
                    return pair.first
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(13))
                    ),
                ]
            ),
            Probe(
                name: "branchInitializedStructCapture",
                source: """
                private struct BranchCapturePair {
                    var first: Int
                    var second: Int
                }

                private func sumBranchCapturePair(
                    _ pair: BranchCapturePair
                ) -> Int {
                    pair.first + pair.second
                }

                public func branchInitializedStructCapture(_ flag: Bool) -> Int {
                    var pair: BranchCapturePair
                    if flag {
                        pair = BranchCapturePair(first: 1, second: 10)
                    } else {
                        pair = BranchCapturePair(first: 2, second: 10)
                    }
                    let update = { pair.second += 1 }
                    update()
                    return sumBranchCapturePair(pair)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(12))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(13))
                    ),
                ]
            ),
            Probe(
                name: "sharedMutableCapture",
                source: """
                public func sharedMutableCapture(_ input: Int) -> Int {
                    var value = input
                    let increment = { value += 1 }
                    let double = { value *= 2 }
                    increment()
                    double()
                    increment()
                    return value
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(9))
                    ),
                ]
            ),
            Probe(
                name: "caughtMutationWithForEach",
                source: """
                enum MutationError: Error { case stopped }

                public func caughtMutationWithForEach(_ values: [Int]) -> Int {
                    var total = 0
                    do {
                        try values.forEach { value in
                            if value < 0 { throw MutationError.stopped }
                            total += value
                        }
                    } catch {
                        total += 100
                    }
                    return total
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(try integer(6))
                    ),
                    .init(
                        arguments: [try integers([1, 2, -1, 9])],
                        expected: .returned(try integer(103))
                    ),
                ]
            ),
            Probe(
                name: "usedReturnedCounter",
                source: """
                private func makeCounter(_ start: Int) -> () -> Int {
                    var value = start
                    return {
                        value += 1
                        return value
                    }
                }

                public func usedReturnedCounter(_ start: Int) -> Int {
                    let counter = makeCounter(start)
                    return counter() * 10 + counter()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(45))
                    ),
                ]
            ),
            Probe(
                name: "usedConditionalCounter",
                source: """
                private func makeConditionalCounter(
                    _ shouldIncrement: Bool,
                    _ start: Int
                ) -> () -> Int {
                    var value = start
                    if shouldIncrement {
                        return { value += 1; return value }
                    }
                    return { value += 2; return value }
                }

                public func usedConditionalCounter(
                    _ shouldIncrement: Bool,
                    _ start: Int
                ) -> Int {
                    let counter = makeConditionalCounter(
                        shouldIncrement,
                        start
                    )
                    return counter() * 10 + counter()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true), try integer(3)],
                        expected: .returned(try integer(45))
                    ),
                    .init(
                        arguments: [.bool(false), try integer(3)],
                        expected: .returned(try integer(57))
                    ),
                ]
            ),
            Probe(
                name: "usedReturnedCollector",
                source: """
                private func makeCollector(_ seed: [Int]) -> (Int) -> [Int] {
                    var values = seed
                    return { value in
                        values.append(value)
                        return values
                    }
                }

                public func usedReturnedCollector(_ value: Int) -> Int {
                    let collect = makeCollector([1])
                    _ = collect(value)
                    let result = collect(value + 1)
                    return result.reduce(0, +)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(8))
                    ),
                ]
            ),
            Probe(
                name: "usedAnyClosure",
                source: """
                public func usedAnyClosure(_ input: Int) -> Int {
                    let echo: (Any) -> Any = { value in value }
                    return echo(input) as! Int
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(try integer(7))
                    ),
                ]
            ),
            Probe(
                name: "usedThrowingAnyClosure",
                source: """
                private enum AnyClosureFailure: Error { case rejected }

                public func usedThrowingAnyClosure(_ input: Int) -> Int {
                    let validate: (Any) throws -> Any = { value in
                        if input < 0 { throw AnyClosureFailure.rejected }
                        return value
                    }
                    do {
                        return try validate(input) as! Int
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "usedReturnedThrowingAnyClosure",
                source: """
                private enum ReturnedAnyClosureFailure: Error {
                    case rejected
                }

                private func makeThrowingAnyClosure(
                    _ shouldFail: Bool
                ) -> (Any) throws -> Any {
                    { value in
                        if shouldFail {
                            throw ReturnedAnyClosureFailure.rejected
                        }
                        return value
                    }
                }

                public func usedReturnedThrowingAnyClosure(
                    _ input: Int
                ) -> Int {
                    let validate = makeThrowingAnyClosure(input < 0)
                    do {
                        return try validate(input) as! Int
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "usedLocalFunctionBox",
                source: """
                public func usedLocalFunctionBox(_ input: Int) -> Int {
                    var value = input
                    func bump() { value += 1 }
                    bump()
                    bump()
                    return value
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(5))
                    ),
                ]
            ),
            Probe(
                name: "usedMultipleReturnedCaptures",
                source: """
                private func makeAccumulator(_ input: Int) -> () -> Int {
                    var total = input
                    var values = [input]
                    return {
                        total += 1
                        values.append(total)
                        return values.reduce(0, +)
                    }
                }

                public func usedMultipleReturnedCaptures(_ input: Int) -> Int {
                    let accumulate = makeAccumulator(input)
                    return accumulate() * 10 + accumulate()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(try integer(59))
                    ),
                ]
            ),
        ])
    }

    @Test("Higher-order callbacks preserve borrowed linear SDK ownership")
    func lowersBorrowedNativeValues() throws {
        let source = """
        import Foundation

        public func mappedObjects(_ values: [NSObject]) -> [NSObject] {
            values.map { $0 }
        }

        public func flatMappedObjects(_ values: [NSObject]) -> [NSObject] {
            values.flatMap { [$0] }
        }

        public func filteredObjects(_ values: [NSObject]) -> [NSObject] {
            values.filter { _ in true }
        }

        public func compactedObjects(_ values: [NSObject?]) -> [NSObject] {
            values.compactMap { $0 }
        }

        public func prefixedObjects(_ values: [NSObject]) -> [NSObject] {
            Array(values.prefix { _ in true })
        }

        public func droppedObjects(_ values: [NSObject]) -> [NSObject] {
            Array(values.drop { _ in false })
        }

        public func reducedObject(
            _ values: [NSObject],
            _ initial: NSObject
        ) -> NSObject {
            values.reduce(initial) { accumulator, _ in accumulator }
        }

        public func reducedObjects(_ values: [NSObject]) -> [NSObject] {
            values.reduce(into: []) { result, value in
                result.append(value)
            }
        }

        public func emptyObjectDictionary() -> [String: NSObject] {
            [String: NSObject]()
        }

        public func mappedDictionaryObjects(
            _ values: [String: NSObject]
        ) -> [NSObject] {
            values.map { $0.value }
        }

        public func filteredObjectDictionary(
            _ values: [String: NSObject]
        ) -> [String: NSObject] {
            values.filter { _ in true }
        }

        public func mappedObjectDictionary(
            _ values: [String: NSObject]
        ) -> [String: NSObject] {
            values.mapValues { $0 }
        }

        public func compactedObjectDictionary(
            _ values: [String: NSObject]
        ) -> [String: NSObject] {
            values.compactMapValues { $0 }
        }

        public func firstObject(_ values: [NSObject]) -> NSObject? {
            values.first { _ in true }
        }

        public func firstObjectIndex(_ values: [NSObject]) -> Int? {
            values.firstIndex { _ in true }
        }

        public func lastObject(_ values: [NSObject]) -> NSObject? {
            values.last { _ in true }
        }

        public func lastObjectIndex(_ values: [NSObject]) -> Int? {
            values.lastIndex { _ in true }
        }

        public func minimumObject(_ values: [NSObject]) -> NSObject? {
            values.min { _, _ in false }
        }

        public func maximumObject(_ values: [NSObject]) -> NSObject? {
            values.max { _, _ in false }
        }

        public func containsObject(_ values: [NSObject]) -> Bool {
            values.contains { _ in true }
        }

        public func visitsObjects(_ values: [NSObject]) {
            values.forEach { _ in }
        }

        public func sortedObjects(_ values: [NSObject]) -> [NSObject] {
            values.sorted { _, _ in false }
        }

        public func sortedObjectsInPlace(_ values: [NSObject]) -> [NSObject] {
            var result = values
            result.sort { _, _ in false }
            return result
        }

        public func partitionedObjects(_ values: [NSObject]) -> [NSObject] {
            var result = values
            _ = result.partition { _ in false }
            return result
        }

        public func reversedObjects(_ values: [NSObject]) -> [NSObject] {
            var result = values
            result.reverse()
            return result
        }

        public func removedObjects(_ values: [NSObject]) -> [NSObject] {
            var result = values
            result.removeAll { _ in false }
            return result
        }

        public func optionalMappedObject(_ value: NSObject?) -> NSObject? {
            value.map { $0 }
        }

        public func optionalFlatMappedObject(_ value: NSObject?) -> NSObject? {
            value.flatMap { $0 }
        }

        enum LinearTransformFailure: Error { case rejected }

        public func optionalThrowingFlatMappedObject(
            _ value: NSObject?,
            _ shouldThrow: Bool
        ) throws -> NSObject? {
            try value.flatMap { object in
                if shouldThrow { throw LinearTransformFailure.rejected }
                return object
            }
        }

        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-linear-higher-order-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(source.utf8).write(to: sourceURL)
        let moduleName = "HelixLinearHigherOrderFixture"
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: moduleName,
            optimization: "-Onone",
            additionalArguments: [
                "-Xfrontend", "-disable-sil-perf-optzns",
            ],
            purpose: .semanticLowering
        )
        let file = try CanonicalSIL.File(text: sil)
        let nativeType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let environment = try file.typeEnvironment.includingNativeTypes(
            ["Foundation.NSObject": nativeType],
            kinds: [nativeType: .reference]
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "linear-higher-order-fixture"
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.linear-higher-order",
            buildNumber: "1",
            seed: "fixture"
        )
        let names = [
            "mappedObjects", "flatMappedObjects", "filteredObjects",
            "compactedObjects", "prefixedObjects", "droppedObjects",
            "reducedObject", "reducedObjects", "emptyObjectDictionary",
            "mappedDictionaryObjects", "filteredObjectDictionary",
            "mappedObjectDictionary", "compactedObjectDictionary",
            "firstObject", "firstObjectIndex",
            "lastObject", "lastObjectIndex", "minimumObject",
            "maximumObject", "containsObject", "visitsObjects",
            "sortedObjects", "sortedObjectsInPlace", "partitionedObjects",
            "reversedObjects", "removedObjects",
            "optionalMappedObject",
            "optionalFlatMappedObject",
            "optionalThrowingFlatMappedObject",
        ]

        for (index, name) in names.enumerated() {
            let candidates = file.functions.filter {
                $0.mangledName.contains(name)
            }.sorted {
                ($0.mangledName.utf8.count, $0.mangledName)
                    < ($1.mangledName.utf8.count, $1.mangledName)
            }
            let function = try #require(candidates.first)
            let signature = try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).parseFunctionType(function.loweredType)
            let key = try Core.FunctionKey.derive(
                namespace: namespace,
                module: moduleName,
                sourceFileLogicalID: "Patch.swift",
                canonicalDeclaration: "func \(name)",
                loweredSignature: .init(
                    parameters: [],
                    result: "Swift.Void"
                ),
                role: .function
            )
            let shellHash = Core.Digest.sha256(
                "linear-higher-order-\(name)"
            )
            let entry = Core.EntryIndex(rawValue: UInt32(index))
            let compiled = try PatchCompiler.Driver().compile(
                .init(
                    canonicalSIL: sil,
                    mangledName: function.mangledName,
                    displayName: name,
                    functionKey: key,
                    entryIndex: entry,
                    shellInterfaceHash: shellHash,
                    compatibility: compatibility,
                    nativeTypes: ["Foundation.NSObject": nativeType],
                    nativeTypeKinds: [nativeType: .reference]
                )
            )
            let shell = try Verification.ShellInterface(
                interfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: compiled.module.capabilities,
                entries: [
                    .init(
                        index: entry,
                        key: key,
                        parameterTypes: signature.parameters,
                        resultType: signature.result,
                        effects: signature.effects
                    ),
                ],
                types: [
                    .init(
                        id: nativeType,
                        canonicalName: "Foundation.NSObject",
                        kind: .reference,
                        layoutFingerprint: .sha256(
                            "Foundation.NSObject.layout"
                        ),
                        isCopyable: true,
                        estimatedSize: 8
                    ),
                ]
            )
            do {
                _ = try Verification.Engine().verify(
                    bytes: compiled.bytecode,
                    shell: shell,
                    policy: .init(
                        acceptedCapabilities: compiled.module.capabilities
                    )
                )
            } catch {
                Issue.record("\(name): \(error)")
                continue
            }
            if name == "emptyObjectDictionary" {
                #expect(
                    signature.result == .dictionary(
                        key: .string,
                        value: .native(nativeType)
                    )
                )
                continue
            }
            if name == "reversedObjects" {
                #expect(signature.result == .array(.native(nativeType)))
                continue
            }
            let closureBodies = compiled.module.functions.filter {
                $0.kind == .closureBody
            }
            #expect(!closureBodies.isEmpty)
            #expect(closureBodies.contains { body in
                zip(
                    body.parameterRegisters,
                    body.parameterConventions
                ).contains { register, convention in
                    body.type(of: register)?.requiresLinearOwnership == true
                        && convention == .borrowed
                }
            })
            if name == "reducedObjects" {
                #expect(closureBodies.contains { body in
                    body.parameterRegisters.map { body.type(of: $0) } == [
                        .address(.array(.native(nativeType))),
                        .native(nativeType),
                    ] && body.parameterConventions == [.inout, .borrowed]
                })
            }
        }
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixHigherOrder_\(probe.name)"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
                                + "\(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "higher-order semantic gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func optionalIntegers(
        _ values: [Int64?]
    ) throws -> VM.Value {
        .array(
            try values.map { value in
                .optional(try value.map(integer))
            },
            elementType: .optional(.int64)
        )
    }

    private func strings(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func dictionary(
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

    private func stringDictionary(
        _ pairs: [(String, String)]
    ) -> VM.Value {
        .dictionary(
            pairs.map {
                .init(key: .string($0.0), value: .string($0.1))
            },
            keyType: .string,
            valueType: .string
        )
    }

    private func set(_ values: [Int64]) throws -> VM.Value {
        .set(
            .init(elements: try values.map(integer), elementType: .int64)
        )
    }

    private func stringSet(_ values: [String]) -> VM.Value {
        .set(
            .init(elements: values.map(VM.Value.string), elementType: .string)
        )
    }
}
}
