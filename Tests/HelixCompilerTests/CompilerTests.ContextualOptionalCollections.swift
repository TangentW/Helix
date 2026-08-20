import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Context-typed Optional collection semantics")
struct ContextualOptionalCollections {
    @Test("Common collection adapters preserve nil elements, keys, and values")
    func lowersContextTypedNilAcrossCollectionStates() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func contextualOptionalCollections(
                _ values: [Int?]
            ) -> (
                [Int?],
                [Int?],
                [Int?],
                [[Int?]],
                [String: Int?],
                [Int?: String]
            ) {
                let mapped = values.map { $0 }
                var retained = values
                retained.removeAll { $0 == nil }
                let sorted = values.sorted {
                    ($0 ?? -1) < ($1 ?? -1)
                }
                let split = values.split(separator: nil).map(Array.init)
                let byName = Dictionary(uniqueKeysWithValues: [
                    ("missing", values[0]),
                    ("present", values[1]),
                ])
                let byValue = Dictionary(uniqueKeysWithValues: [
                    (values[0], "missing"),
                    (values[1], "present"),
                ])
                return (mapped, retained, sorted, split, byName, byValue)
            }
            """,
            functionName: "contextualOptionalCollections",
            moduleName: "HelixContextualOptionalCollectionsFixture"
        )
        let optionalInteger = Bytecode.ValueType.optional(.int64)
        let nilValue = VM.Value.optional(nil)
        let one = VM.Value.optional(try integer(1))
        let two = VM.Value.optional(try integer(2))
        let three = VM.Value.optional(try integer(3))
        let input = VM.Value.array(
            [nilValue, two, one, nilValue, three],
            elementType: optionalInteger
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [input]
            ) == .returned(.tuple([
                input,
                .array([two, one, three], elementType: optionalInteger),
                .array(
                    [nilValue, nilValue, one, two, three],
                    elementType: optionalInteger
                ),
                .array(
                    [
                        .array([two, one], elementType: optionalInteger),
                        .array([three], elementType: optionalInteger),
                    ],
                    elementType: .array(optionalInteger)
                ),
                .dictionary(
                    [
                        .init(key: .string("missing"), value: nilValue),
                        .init(key: .string("present"), value: two),
                    ],
                    keyType: .string,
                    valueType: optionalInteger
                ),
                .dictionary(
                    [
                        .init(key: nilValue, value: .string("missing")),
                        .init(key: two, value: .string("present")),
                    ],
                    keyType: optionalInteger,
                    valueType: .string
                ),
            ]))
        )
    }

    @Test("Generic indirect results initialize whole Array literal elements")
    func lowersIndirectResultsIntoArrayLiteralStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func indirectOptionalResults(
                _ values: [Int?]
            ) -> ([Int?], [Int??], [Int??]) {
                let dictionary = Dictionary(uniqueKeysWithValues: [
                    ("missing", values[0]),
                    ("present", values[1]),
                ])
                return (
                    [values[0], values[1]],
                    [values.first, values.last],
                    [dictionary["missing"], dictionary["absent"]]
                )
            }
            """,
            functionName: "indirectOptionalResults",
            moduleName: "HelixIndirectOptionalResultsFixture"
        )
        let optionalInteger = Bytecode.ValueType.optional(.int64)
        let nestedOptionalInteger = Bytecode.ValueType.optional(
            optionalInteger
        )
        let nilValue = VM.Value.optional(nil)
        let two = VM.Value.optional(try integer(2))
        let three = VM.Value.optional(try integer(3))
        let input = VM.Value.array(
            [nilValue, two, three],
            elementType: optionalInteger
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [input]
            ) == .returned(.tuple([
                .array([nilValue, two], elementType: optionalInteger),
                .array(
                    [.optional(nilValue), .optional(three)],
                    elementType: nestedOptionalInteger
                ),
                .array(
                    [.optional(nilValue), .optional(nil)],
                    elementType: nestedOptionalInteger
                ),
            ]))
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }
}
}
