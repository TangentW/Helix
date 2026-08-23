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

    @Test("Specialization does not rewrite a qualified nominal with the same leaf name")
    func preservesQualifiedNominalLeafNames() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture9qualified",
            loweredType: "@convention(thin) <Value> "
                + "(Value, Fixture.Value) -> Value",
            body: """
            bb0(%0 : $Value, %1 : $Fixture.Value):
              debug_value %1
              return %0
            """
        )

        let materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Int"
        )

        #expect(materialized.function.loweredType
            == "@convention(thin) (Int, Fixture.Value) -> Int")
        #expect(materialized.function.body.contains("%1 : $Fixture.Value"))
    }

    @Test("Successive generic clauses and numbered archetypes specialize in order")
    func specializesSuccessiveClauses() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture3map",
            loweredType: "@convention(method) <Element><Result> "
                + "(@in_guaranteed Element) -> @out Result",
            body: """
            bb0(%0 : $*Result, %1 : $*Element):
              copy_addr %1 to [init] %0
              return %2
            """
        )
        let witness = CanonicalSIL.Function(
            mangledName: "$sFixture7witness",
            loweredType: "@convention(witness_method: Feature) "
                + "<τ_0_0> (@in_guaranteed τ_0_0) -> @out τ_0_0",
            body: "bb0(%0 : $*τ_0_0, %1 : $*τ_0_0):\n  return %2"
        )

        let materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Int, String"
        )
        let numbered = try CanonicalSIL.GenericFunction.specialize(
            witness,
            arguments: "Bool"
        )

        #expect(materialized.descriptor.arguments == ["Int", "String"])
        #expect(materialized.function.loweredType
            == "@convention(method) (@in_guaranteed Int) -> @out String")
        #expect(materialized.function.body.contains("$*String"))
        #expect(materialized.function.body.contains("$*Int"))
        #expect(numbered.function.loweredType
            == "@convention(witness_method: Feature) (@in_guaranteed Bool) -> @out Bool")
    }

    @Test("Protocol and associated-type requirements require exact concrete evidence")
    func resolvesConcreteRequirements() throws {
        let evidence = """
        struct Number {
          @_hasStorage var value: Int
        }
        sil_witness_table Number: Projecting module Fixture {
          associated_type Output: Int
        }
        sil_witness_table Number: Marker module Fixture {
        }
        """
        let conformances = try CanonicalSIL.ProtocolConformance.Environment(
            text: evidence
        )
        let environment = try CanonicalSIL.TypeEnvironment(
            text: evidence,
            functions: [],
            protocolConformances: conformances
        )
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture7project",
            loweredType: "@convention(thin) "
                + "<Value, Output where Value : Projecting & Marker, "
                + "Value.Output == Output> "
                + "(@in_guaranteed Value) -> @out Value.Output",
            body: """
            bb0(%0 : $*Value.Output, %1 : $*Value):
              copy_addr %1 to [init] %0
              return %2
            """
        )

        let materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: "Number, Int",
            conformances: conformances,
            typeEnvironment: environment
        )
        #expect(materialized.function.loweredType
            == "@convention(thin) (@in_guaranteed Number) -> @out Int")
        #expect(materialized.function.body.contains("$*Int"))
        #expect(!materialized.function.body.contains("Value.Output"))

        for arguments in ["Number, String", "Bool, Int"] {
            #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
                _ = try CanonicalSIL.GenericFunction.specialize(
                    function,
                    arguments: arguments,
                    conformances: conformances,
                    typeEnvironment: environment
                )
            }
        }

        let incompleteEvidence = try CanonicalSIL.ProtocolConformance
            .Environment(
                text: """
                struct Number {
                  @_hasStorage var value: Int
                }
                sil_witness_table Number: Projecting module Fixture {
                  associated_type Output: Int
                  future_requirement #Projecting.project: @future
                }
                """
            )
        let incompleteEnvironment = try CanonicalSIL.TypeEnvironment(
            text: evidence,
            functions: [],
            protocolConformances: incompleteEvidence
        )
        #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
            _ = try CanonicalSIL.GenericFunction.specialize(
                function,
                arguments: "Number, Int",
                conformances: incompleteEvidence,
                typeEnvironment: incompleteEnvironment
            )
        }
    }

    @Test("Represented standard Collections provide closed associated types")
    func resolvesRepresentedStandardCollectionRequirements() throws {
        let evidence = """
        struct Wrapper {
          @_hasStorage var values: Array<Int>
        }
        """
        let conformances = try CanonicalSIL.ProtocolConformance.Environment(
            text: evidence
        )
        let environment = try CanonicalSIL.TypeEnvironment(
            text: evidence,
            functions: [],
            protocolConformances: conformances
        )
        let function = CanonicalSIL.Function(
            mangledName: "$sFixture7element",
            loweredType: "@convention(thin) "
                + "<Value where Value : Collection> "
                + "(@in_guaranteed Value) -> @out Value.Element",
            body: """
            bb0(%0 : $*Value.Element, %1 : $*Value):
              copy_addr %1 to [init] %0
              return %2
            """
        )

        for (argument, element) in [
            ("Array<Int>", "Int"),
            ("ArraySlice<String>", "String"),
            ("String", "Character"),
            ("EnumeratedSequence<Array<Int>>", "(offset:Int,element:Int)"),
            ("Range<Int>", "Int"),
        ] {
            let materialized = try CanonicalSIL.GenericFunction.specialize(
                function,
                arguments: argument,
                conformances: conformances,
                typeEnvironment: environment
            )
            #expect(materialized.function.loweredType.contains("@out \(element)"))
            #expect(!materialized.function.body.contains("Value.Element"))
        }

        for unsupported in [
            "Wrapper",
            "Zip2Sequence<Array<Int>, Array<Int>>",
            "Range<Double>",
        ] {
            #expect(throws: CanonicalSIL.GenericFunction.SpecializationError.self) {
                _ = try CanonicalSIL.GenericFunction.specialize(
                    function,
                    arguments: unsupported,
                    conformances: conformances,
                    typeEnvironment: environment
                )
            }
        }
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

    @Test("Generic signature limits fail before concrete solving")
    func rejectsOversizedGenericSignatures() {
        let parameters = (0...CanonicalSIL.GenericSignature
            .maximumParameterCount).map { "T\($0)" }
        #expect(throws: CanonicalSIL.GenericSignature.ParseError.self) {
            _ = try CanonicalSIL.GenericSignature.standaloneClause(
                "<" + parameters.joined(separator: ", ") + ">"
            )
        }

        let requirements = Array(
            repeating: "T == Int",
            count: CanonicalSIL.GenericSignature.maximumRequirementCount + 1
        )
        #expect(throws: CanonicalSIL.GenericSignature.ParseError.self) {
            _ = try CanonicalSIL.GenericSignature.standaloneClause(
                "<T where " + requirements.joined(separator: ", ") + ">"
            )
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
