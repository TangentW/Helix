import Foundation
import HelixBytecode
import HelixCore
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Concrete substituted function types")
struct SubstitutedFunctionTypes {
    @Test("A concrete substituted SIL ABI resolves without retaining archetypes")
    func resolvesConcreteSubstitution() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) @substituted <τ_0_0, τ_0_1, τ_0_2> "
                + "(@in_guaranteed τ_0_0) -> "
                + "(@out τ_0_2, @error_indirect τ_0_1) "
                + "for <Int, Never, String>"
        )

        #expect(signature.parameters == [.int64])
        #expect(signature.parameterConventions == [.owned])
        #expect(signature.result == .string)
        #expect(signature.hasIndirectResult)
        #expect(!signature.effects.mayThrow)
    }

    @Test("Concrete constrained substitutions discard requirements, not parameters")
    func resolvesConstrainedSubstitution() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) @substituted "
                + "<τ_0_0, τ_0_1, τ_0_2 where τ_0_2 : Error> "
                + "(@in_guaranteed τ_0_0) -> @out Result<τ_0_1, τ_0_2> "
                + "for <Int, String, Never>"
        )

        #expect(signature.parameters == [.int64])
        #expect(
            signature.result == .local(
                .init(rawValue: "Swift.Result<String, Never>")
            )
        )
        #expect(signature.hasIndirectResult)
    }

    @Test("Nested substituted closure parameters retain their throwing contract")
    func resolvesNestedClosureSubstitution() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) (@guaranteed @noescape @callee_guaranteed "
                + "@substituted <τ_0_0> (@in_guaranteed τ_0_0) "
                + "-> (Bool, @error any Error) for <Int>) -> ()"
        )
        let closure = try #require(signature.parameters.first)
        guard case let .closure(closureSignature) = closure else {
            Issue.record("expected a concrete closure parameter")
            return
        }

        #expect(closureSignature.parameters == [.int64])
        #expect(closureSignature.result == .bool)
        #expect(closureSignature.effects.mayThrow)
    }

    @Test("A throwing SIL tuple result keeps every normal component")
    func resolvesThrowingTupleResult() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) (Int, Bool) "
                + "-> (Int, Bool, @error any Error)"
        )

        #expect(signature.parameters == [.int64, .bool])
        #expect(signature.result == .tuple([.int64, .bool]))
        #expect(!signature.hasIndirectResult)
        #expect(signature.indirectErrorType == nil)
        #expect(signature.effects.mayThrow)
    }

    @Test("Indirect tuple and Error results retain both address conventions")
    func resolvesIndirectThrowingTupleResult() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) () "
                + "-> (@out (Int, Bool), @error_indirect any Error)"
        )

        #expect(signature.result == .tuple([.int64, .bool]))
        #expect(signature.hasIndirectResult)
        #expect(signature.indirectErrorType == .string)
        #expect(signature.effects.mayThrow)
    }

    @Test("The SIL error result must be the sole trailing component")
    func rejectsMalformedTupleErrorResults() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) () "
                    + "-> (Int, @error any Error, Bool)"
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) () "
                    + "-> (Int, @error any Error, @error any Error)"
            )
        }
    }

    @Test("Partial or mismatched substitutions fail closed")
    func rejectsIncompleteSubstitutions() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) @substituted <τ_0_0, τ_0_1> "
                    + "(τ_0_0) -> τ_0_1 for <Int>"
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) @substituted <τ_0_0> "
                    + "(τ_0_0) -> τ_0_0 for <τ_1_0>"
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) @substituted <τ_0_0> "
                    + "(τ_0_0) -> τ_0_0 for <(Int, String>"
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) @substituted <τ_0_0 where > "
                    + "(τ_0_0) -> τ_0_0 for <Int>"
            )
        }
    }

    @Test("Concrete closure ABIs preserve borrowed linear parameters")
    func preservesBorrowedLinearClosureConvention() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.Reference"))
        let environment = try CanonicalSIL.TypeEnvironment()
            .includingNativeTypes(["Fixture.Reference": typeID])

        guard case let .closure(borrowed) = try environment.resolve(
            "@callee_guaranteed (@in_guaranteed Fixture.Reference) -> Int"
        ), case let .closure(owned) = try environment.resolve(
            "@callee_guaranteed (@owned Fixture.Reference) -> Int"
        ) else {
            Issue.record("expected concrete closure types")
            return
        }

        #expect(borrowed.parameters == [.native(typeID)])
        #expect(borrowed.parameterConventions == [.borrowed])
        #expect(owned.parameterConventions == [.owned])
    }

    @Test("Concrete closure ABIs preserve inout address parameters")
    func preservesInoutClosureConvention() throws {
        guard case let .closure(signature) = try CanonicalSIL
            .TypeEnvironment().resolve(
                "@callee_guaranteed (@inout (Int, [String]), "
                    + "@in_guaranteed Int) -> @error any Error"
            )
        else {
            Issue.record("expected a concrete inout closure type")
            return
        }

        #expect(signature.parameters == [
            .address(.tuple([.int64, .array(.string)])),
            .int64,
        ])
        #expect(signature.parameterConventions == [.inout, .owned])
        #expect(signature.result == .void)
        #expect(signature.effects.mayThrow)
    }

    @Test("Declaration collection and Optional sugar resolves recursively")
    func resolvesDeclarationTypeSugar() throws {
        let environment = CanonicalSIL.TypeEnvironment()

        #expect(
            try environment.resolve("[String?]")
                == .array(.optional(.string))
        )
        #expect(
            try environment.resolve("[String: [Int?]]")
                == .dictionary(
                    key: .string,
                    value: .array(.optional(.int64))
                )
        )
        #expect(try environment.resolve("String!") == .optional(.string))
        guard case let .closure(returningOptional) = try environment.resolve(
            "@callee_guaranteed (Int) -> String?"
        ) else {
            Issue.record("expected a closure returning Optional<String>")
            return
        }
        #expect(returningOptional.result == .optional(.string))
        guard case let .optional(.closure(optionalClosure)) = try environment
            .resolve("((Int) -> String)?")
        else {
            Issue.record("expected an Optional closure type")
            return
        }
        #expect(optionalClosure.parameters == [.int64])
        #expect(optionalClosure.result == .string)
        #expect(try environment.resolve("(((String)))") == .string)
    }

    @Test("Current Swift map and filter closure ABIs are discovered concretely")
    func discoversCurrentFrontendClosureABIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-substituted-closure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            public func mapped(_ values: [Int]) -> [Int] {
                values.map { $0 + 1 }
            }

            public func filtered(_ values: [Int]) -> [Int] {
                values.filter { $0 > 0 }
            }
            """.utf8
        ).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixSubstitutedClosureFixture",
            optimization: "-Onone",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"],
            purpose: .semanticLowering
        )
        let file = try CanonicalSIL.File(text: sil)
        let closures = file.functions.filter {
            $0.mangledName.contains("cfU_") || $0.mangledName.contains("fU_")
        }
        #expect(closures.count == 2)

        let signatures = try closures.map {
            try CanonicalSIL.ImageFunctions.signature(
                of: $0,
                environment: file.typeEnvironment,
                symbol: $0.mangledName,
                kind: .closureBody
            )
        }
        #expect(signatures.allSatisfy { $0.parameters == [.int64] })
        #expect(signatures.contains {
            $0.result == .int64 && !$0.effects.mayThrow
        })
        #expect(signatures.contains {
            $0.result == .bool && $0.effects.mayThrow
        })
    }

    @Test("Throwing closures preserve their local normal and error control flow")
    func executesThrowingClosureTryApply() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum ProbeError: Error { case rejected }

            @inline(never)
            func applyThrowing(
                _ value: Int,
                _ transform: (Int) throws -> Int
            ) throws -> Int {
                try transform(value)
            }

            public func caughtTransform(_ value: Int) -> Int {
                do {
                    return try applyThrowing(value) { input in
                        if input < 0 { throw ProbeError.rejected }
                        return input + 1
                    }
                } catch {
                    return -1
                }
            }
            """,
            functionName: "caughtTransform",
            moduleName: "HelixThrowingClosureFixture"
        )
        let positive = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(4)]
        )
        let negative = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(-4)]
        )

        #expect(positive == .returned(try integer(5)))
        #expect(negative == .returned(try integer(-1)))
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
