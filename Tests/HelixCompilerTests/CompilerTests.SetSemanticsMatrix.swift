import HelixBytecode
import HelixVM
import Testing

extension CompilerTests {
@Suite("Set semantics matrix")
struct SetSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Set literals, queries, mutation, iteration, and construction lower from real SIL")
    func lowersCoreSetMatrix() throws {
        let probes = [
            Probe(
                name: "setLiteralQuery",
                source: """
                public func setLiteralQuery(_ needle: Int) -> (Int, Bool, Bool) {
                    let values: Set<Int> = [1, 2, 2, 3]
                    return (values.count, values.isEmpty, values.contains(needle))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(.tuple([try integer(3), .bool(false), .bool(true)]))
                    ),
                    .init(
                        arguments: [try integer(9)],
                        expected: .returned(.tuple([try integer(3), .bool(false), .bool(false)]))
                    ),
                ]
            ),
            Probe(
                name: "setMutation",
                source: """
                public func setMutation(
                    _ input: Set<Int>,
                    _ value: Int
                ) -> (Bool, Int, Int?, Int?, Set<Int>) {
                    var values = input
                    let inserted = values.insert(value)
                    let previous = values.update(with: value)
                    let removed = values.remove(value)
                    return (
                        inserted.inserted,
                        inserted.memberAfterInsert,
                        previous,
                        removed,
                        values
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2]), try integer(3)],
                        expected: .returned(
                            .tuple([
                                .bool(true),
                                try integer(3),
                                .optional(try integer(3)),
                                .optional(try integer(3)),
                                try set([1, 2]),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try set([1, 2]), try integer(2)],
                        expected: .returned(
                            .tuple([
                                .bool(false),
                                try integer(2),
                                .optional(try integer(2)),
                                .optional(try integer(2)),
                                try set([1]),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setIteration",
                source: """
                public func setIteration(_ values: Set<Int>) -> Int {
                    var total = 0
                    for value in values { total += value }
                    return total
                }
                """,
                scenarios: [
                    .init(arguments: [try set([4, 1, 7])], expected: .returned(try integer(12))),
                    .init(arguments: [try set([])], expected: .returned(try integer(0))),
                ]
            ),
            Probe(
                name: "setFromArray",
                source: """
                public func setFromArray(_ values: [Int]) -> (Int, Bool) {
                    let set = Set(values)
                    return (set.count, set.contains(3))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.array([try integer(3), try integer(3), try integer(4)], elementType: .int64)],
                        expected: .returned(.tuple([try integer(2), .bool(true)]))
                    ),
                ]
            ),
            Probe(
                name: "emptySetBoundary",
                source: """
                public func emptySetBoundary() -> (Set<Int>, Int?, Int?) {
                    var values = Set<Int>()
                    let first = values.first
                    let popped = values.popFirst()
                    return (values, first, popped)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [],
                        expected: .returned(
                            .tuple([
                                try set([]),
                                .optional(nil),
                                .optional(nil),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setFirstRemoval",
                source: """
                public func setFirstRemoval(
                    _ input: Set<Int>
                ) -> (Int?, Int?, Int, Set<Int>) {
                    var values = input
                    let first = values.first
                    let popped = values.popFirst()
                    values.reserveCapacity(32)
                    let removed = values.removeFirst()
                    return (first, popped, removed, values)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([4, 1, 7])],
                        expected: .returned(
                            .tuple([
                                .optional(try integer(4)),
                                .optional(try integer(4)),
                                try integer(1),
                                try set([7]),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setMutableCapture",
                source: """
                public func setMutableCapture(
                    _ input: Set<Int>
                ) -> (Int, Bool) {
                    var values = input
                    let mutate = { values.insert(3).inserted }
                    let inserted = mutate()
                    return (values.count, inserted)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2])],
                        expected: .returned(
                            .tuple([try integer(3), .bool(true)])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setReserveCapacity",
                source: """
                public func setReserveCapacity(_ capacity: Int) -> Bool {
                    var values = Set<Int>()
                    values.reserveCapacity(capacity)
                    return values.isEmpty
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(32)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try integer(-1)],
                        expected: .trapped(
                            .explicit("Set capacity must not be negative")
                        )
                    ),
                ]
            ),
        ]

        try execute(probes)
    }

    @Test("Set algebra, relations, in-place forms, equality, and removeAll share generic operations")
    func lowersSetAlgebraMatrix() throws {
        let probes = [
            Probe(
                name: "setAlgebra",
                source: """
                public func setAlgebra(
                    _ lhs: Set<Int>,
                    _ rhs: Set<Int>
                ) -> (Set<Int>, Set<Int>, Set<Int>, Set<Int>) {
                    (
                        lhs.union(rhs),
                        lhs.intersection(rhs),
                        lhs.subtracting(rhs),
                        lhs.symmetricDifference(rhs)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2, 3]), try set([3, 4])],
                        expected: .returned(
                            .tuple([
                                try set([1, 2, 3, 4]),
                                try set([3]),
                                try set([1, 2]),
                                try set([1, 2, 4]),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setRelations",
                source: """
                public func setRelations(
                    _ lhs: Set<Int>,
                    _ rhs: Set<Int>
                ) -> (Bool, Bool, Bool, Bool, Bool, Bool) {
                    (
                        lhs == rhs,
                        lhs.isSubset(of: rhs),
                        lhs.isStrictSubset(of: rhs),
                        lhs.isSuperset(of: rhs),
                        lhs.isStrictSuperset(of: rhs),
                        lhs.isDisjoint(with: rhs)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2]), try set([1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                .bool(false), .bool(true), .bool(true),
                                .bool(false), .bool(false), .bool(false),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try set([1, 2]), try set([3, 4])],
                        expected: .returned(
                            .tuple([
                                .bool(false), .bool(false), .bool(false),
                                .bool(false), .bool(false), .bool(true),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "setFormAlgebra",
                source: """
                public func setFormAlgebra(
                    _ lhs: Set<Int>,
                    _ rhs: Set<Int>
                ) -> Set<Int> {
                    var result = lhs
                    result.formUnion(rhs)
                    result.formIntersection([2, 3, 4])
                    result.subtract([4])
                    result.formSymmetricDifference([3, 5])
                    return result
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try set([1, 2]), try set([3, 4])],
                        expected: .returned(try set([2, 5]))
                    ),
                ]
            ),
            Probe(
                name: "setRemoveAll",
                source: """
                public func setRemoveAll(_ input: Set<Int>, _ keep: Bool) -> Bool {
                    var values = input
                    values.removeAll(keepingCapacity: keep)
                    return values.isEmpty
                }
                """,
                scenarios: [
                    .init(arguments: [try set([1, 2]), .bool(false)], expected: .returned(.bool(true))),
                    .init(arguments: [try set([1, 2]), .bool(true)], expected: .returned(.bool(true))),
                ]
            ),
        ]

        try execute(probes)
    }

    @Test("VM-defined Hashable semantics cover floating, Optional, and nested collection values")
    func lowersRecursiveHashableCollections() throws {
        let probes = [
            Probe(
                name: "floatingSet",
                source: """
                public func floatingSet(_ value: Double) -> (Int, Bool) {
                    let values: Set<Double> = [0.0, -0.0, 1.5]
                    return (values.count, values.contains(value))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(-0.0)],
                        expected: .returned(.tuple([try integer(2), .bool(true)]))
                    ),
                ]
            ),
            Probe(
                name: "optionalSet",
                source: """
                public func optionalSet(_ value: Int?) -> Bool {
                    let values: Set<Int?> = [nil, 1, 2]
                    return values.contains(value)
                }
                """,
                scenarios: [
                    .init(arguments: [.optional(nil)], expected: .returned(.bool(true))),
                    .init(arguments: [.optional(try integer(9))], expected: .returned(.bool(false))),
                ]
            ),
            Probe(
                name: "arrayDictionaryKey",
                source: """
                public func arrayDictionaryKey(_ key: [Int]) -> Int? {
                    let values: [[Int]: Int] = [[1, 2]: 7]
                    return values[key]
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.array([try integer(1), try integer(2)], elementType: .int64)],
                        expected: .returned(.optional(try integer(7)))
                    ),
                    .init(
                        arguments: [.array([try integer(2), try integer(1)], elementType: .int64)],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
            Probe(
                name: "dictionarySetElement",
                source: """
                public func dictionarySetElement(_ value: [String: Int]) -> Bool {
                    let values: Set<[String: Int]> = [["one": 1, "two": 2]]
                    return values.contains(value)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .dictionary(
                                [
                                    .init(key: .string("two"), value: try integer(2)),
                                    .init(key: .string("one"), value: try integer(1)),
                                ],
                                keyType: .string,
                                valueType: .int64
                            ),
                        ],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [
                            .dictionary(
                                [.init(key: .string("one"), value: try integer(9))],
                                keyType: .string,
                                valueType: .int64
                            ),
                        ],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "nanSetSemantics",
                source: """
                public func nanSetSemantics(
                    _ input: Set<Double>,
                    _ independent: Set<Double>,
                    _ value: Double
                ) -> (Bool, Bool, Int) {
                    let copy = input
                    let duplicates: Set<Double> = [value, value]
                    return (input == copy, input == independent, duplicates.count)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .set(
                                VM.SetValue(
                                    elements: [.float64(.nan)],
                                    elementType: .float(bitWidth: 64)
                                )
                            ),
                            .set(
                                VM.SetValue(
                                    elements: [.float64(.nan)],
                                    elementType: .float(bitWidth: 64)
                                )
                            ),
                            .float64(.nan),
                        ],
                        expected: .returned(
                            .tuple([.bool(true), .bool(false), try integer(2)])
                        )
                    ),
                ]
            ),
        ]

        try execute(probes)
    }

    private func execute(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected \(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record("Set semantic gaps:\n\(failures.joined(separator: "\n"))")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func set(_ values: [Int64]) throws -> VM.Value {
        .set(
            VM.SetValue(
                elements: try values.map {
                    .integer(
                        try VM.Integer(
                            signed: $0,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                },
                elementType: .int64
            )
        )
    }
}
}
