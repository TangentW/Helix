import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift text Sequence semantics")
struct TextSequenceSemanticsMatrix {
    @Test("Logical text element recovery is concrete and fail-closed")
    func classifiesNormalizedTextSequences() {
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSa8capacitySivg"
            ) == nil
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSlsE13randomElement0B0QzSgyF"
            ) == nil
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$sSlsE8dropLasty11SubSequenceQzSiF"
            ) == .adapter(.subsequence(.dropLast))
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSmsE6filteryxSb7ElementQzKXEKF"
            ) == .higherOrder(.filter(.rangeReplaceableCollection))
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName:
                    "$sSSySSxcs25LosslessStringConvertibleRzSTRzSJ7ElementSTRtzlufC"
            ) == .text(.construction(.fromCharacterSequence))
        )
        #expect(
            CanonicalSIL.CollectionIntrinsic(
                mangledName: "$sSKsE8dropLasty11SubSequenceQzSiF"
            ) == .adapter(.subsequence(.dropLast))
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "Array<Character>"
            ) == .character
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "ReversedCollection<Array<Character>>"
            ) == .character
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "FlattenSequence<Array<Array<Character>>>"
            ) == .character
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "JoinedSequence<Array<Array<String>>>"
            ) == .string
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "FlattenSequence<FlattenSequence<Array<Array<Array<Character>>>>>"
            ) == .character
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "CollectionOfOne<Character>"
            ) == nil
        )
        #expect(
            CanonicalSIL.TextRepresentation.sequenceElementKind(
                of: "Application.CharacterCollection"
            ) == nil
        )
    }

    @Test("Only direct semantic intrinsic references terminate discovery")
    func preservesIntrinsicClosureDependencies() throws {
        let intrinsic = "$sSS10uppercasedSSyF"
        let file = try CanonicalSIL.File(text: """
        sil hidden @$s7Fixture13closureEntryyyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @\(intrinsic) : $@convention(method) (@guaranteed String) -> @owned String
          %1 = thin_to_thick_function %0 to $@callee_guaranteed (@guaranteed String) -> @owned String
          return
        } // end sil function '$s7Fixture13closureEntryyyF'

        sil hidden @$s7Fixture11directEntryyyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @\(intrinsic) : $@convention(method) (@guaranteed String) -> @owned String
          %1 = apply %0() : $@convention(method) (@guaranteed String) -> @owned String
          return
        } // end sil function '$s7Fixture11directEntryyyF'

        sil public_external @\(intrinsic) : $@convention(method) (@guaranteed String) -> @owned String {
        bb0(%0 : $String):
          return %0 : $String
        } // end sil function '\(intrinsic)'
        """)

        let closureDependencies = try CanonicalSIL.ImageFunctions.discover(
            in: file,
            startingAt: ["$s7Fixture13closureEntryyyF"],
            excluding: [],
            environment: file.typeEnvironment,
            kindForSymbol: { _ in .ordinary }
        )
        #expect(closureDependencies[intrinsic]?.kind == .closureBody)

        let directDependencies = try CanonicalSIL.ImageFunctions.discover(
            in: file,
            startingAt: ["$s7Fixture11directEntryyyF"],
            excluding: [],
            environment: file.typeEnvironment,
            kindForSymbol: { _ in .ordinary }
        )
        #expect(directDependencies[intrinsic] == nil)
    }

    @Test("String Collection boundaries preserve extended grapheme clusters")
    func lowersStringCollectionBoundaries() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: #"""
            public func stringCollectionBoundaries(
                _ value: String
            ) -> (Int, Bool, String?, String?, String, String, String, String) {
                let first = value.first.map { String($0) }
                let last = value.last.map { String($0) }
                return (
                    value.count,
                    value.isEmpty,
                    first,
                    last,
                    String(value.prefix(2)),
                    String(value.suffix(2)),
                    String(value.dropFirst()),
                    String(value.dropLast())
                )
            }
            """#,
            functionName: "stringCollectionBoundaries",
            moduleName: "HelixStringCollectionBoundaries"
        )
        let family = "👨‍👩‍👧‍👦"
        let flag = "🇨🇳"
        let decomposed = "e\u{301}"
        let value = decomposed + family + flag + "x"
        #expect(
            invoke(fixture, arguments: [.string(value)]) == .returned(
                .tuple([
                    try integer(4),
                    .bool(false),
                    .optional(.string(decomposed)),
                    .optional(.string("x")),
                    .string(decomposed + family),
                    .string(flag + "x"),
                    .string(family + flag + "x"),
                    .string(decomposed + family + flag),
                ])
            )
        )
        #expect(
            invoke(fixture, arguments: [.string("")]) == .returned(
                .tuple([
                    try integer(0),
                    .bool(true),
                    .optional(nil),
                    .optional(nil),
                    .string(""),
                    .string(""),
                    .string(""),
                    .string(""),
                ])
            )
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.character"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("String shares finite Sequence adapters and relations")
    func lowersStringSequenceAdapters() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: #"""
            public func stringSequenceAdapters(
                _ value: String,
                prefix: [Character],
                other: [Character]
            ) -> (String, String, String, String, Bool, Bool) {
                let characters = Array(value)
                let mapped = value.map { String($0) }.joined(separator: "|")
                let reversed = String(value.reversed())
                let nested = [Array(value.prefix(1)), Array(value.dropFirst())]
                return (
                    String(characters),
                    mapped,
                    reversed,
                    String(nested.joined()),
                    value.starts(with: prefix),
                    value.elementsEqual(other)
                )
            }
            """#,
            functionName: "stringSequenceAdapters",
            moduleName: "HelixStringSequenceAdapters"
        )
        let value = "A👩🏽‍💻é"
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string(value),
                    characters(["A", "👩🏽‍💻"]),
                    characters(["A", "👩🏽‍💻", "é"]),
                ]
            ) == .returned(.tuple([
                .string(value),
                .string("A|👩🏽‍💻|é"),
                .string("é👩🏽‍💻A"),
                .string(value),
                .bool(true),
                .bool(true),
            ]))
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.character"))
        #expect(disassembly.contains("string_join.string"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("String split and Substring conversion reuse normalized Collections")
    func lowersStringSplitAndSubstringConversion() throws {
        let separator = try FrontendExecutionHarness.compile(
            source: #"""
            public func splitText(
                _ value: String,
                maximum: Int,
                omitEmpty: Bool
            ) -> String {
                value.split(
                    separator: ",",
                    maxSplits: maximum,
                    omittingEmptySubsequences: omitEmpty
                ).map { String($0) }.joined(separator: "|")
            }
            """#,
            functionName: "splitText",
            moduleName: "HelixStringSeparatorSplit"
        )
        #expect(
            invoke(
                separator,
                arguments: [.string(",a,,👨‍👩‍👧‍👦,"), try integer(2), .bool(false)]
            ) == .returned(.string("|a|,👨‍👩‍👧‍👦,"))
        )
        #expect(
            invoke(
                separator,
                arguments: [.string("a,b"), try integer(-1), .bool(true)]
            ) == .trapped(.explicit("maximum split count cannot be negative"))
        )

        let predicate = try FrontendExecutionHarness.compile(
            source: #"""
            private enum SplitFailure: Error { case marker }

            public func splitTextWhere(_ value: String) -> String {
                do {
                    return try value.split { character in
                        if character == "!" { throw SplitFailure.marker }
                        return character == ";"
                    }.map { String($0) }.joined(separator: "/")
                } catch {
                    return "failed"
                }
            }
            """#,
            functionName: "splitTextWhere",
            moduleName: "HelixStringPredicateSplit"
        )
        #expect(
            invoke(predicate, arguments: [.string("a;👩🏽‍💻;c")])
                == .returned(.string("a/👩🏽‍💻/c"))
        )
        #expect(
            invoke(predicate, arguments: [.string("a;!;c")])
                == .returned(.string("failed"))
        )

        let substring = try FrontendExecutionHarness.compile(
            source: #"""
            public func substringRoundTrip(
                _ value: Substring
            ) -> (Int, Bool, String, String) {
                (
                    value.count,
                    value.isEmpty,
                    String(value),
                    value.map { String($0) }.joined()
                )
            }
            """#,
            functionName: "substringRoundTrip",
            moduleName: "HelixSubstringRoundTrip"
        )
        #expect(
            invoke(
                substring,
                arguments: [characters(["e\u{301}", "🧬"])]
            ) == .returned(.tuple([
                try integer(2),
                .bool(false),
                .string("e\u{301}🧬"),
                .string("e\u{301}🧬"),
            ]))
        )
    }

    @Test("Text construction and mutation keep logical String and Character roles")
    func lowersTextConstructionAndMutation() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: #"""
            public func constructText(
                _ seed: String,
                count: Int,
                suffix: String,
                marker: Character
            ) -> (String, String, String, String, Bool, Bool) {
                var value = String(repeating: seed, count: count)
                value.append(contentsOf: suffix)
                value.append(marker)
                value += "!"
                let tail = seed.dropFirst()
                return (
                    value,
                    String(describing: count),
                    String(marker),
                    "\(marker):\(tail)",
                    marker == "🧬",
                    marker < "🧭"
                )
            }
            """#,
            functionName: "constructText",
            moduleName: "HelixTextConstruction"
        )
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string("ab"),
                    try integer(2),
                    .string("-"),
                    .string("🧬"),
                ]
            ) == .returned(.tuple([
                .string("abab-🧬!"),
                .string("2"),
                .string("🧬"),
                .string("🧬:b"),
                .bool(true),
                .bool(true),
            ]))
        )
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string("x"),
                    try integer(-1),
                    .string(""),
                    .string("a"),
                ]
            ) == .trapped(.explicit("Array repeat count must not be negative"))
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("array_repeat"))
        #expect(disassembly.contains("string_join.string"))
        #expect(disassembly.contains("stringify"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("String reuses generic Sequence consumers, builders, and adapters")
    func lowersStringSequenceFamilies() throws {
        let consumers = try FrontendExecutionHarness.compile(
            source: #"""
            public func consumeText(
                _ value: String,
                marker: Character
            ) -> (String, String, String, Bool, Int, String?, String?, String, Int) {
                let filtered = String(value.filter { $0 != marker })
                let compacted = String(value.compactMap {
                    $0 == marker ? nil : $0
                })
                let folded = value.reduce(into: "") { $0.append($1) }
                return (
                    filtered,
                    compacted,
                    folded,
                    value.contains { $0 == marker },
                    value.count { $0 == marker },
                    value.min().map { String($0) },
                    value.max().map { String($0) },
                    String(value.sorted()),
                    Set(value).count
                )
            }
            """#,
            functionName: "consumeText",
            moduleName: "HelixStringSequenceFamilies"
        )
        #expect(
            invoke(
                consumers,
                arguments: [.string("cabac"), .string("a")]
            ) == .returned(.tuple([
                .string("cbc"),
                .string("cbc"),
                .string("cabac"),
                .bool(true),
                try integer(2),
                .optional(.string("a")),
                .optional(.string("c")),
                .string("aabcc"),
                try integer(3),
            ]))
        )

        let adapters = try FrontendExecutionHarness.compile(
            source: #"""
            public func adaptText(_ lhs: String, _ rhs: String) -> (String, String) {
                let indexed = lhs.enumerated().map {
                    "\($0.offset):\($0.element)"
                }.joined(separator: "|")
                let paired = zip(lhs, rhs).map {
                    String($0) + String($1)
                }.joined(separator: "|")
                return (indexed, paired)
            }
            """#,
            functionName: "adaptText",
            moduleName: "HelixStringSequenceAdaptersExtended"
        )
        #expect(
            invoke(
                adapters,
                arguments: [.string("A🧬Z"), .string("12")]
            ) == .returned(.tuple([
                .string("0:A|1:🧬|2:Z"),
                .string("A1|🧬2"),
            ]))
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            adapters.image.module
        )
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.string"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("String predicate traversal reuses forward and reverse Collection plans")
    func lowersStringPredicateTraversal() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: #"""
            public func traverseTextPredicates(
                _ value: String,
                marker: Character
            ) -> (String, String, String?, String?, Int) {
                var lastVisits = 0
                let first = value.first { $0 == marker }.map { String($0) }
                let last = value.last {
                    lastVisits += 1
                    return $0 == marker
                }.map { String($0) }
                return (
                    String(value.prefix { $0 != marker }),
                    String(value.drop { $0 != marker }),
                    first,
                    last,
                    lastVisits
                )
            }
            """#,
            functionName: "traverseTextPredicates",
            moduleName: "HelixStringPredicateTraversal"
        )
        #expect(
            invoke(
                fixture,
                arguments: [.string("A👩🏽‍💻B👩🏽‍💻C"), .string("👩🏽‍💻")]
            ) == .returned(.tuple([
                .string("A"),
                .string("👩🏽‍💻B👩🏽‍💻C"),
                .optional(.string("👩🏽‍💻")),
                .optional(.string("👩🏽‍💻")),
                try integer(2),
            ]))
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.character"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Index- and encoding-dependent text operations remain fail-closed")
    func rejectsUnrepresentedTextStorageSemantics() {
        expectUnsupported(
            name: "stringUTF8Count",
            source: """
            public func stringUTF8Count(_ value: String) -> Int {
                value.utf8.count
            }
            """,
            diagnostic: "is not frozen in the target HLXI"
        )
        expectUnsupported(
            name: "stringUTF16Count",
            source: """
            public func stringUTF16Count(_ value: String) -> Int {
                value.utf16.count
            }
            """,
            diagnostic: "is not frozen in the target HLXI"
        )
        expectUnsupported(
            name: "stringUnicodeScalarCount",
            source: """
            public func stringUnicodeScalarCount(_ value: String) -> Int {
                value.unicodeScalars.count
            }
            """,
            diagnostic: "is not frozen in the target HLXI"
        )
        expectUnsupported(
            name: "stringIndexedElement",
            source: """
            public func stringIndexedElement(_ value: String) -> Character {
                value[value.index(after: value.startIndex)]
            }
            """,
            diagnostic: "is not frozen in the target HLXI"
        )
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        arguments: [VM.Value]
    ) -> VM.ExecutionResult {
        VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func characters(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
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
                moduleName: "HelixTextNegative_\(name)"
            )
            Issue.record("\(name) unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains(diagnostic))
        } catch {
            Issue.record("\(name) produced an unexpected error: \(error)")
        }
    }
}
}
