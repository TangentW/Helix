import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift collection capacity hint semantics")
struct CollectionCapacityHintSemantics {
    @Test("Dictionary capacity hints validate their shared precondition")
    func lowersDictionaryCapacityHint() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func dictionaryCapacity(
                _ capacity: Int
            ) -> [String: Int] {
                var result = ["seed": 1]
                result.reserveCapacity(capacity)
                return result
            }
            """,
            functionName: "dictionaryCapacity",
            moduleName: "HelixDictionaryCapacityHint"
        )
        let expected = VM.Value.dictionary(
            [.init(key: .string("seed"), value: try integer(1))],
            keyType: .string,
            valueType: .int64
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(8)]
            ) == .returned(expected)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(.max)]
            ) == .returned(expected)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(-1)]
            ) == .trapped(
                .explicit("Dictionary capacity must not be negative")
            )
        )
    }

    @Test("Set capacity hints preserve values and validate negative bounds")
    func lowersSetCapacityHint() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func setCapacity(_ capacity: Int) -> Set<Int> {
                var result: Set<Int> = [1, 2]
                result.reserveCapacity(capacity)
                return result
            }
            """,
            functionName: "setCapacity",
            moduleName: "HelixSetCapacityHint"
        )
        let expected = try set([1, 2])

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(.max)]
            ) == .returned(expected)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(-1)]
            ) == .trapped(
                .explicit("Set capacity must not be negative")
            )
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func set(_ values: [Int64]) throws -> VM.Value {
        .set(
            .init(
                elements: try values.map(integer),
                elementType: .int64
            )
        )
    }
}
}
