import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift represented RangeReplaceableCollection append semantics")
struct RangeReplaceableCollectionAppendSemanticsMatrix {
    @Test("Swift type identities preserve logical Sequence.Element semantics")
    func resolvesLogicalSequenceElementIdentities() {
        typealias Identity = CanonicalSIL.SwiftTypeIdentity

        #expect(
            Identity.normalized(
                "Swift.Array<(key: Swift.Int, value: Swift.String)>"
            ) == "Array<(key:Int,value:String)>"
        )
        #expect(
            Identity.normalized("(key: Int, value: String)")
                != Identity.normalized("(Int, String)")
        )
        #expect(
            Identity.normalized("MySwift.Widget") == "MySwift.Widget"
        )
        #expect(
            Identity.representedSequenceElement(
                of: "Dictionary<Swift.Int, Swift.String>"
            ) == "(key:Int,value:String)"
        )
        #expect(
            Identity.representedSequenceElement(
                of: "Dictionary<Int, String>.Values"
            ) == "String"
        )
        #expect(
            Identity.representedSequenceElement(
                of: "EnumeratedSequence<Array<Character>>"
            ) == "(offset:Int,element:Character)"
        )
        #expect(
            Identity.representedSequenceElement(
                of: "Zip2Sequence<Array<Int>, Substring>"
            ) == "(Int,Character)"
        )
        #expect(
            Identity.representedSequenceElement(
                of: "FlattenSequence<Array<Array<Character>>>"
            ) == "Character"
        )
        #expect(Identity.representedSequenceElement(of: "Array<>") == nil)
        #expect(
            Identity.representedSequenceElement(
                of: "Dictionary<Int,>"
            ) == nil
        )

        for type in [
            "String", "Substring", "Array<Int>", "ArraySlice<Int>",
            "Slice<Array<Int>>",
        ] {
            #expect(
                Identity.isRepresentedRangeReplaceableCollection(type)
            )
        }
        for type in [
            "Set<Int>", "Repeated<Int>", "ReversedCollection<Array<Int>>",
            "Range<Int>", "Slice<Set<Int>>", "Array<>",
        ] {
            #expect(
                !Identity.isRepresentedRangeReplaceableCollection(type)
            )
        }
    }

    @Test("Frontend append entry points converge on one semantic classifier")
    func classifiesFrontendEntryPoints() {
        typealias Append = CanonicalSIL.CollectionIntrinsic
            .RangeReplaceableAppend
        let cases: [(String, Append)] = [
            (
                "$sSS6appendyySJF",
                .init(
                    destination: .string,
                    input: .element,
                    callShape: .method
                )
            ),
            (
                "$sSS6append10contentsOfySs_tF",
                .init(
                    destination: .string,
                    input: .contents(.fixed(.substring)),
                    callShape: .method
                )
            ),
            (
                "$sSS6append10contentsOfyx_tSTRzSJ7ElementRtzlF",
                .init(
                    destination: .string,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            ),
            (
                "$sSs6append10contentsOfyx_tSTRzSJ7ElementRtzlF",
                .init(
                    destination: .substring,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            ),
            (
                "$sSmsE6appendyy7ElementQznF",
                .init(
                    destination: .genericSelf,
                    input: .element,
                    callShape: .method
                )
            ),
            (
                "$sSmsE6append10contentsOfyqd__n_tSTRd__7ElementQyd__ACRtzlF",
                .init(
                    destination: .genericSelf,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            ),
            (
                "$sSa6appendyyxnF",
                .init(
                    destination: .array,
                    input: .element,
                    callShape: .method
                )
            ),
            (
                "$ss10ArraySliceV6appendyyxnF",
                .init(
                    destination: .arraySlice,
                    input: .element,
                    callShape: .method
                )
            ),
            (
                "$sSa6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF",
                .init(
                    destination: .array,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            ),
            (
                "$ss10ArraySliceV6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF",
                .init(
                    destination: .arraySlice,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            ),
            (
                "$sSS2peoiyySSz_SStFZ",
                .init(
                    destination: .string,
                    input: .contents(.destination),
                    callShape: .additionAssignment
                )
            ),
            (
                "$sSa2peoiyySayxGz_ABtFZ",
                .init(
                    destination: .array,
                    input: .contents(.destination),
                    callShape: .additionAssignment
                )
            ),
            (
                "$sSmsE2peoiyyxz_qd__tSTRd__7ElementQyd__ABRtzlFZ",
                .init(
                    destination: .genericSelf,
                    input: .contents(.genericArgument),
                    callShape: .additionAssignment
                )
            ),
        ]

        for (symbol, expected) in cases {
            #expect(
                CanonicalSIL.CollectionIntrinsic(mangledName: symbol)
                    == .rangeReplaceableAppend(expected)
            )
            #expect(
                CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol)
                    == .collection(.rangeReplaceableAppend(expected))
            )
        }
    }

    @Test("String appends concrete and represented Character sequences")
    func appendsStringSourcesByGrapheme() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendStringSources(
                _ base: String,
                _ character: Character,
                _ text: String,
                _ segment: Substring,
                _ characters: [Character]
            ) -> String {
                var value = base
                value.append(character)
                value.append(text)
                value.append(contentsOf: text)
                value.append(contentsOf: segment)
                value.append(contentsOf: characters)
                value += text
                value += segment
                value += characters
                return value
            }
            """,
            functionName: "appendStringSources",
            moduleName: "HelixStringAppendSources"
        )

        let text = "B🇨🇳"
        let segment = ["é", "क्‍ष"]
        let characters = ["C", "👨‍👩‍👧‍👦"]
        let expected = (["A", "👩🏽‍💻", "B", "🇨🇳", "B", "🇨🇳"]
            + segment + characters + ["B", "🇨🇳"]
            + segment + characters).joined()
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string("A"),
                    .string("👩🏽‍💻"),
                    .string(text),
                    charactersValue(segment),
                    charactersValue(characters),
                ]
            ) == .returned(.string(expected))
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("string_concat"))
        #expect(disassembly.contains("string_join.character"))
        #expect(!disassembly.contains("string_characters"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Substring appends share Array-backed storage and String segmentation")
    func appendsSubstringSources() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendSubstringSources(
                _ base: Substring,
                _ character: Character,
                _ text: String,
                _ segment: Substring,
                _ characters: [Character]
            ) -> Substring {
                var value = base
                value.append(character)
                value.append(contentsOf: text)
                value.append(contentsOf: segment)
                value += characters
                value += text
                return value
            }
            """,
            functionName: "appendSubstringSources",
            moduleName: "HelixSubstringAppendSources"
        )

        #expect(
            invoke(
                fixture,
                arguments: [
                    charactersValue(["A"]),
                    .string("👩🏽‍💻"),
                    .string("B🇨🇳"),
                    charactersValue(["é", "क्‍ष"]),
                    charactersValue(["C", "👨‍👩‍👧‍👦"]),
                ]
            ) == .returned(
                charactersValue([
                    "A", "👩🏽‍💻", "B", "🇨🇳", "é", "क्‍ष", "C",
                    "👨‍👩‍👧‍👦", "B", "🇨🇳",
                ])
            )
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("array_append"))
        #expect(disassembly.contains("array_replace"))
        #expect(disassembly.contains("string_characters"))
        #expect(!disassembly.contains("string_concat"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Array and ArraySlice accept represented finite Sequence sources")
    func appendsArrayBackedAndProgressionSources() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendArraySources(
                _ input: [Int],
                _ element: Int,
                _ lower: Int,
                _ upper: Int
            ) -> ([Int], [Int]) {
                let slice = input.dropFirst()
                let range = lower..<upper

                var array = input
                array.append(element)
                array.append(contentsOf: input)
                array.append(contentsOf: slice)
                array.append(contentsOf: range)
                array += input
                array += slice
                array += range

                var view = input.dropFirst()
                view.append(element)
                view.append(contentsOf: input)
                view.append(contentsOf: slice)
                view.append(contentsOf: range)
                view += input
                view += slice
                view += range
                return (array, Array(view))
            }
            """,
            functionName: "appendArraySources",
            moduleName: "HelixArrayAppendSources"
        )

        let input: [Int64] = [1, 2, 3]
        let slice: [Int64] = [2, 3]
        let range: [Int64] = [4, 5]
        let expectedArray = input + [9] + input + slice + range
            + input + slice + range
        let expectedSlice = slice + [9] + input + slice + range
            + input + slice + range
        #expect(
            invoke(
                fixture,
                arguments: [
                    try integers(input),
                    try integer(9),
                    try integer(4),
                    try integer(6),
                ]
            ) == .returned(
                .tuple([
                    try integers(expectedArray),
                    try integers(expectedSlice),
                ])
            )
        )

        let empty = invoke(
            fixture,
            arguments: [
                try integers([]),
                try integer(7),
                try integer(0),
                try integer(0),
            ]
        )
        #expect(
            empty == .returned(
                .tuple([try integers([7]), try integers([7])])
            )
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("array_append"))
        #expect(disassembly.contains("array_replace"))
        #expect(disassembly.contains("progression_next"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Generic Slice destinations remain mutable after normalization")
    func appendsGenericSliceDestination() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendGenericSlice(
                _ input: Slice<Array<Int>>
            ) -> [Int] {
                var value = input
                value.append(9)
                value.append(contentsOf: [10, 11])
                value += 12..<14
                return Array(value)
            }
            """,
            functionName: "appendGenericSlice",
            moduleName: "HelixGenericSliceAppend"
        )

        #expect(
            invoke(fixture, arguments: [try integers([1, 2])])
                == .returned(try integers([1, 2, 9, 10, 11, 12, 13]))
        )
    }

    @Test("Non-Array represented Sequences reuse the same contents path")
    func appendsSetSource() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendSetSource(_ source: Set<Int>) -> [Int] {
                var result = [-1]
                result += source
                return result.sorted()
            }
            """,
            functionName: "appendSetSource",
            moduleName: "HelixSetAppendSource"
        )

        #expect(
            invoke(fixture, arguments: [try integersSet([3, 1, 2])])
                == .returned(try integers([-1, 1, 2, 3]))
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("collection_materialize"))
        #expect(disassembly.contains("array_replace"))
    }

    @Test("Dictionary and adapter Elements retain their logical identities")
    func appendsDictionaryAndAdapterSources() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendDictionaryAndAdapterSources(
                _ source: [Int: String]
            ) -> (Int, [Int], Int) {
                var pairs: [(key: Int, value: String)] = []
                pairs.append(contentsOf: source)
                pairs += source

                var keys = [-1]
                keys.append(contentsOf: source.keys)
                keys += source.keys
                keys.sort()

                var enumerated: [(offset: Int, element: Int)] = []
                enumerated.append(contentsOf: keys.enumerated())
                return (pairs.count, keys, enumerated.count)
            }
            """,
            functionName: "appendDictionaryAndAdapterSources",
            moduleName: "HelixDictionaryAdapterAppendSources"
        )

        #expect(
            invoke(
                fixture,
                arguments: [
                    try integerStringDictionary([(1, "one"), (3, "three")]),
                ]
            ) == .returned(.tuple([
                try integer(4),
                try integers([-1, 1, 1, 3, 3]),
                try integer(5),
            ]))
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("collection_materialize"))
        #expect(disassembly.contains("array_replace"))
    }

    @Test("Self-aliased appends preserve Swift value semantics")
    func preservesSnapshotSemantics() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func appendSnapshots(
                _ input: [Int],
                _ text: String
            ) -> ([Int], String) {
                var values = input
                values.append(contentsOf: values)
                values += values

                var output = text
                output.append(contentsOf: output)
                output += output
                return (values, output)
            }
            """,
            functionName: "appendSnapshots",
            moduleName: "HelixAppendSnapshots"
        )

        #expect(
            invoke(
                fixture,
                arguments: [try integers([1, 2]), .string("A🇨🇳")]
            ) == .returned(
                .tuple([
                    try integers([1, 2, 1, 2, 1, 2, 1, 2]),
                    .string("A🇨🇳A🇨🇳A🇨🇳A🇨🇳"),
                ])
            )
        )
    }

    @Test("Element and contents append preserve imported-reference ownership")
    func verifiesLinearElementOwnership() throws {
        let objectType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func appendObjects(
                _ input: [NSObject],
                _ object: NSObject
            ) -> [NSObject] {
                var result = input
                result.append(object)
                result.append(contentsOf: input)
                result += input
                return result
            }
            """,
            functionName: "appendObjects",
            moduleName: "HelixLinearCollectionAppend",
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
            if case .arrayAppend = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .arrayReplaceSubrange = instruction { return true }
            return false
        })
    }

    @Test("Operator metatypes retain logical collection identity")
    func rejectsMismatchedOperatorMetatype() {
        let stringFunction = CanonicalSIL.Function(
            mangledName: "$s7Fixture12badMetatypeyySSz_SStF",
            loweredType: "@convention(thin) (@inout String, @guaranteed String) -> ()",
            body: """
            bb0(%0 : $*String, %1 : $String):
              %2 = metatype $@thick Substring.Type
              %3 = function_ref @$sSS2peoiyySSz_SStFZ : $@convention(method) (@inout String, @guaranteed String, @thin String.Type) -> ()
              %4 = apply %3(%0, %1, %2) : $@convention(method) (@inout String, @guaranteed String, @thin String.Type) -> ()
              %5 = tuple ()
              return %5
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                stringFunction,
                displayName: "Fixture.badMetatype"
            )
            Issue.record("a mismatched += metatype unexpectedly compiled")
        } catch {
            #expect(
                String(describing: error).contains(
                    "+= metatype does not match Self"
                )
            )
        }

        let arrayFunction = CanonicalSIL.Function(
            mangledName: "$s7Fixture16badArrayMetatypeyySaySiGz_ADtF",
            loweredType: "@convention(thin) (@inout Array<Int>, @guaranteed Array<Int>) -> ()",
            body: """
            bb0(%0 : $*Array<Int>, %1 : $Array<Int>):
              %2 = metatype $@thin ArraySlice<Int>.Type
              %3 = function_ref @$sSa2peoiyySayxGz_ABtFZ : $@convention(method) <τ_0_0> (@inout Array<τ_0_0>, @guaranteed Array<τ_0_0>, @thin Array<τ_0_0>.Type) -> ()
              %4 = apply %3<Int>(%0, %1, %2) : $@convention(method) <τ_0_0> (@inout Array<τ_0_0>, @guaranteed Array<τ_0_0>, @thin Array<τ_0_0>.Type) -> ()
              %5 = tuple ()
              return %5
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                arrayFunction,
                displayName: "Fixture.badArrayMetatype"
            )
            Issue.record(
                "ArraySlice metatype unexpectedly satisfied Array +="
            )
        } catch {
            #expect(
                String(describing: error).contains(
                    "+= metatype does not match Self"
                )
            )
        }
    }

    @Test("Erased String and Character element identities are not conflated")
    func rejectsStringElementsAsCharacters() {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture17badTextElementsyySSz_SaySSGtF",
            loweredType: "@convention(thin) (@inout String, @guaranteed Array<String>) -> ()",
            body: """
            bb0(%0 : $*String, %1 : $Array<String>):
              %2 = alloc_stack $Array<String>
              store %1 to %2
              %3 = function_ref @$sSS6append10contentsOfyx_tSTRzSJ7ElementRtzlF : $@convention(method) <τ_0_0 where τ_0_0 : Sequence, τ_0_0.Element == Character> (@in_guaranteed τ_0_0, @inout String) -> ()
              %4 = apply %3<Array<String>>(%2, %0) : $@convention(method) <τ_0_0 where τ_0_0 : Sequence, τ_0_0.Element == Character> (@in_guaranteed τ_0_0, @inout String) -> ()
              dealloc_stack %2
              %5 = tuple ()
              return %5
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.badTextElements"
            )
            Issue.record("Array<String> unexpectedly satisfied Character input")
        } catch {
            #expect(
                String(describing: error).contains(
                    "Sequence.Element does not match destination Element"
                )
            )
        }
    }

    @Test("All erased Element identities must agree, not only text")
    func rejectsPhysicallyEqualNumericElements() {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture18badNumericElementsyySaySiGz_Says5Int64VGtF",
            loweredType: "@convention(thin) (@inout Array<Int>, @guaranteed Array<Int64>) -> ()",
            body: """
            bb0(%0 : $*Array<Int>, %1 : $Array<Int64>):
              %2 = alloc_stack $Array<Int64>
              store %1 to %2
              %3 = function_ref @$sSa6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF : $@convention(method) <τ_0_0, τ_1_0 where τ_1_0 : Sequence, τ_0_0 == τ_1_0.Element> (@in_guaranteed τ_1_0, @inout Array<τ_0_0>) -> ()
              %4 = apply %3<Int, Array<Int64>>(%2, %0) : $@convention(method) <τ_0_0, τ_1_0 where τ_1_0 : Sequence, τ_0_0 == τ_1_0.Element> (@in_guaranteed τ_1_0, @inout Array<τ_0_0>) -> ()
              dealloc_stack %2
              %5 = tuple ()
              return %5
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.badNumericElements"
            )
            Issue.record("Array<Int64> unexpectedly satisfied Int input")
        } catch {
            #expect(
                String(describing: error).contains(
                    "Sequence.Element does not match destination Element"
                )
            )
        }
    }

    @Test("Opaque Sequence storage remains fail-closed")
    func rejectsOpaqueSequenceSource() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public func appendOpaque(
                    _ source: AnySequence<Int>
                ) -> [Int] {
                    var result: [Int] = []
                    result.append(contentsOf: source)
                    return result
                }
                """,
                functionName: "appendOpaque",
                moduleName: "HelixOpaqueAppendSource"
            )
            Issue.record("opaque Sequence append unexpectedly compiled")
        } catch {
            #expect(String(describing: error).contains("AnySequence<Int>"))
        }
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

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func charactersValue(_ values: [String]) -> VM.Value {
        .array(values.map(VM.Value.string), elementType: .string)
    }

    private func integersSet(_ values: [Int64]) throws -> VM.Value {
        .set(
            VM.SetValue(
                elements: try values.map(integer),
                elementType: .int64
            )
        )
    }

    private func integerStringDictionary(
        _ entries: [(Int64, String)]
    ) throws -> VM.Value {
        .dictionary(
            try entries.map {
                .init(key: try integer($0.0), value: .string($0.1))
            },
            keyType: .int64,
            valueType: .string
        )
    }
}
}
