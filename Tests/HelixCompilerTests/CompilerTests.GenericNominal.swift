import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Concrete generic nominals and opaque results")
struct GenericNominalTests {
    @Test("Generic nominal constraints are concretely proven")
    func validatesGenericNominalConstraints() throws {
        let text = """
        struct Pair<First, Second> where First : Equatable, Second == Int {
          @_hasStorage var first: First
          @_hasStorage var second: Int
        }
        """
        let environment = try CanonicalSIL.TypeEnvironment(
            text: text,
            functions: []
        )
        let key = Bytecode.LocalTypeKey(
            rawValue: "Pair<String, Int>"
        )
        #expect(try environment.resolve(key.rawValue) == .local(key))
        let definition = try environment.definition(for: key)
        guard case let .structure(fields) = definition.kind else {
            Issue.record("expected a concrete generic structure")
            return
        }
        #expect(fields.map(\.type) == [.string, .int64])

        for invalid in [
            "Pair<(Int, Int), Int>",
            "Pair<String, Bool>",
        ] {
            #expect(throws: CanonicalSIL.LoweringError.self) {
                _ = try environment.definition(
                    for: .init(rawValue: invalid)
                )
            }
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try environment.resolve("Pair<String, Missing>")
        }

        let referenceEnvironment = try CanonicalSIL.TypeEnvironment(
            text: """
            final class Reference {
            }
            struct ReferenceBox<Value> where Value : AnyObject {
              @_hasStorage var value: Value
            }
            struct ClassBox<Value> where Value : Reference {
              @_hasStorage var value: Value
            }
            """,
            functions: []
        )
        #expect(try referenceEnvironment.definition(
            for: .init(rawValue: "ReferenceBox<Reference>")
        ).key.rawValue == "ReferenceBox<Reference>")
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try referenceEnvironment.definition(
                for: .init(rawValue: "ReferenceBox<Int>")
            )
        }
        #expect(try referenceEnvironment.definition(
            for: .init(rawValue: "ClassBox<Reference>")
        ).key.rawValue == "ClassBox<Reference>")
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try referenceEnvironment.definition(
                for: .init(rawValue: "ClassBox<Int>")
            )
        }
    }

    @Test("Qualified generic nominal identity wins over shorthand")
    func preservesQualifiedGenericNominalIdentity() throws {
        let environment = try CanonicalSIL.TypeEnvironment(
            text: """
            struct Box<Value> {
              @_hasStorage var value: Value
            }
            enum Scope {
              struct Box<Value> {
                @_hasStorage var value: Value
                @_hasStorage var flag: Bool
              }
            }
            """,
            functions: []
        )

        let topLevel = try environment.definition(
            for: .init(rawValue: "Box<Int>")
        )
        let nested = try environment.definition(
            for: .init(rawValue: "Scope.Box<Int>")
        )
        #expect(topLevel.key.rawValue == "Box<Int>")
        #expect(nested.key.rawValue == "Scope.Box<Int>")
        guard case let .structure(topFields) = topLevel.kind,
              case let .structure(nestedFields) = nested.kind else {
            Issue.record("expected concrete generic structures")
            return
        }
        #expect(topFields.map(\.type) == [.int64])
        #expect(nestedFields.map(\.type) == [.int64, .bool])
        #expect(try environment.resolve("Fixture.Scope.Box<Int>")
            == .local(.init(rawValue: "Scope.Box<Int>")))
    }

    @Test("Nested types in generic contexts remain fail-closed")
    func rejectsImplicitOuterArchetypes() throws {
        let environment = try CanonicalSIL.TypeEnvironment(
            text: """
            struct Outer<Element> {
              struct Nested {
                @_hasStorage var value: Element
              }
              @_hasStorage var value: Element
            }
            extension Outer {
              struct ExtensionNested {
                @_hasStorage var value: Element
              }
            }
            """,
            functions: []
        )

        #expect(try environment.resolve("Outer<Int>")
            == .local(.init(rawValue: "Outer<Int>")))
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try environment.resolve("Outer<Int>.Nested")
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try environment.resolve("Outer.ExtensionNested")
        }
    }

    @Test("Generic struct, enum, final class, and instance method stay concrete")
    func executesGenericNominalFamilies() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Box<Element> {
                var value: Element

                func map<Result>(
                    _ transform: (Element) -> Result
                ) -> Box<Result> {
                    Box<Result>(value: transform(value))
                }
            }

            private extension Box where Element == Int {
                func doubled() -> Int { value * 2 }
            }

            private enum Choice<Value> {
                case none
                case some(Value)
            }

            private final class Reference<Value> {
                var value: Value
                init(value: Value) { self.value = value }
            }

            @inline(never)
            private func wrap<Value>(_ value: Value) -> Box<Value> {
                Box(value: value)
            }

            public func concreteGenericNominals(
                _ value: Int,
                _ present: Bool
            ) -> Int {
                let box = wrap(value)
                let mapped = box.map { $0 + 2 }
                let doubled = box.doubled()
                let choice: Choice<Int> = present
                    ? .some(mapped.value) : .none
                let reference = Reference(value: mapped.value + 3)
                switch choice {
                case let .some(item): return item + reference.value + doubled
                case .none: return reference.value + doubled
                }
            }
            """,
            functionName: "concreteGenericNominals",
            moduleName: "HelixConcreteGenericNominalsFixture"
        )

        #expect(try invoke(fixture, [integer(4), .bool(true)]) == integer(23))
        #expect(try invoke(fixture, [integer(4), .bool(false)]) == integer(17))
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "Box<Int>"
        })
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "Choice<Int>"
        })
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "Reference<Int>"
        })
    }

    @Test("Generic local members do not intercept standard-library storage")
    func composesGenericNominalsWithArrayLiterals() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Box<Value> {
                var value: Value
            }

            public func genericBoxArrayLiteral(_ value: Int) -> Int {
                let box = Box(value: value)
                return [box.value, box.value + 1][1]
            }
            """,
            functionName: "genericBoxArrayLiteral",
            moduleName: "HelixGenericBoxArrayLiteralFixture"
        )

        #expect(try invoke(fixture, [integer(9)]) == integer(10))
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "Box<Int>"
        })
    }

    @Test("Associated types flow through a proven conditional conformance")
    func executesConditionalAssociatedTypeWitness() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Projecting<Output> {
                associatedtype Output
                func project() -> Output
            }

            private struct Number: Projecting {
                var value: Int
                func project() -> Int { value + 1 }
            }

            private struct Envelope<Value> {
                var value: Value
            }

            extension Envelope: Projecting where Value: Projecting {
                typealias Output = Value.Output
                func project() -> Value.Output { value.project() }
            }

            @inline(never)
            private func read<Value: Projecting>(
                _ value: Value
            ) -> Value.Output where Value.Output == Int {
                value.project()
            }

            public func conditionalAssociatedWitness(_ value: Int) -> Int {
                read(Envelope(value: Number(value: value)))
            }
            """,
            functionName: "conditionalAssociatedWitness",
            moduleName: "HelixConditionalAssociatedWitnessFixture"
        )

        #expect(try invoke(fixture, [integer(8)]) == integer(9))
        #expect(fixture.image.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
    }

    @Test("A concrete opaque result uses no runtime opaque metadata")
    func executesConcreteOpaqueResult() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Scoring {
                func score() -> Int
            }

            private struct Score: Scoring {
                var value: Int
                func score() -> Int { value + 4 }
            }

            @inline(never)
            private func makeScore(_ value: Int) -> some Scoring {
                Score(value: value)
            }

            public func concreteOpaqueResult(_ value: Int) -> Int {
                makeScore(value).score()
            }
            """,
            functionName: "concreteOpaqueResult",
            moduleName: "HelixConcreteOpaqueResultFixture"
        )

        #expect(try invoke(fixture, [integer(7)]) == integer(11))
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "Score"
        })
    }

    @Test("An opaque parameter is an ordinary constrained specialization")
    func executesOpaqueParameter() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Scoring {
                func score() -> Int
            }

            private struct Score: Scoring {
                var value: Int
                func score() -> Int { value + 2 }
            }

            @inline(never)
            private func read(_ value: some Scoring) -> Int {
                value.score()
            }

            public func opaqueParameter(_ value: Int) -> Int {
                read(Score(value: value))
            }
            """,
            functionName: "opaqueParameter",
            moduleName: "HelixOpaqueParameterFixture"
        )

        #expect(try invoke(fixture, [integer(9)]) == integer(11))
        #expect(fixture.image.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
    }

    @Test("A generic opaque result concretizes after specialization")
    func executesGenericOpaqueResult() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Scoring {
                func score() -> Int
            }

            private struct GenericScore<Value>: Scoring {
                var value: Value
                func score() -> Int { 12 }
            }

            @inline(never)
            private func makeScore<Value>(_ value: Value) -> some Scoring {
                GenericScore(value: value)
            }

            public func genericOpaqueResult(_ value: Int) -> Int {
                makeScore(value).score()
            }
            """,
            functionName: "genericOpaqueResult",
            moduleName: "HelixGenericOpaqueResultFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(12))
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue == "GenericScore<Int>"
        })
    }

    @Test("Multiple opaque results preserve frontend result order")
    func executesMultipleOpaqueResults() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Scoring {
                func score() -> Int
            }

            private struct First: Scoring {
                func score() -> Int { 3 }
            }

            private struct Second: Scoring {
                func score() -> Int { 7 }
            }

            @inline(never)
            private func makeScores() -> (some Scoring, some Scoring) {
                (First(), Second())
            }

            public func multipleOpaqueResults() -> Int {
                let (first, second) = makeScores()
                return first.score() * 10 + second.score()
            }
            """,
            functionName: "multipleOpaqueResults",
            moduleName: "HelixMultipleOpaqueResultsFixture"
        )

        #expect(try invoke(fixture, []) == integer(37))
    }

    @Test("Mismatched opaque identities remain unresolved")
    func rejectsMismatchedOpaqueIdentity() {
        let symbol = "$s7Fixture5makeyQryF"
        let function = CanonicalSIL.Function(
            mangledName: symbol,
            loweredType: "@convention(thin) @substituted <τ_0_0> "
                + "() -> @out τ_0_0 for "
                + "<@_opaqueReturnTypeOf(\"\(symbol)\", 1) __>",
            body: "bb0(%0 : $*Value):\n  return %1"
        )

        #expect(CanonicalSIL.OpaqueResult.concretize(function) == function)

        let genericSymbol = "$s7Fixture11makeGenericyQrxlF"
        let direct = CanonicalSIL.Function(
            mangledName: genericSymbol,
            loweredType: "@convention(thin) <Value> () -> @out "
                + "@_opaqueReturnTypeOf(\"\(genericSymbol)\", 1) __<Value>",
            body: "bb0(%0 : $*Box<Value>):\n  return %1"
        )
        #expect(CanonicalSIL.OpaqueResult.concretize(direct) == direct)

        let unresolvedUnderlying = CanonicalSIL.Function(
            mangledName: genericSymbol,
            loweredType: "@convention(thin) <Value> () -> @out "
                + "@_opaqueReturnTypeOf(\"\(genericSymbol)\", 0) __<Value>",
            body: "bb0(%0 : $*Box<τ_1_0>):\n  return %1"
        )
        #expect(CanonicalSIL.OpaqueResult.concretize(unresolvedUnderlying)
            == unresolvedUnderlying)

        let mismatchedGenericIdentity = CanonicalSIL.Function(
            mangledName: genericSymbol,
            loweredType: "@convention(thin) <Value> () -> @out "
                + "@_opaqueReturnTypeOf(\"\(genericSymbol)\", 0) __<Int>",
            body: "bb0(%0 : $*Box<Value>):\n  return %1"
        )
        #expect(CanonicalSIL.OpaqueResult.concretize(
            mismatchedGenericIdentity
        ) == mismatchedGenericIdentity)
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        _ arguments: [VM.Value]
    ) throws -> VM.Value {
        let outcome = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
        guard case let .returned(value) = outcome else {
            Issue.record("unexpected VM outcome: \(outcome)")
            return try integer(0)
        }
        return try #require(value)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
