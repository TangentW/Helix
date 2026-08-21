import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift collection capacity hint semantics")
struct CollectionCapacityHintSemantics {
    @Test("Minimum-capacity constructors are managed collection intrinsics")
    func classifiesMinimumCapacityInitializers() {
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSD15minimumCapacitySDyxq_GSi_tcfC"
            ) == .dictionaryMinimumCapacity
        )
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSh15minimumCapacityShyxGSi_tcfC"
            ) == .setMinimumCapacity
        )
    }

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

    @Test("Minimum-capacity initializers share capacity validation")
    func lowersMinimumCapacityInitializers() throws {
        let dictionary = try FrontendExecutionHarness.compile(
            source: """
            public func dictionaryMinimumCapacity(
                _ capacity: Int
            ) -> [String: Int] {
                var result = Dictionary<String, Int>(
                    minimumCapacity: capacity
                )
                result["seed"] = 1
                return result
            }
            """,
            functionName: "dictionaryMinimumCapacity",
            moduleName: "HelixDictionaryMinimumCapacity"
        )
        let expectedDictionary = VM.Value.dictionary(
            [.init(key: .string("seed"), value: try integer(1))],
            keyType: .string,
            valueType: .int64
        )
        #expect(
            VM.Interpreter().invoke(
                entry: dictionary.entry,
                image: dictionary.image,
                arguments: [try integer(16)]
            ) == .returned(expectedDictionary)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: dictionary.entry,
                image: dictionary.image,
                arguments: [try integer(-1)]
            ) == .trapped(
                .explicit("Dictionary capacity must not be negative")
            )
        )

        let setFixture = try FrontendExecutionHarness.compile(
            source: """
            public func setMinimumCapacity(_ capacity: Int) -> Set<Int> {
                var result = Set<Int>(minimumCapacity: capacity)
                result.insert(7)
                return result
            }
            """,
            functionName: "setMinimumCapacity",
            moduleName: "HelixSetMinimumCapacity"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: setFixture.entry,
                image: setFixture.image,
                arguments: [try integer(.max)]
            ) == .returned(try set([7]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: setFixture.entry,
                image: setFixture.image,
                arguments: [try integer(-1)]
            ) == .trapped(.explicit("Set capacity must not be negative"))
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
