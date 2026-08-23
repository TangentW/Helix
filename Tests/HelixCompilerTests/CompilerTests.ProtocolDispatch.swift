import HelixBytecode
import HelixCore
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Concrete Swift protocol dispatch")
struct ProtocolDispatchTests {
    @Test("Generic calls execute getter, static, mutating, and default witnesses")
    func executesConcreteGenericWitnesses() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Scorable {
                var score: Int { get set }
                static func baseline() -> Int
                mutating func increment(by amount: Int)
                func decorated() -> Int
            }

            private extension Scorable {
                func decorated() -> Int {
                    score + Self.baseline()
                }
            }

            private struct Score: Scorable {
                var score: Int

                static func baseline() -> Int { 10 }

                mutating func increment(by amount: Int) {
                    score += amount
                }
            }

            @inline(never)
            private func adjusted<Value: Scorable>(
                _ value: Value,
                by amount: Int
            ) -> Int {
                var copy = value
                copy.score = copy.score + 1
                copy.increment(by: amount)
                return copy.decorated()
            }

            public func concreteProtocolDispatch(_ value: Int) -> Int {
                adjusted(Score(score: value), by: 3)
            }
            """,
            functionName: "concreteProtocolDispatch",
            moduleName: "HelixConcreteProtocolDispatchFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(4)]
            ) == .returned(try integer(18))
        )
        #expect(fixture.image.module.capabilities.contains(
            .compilerSpecializationsV1
        ))
        #expect(fixture.image.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
    }

    @Test("Throwing requirements retain normal and error continuations")
    func executesThrowingWitness() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol CheckedValue {
                func checked() throws -> Int
            }

            private struct Input: CheckedValue {
                var value: Int

                func checked() throws -> Int { value + 1 }
            }

            @inline(never)
            private func read<Value: CheckedValue>(_ value: Value) throws -> Int {
                try value.checked()
            }

            public func throwingConcreteProtocol(_ value: Int) throws -> Int {
                try read(Input(value: value))
            }
            """,
            functionName: "throwingConcreteProtocol",
            moduleName: "HelixThrowingConcreteProtocolFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(8)]
            ) == .returned(try integer(9))
        )
    }

    @Test("Bound protocol methods form ordinary closure values")
    func executesBoundWitnessClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Transforming {
                func transform(_ value: Int) -> Int
            }

            private struct Offset: Transforming {
                var amount: Int

                func transform(_ value: Int) -> Int { value + amount }
            }

            @inline(never)
            private func bind<Value: Transforming>(
                _ value: Value
            ) -> (Int) -> Int {
                value.transform
            }

            public func boundConcreteProtocol(_ value: Int) -> Int {
                bind(Offset(amount: 5))(value)
            }
            """,
            functionName: "boundConcreteProtocol",
            moduleName: "HelixBoundConcreteProtocolFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(7)]
            ) == .returned(try integer(12))
        )
        #expect(fixture.image.module.capabilities.contains(.closureValuesV1))
    }

    @Test("Inherited protocol requirements select the base conformance")
    func executesInheritedWitness() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Valued {
                var value: Int { get }
            }

            private protocol Doubled: Valued {
                func doubled() -> Int
            }

            private extension Doubled {
                func doubled() -> Int { value * 2 }
            }

            private struct Number: Doubled {
                var value: Int
            }

            @inline(never)
            private func read<Value: Doubled>(_ value: Value) -> Int {
                value.doubled() + value.value
            }

            public func inheritedConcreteProtocol(_ value: Int) -> Int {
                read(Number(value: value))
            }
            """,
            functionName: "inheritedConcreteProtocol",
            moduleName: "HelixInheritedConcreteProtocolFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(6)]
            ) == .returned(try integer(18))
        )
    }

    @Test("Class and enum conformers share closed dispatch")
    func executesReferenceAndEnumWitnesses() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Measuring {
                func measure() -> Int
            }

            private final class Reference: Measuring {
                var base: Int

                init(base: Int) { self.base = base }

                func measure() -> Int { base + 1 }
            }

            private enum Choice: Measuring {
                case amount(Int)
                case none

                func measure() -> Int {
                    switch self {
                    case let .amount(value): value * 2
                    case .none: -1
                    }
                }
            }

            @inline(never)
            private func measure<Value: Measuring>(_ value: Value) -> Int {
                value.measure()
            }

            public func classAndEnumProtocol(
                _ value: Int,
                _ hasAmount: Bool
            ) -> Int {
                let choice: Choice = hasAmount ? .amount(value) : .none
                return measure(Reference(base: value)) + measure(choice)
            }
            """,
            functionName: "classAndEnumProtocol",
            moduleName: "HelixClassAndEnumProtocolFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(4), .bool(true)]
            ) == .returned(try integer(13))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(4), .bool(false)]
            ) == .returned(try integer(4))
        )
    }

    @Test("One generic helper keeps conformer-specific witness targets")
    func separatesConcreteConformers() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Applying {
                func apply(to value: Int) -> Int
            }

            private struct Addition: Applying {
                var amount: Int
                func apply(to value: Int) -> Int { value + amount }
            }

            private struct Multiplication: Applying {
                var factor: Int
                func apply(to value: Int) -> Int { value * factor }
            }

            @inline(never)
            private func invoke<Value: Applying>(
                _ operation: Value,
                value: Int
            ) -> Int {
                operation.apply(to: value)
            }

            public func distinctConcreteProtocols(
                _ value: Int,
                _ multiply: Bool
            ) -> Int {
                if multiply {
                    return invoke(Multiplication(factor: 3), value: value)
                }
                return invoke(Addition(amount: 3), value: value)
            }
            """,
            functionName: "distinctConcreteProtocols",
            moduleName: "HelixDistinctConcreteProtocolsFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(5), .bool(false)]
            ) == .returned(try integer(8))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(5), .bool(true)]
            ) == .returned(try integer(15))
        )
    }

    @Test("Static rewriting preserves aliases and specializes call syntax")
    func rewritesAliasedWitnessApplication() throws {
        let witnessType = "<Self where Self : Feature> "
            + "(Self) -> () -> Int"
        let genericFunctionType = "@convention(witness_method: Feature) "
            + "<T where T : Feature> (@in_guaranteed T) -> Int"
        let targetType = "@convention(witness_method: Feature) "
            + "(@in_guaranteed Value) -> Int"
        let targetSymbol = "$s7Fixture5valueSiyFTW"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture6calleryyF",
            loweredType: "@convention(thin) (@in_guaranteed Value) -> Int",
            body: """
            bb0(%0 : $*Value):
              %1 = witness_method $Value, #Feature.value : \(witnessType) : $\(genericFunctionType)
              %2 = copy_value %1
              %3 = apply %2<Value>(%0) : $\(genericFunctionType)
              %4 = partial_apply [callee_guaranteed] %2<Value>(%0) : $\(genericFunctionType)
              %5 = begin_borrow %1
              %6 = move_value %5
              (%7, %8) = begin_apply %6<Value>(%0) : $\(genericFunctionType)
              return %3
            """
        )
        let target = CanonicalSIL.Function(
            mangledName: targetSymbol,
            loweredType: targetType,
            body: "bb0:\n  unreachable"
        )
        let conformances = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              method #Feature.value: \(witnessType) : @\(targetSymbol)
            }
            """
        )

        let rewritten = CanonicalSIL.ProtocolConformance.StaticDispatch.rewrite(
            function,
            conformances: conformances,
            availableFunctions: [target]
        )

        #expect(rewritten.body.contains(
            "%1 = function_ref @\(targetSymbol) : $\(targetType)"
        ))
        #expect(rewritten.body.contains(
            "%3 = apply %2(%0) : $\(targetType)"
        ))
        #expect(rewritten.body.contains(
            "%4 = partial_apply [callee_guaranteed] %2(%0) : $\(targetType)"
        ))
        #expect(rewritten.body.contains(
            "(%7, %8) = begin_apply %6(%0) : $\(targetType)"
        ))
        #expect(!rewritten.body.contains(" = witness_method $"))
        #expect(!rewritten.body.contains("%2<Value>"))
        #expect(!rewritten.body.contains("%6<Value>"))
    }

    @Test("Proven conditional witnesses specialize conformer arguments")
    func rewritesProvenConditionalWitness() throws {
        let requirementType = "<Self where Self : Feature> "
            + "(Self) -> () -> Int"
        let callerType = "@convention(witness_method: Feature) "
            + "<T where T : Feature> (@in_guaranteed T) -> Int"
        let targetType = "@convention(witness_method: Feature) "
            + "<Element where Element : Equatable> "
            + "(@in_guaranteed Box<Element>) -> Int"
        let targetSymbol = "$s7Fixture3BoxV5valueSiyFTW"
        let evidence = """
        struct Box<Element> {
          @_hasStorage var value: Element
        }
        sil_witness_table <Element where Element : Equatable> Box<Element>: Feature module Fixture {
          method #Fixture.Feature.value: \(requirementType) : @\(targetSymbol)
        }
        """
        let conformances = try CanonicalSIL.ProtocolConformance.Environment(
            text: evidence
        )
        let typeEnvironment = try CanonicalSIL.TypeEnvironment(
            text: evidence,
            functions: [],
            protocolConformances: conformances
        )
        let body = """
        bb0(%0 : $*Box<Int>):
          %1 = witness_method $Box<Int>, #Fixture.Feature.value : \(requirementType) : $\(callerType)
          %2 = apply %1<Box<Int>>(%0) : $\(callerType)
          return %2
        """
        let caller = CanonicalSIL.Function(
            mangledName: "$s7Fixture6calleryyF",
            loweredType: "@convention(thin) (@in_guaranteed Box<Int>) -> Int",
            body: body
        )
        let target = CanonicalSIL.Function(
            mangledName: targetSymbol,
            loweredType: targetType,
            body: "bb0:\n  unreachable"
        )

        let rewritten = CanonicalSIL.ProtocolConformance.StaticDispatch.rewrite(
            caller,
            conformances: conformances,
            availableFunctions: [target],
            typeEnvironment: typeEnvironment
        )
        #expect(rewritten.body.contains(
            "%1 = function_ref @\(targetSymbol) : $\(targetType)"
        ))
        #expect(rewritten.body.contains(
            "%2 = apply %1<Int>(%0) : $\(targetType)"
        ))

        let unprovenBody = body.replacingOccurrences(
            of: "Box<Int>",
            with: "Box<(Int, Int)>"
        )
        let unproven = CanonicalSIL.Function(
            mangledName: caller.mangledName,
            loweredType: caller.loweredType.replacingOccurrences(
                of: "Box<Int>",
                with: "Box<(Int, Int)>"
            ),
            body: unprovenBody
        )
        #expect(CanonicalSIL.ProtocolConformance.StaticDispatch.rewrite(
            unproven,
            conformances: conformances,
            availableFunctions: [target],
            typeEnvironment: typeEnvironment
        ).body == unprovenBody)
    }

    @Test("Conditional dispatch uses native type evidence injected after parsing")
    func rewritesConditionalWitnessUsingInjectedNativeTypeKind() throws {
        let requirementType = "<Self where Self : Feature> "
            + "(Self) -> () -> Int"
        let callerType = "@convention(witness_method: Feature) "
            + "<T where T : Feature> (@in_guaranteed T) -> Int"
        let targetType = "@convention(witness_method: Feature) "
            + "<Element where Element : AnyObject> "
            + "(@in_guaranteed Box<Element>) -> Int"
        let callerSymbol = "$s7Fixture6calleryyF"
        let targetSymbol = "$s7Fixture3BoxV5valueSiyFTW"
        let file = try CanonicalSIL.File(text: """
        struct Box<Element> {
          @_hasStorage var value: Element
        }
        sil_witness_table <Element where Element : AnyObject> Box<Element>: Feature module Fixture {
          method #Fixture.Feature.value: \(requirementType) : @\(targetSymbol)
        }
        sil hidden @\(callerSymbol) : $@convention(thin) (@in_guaranteed Box<Fixture.Reference>) -> Int {
        bb0(%0 : $*Box<Fixture.Reference>):
          %1 = witness_method $Box<Fixture.Reference>, #Fixture.Feature.value : \(requirementType) : $\(callerType)
          %2 = apply %1<Box<Fixture.Reference>>(%0) : $\(callerType)
          return %2 : $Int
        } // end sil function '\(callerSymbol)'
        sil private [transparent] @\(targetSymbol) : $\(targetType) {
        bb0:
          unreachable
        } // end sil function '\(targetSymbol)'
        """)
        let caller = try #require(file.function(mangledName: callerSymbol))
        #expect(caller.body.contains(" = witness_method $"))

        let referenceID = Core.TypeID(
            rawValue: .sha256("Fixture.Reference")
        )
        let environment = try file.typeEnvironment.includingNativeTypes(
            ["Fixture.Reference": referenceID],
            kinds: [referenceID: .reference]
        )
        let rewritten = file.rewritingClosedProtocolDispatch(
            in: caller,
            typeEnvironment: environment
        )

        #expect(rewritten.body.contains(
            "%1 = function_ref @\(targetSymbol) : $\(targetType)"
        ))
        #expect(rewritten.body.contains(
            "%2 = apply %1<Fixture.Reference>(%0) : $\(targetType)"
        ))
        #expect(!rewritten.body.contains(" = witness_method $"))
    }

    @Test("Ambiguous textual witness evidence remains dynamic")
    func rejectsAmbiguousStaticResolution() throws {
        let witnessType = "<Self where Self : Feature> "
            + "(Self.Type) -> (Self) -> Self"
        let functionType = "@convention(witness_method: Feature) "
            + "<T where T : Feature> (@in T, @thick T.Type) -> @out T"
        let body = """
        bb0(%0 : $*Value, %1 : $@thick Value.Type):
          %2 = witness_method $Value, #Feature.init!allocator : \(witnessType) : $\(functionType)
          %3 = apply %2<Value>(%0, %1) : $\(functionType)
          return %3
        """
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture6calleryyF",
            loweredType: "@convention(thin) (@in Value) -> @out Value",
            body: body
        )
        let targetType = "@convention(witness_method: Feature) "
            + "(@in Value, @thick Value.Type) -> @out Value"
        let targetSymbols = [
            "$s7Fixture5firstyyFTW",
            "$s7Fixture6secondyyFTW",
        ]
        let targets = targetSymbols.map {
            CanonicalSIL.Function(
                mangledName: $0,
                loweredType: targetType,
                body: "bb0:\n  unreachable"
            )
        }
        let conformances = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              method #Feature.init!allocator: \(witnessType) : @\(targetSymbols[0])
              method #Feature.init!allocator: \(witnessType) : @\(targetSymbols[1])
            }
            """
        )

        let rewritten = CanonicalSIL.ProtocolConformance.StaticDispatch.rewrite(
            function,
            conformances: conformances,
            availableFunctions: targets
        )

        #expect(rewritten.body == body)
        #expect(rewritten.body.contains("witness_method"))
    }

    @Test("Dynamic, unproven, missing, and external evidence stays unresolved")
    func rejectsUnsafeStaticResolutionBoundaries() throws {
        let requirementType = "<Self where Self : Feature> "
            + "(Self) -> () -> Int"
        let functionType = "@convention(witness_method: Feature) "
            + "<T where T : Feature> (@in_guaranteed T) -> Int"
        let body = """
        bb0(%0 : $*Value):
          %1 = witness_method $Value, #Feature.value : \(requirementType) : $\(functionType)
          %2 = apply %1<Value>(%0) : $\(functionType)
          return %2
        """
        let caller = CanonicalSIL.Function(
            mangledName: "$s7Fixture6calleryyF",
            loweredType: "@convention(thin) (@in_guaranteed Value) -> Int",
            body: body
        )
        let targetSymbol = "$s7Fixture5valueSiyFTW"
        var externalTarget = CanonicalSIL.Function(
            mangledName: targetSymbol,
            loweredType: "@convention(witness_method: Feature) "
                + "(@in_guaranteed Value) -> Int",
            body: "bb0:\n  unreachable"
        )
        externalTarget.isExternalDefinition = true

        let conditional = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table <Element where Element : Feature> Value: Feature module Fixture {
              method #Feature.value: \(requirementType) : @\(targetSymbol)
            }
            """
        )
        let external = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              method #Feature.value: \(requirementType) : @\(targetSymbol)
            }
            """
        )
        let missing = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              method #Feature.value: \(requirementType) : nil
            }
            """
        )

        for (environment, targets) in [
            (conditional, [externalTarget]),
            (external, [externalTarget]),
            (missing, []),
        ] {
            let rewritten = CanonicalSIL.ProtocolConformance.StaticDispatch
                .rewrite(
                    caller,
                    conformances: environment,
                    availableFunctions: targets
                )
            #expect(rewritten.body == body)
        }

        let openedBody = """
        bb0(%0 : $*any Feature):
          %1 = witness_method $@opened(ABC, any Feature) Self, #Feature.value : \(requirementType), %0 : $*any Feature : $\(functionType)
          return %0
        """
        let opened = CanonicalSIL.Function(
            mangledName: "$s7Fixture6openedyypF",
            loweredType: "@convention(thin) (@in_guaranteed any Feature) -> ()",
            body: openedBody
        )
        let rewritten = CanonicalSIL.ProtocolConformance.StaticDispatch.rewrite(
            opened,
            conformances: external,
            availableFunctions: [externalTarget]
        )
        #expect(rewritten.body == openedBody)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
