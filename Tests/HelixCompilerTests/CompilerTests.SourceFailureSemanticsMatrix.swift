import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift source failure semantics")
struct SourceFailureSemanticsMatrix {
    @Test("Current frontend failure ABIs converge on one classifier")
    func classifiesCurrentFrontendEntryPoints() {
        typealias Intrinsic = CanonicalSIL.SourceFailureIntrinsic
        let cases: [(String, Intrinsic)] = [
            (
                "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF",
                .runtimeAssertion
            ),
            (
                "$ss17_assertionFailure__5flagss5NeverOs12StaticStringV_SSs6UInt32VtF",
                .runtimeAssertionWithoutLocation
            ),
            (
                "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF",
                .runtimeStaticAssertion
            ),
            (
                "$ss18_fatalErrorMessage__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF",
                .runtimeStaticAssertion
            ),
            (
                "$ss16assertionFailure_4file4lineySSyXK_s12StaticStringVSutF",
                .debugAssertion
            ),
            ("swift_unexpectedError", .unexpectedError),
            ("swift_unexpectedErrorTyped", .typedUnexpectedError),
        ]

        for (symbol, expected) in cases {
            #expect(
                CanonicalSIL.SourceFailureIntrinsic(mangledName: symbol)
                    == expected
            )
            #expect(
                CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol)
                    == .sourceFailure(expected)
            )
        }
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName: "$sSq17unsafelyUnwrappedxvg"
            ) == .unsafeOptionalUnwrap
        )
        let emptyMessageSymbols = [
            "$ss12precondition__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_",
            "$ss19preconditionFailure_4file4lines5NeverOSSyXK_s12StaticStringVSutFfA_SSycfu_",
            "$ss10fatalError_4file4lines5NeverOSSyXK_s12StaticStringVSutFfA_SSycfu_",
            "$ss6assert__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_",
            "$ss16assertionFailure_4file4lineySSyXK_s12StaticStringVSutFfA_SSycfu_",
        ]
        for symbol in emptyMessageSymbols {
            #expect(
                CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol)
                    == .defaultValue(.emptyString)
            )
        }
    }

    @Test("Location-free runtime failures use the same represented terminator")
    func lowersLocationFreeRuntimeAssertionABI() throws {
        let symbol =
            "$ss17_assertionFailure__5flagss5NeverOs12StaticStringV_SSs6UInt32VtF"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture15unavailableCodeyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = string_literal utf8 "Fatal error"
              %1 = integer_literal $Builtin.Word, 11
              %2 = builtin "ptrtoint_Word"(%0) : $Builtin.Word
              %3 = integer_literal $Builtin.Int8, 2
              %4 = struct $StaticString (%2, %1, %3)
              %5 = string_literal utf8 "Unavailable code reached"
              %6 = integer_literal $Builtin.Word, 24
              %7 = integer_literal $Builtin.Int1, -1
              %8 = metatype $@thin String.Type
              %9 = function_ref @$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC : $@convention(method) (Builtin.RawPointer, Builtin.Word, Builtin.Int1, @thin String.Type) -> @owned String
              %10 = apply %9(%5, %6, %7, %8) : $@convention(method) (Builtin.RawPointer, Builtin.Word, Builtin.Int1, @thin String.Type) -> @owned String
              %11 = integer_literal $Builtin.Int32, 1
              %12 = struct $UInt32 (%11)
              %13 = function_ref @\(symbol) : $@convention(thin) (StaticString, @guaranteed String, UInt32) -> Never
              %14 = apply %13(%4, %10, %12) : $@convention(thin) (StaticString, @guaranteed String, UInt32) -> Never
              unreachable
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "unavailableCode"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        #expect(instructions.contains { instruction in
            if case .constantString(_, "Unavailable code reached") = instruction {
                return true
            }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .sourceFailure("Fatal error", _) = instruction {
                return true
            }
            return false
        })
        #expect(!instructions.contains { instruction in
            if case .nativeApply = instruction { return true }
            return false
        })
    }

    @Test("Precondition and fatal families preserve dynamic diagnostics")
    func lowersRuntimeAssertions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func checkedFailure(_ value: Int, _ mode: Int) -> Int {
                switch mode {
                case 0:
                    precondition(value >= 0, "precondition \\(value)")
                case 1:
                    guard value >= 0 else {
                        preconditionFailure("failure \\(value)")
                    }
                case 2:
                    guard value >= 0 else { fatalError("fatal \\(value)") }
                case 3:
                    precondition(value >= 0)
                case 4:
                    guard value >= 0 else { preconditionFailure() }
                case 5:
                    guard value >= 0 else { fatalError() }
                default:
                    assert(value >= 0)
                }
                return value * 2
            }
            """,
            functionName: "checkedFailure",
            moduleName: "HelixSourceFailureRuntime"
        )

        for mode in 0...6 {
            #expect(
                invoke(
                    fixture,
                    arguments: [try integer(3), try integer(Int64(mode))]
                ) == .returned(try integer(6))
            )
        }
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(0)]
            ) == .trapped(
                .sourceFailure(
                    prefix: "Precondition failed",
                    detail: "precondition -2"
                )
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(1)]
            ) == .trapped(
                .sourceFailure(prefix: "Fatal error", detail: "failure -2")
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(2)]
            ) == .trapped(
                .sourceFailure(prefix: "Fatal error", detail: "fatal -2")
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(3)]
            ) == .trapped(
                .sourceFailure(prefix: "Precondition failed", detail: "")
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(4)]
            ) == .trapped(
                .sourceFailure(prefix: "Fatal error", detail: "")
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(5)]
            ) == .trapped(
                .sourceFailure(prefix: "Fatal error", detail: "")
            )
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(-2), try integer(6)]
            ) == .trapped(
                .sourceFailure(prefix: "Assertion failed", detail: "")
            )
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("source_failure"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Direct assertionFailure evaluates its autoclosure only on the failing path")
    func lowersDebugAssertionAutoclosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            func assertionMessage(_ value: Int) -> String {
                "assertion \\(value)"
            }
            public func checkedAssertion(
                _ value: Int,
                _ usesDefaultMessage: Bool
            ) -> Int {
                guard value >= 0 else {
                    if usesDefaultMessage {
                        assertionFailure()
                    } else {
                        assertionFailure(assertionMessage(value))
                    }
                    return 99
                }
                return value + 1
            }
            """,
            functionName: "checkedAssertion",
            moduleName: "HelixSourceFailureDebugAssertion"
        )

        #expect(
            invoke(fixture, arguments: [try integer(4), .bool(false)])
                == .returned(try integer(5))
        )
        #expect(
            invoke(fixture, arguments: [try integer(-4), .bool(false)])
                == .trapped(
                    .sourceFailure(
                        prefix: "Assertion failed",
                        detail: "assertion -4"
                    )
                )
        )
        #expect(
            invoke(fixture, arguments: [try integer(-4), .bool(true)])
                == .trapped(
                    .sourceFailure(
                        prefix: "Assertion failed",
                        detail: ""
                    )
                )
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("closure_apply"))
        #expect(disassembly.contains("source_failure"))
        let failureBlocks = fixture.image.module.functions
            .flatMap(\.blocks)
            .filter { block in
                block.instructions.contains { instruction in
                    if case .sourceFailure = instruction { true } else { false }
                }
            }
        #expect(!failureBlocks.isEmpty)
        #expect(
            failureBlocks.allSatisfy { block in
                guard let terminal = block.instructions.last else {
                    return false
                }
                if case .sourceFailure = terminal { return true }
                return false
            }
        )
    }

    @Test("Static frontend diagnostics remain terminal without a native ABI")
    func lowersStaticRuntimeAssertion() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func checkedRange(_ lower: Int, _ upper: Int) -> Int {
                Array(lower..<upper).count
            }
            """,
            functionName: "checkedRange",
            moduleName: "HelixSourceFailureStaticRuntime"
        )

        #expect(
            invoke(
                fixture,
                arguments: [try integer(2), try integer(5)]
            ) == .returned(try integer(3))
        )
        #expect(
            invoke(
                fixture,
                arguments: [try integer(5), try integer(2)]
            ) == .trapped(
                .explicit(
                    "Range requires lowerBound <= upperBound"
                )
            )
        )
        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("Range requires lowerBound <= upperBound"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Dead-block pruning remains limited to terminated source edges")
    func rejectsUnrelatedUnreachableBlocks() {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture6orphanyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = tuple ()
              return %0
            bb1:
              %1 = tuple ()
              return %1
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "orphan"
            )
            Issue.record("unrelated unreachable SIL block was accepted")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(
                error.description.contains(
                    "unrelated unreachable blocks"
                )
            )
        } catch {
            Issue.record("unexpected lowering error: \(error)")
        }
    }

    @Test("try! turns represented Swift errors into a terminal diagnostic")
    func lowersForcedTry() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            enum ForcedFailure: Error { case rejected(Int) }
            func forcedLeaf(_ value: Int) throws -> Int {
                guard value >= 0 else { throw ForcedFailure.rejected(value) }
                return value + 10
            }
            public func forcedTry(_ value: Int) -> Int {
                try! forcedLeaf(value)
            }
            """,
            functionName: "forcedTry",
            moduleName: "HelixSourceFailureForcedTry"
        )

        #expect(
            invoke(fixture, arguments: [try integer(2)])
                == .returned(try integer(12))
        )
        let failed = invoke(fixture, arguments: [try integer(-1)])
        guard case let .trapped(.sourceFailure(prefix, detail)) = failed else {
            Issue.record("try! did not produce a represented source failure: \(failed)")
            return
        }
        #expect(prefix == "try! expression unexpectedly raised an error")
        #expect(detail.hasSuffix("ForcedFailure.rejected"))
    }

    @Test("unsafelyUnwrapped reuses generic Optional projection semantics")
    func lowersUnsafeOptionalUnwrap() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func unsafeValues(
                _ number: Int?,
                _ text: String?
            ) -> (Int, String) {
                (number.unsafelyUnwrapped, text.unsafelyUnwrapped)
            }
            """,
            functionName: "unsafeValues",
            moduleName: "HelixUnsafeOptionalUnwrap"
        )

        #expect(
            invoke(
                fixture,
                arguments: [.optional(try integer(7)), .optional(.string("ok"))]
            ) == .returned(.tuple([try integer(7), .string("ok")]))
        )
        #expect(
            invoke(
                fixture,
                arguments: [.optional(nil), .optional(.string("ok"))]
            ) == .trapped(.optionalUnwrapOfNil)
        )
        #expect(
            invoke(
                fixture,
                arguments: [.optional(try integer(7)), .optional(nil)]
            ) == .trapped(.optionalUnwrapOfNil)
        )

        let disassembly = Bytecode.Disassembler.disassemble(
            fixture.image.module
        )
        #expect(disassembly.contains("optional_unwrap"))
        #expect(!disassembly.contains("native_apply"))
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
        .integer(
            try VM.Integer(signed: value, bitWidth: 64, isSigned: true)
        )
    }
}
}
