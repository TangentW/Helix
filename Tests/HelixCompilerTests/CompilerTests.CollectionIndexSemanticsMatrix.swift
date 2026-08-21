import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift Collection index identity semantics")
struct CollectionIndexSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
        var optimization = "-Onone"
        var requiredDisassembly: [String] = []
        var forbiddenDisassembly: [String] = ["native_apply"]
    }

    @Test("Mutating index entry points retain their concrete source shape")
    func classifiesFormIndexEntryPoints() {
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$sSa9formIndex5afterySiz_tF"
            ) == .collectionIndex(
                .init(operation: .formAfter, source: .arrayElement)
            )
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$ss8RepeatedV10startIndexSivg"
            ) == .collectionIndex(
                .init(operation: .start, source: .arrayElement)
            )
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE5index_8offsetByA2B_SitF"
            ) == .collectionIndex(
                .init(operation: .offsetBy, source: .genericCollection)
            )
        )
        #expect(
            CanonicalSIL.CollectionIndex.Intrinsic(
                operation: .after,
                source: .genericCollection
            ).returnsIndexIndirectly
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$ss5SliceVsSKRzrlE9formIndex6beforey0C0Qzz_tF"
            ) == .collectionIndex(
                .init(operation: .formBefore, source: .sliceBase)
            )
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$sSlsE9formIndex_8offsetBy07limitedD0Sb0B0Qzz_SiAEtF"
            ) == .collectionIndex(
                .init(
                    operation: .formOffsetByLimited,
                    source: .genericCollection
                )
            )
        )
    }

    @Test("ArraySlice boundaries, movement, search, and indices retain their base")
    func lowersIntegerIndexSurface() throws {
        let source = """
        public func sliceIndexSurface(
            _ values: [Int],
            _ offset: Int
        ) -> (Int, Int, Int, Int, Int, Int, Int, Int?, [Int]) {
            let slice = values.dropFirst()
            let start = slice.startIndex
            let end = slice.endIndex
            return (
                start,
                end,
                slice[start],
                slice.index(after: start),
                slice.index(before: end),
                slice.distance(from: start, to: end),
                slice.index(start, offsetBy: offset),
                slice.index(start, offsetBy: offset, limitedBy: end),
                Array(slice.indices)
            )
        }
        """
        let scenario = Scenario(
            arguments: [try integers([10, 20, 30, 40]), try integer(2)],
            expected: .returned(
                .tuple([
                    try integer(1),
                    try integer(4),
                    try integer(20),
                    try integer(2),
                    try integer(3),
                    try integer(3),
                    try integer(3),
                    .optional(try integer(3)),
                    try integers([1, 2, 3]),
                ])
            )
        )
        try run([
            .init(
                name: "sliceIndexSurface",
                source: source,
                scenarios: [scenario],
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "sliceIndexSurface",
                source: source,
                scenarios: [scenario],
                optimization: "-O",
                requiredDisassembly: ["array_index_base"]
            ),
        ])
    }

    @Test("Nested views and both search families expose logical indices")
    func lowersComposedViewsAndSearches() throws {
        try run([
            .init(
                name: "composedSliceIdentity",
                source: """
                public func composedSliceIdentity(
                    _ values: [Int],
                    _ needle: Int
                ) -> (Int, Int, Int, Int?, Int?, [Int], [Int]) {
                    let outer = values.dropFirst()
                    let lower = outer.index(after: outer.startIndex)
                    let middle = outer[lower..<outer.endIndex]
                    let nested = middle.dropFirst()
                    return (
                        middle.startIndex,
                        nested.startIndex,
                        nested.endIndex,
                        nested.firstIndex(of: needle),
                        nested.lastIndex { $0 == needle },
                        Array(middle),
                        Array(nested)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 1, 3]),
                            try integer(1),
                        ],
                        expected: .returned(
                            .tuple([
                                try integer(2),
                                try integer(3),
                                try integer(5),
                                .optional(try integer(3)),
                                .optional(try integer(3)),
                                try integers([2, 1, 3]),
                                try integers([1, 3]),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "explicitSliceIdentity",
                source: """
                public func explicitSliceIdentity(
                    _ values: [Int]
                ) -> (Int, Int, Int, [Int]) {
                    let bounds = values.index(after: values.startIndex)..<values.endIndex
                    let slice = Slice(base: values, bounds: bounds)
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        slice[slice.startIndex],
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(4),
                                try integer(1), try integers([1, 2, 3]),
                            ])
                        )
                    ),
                ],
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "nestedExplicitSliceIdentity",
                source: """
                public func nestedExplicitSliceIdentity(
                    _ values: [Int]
                ) -> (Int, Int, [Int]) {
                    let base = values.dropFirst()
                    let lower = base.index(after: base.startIndex)
                    let slice = Slice(
                        base: base,
                        bounds: lower..<base.endIndex
                    )
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                try integer(2), try integer(4),
                                try integers([2, 3]),
                            ])
                        )
                    ),
                ],
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "repeatedSliceIdentity",
                source: """
                public func repeatedSliceIdentity(
                    _ value: Int
                ) -> (Int, Int, Int, [Int]) {
                    let base = repeatElement(value, count: 4)
                    let slice = Slice(base: base, bounds: 1..<3)
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        slice[slice.startIndex],
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(3),
                                try integer(7), try integers([7, 7]),
                            ])
                        )
                    ),
                ],
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "explicitSliceMovement",
                source: """
                public func explicitSliceMovement(
                    _ values: [Int]
                ) -> (Int, Int, Int, Int, Int?, [Int]) {
                    let slice = Slice(
                        base: values,
                        bounds: 1..<values.endIndex
                    )
                    let start = slice.startIndex
                    let end = slice.endIndex
                    return (
                        slice.index(after: start),
                        slice.index(before: end),
                        slice.distance(from: start, to: end),
                        slice.index(start, offsetBy: 1),
                        slice.index(start, offsetBy: 1, limitedBy: end),
                        Array(slice.indices)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                try integer(2), try integer(3),
                                try integer(3), try integer(2),
                                .optional(try integer(2)),
                                try integers([1, 2, 3]),
                            ])
                        )
                    ),
                ],
                requiredDisassembly: ["array_index_base"]
            ),
        ])
    }

    @Test("Predicate subsequences preserve the source view's logical bounds")
    func lowersPredicateSubsequences() throws {
        try run([
            .init(
                name: "predicateViews",
                source: """
                public func predicateViews(
                    _ values: [Int],
                    _ limit: Int
                ) -> (Int, Int, Int, Int, [Int], [Int]) {
                    let source = values.dropFirst()
                    let prefix = source.prefix { $0 < limit }
                    let dropped = source.drop { $0 < limit }
                    return (
                        prefix.startIndex,
                        prefix.endIndex,
                        dropped.startIndex,
                        dropped.endIndex,
                        Array(prefix),
                        Array(dropped)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 4, 5]),
                            try integer(4),
                        ],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(3),
                                try integer(3), try integer(5),
                                try integers([1, 2]),
                                try integers([4, 5]),
                            ])
                        )
                    ),
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 4, 5]),
                            try integer(10),
                        ],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(5),
                                try integer(5), try integer(5),
                                try integers([1, 2, 4, 5]),
                                try integers([]),
                            ])
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Index bases survive calls, tuples, and Optional storage")
    func preservesIdentityAcrossValueBoundaries() throws {
        try run([
            .init(
                name: "storedSliceIdentity",
                source: """
                private func identity(
                    _ value: ArraySlice<Int>
                ) -> ArraySlice<Int> { value }

                private func pack(
                    _ value: ArraySlice<Int>
                ) -> (ArraySlice<Int>?, ArraySlice<Int>) {
                    (value, identity(value))
                }

                public func storedSliceIdentity(
                    _ values: [Int]
                ) -> (Int, Int, Int, Int) {
                    let pair = pack(values.dropFirst(2))
                    let optional = pair.0!
                    let array = Array(pair.1)
                    return (
                        optional.startIndex,
                        pair.1.endIndex,
                        pair.1[pair.1.startIndex],
                        array.startIndex
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([7, 8, 9, 10])],
                        expected: .returned(
                            .tuple([
                                try integer(2), try integer(4),
                                try integer(9), try integer(0),
                            ])
                        )
                    ),
                ],
                requiredDisassembly: ["array_rebase"]
            ),
        ])
    }

    @Test("Range views keep bounds while Array materialization resets to zero")
    func lowersRangeViewComposition() throws {
        try run([
            .init(
                name: "rangeViews",
                source: """
                public func rangeViews(
                    _ values: [Int]
                ) -> (Int, Int, Int, Int, [Int], [Int], [Int], [Int]) {
                    let source = values.dropFirst()
                    let lower = source.index(after: source.startIndex)
                    let upper = source.index(before: source.endIndex)
                    let closed = source[lower...upper]
                    let tail = source[lower...]
                    let head = source[..<lower]
                    let full = source[...]
                    return (
                        closed.startIndex,
                        tail.startIndex,
                        head.startIndex,
                        full.startIndex,
                        Array(closed),
                        Array(tail),
                        Array(head),
                        Array(full)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                try integer(2), try integer(2),
                                try integer(1), try integer(1),
                                try integers([2, 3]),
                                try integers([2, 3]),
                                try integers([1]),
                                try integers([1, 2, 3]),
                            ])
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Array-backed view mutations retain or intentionally reset their base")
    func lowersMutatingViewSemantics() throws {
        let explicitSliceMutationSource = """
        public func mutateExplicitSlice(
            _ values: [Int]
        ) -> (Int, Int, [Int]) {
            var slice = Slice(
                base: values,
                bounds: 1..<values.endIndex
            )
            slice[slice.startIndex] += 10
            slice.reverse()
            slice.sort()
            return (
                slice.startIndex,
                slice.endIndex,
                Array(slice)
            )
        }
        """
        let explicitSliceMutationScenario = Scenario(
            arguments: [try integers([0, 3, 1, 2])],
            expected: .returned(
                .tuple([
                    try integer(1), try integer(4),
                    try integers([1, 2, 13]),
                ])
            )
        )

        try run([
            .init(
                name: "mutateSlice",
                source: """
                public func mutateSlice(
                    _ values: [Int]
                ) -> (Int, Int, Int, [Int]) {
                    var slice = values.dropFirst()
                    slice.reverse()
                    slice.sort()
                    let boundary = slice.partition {
                        $0.isMultiple(of: 2)
                    }
                    slice.removeAll { $0 < 0 }
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        boundary,
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 4, 1, 3, 2])],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(5),
                                try integer(3),
                                try integers([1, 3, 2, 4]),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "clearAndRemoveSlice",
                source: """
                public func clearAndRemoveSlice(
                    _ values: [Int]
                ) -> (Int, Int, Int, Int, Int, Int, Int) {
                    var kept = values.dropFirst(2)
                    kept.removeAll(keepingCapacity: true)
                    var reset = values.dropFirst(2)
                    reset.removeAll()
                    var removed = values.dropFirst(2)
                    let first = removed.removeFirst()
                    removed.removeFirst(1)
                    return (
                        kept.startIndex, kept.endIndex,
                        reset.startIndex, reset.endIndex,
                        removed.startIndex, removed.endIndex,
                        first
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3, 4])],
                        expected: .returned(
                            .tuple([
                                try integer(2), try integer(2),
                                try integer(0), try integer(0),
                                try integer(4), try integer(5),
                                try integer(2),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "modifyAndFilterSlice",
                source: """
                public func modifyAndFilterSlice(
                    _ values: [Int]
                ) -> (Int, Int, [Int]) {
                    var slice = values.dropFirst()
                    slice[slice.startIndex] += 10
                    slice.sort { $0 > $1 }
                    slice.removeAll { $0.isMultiple(of: 2) }
                    return (slice.startIndex, slice.endIndex, Array(slice))
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3, 4])],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(3),
                                try integers([11, 3]),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "mutateExplicitSlice",
                source: explicitSliceMutationSource,
                scenarios: [explicitSliceMutationScenario],
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "mutateExplicitSlice",
                source: explicitSliceMutationSource,
                scenarios: [explicitSliceMutationScenario],
                optimization: "-O",
                requiredDisassembly: ["array_index_base"]
            ),
            .init(
                name: "structuralSliceMutations",
                source: """
                public func structuralSliceMutations(
                    _ values: [Int]
                ) -> (Int, Int, Int, Int, [Int]) {
                    var slice = values.dropFirst()
                    slice.append(5)
                    slice.append(contentsOf: [6, 7])
                    slice.insert(
                        contentsOf: [8, 9],
                        at: slice.index(after: slice.startIndex)
                    )
                    let lower = slice.index(
                        slice.startIndex,
                        offsetBy: 2
                    )
                    let upper = slice.index(lower, offsetBy: 2)
                    slice.replaceSubrange(lower..<upper, with: [10])
                    slice.removeSubrange(
                        slice.startIndex..<slice.index(after: slice.startIndex)
                    )
                    let last = slice.removeLast()
                    let popped = slice.popLast()!
                    slice.swapAt(
                        slice.startIndex,
                        slice.index(before: slice.endIndex)
                    )
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        last,
                        popped,
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3, 4])],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(6),
                                try integer(7), try integer(6),
                                try integers([5, 10, 3, 4, 8]),
                            ])
                        )
                    ),
                ]
            ),
            .init(
                name: "optimizedSliceReplace",
                source: """
                public func optimizedSliceReplace(
                    _ values: [Int]
                ) -> (Int, Int, [Int]) {
                    var slice = values.dropFirst()
                    let lower = slice.index(after: slice.startIndex)
                    slice.replaceSubrange(
                        lower..<slice.endIndex,
                        with: [9, 8]
                    )
                    return (
                        slice.startIndex,
                        slice.endIndex,
                        Array(slice)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(
                            .tuple([
                                try integer(1), try integer(4),
                                try integers([1, 9, 8]),
                            ])
                        )
                    ),
                ],
                optimization: "-O"
            ),
        ])
    }

    @Test("Index movement enforces Collection preconditions")
    func trapsInvalidMovement() throws {
        try run([
            .init(
                name: "invalidAfterEnd",
                source: """
                public func invalidAfterEnd(_ values: [Int]) -> Int {
                    let slice = values.dropFirst()
                    return slice.index(after: slice.endIndex)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .trapped(
                            .explicit("Collection index is out of bounds")
                        )
                    ),
                ]
            ),
            .init(
                name: "invalidOffset",
                source: """
                public func invalidOffset(_ values: [Int]) -> Int {
                    let slice = values.dropFirst()
                    return slice.index(slice.startIndex, offsetBy: 10)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .trapped(
                            .explicit("Collection index is out of bounds")
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Mutating index movement reuses represented integer-index semantics")
    func lowersFormIndexFamilies() throws {
        try run([
            .init(
                name: "arrayFormIndex",
                source: """
                public func arrayFormIndex(
                    _ values: [Int]
                ) -> (Int, Int) {
                    var first = values.startIndex
                    values.formIndex(after: &first)
                    values.formIndex(before: &first)
                    var offset = values.startIndex
                    values.formIndex(&offset, offsetBy: 2)
                    return (first, offset)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2, 3])],
                        expected: .returned(.tuple([
                            try integer(0), try integer(2),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "sliceLimitedFormIndex",
                source: """
                public func sliceLimitedFormIndex(
                    _ values: [Int],
                    _ distance: Int,
                    _ limit: Int
                ) -> (Bool, Int) {
                    let slice = values.dropFirst()
                    var index = slice.startIndex
                    let reached = slice.formIndex(
                        &index,
                        offsetBy: distance,
                        limitedBy: limit
                    )
                    return (reached, index)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 3]),
                            try integer(2),
                            try integer(3),
                        ],
                        expected: .returned(.tuple([
                            .bool(true), try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 3]),
                            try integer(3),
                            try integer(2),
                        ],
                        expected: .returned(.tuple([
                            .bool(false), try integer(2),
                        ]))
                    ),
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 3]),
                            try integer(.max),
                            try integer(3),
                        ],
                        expected: .returned(.tuple([
                            .bool(false), try integer(3),
                        ]))
                    ),
                    .init(
                        arguments: [
                            try integers([0, 1, 2, 3]),
                            try integer(0),
                            try integer(3),
                        ],
                        expected: .returned(.tuple([
                            .bool(true), try integer(1),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "composedSliceFormIndex",
                source: """
                public func composedSliceFormIndex(_ values: [Int]) -> Int {
                    let slice = Slice(
                        base: values,
                        bounds: 1..<values.endIndex
                    )
                    var index = slice.startIndex
                    slice.formIndex(after: &index)
                    slice.formIndex(before: &index)
                    return index
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([0, 1, 2, 3])],
                        expected: .returned(try integer(1))
                    ),
                ]
            ),
            .init(
                name: "repeatedIndexSurface",
                source: """
                public func repeatedIndexSurface(
                    _ value: Int
                ) -> (Int, Int, Int, Int, Int, Int, Int?, [Int]) {
                    let values = repeatElement(value, count: 4)
                    var index = values.startIndex
                    values.formIndex(after: &index)
                    values.formIndex(&index, offsetBy: 2)
                    return (
                        values.startIndex,
                        values.endIndex,
                        values.index(before: values.endIndex),
                        values.distance(
                            from: values.startIndex,
                            to: values.endIndex
                        ),
                        index,
                        values[index],
                        values.index(
                            values.startIndex,
                            offsetBy: 2,
                            limitedBy: values.endIndex
                        ),
                        Array(values.indices)
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(7)],
                        expected: .returned(.tuple([
                            try integer(0), try integer(4),
                            try integer(3), try integer(4),
                            try integer(3), try integer(7),
                            .optional(try integer(2)),
                            try integers([0, 1, 2, 3]),
                        ]))
                    ),
                ]
            ),
            .init(
                name: "invalidFormIndex",
                source: """
                public func invalidFormIndex(_ values: [Int]) -> Int {
                    var index = values.endIndex
                    values.formIndex(after: &index)
                    return index
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .trapped(
                            .explicit("Collection index is out of bounds")
                        )
                    ),
                ]
            ),
            .init(
                name: "invalidFormIndexBefore",
                source: """
                public func invalidFormIndexBefore(_ values: [Int]) -> Int {
                    var index = values.startIndex
                    values.formIndex(before: &index)
                    return index
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integers([1, 2])],
                        expected: .trapped(
                            .explicit(
                                "Collection index(before:) precedes startIndex"
                            )
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Opaque stdlib index identities remain fail-closed")
    func rejectsOpaqueIndices() {
        for (name, source) in [
            (
                "stringIndex",
                """
                public func stringIndex(_ value: String) -> Character {
                    value[value.startIndex]
                }
                """
            ),
            (
                "reversedIndex",
                """
                public func reversedIndex(_ values: [Int]) -> Bool {
                    values.reversed().lastIndex { $0 > 0 } != nil
                }
                """
            ),
        ] {
            #expect(throws: CanonicalSIL.LoweringError.self) {
                _ = try FrontendExecutionHarness.compile(
                    source: source,
                    functionName: name,
                    moduleName: "HelixOpaqueIndex_\(name)"
                )
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
                    moduleName: "HelixCollectionIndex_\(probe.name)_"
                        + probe.optimization.replacingOccurrences(
                            of: "-",
                            with: ""
                        ),
                    optimization: probe.optimization
                )
                let disassembly = Bytecode.Disassembler.disassemble(
                    fixture.image.module
                )
                for required in probe.requiredDisassembly
                where !disassembly.contains(required) {
                    failures.append(
                        "\(probe.name): missing \(required)"
                    )
                }
                for forbidden in probe.forbiddenDisassembly
                where disassembly.contains(forbidden) {
                    failures.append(
                        "\(probe.name): unexpectedly contains \(forbidden)"
                    )
                }
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
                    rawValue: "collection-index gaps:\n"
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
}
}
