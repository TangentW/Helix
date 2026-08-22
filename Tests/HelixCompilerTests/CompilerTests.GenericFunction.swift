import HelixBytecode
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Concrete generic image functions")
struct GenericFunction {
    @Test("Named generic bodies materialize deterministic concrete closure ABIs")
    func materializesConcreteClosureABI() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture7forwardyxxcxxclF",
            loweredType: "@convention(thin) <Value> "
                + "(@guaranteed @callee_guaranteed "
                + "@substituted <τ_0_0, τ_0_1> "
                + "(@in_guaranteed τ_0_0) -> @out τ_0_1 "
                + "for <Value, Value>) -> @owned @callee_guaranteed "
                + "@substituted <τ_0_0, τ_0_1> "
                + "(@in_guaranteed τ_0_0) -> @out τ_0_1 "
                + "for <Value, Value>",
            body: """
            bb0(%0 : $@callee_guaranteed @substituted <τ_0_0, τ_0_1> (@in_guaranteed τ_0_0) -> @out τ_0_1 for <Value, Value>):
              strong_retain %0
              return %0
            """
        )

        let first = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Int"
        )
        let repeated = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Int"
        )
        let other = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Bool"
        )

        #expect(first.function == repeated.function)
        #expect(first.descriptor == repeated.descriptor)
        #expect(first.function.mangledName.hasPrefix(
            "$hlx_generic_specialization_"
        ))
        #expect(first.function.mangledName != other.function.mangledName)
        #expect(!first.function.loweredType.contains("<Value>"))
        #expect(!first.function.body.contains("Value"))
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            first.function.loweredType
        )
        let closure = Bytecode.ValueType.closure(.init(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        ))
        #expect(signature.parameters == [closure])
        #expect(signature.result == closure)
    }

    @Test("Specialization preserves quoted SIL spellings")
    func preservesQuotedSpellings() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture6quoted",
            loweredType: "@convention(thin) <Value> (Value) -> Value",
            body: """
            bb0(%0 : $Value):
              %1 = string_literal utf8 "Value"
              debug_value %0, name "Value"
              return %0
            """
        )

        let materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Int"
        )

        #expect(materialized.function.body.contains("bb0(%0 : $Int)"))
        #expect(materialized.function.body.contains("utf8 \"Value\""))
        #expect(materialized.function.body.contains("name \"Value\""))
    }

    @Test("Concrete argument parsing preserves nested type syntax")
    func parsesNestedArguments() throws {
        #expect(
            try CanonicalSIL.GenericFunction.arguments(
                in: "(Int, String), Dictionary<String, [Int]>"
            ) == ["(Int, String)", "Dictionary<String, [Int]>"]
        )
        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.arguments(in: "Int, ")
        }
        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.arguments(in: "τ_0_0")
        }
        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.arguments(in: "repeat each Value")
        }
        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.arguments(in: "_")
        }
    }

    @Test("Unsupported declaration parameters fail before textual rewriting")
    func rejectsUnsupportedDeclarationParameters() {
        let pack = CanonicalSIL.Function(
            mangledName: "$sFixture4pack",
            loweredType: "@convention(thin) <each Value> () -> ()",
            body: "bb0:\n  return %0"
        )

        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.specialize(
                pack,
                arguments: "Int"
            )
        }
    }

    @Test("Direct-call tables distinguish specializations by concrete arguments")
    func validatesSpecializedCallVariants() throws {
        let integer = CanonicalSIL.GenericFunction.Specialization(
            arguments: ["Int"],
            concreteLoweredType: "@convention(thin) (Int) -> Int"
        )
        let boolean = CanonicalSIL.GenericFunction.Specialization(
            arguments: ["Bool"],
            concreteLoweredType: "@convention(thin) (Bool) -> Bool"
        )
        let symbol = "$sFixture8identityyxxlF"
        let integerBinding = CanonicalSIL.DirectCallBinding(
            mangledName: symbol,
            parameterTypes: [.int64],
            resultType: .int64,
            target: .function(.init(rawValue: 1)),
            genericSpecialization: integer
        )
        let booleanBinding = CanonicalSIL.DirectCallBinding(
            mangledName: symbol,
            parameterTypes: [.bool],
            resultType: .bool,
            target: .function(.init(rawValue: 2)),
            genericSpecialization: boolean
        )

        let table = try CanonicalSIL.DirectCallTable([
            booleanBinding,
            integerBinding,
        ])
        #expect(table.bindings(for: symbol).count == 2)
        #expect(table.binding(for: symbol) == nil)

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.DirectCallTable([
                integerBinding,
                .init(
                    mangledName: symbol,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    target: .function(.init(rawValue: 3)),
                    genericSpecialization: integer
                ),
            ])
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.DirectCallTable([
                integerBinding,
                .init(
                    mangledName: symbol,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    target: .function(.init(rawValue: 4))
                ),
            ])
        }
    }
}
}
