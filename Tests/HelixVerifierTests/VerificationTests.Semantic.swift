import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

enum VerificationTests {}

extension VerificationTests {
@Suite("HLBC semantic verifier")
struct SemanticVerifier {
    @Test("A valid typed entry is accepted")
    func acceptsValidEntry() throws {
        let fixture = try makeFixture()
        let verified = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(verified.module == fixture.module)
        #expect(verified.function(entry: .init(rawValue: 0))?.name == "identity")
    }

    @Test("Shell signatures reject nested patch-local values at construction")
    func rejectsLocalValuesInShellSignatures() throws {
        let fixture = try makeFixture()
        let index = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[index])
        entry.parameterTypes = [
            .optional(.array(.local(.init(rawValue: "Fixture.Local")))),
        ]

        #expect(
            throws: Verification.Error.invalidShellInterface(
                "patch-local nominal, Error, internal storage, and closure values cannot appear in entry 0 signature"
            )
        ) {
            try Verification.ShellInterface(
                interfaceHash: fixture.shell.interfaceHash,
                compatibility: fixture.shell.compatibility,
                capabilities: fixture.shell.capabilities,
                entries: [entry]
            )
        }

        var mutatedShell = fixture.shell
        mutatedShell.entries[index]?.resultType = .error
        #expect(
            throws: Verification.Error.invalidShellInterface(
                "patch-local nominal, Error, internal storage, and closure values cannot appear in entry 0 signature"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: mutatedShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Shell NativeImports require one current logical callback contract")
    func rejectsInconsistentNativeImportSignature() throws {
        let fixture = try makeFixture()
        let callback = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 0, lifetime: .nonescaping),
            ]
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 0),
            key: .init(rawValue: .sha256("invalid-native-signature")),
            parameterTypes: [.closure(callback)],
            resultType: .void,
            signature: .init(parameters: [], result: "Swift.Void"),
            effects: .init(),
            contract: contract
        )

        #expect(
            throws: Verification.Error.invalidShellInterface(
                "native import 0 has inconsistent signature, effects, isolation, or capability"
            )
        ) {
            try Verification.ShellInterface(
                interfaceHash: fixture.shell.interfaceHash,
                compatibility: fixture.shell.compatibility,
                capabilities: fixture.shell.capabilities.union([
                    .nativeImportsV1, .closureValuesV1,
                ]),
                imports: [descriptor]
            )
        }
    }

    @Test("A module for another Shell is rejected")
    func rejectsWrongShell() throws {
        let fixture = try makeFixture()
        var module = fixture.module
        module.shellInterfaceHash = .sha256("another-shell")

        #expect(throws: Verification.Error.shellInterfaceHashMismatch) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Use-before-definition is rejected before execution")
    func rejectsUndefinedRegister() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [.returnValue(.init(rawValue: 1))]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A malformed later callee is rejected without crashing its caller verification")
    func rejectsMalformedLaterCallee() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "malformedCallee",
                parameterRegisters: [.init(rawValue: 99)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 99)],
                        instructions: [.returnValue(.init(rawValue: 99))]
                    ),
                ]
            )
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "callee 1 has a parameter register outside its type table"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

    }

    @Test("A block without a terminator is rejected")
    func rejectsMissingTerminator() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [.constantInteger(result: .init(rawValue: 1), bitPattern: 1)]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("The function entry block has no control-flow predecessors")
    func rejectsBackedgeToEntryBlock() throws {
        let fixture = try makeFixture { function in
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .branch(
                            target: .init(rawValue: 1),
                            arguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .branch(
                            target: .init(rawValue: 0),
                            arguments: [.init(rawValue: 0)]
                        ),
                    ]
                ),
            ]
        }

        #expect(
            throws: Verification.Error.invalidBlock(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                reason: "entry block cannot have predecessors"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Floating arithmetic requires one matching Float width")
    func rejectsMismatchedFloatingOperands() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 32))
            function.registerTypes.append(.float(bitWidth: 64))
            function.registerTypes.append(.float(bitWidth: 32))
            function.blocks[0].instructions = [
                .constantFloat(
                    result: .init(rawValue: 1),
                    bitPattern: UInt64(Float(1).bitPattern)
                ),
                .constantFloat(result: .init(rawValue: 2), bitPattern: Double(2).bitPattern),
                .floatingBinary(
                    result: .init(rawValue: 3),
                    operation: .add,
                    lhs: .init(rawValue: 1),
                    rhs: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "floating binary operands and result must use one float type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Scalar constants must fit their destination bit width")
    func rejectsOversizedScalarBitPatterns() throws {
        let integerFixture = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 8, signed: true))
            function.blocks[0].instructions = [
                .constantInteger(
                    result: .init(rawValue: 1),
                    bitPattern: 0x100
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "integer bit pattern does not fit 8 bits"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(integerFixture.module),
                shell: integerFixture.shell,
                policy: integerFixture.policy
            )
        }

        let floatFixture = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 32))
            function.blocks[0].instructions = [
                .constantFloat(
                    result: .init(rawValue: 1),
                    bitPattern: UInt64(UInt32.max) + 1
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "floating bit pattern does not fit binary32"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(floatFixture.module),
                shell: floatFixture.shell,
                policy: floatFixture.policy
            )
        }
    }

    @Test("UInt64 constants admit the complete fixed-width domain")
    func acceptsUInt64MaximumConstant() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 64, signed: false))
            function.blocks[0].instructions.insert(
                .constantInteger(
                    result: .init(rawValue: 1),
                    bitPattern: .max
                ),
                at: 0
            )
        }
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Scalar type widths are rejected before constant payload validation")
    func rejectsUnsupportedScalarWidthsBeforeConstants() throws {
        let integerFixture = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 1, signed: false))
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "unsupported integer width 1"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(integerFixture.module),
                shell: integerFixture.shell,
                policy: integerFixture.policy
            )
        }

        let floatFixture = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 16))
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), bitPattern: 0),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "unsupported float width 16"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(floatFixture.module),
                shell: floatFixture.shell,
                policy: floatFixture.policy
            )
        }
    }

    @Test("Numeric conversions reject forged widths and signedness")
    func rejectsInvalidNumericConversions() throws {
        let invalidExtension = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 8, signed: true))
            function.blocks[0].instructions = [
                .integerConvert(
                    result: .init(rawValue: 1),
                    operation: .signExtend,
                    value: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "sign extension requires a signed input and wider result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidExtension.module),
                shell: invalidExtension.shell,
                policy: invalidExtension.policy
            )
        }

        let invalidSignedness = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 64))
            function.blocks[0].instructions = [
                .floatingConvert(
                    result: .init(rawValue: 1),
                    operation: .unsignedIntegerToFloat,
                    value: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "unsigned integer-to-float conversion requires an unsigned integer"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidSignedness.module),
                shell: invalidSignedness.shell,
                policy: invalidSignedness.policy
            )
        }
    }

    @Test("Scalar unary operations enforce operation-specific result types")
    func rejectsMalformedScalarUnaryOperations() throws {
        let badPredicate = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.float(bitWidth: 64), .int64])
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), bitPattern: 0),
                .floatingPredicate(
                    result: .init(rawValue: 2),
                    operation: .isFinite,
                    operand: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "floating predicate requires a float operand and Bool result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badPredicate.module),
                shell: badPredicate.shell,
                policy: badPredicate.policy
            )
        }

        let signedMagnitude = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .integerUnary(
                    result: .init(rawValue: 1),
                    operation: .magnitude,
                    operand: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "integer magnitude must produce the same-width unsigned type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(signedMagnitude.module),
                shell: signedMagnitude.shell,
                policy: signedMagnitude.policy
            )
        }

        let mismatchedBitOperation = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 64, signed: false))
            function.blocks[0].instructions = [
                .integerUnary(
                    result: .init(rawValue: 1),
                    operation: .nonzeroBitCount,
                    operand: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "integer bit operation must preserve its operand type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatchedBitOperation.module),
                shell: mismatchedBitOperation.shell,
                policy: mismatchedBitOperation.policy
            )
        }

        let unsignedSignum = try makeFixture { function in
            let unsigned = Bytecode.ValueType.integer(bitWidth: 64, signed: false)
            function.registerTypes.append(contentsOf: [unsigned, unsigned])
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                .integerUnary(
                    result: .init(rawValue: 2),
                    operation: .signum,
                    operand: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "integer signum requires one signed integer type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(unsignedSignum.module),
                shell: unsignedSignum.shell,
                policy: unsignedSignum.policy
            )
        }

        let mismatchedBitcast = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 32))
            function.blocks[0].instructions = [
                .scalarBitCast(
                    result: .init(rawValue: 1),
                    operand: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "scalar bitcast must preserve its storage width"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatchedBitcast.module),
                shell: mismatchedBitcast.shell,
                policy: mismatchedBitcast.policy
            )
        }

        let sameKindBitcast = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .scalarBitCast(
                    result: .init(rawValue: 1),
                    operand: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "scalar bitcast requires one integer and one float"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(sameKindBitcast.module),
                shell: sameKindBitcast.shell,
                policy: sameKindBitcast.policy
            )
        }
    }

    @Test("Select cannot merge values of different verified types")
    func rejectsMismatchedSelectTypes() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.bool, .int64])
            function.blocks[0].instructions = [
                .constantBool(result: .init(rawValue: 1), value: true),
                .select(
                    result: .init(rawValue: 2),
                    condition: .init(rawValue: 1),
                    trueValue: .init(rawValue: 0),
                    falseValue: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 2)),
            ]
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "select requires a Bool condition and matching value types"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("String instructions require their exact operand and result types")
    func rejectsMismatchedStringInstructionTypes() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.string, .string])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "Helix"),
                .stringCount(result: .init(rawValue: 2), string: .init(rawValue: 1)),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.insert(.stringsV1)
        fixture.shell.capabilities.insert(.stringsV1)
        fixture.policy.acceptedCapabilities.insert(.stringsV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "string_count needs a String operand and Int64 result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var invalidTransform = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .stringTransform(
                    result: .init(rawValue: 1),
                    operation: .uppercase,
                    string: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        invalidTransform.module.capabilities.insert(.stringsV1)
        invalidTransform.shell.capabilities.insert(.stringsV1)
        invalidTransform.policy.acceptedCapabilities.insert(.stringsV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "string transform operand and result must both be String"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidTransform.module),
                shell: invalidTransform.shell,
                policy: invalidTransform.policy
            )
        }
    }

    @Test("Scalar text instructions reject forged targets and format operands")
    func rejectsInvalidScalarTextInstructions() throws {
        func enableStrings(_ fixture: inout Fixture) {
            fixture.module.capabilities.insert(.stringsV1)
            fixture.shell.capabilities.insert(.stringsV1)
            fixture.policy.acceptedCapabilities.insert(.stringsV1)
        }

        var invalidTarget = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .string, .optional(.string),
            ])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "1"),
                .scalarFromString(
                    result: .init(rawValue: 2),
                    string: .init(rawValue: 1),
                    radix: nil
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        enableStrings(&invalidTarget)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "scalar_from_string supports only Bool, integer, and floating-point targets"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidTarget.module),
                shell: invalidTarget.shell,
                policy: invalidTarget.policy
            )
        }

        var invalidFloatingRadix = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .string, .optional(.float(bitWidth: 32)),
            ])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "1"),
                .scalarFromString(
                    result: .init(rawValue: 2),
                    string: .init(rawValue: 1),
                    radix: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        enableStrings(&invalidFloatingRadix)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "Bool and floating scalar_from_string cannot carry a radix"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidFloatingRadix.module),
                shell: invalidFloatingRadix.shell,
                policy: invalidFloatingRadix.policy
            )
        }

        var invalidFormatting = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .integerToString(
                    result: .init(rawValue: 1),
                    value: .init(rawValue: 0),
                    radix: .init(rawValue: 0),
                    uppercase: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        enableStrings(&invalidFormatting)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "integer_to_string requires an integer, Int64 radix, Bool case, and String result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidFormatting.module),
                shell: invalidFormatting.shell,
                policy: invalidFormatting.policy
            )
        }
    }

    @Test("Source failures require a bounded prefix and represented diagnostic")
    func rejectsInvalidSourceFailures() throws {
        let invalidDetail = try makeFixture { function in
            function.blocks[0].instructions = [
                .sourceFailure(
                    prefix: "Failure",
                    detail: .init(rawValue: 0)
                ),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "source_failure detail must be String or represented Error"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidDetail.module),
                shell: invalidDetail.shell,
                policy: invalidDetail.policy
            )
        }

        var emptyPrefix = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "detail"),
                .sourceFailure(prefix: "", detail: .init(rawValue: 1)),
            ]
        }
        emptyPrefix.module.capabilities.insert(.stringsV1)
        emptyPrefix.shell.capabilities.insert(.stringsV1)
        emptyPrefix.policy.acceptedCapabilities.insert(.stringsV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "source_failure requires a nonempty prefix"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(emptyPrefix.module),
                shell: emptyPrefix.shell,
                policy: emptyPrefix.policy
            )
        }
    }

    @Test("Source failures accept only Error-conforming local diagnostics")
    func validatesLocalSourceFailureDiagnostics() throws {
        let errorKey = Bytecode.LocalTypeKey(
            rawValue: "Fixture.SourceFailureError"
        )
        var fixture = try makeFixture { function in
            function.registerTypes.append(.local(errorKey))
            function.blocks[0].instructions = [
                .makeEnum(
                    result: .init(rawValue: 1),
                    caseIndex: 0,
                    payload: nil
                ),
                .sourceFailure(
                    prefix: "Forced try failed",
                    detail: .init(rawValue: 1)
                ),
            ]
        }
        fixture.module.localTypes = [
            .init(
                key: errorKey,
                kind: .enumeration(cases: [.init(name: "rejected")]),
                conformsToError: true
            ),
        ]
        fixture.module.capabilities.insert(.localNominalsV1)
        fixture.shell.capabilities.insert(.localNominalsV1)
        fixture.policy.acceptedCapabilities.insert(.localNominalsV1)

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        fixture.module.localTypes[0].conformsToError = false
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "source_failure detail must be String or represented Error"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Text representation primitives enforce types and logical Character shape")
    func rejectsInvalidTextRepresentationInstructions() throws {
        var invalidCharacters = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .string, .array(.int64),
            ])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "Helix"),
                .stringCharacters(
                    result: .init(rawValue: 2),
                    string: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        invalidCharacters.module.capabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])
        invalidCharacters.shell.capabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])
        invalidCharacters.policy.acceptedCapabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "string_characters requires a String and produces Array<String>"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidCharacters.module),
                shell: invalidCharacters.shell,
                policy: invalidCharacters.policy
            )
        }

        var invalidCharacterJoin = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.string), .string, .string,
            ])
            function.blocks[0].instructions = [
                .makeArray(result: .init(rawValue: 1), elements: []),
                .constantString(result: .init(rawValue: 2), value: "|"),
                .stringJoin(
                    result: .init(rawValue: 3),
                    elements: .init(rawValue: 1),
                    separator: .init(rawValue: 2),
                    elementKind: .character
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        invalidCharacterJoin.module.capabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])
        invalidCharacterJoin.shell.capabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])
        invalidCharacterJoin.policy.acceptedCapabilities.formUnion([
            .collectionsV1, .stringsV1,
        ])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "character string_join cannot carry a separator"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidCharacterJoin.module),
                shell: invalidCharacterJoin.shell,
                policy: invalidCharacterJoin.policy
            )
        }
    }

    @Test("String value types cannot be smuggled in without the String capability")
    func rejectsUndeclaredStringCapability() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "Helix"),
                .returnValue(.init(rawValue: 0)),
            ]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array construction cannot smuggle an element of another type")
    func rejectsMismatchedArrayElement() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.array(.int64), .string])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 2), value: "not an Int"),
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 2)]
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "make_array elements must match its Array element type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array update cannot forge an index or replacement element type")
    func rejectsMismatchedArrayUpdate() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.int64), .bool, .string, .array(.int64),
            ])
            function.blocks[0].instructions = [
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0)]
                ),
                .constantBool(result: .init(rawValue: 2), value: true),
                .constantString(result: .init(rawValue: 3), value: "wrong"),
                .arrayUpdate(
                    result: .init(rawValue: 4),
                    array: .init(rawValue: 1),
                    index: .init(rawValue: 2),
                    value: .init(rawValue: 3)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "array_update types do not match Array.Element and Int index"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array structural edits require matching Arrays and Int indices")
    func rejectsMismatchedArrayStructuralEdits() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.int64),
                .array(.bool),
                .bool,
                .int64,
                .array(.int64),
            ])
            function.blocks[0].instructions = [
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0)]
                ),
                .makeArray(result: .init(rawValue: 2), elements: []),
                .constantBool(result: .init(rawValue: 3), value: false),
                .constantInteger(result: .init(rawValue: 4), bitPattern: 0),
                .arrayReplaceSubrange(
                    result: .init(rawValue: 5),
                    array: .init(rawValue: 1),
                    lowerBound: .init(rawValue: 3),
                    upperBound: .init(rawValue: 4),
                    replacement: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "array_replace requires matching Arrays and Int bounds"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        fixture.module.functions[0].registerTypes[2] = .array(.int64)
        fixture.module.functions[0].registerTypes[3] = .int64
        fixture.module.functions[0].blocks[0].instructions[2] =
            .constantInteger(result: .init(rawValue: 3), bitPattern: 0)
        fixture.module.functions[0].registerTypes[4] = .bool
        fixture.module.functions[0].blocks[0].instructions[3] =
            .constantBool(result: .init(rawValue: 4), value: false)
        fixture.module.functions[0].blocks[0].instructions[4] = .arraySwap(
            result: .init(rawValue: 5),
            array: .init(rawValue: 1),
            lhsIndex: .init(rawValue: 3),
            rhsIndex: .init(rawValue: 4)
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "array_swap requires a copyable Array and two Int indices"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array popLast cannot forge either result type")
    func rejectsMismatchedArrayPopLastResults() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.int64), .optional(.int64), .array(.bool),
            ])
            function.blocks[0].instructions = [
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0)]
                ),
                .arrayPopLast(
                    elementResult: .init(rawValue: 2),
                    arrayResult: .init(rawValue: 3),
                    array: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "array_pop_last results must match Array.Element"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array value types require the collection capability")
    func rejectsUndeclaredArrayCapability() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.array(.int64))
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary keys require VM-defined Hashable semantics")
    func rejectsUnsupportedDictionaryKey() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(
                .dictionary(key: .tuple([.int64]), value: .int64)
            )
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary mutation cannot forge its previous-value result")
    func rejectsMismatchedDictionarySetResults() throws {
        var fixture = try makeFixture { function in
            let pair = Bytecode.ValueType.tuple([.string, .int64])
            let dictionary = Bytecode.ValueType.dictionary(key: .string, value: .int64)
            function.registerTypes.append(contentsOf: [
                .array(pair), dictionary, .string, .optional(.string), dictionary,
                .optional(.int64),
            ])
            function.blocks[0].instructions = [
                .makeArray(result: .init(rawValue: 1), elements: []),
                .makeDictionary(
                    result: .init(rawValue: 2),
                    pairs: .init(rawValue: 1)
                ),
                .constantString(result: .init(rawValue: 3), value: "key"),
                .makeOptionalNone(result: .init(rawValue: 6)),
                .dictionarySet(
                    previousValueResult: .init(rawValue: 4),
                    dictionaryResult: .init(rawValue: 5),
                    dictionary: .init(rawValue: 2),
                    key: .init(rawValue: 3),
                    value: .init(rawValue: 6)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "dictionary_set operands and results must match Dictionary types"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary projection cannot forge its selected element type")
    func rejectsMismatchedDictionaryProjection() throws {
        var fixture = try makeFixture { function in
            let pair = Bytecode.ValueType.tuple([.string, .int64])
            let dictionary = Bytecode.ValueType.dictionary(
                key: .string,
                value: .int64
            )
            function.registerTypes.append(contentsOf: [
                .array(pair), dictionary, .array(.int64),
            ])
            function.blocks[0].instructions = [
                .makeArray(result: .init(rawValue: 1), elements: []),
                .makeDictionary(
                    result: .init(rawValue: 2),
                    pairs: .init(rawValue: 1)
                ),
                .dictionaryProject(
                    result: .init(rawValue: 3),
                    dictionary: .init(rawValue: 2),
                    projection: .keys
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "dictionary_project result must match its selected element type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary iteration requires an initialized verified index slot")
    func rejectsUninitializedDictionaryIterator() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.tuple([.string, .int64])),
                .dictionary(key: .string, value: .int64),
                .optional(.tuple([.string, .int64])),
            ])
            function.stackSlotTypes = [.int64]
            function.blocks[0].instructions = [
                .makeArray(result: .init(rawValue: 1), elements: []),
                .makeDictionary(result: .init(rawValue: 2), pairs: .init(rawValue: 1)),
                .collectionNext(
                    result: .init(rawValue: 3),
                    collection: .init(rawValue: 2),
                    indexSlot: .init(rawValue: 0),
                    direction: .forward
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "stack storage $0 is used before initialization"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A duplicate SSA definition is rejected")
    func rejectsDuplicateDefinition() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                .constantInteger(result: .init(rawValue: 1), bitPattern: 2),
                .returnValue(.init(rawValue: 1)),
            ]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Capabilities are intersected with runtime policy")
    func rejectsDeniedCapability() throws {
        let fixture = try makeFixture()
        var module = fixture.module
        module.capabilities.insert(.stringsV1)

        #expect(throws: Verification.Error.capabilityDenied(.stringsV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Capabilities unknown to this Runtime are rejected even if policy lists them")
    func rejectsUnsupportedCapability() throws {
        var fixture = try makeFixture()
        let future: Core.Capability = "future-execution-99"
        fixture.module.capabilities.insert(future)
        fixture.shell.capabilities.insert(future)
        fixture.policy.acceptedCapabilities.insert(future)

        #expect(throws: Verification.Error.unsupportedCapability(future)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Source maps must reference an existing instruction and valid location")
    func rejectsInvalidSourceMap() throws {
        var fixture = try makeFixture()
        fixture.module.sourceMap = [
            .init(
                functionID: .init(rawValue: 0),
                blockID: .init(rawValue: 0),
                instructionOffset: 1,
                location: .init(file: "Sources/Fixture.swift", line: 1, column: 1)
            ),
        ]

        #expect(throws: Verification.Error.invalidSourceMap("instruction offset is outside 0.bb0")) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("copy_value cannot copy a noncopyable frozen native type")
    func rejectsCopyOfNoncopyableNativeType() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnly"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.blocks[0].instructions = [
                .copyValue(result: .init(rawValue: 1), source: .init(rawValue: 0)),
                .destroyValue(.init(rawValue: 0)),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnly",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnly.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A borrowed copyable Native reference can be copied into owned storage")
    func acceptsCopyOfBorrowedNativeReference() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterConventions = [.borrowed]
            function.registerTypes = [.native(typeID), .native(typeID), .int64]
            function.blocks[0].instructions = [
                .copyValue(result: .init(rawValue: 1), source: .init(rawValue: 0)),
                .destroyValue(.init(rawValue: 1)),
                .constantInteger(result: .init(rawValue: 2), bitPattern: 7),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        fixture.module.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.policy.acceptedCapabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID)]
        fixture.shell.entries[entryIndex] = entry

        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(image.module.functions[0].parameterConventions == [.borrowed])
    }

    @Test("Owned native values may remain live across Optional control flow")
    func acceptsOwnedValueCarriedAcrossOptionalSwitch() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterRegisters = [
                .init(rawValue: 0),
                .init(rawValue: 1),
            ]
            function.parameterConventions = [.owned, .owned]
            function.registerTypes = [
                .native(typeID),
                .optional(.int64),
                .int64,
                .int64,
            ]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .switchOptional(
                            optional: .init(rawValue: 1),
                            someTarget: .init(rawValue: 1),
                            noneTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 2)],
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .constantInteger(result: .init(rawValue: 3), bitPattern: 0),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID), .optional(.int64)]
        fixture.shell.entries[entryIndex] = entry

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Owned-value states must agree at a CFG merge")
    func rejectsMismatchedOwnershipAtMerge() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterRegisters = [
                .init(rawValue: 0),
                .init(rawValue: 1),
            ]
            function.parameterConventions = [.owned, .owned]
            function.registerTypes = [.native(typeID), .bool]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .conditionalBranch(
                            condition: .init(rawValue: 1),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [
                        .trap(.explicit("merge should be unreachable")),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID), .bool]
        fixture.shell.entries[entryIndex] = entry

        #expect(
            throws: Verification.Error.invalidBlock(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                reason: "incoming owned-value states disagree"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Linear call arguments transfer ownership instead of minting an alias")
    func rejectsUseAfterLinearCallTransfer() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnly"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .destroyValue(.init(rawValue: 0)),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "forwardMoveOnly",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .native(typeID),
                registerTypes: [.native(typeID)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnly",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnly.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Possible stack initialization must be resolved before exit")
    func rejectsPossibleStackStateAtExit() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.bool)
            function.stackSlotTypes = [.int64]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantBool(result: .init(rawValue: 1), value: true),
                        .conditionalBranch(
                            condition: .init(rawValue: 1),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [.branch(target: .init(rawValue: 3), arguments: [])]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 0,
                reason: "initialized stack slots remain at function exit"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var strictDestroy = fixture.module
        strictDestroy.functions[0].blocks[3].instructions.insert(
            .destroyStack(.init(rawValue: 0)),
            at: 0
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 0,
                reason: "destroy_stack targets uninitialized stack storage"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(strictDestroy),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var conditionalDestroy = fixture.module
        conditionalDestroy.functions[0].blocks[3].instructions.insert(
            .destroyStackIfInitialized(.init(rawValue: 0)),
            at: 0
        )
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(conditionalDestroy),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Replace resolves a maybe-initialized stack state at a CFG merge")
    func validatesConditionalStackReplacement() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.bool, .int64])
            function.stackSlotTypes = [.int64]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantBool(result: .init(rawValue: 1), value: true),
                        .conditionalBranch(
                            condition: .init(rawValue: 1),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .replace
                        ),
                        .loadStack(
                            result: .init(rawValue: 2),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        }

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        for (mode, reason) in [
            (
                Bytecode.StackStoreMode.initialize,
                "store_stack.initialize targets initialized stack storage"
            ),
            (
                Bytecode.StackStoreMode.assign,
                "store_stack.assign targets uninitialized stack storage"
            ),
        ] {
            var invalid = fixture.module
            invalid.functions[0].blocks[3].instructions[0] = .storeStack(
                slot: .init(rawValue: 0),
                source: .init(rawValue: 0),
                mode: mode
            )
            #expect(
                throws: Verification.Error.invalidInstruction(
                    function: .init(rawValue: 0),
                    block: .init(rawValue: 3),
                    offset: 0,
                    reason: reason
                )
            ) {
                try Verification.Engine().verify(
                    bytes: Bytecode.Encoder.encode(invalid),
                    shell: fixture.shell,
                    policy: fixture.policy
                )
            }
        }
    }

    @Test("throw_error requires both a throwing effect and capability")
    func rejectsThrowFromNonthrowingFunction() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "failure"),
                .throwError(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.shell.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.policy.acceptedCapabilities.formUnion([.stringsV1, .untypedThrowsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "throw_error payload does not match the function's thrown type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("switch_optional requires one wrapped payload only on its some edge")
    func rejectsMalformedOptionalSwitchTargets() throws {
        var fixture = try makeFixture { function in
            function.parameterRegisters = [.init(rawValue: 0)]
            function.resultType = .int64
            function.registerTypes = [.optional(.int64), .int64, .int64]
            function.entryBlock = .init(rawValue: 0)
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .switchOptional(
                            optional: .init(rawValue: 0),
                            someTarget: .init(rawValue: 1),
                            noneTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 2), bitPattern: 0),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        }
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.optional(.int64)],
            resultType: .int64,
            effects: entry.effects
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "switch_optional some target must accept the wrapped value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A noncopyable native value cannot be copied out of a stack slot")
    func rejectsStackCopyOfNoncopyableNativeType() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnlyStackValue"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.stackSlotTypes = [.native(typeID)]
            function.blocks[0].instructions = [
                .storeStack(
                    slot: .init(rawValue: 0),
                    source: .init(rawValue: 0),
                    mode: .initialize
                ),
                .loadStack(
                    result: .init(rawValue: 1),
                    slot: .init(rawValue: 0),
                    mode: .copy
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnlyStackValue",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnlyStackValue.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "load_stack.copy requires a copyable slot type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Call effects must be contained by the caller declaration")
    func rejectsUnreportedEntrySideEffects() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .entryApply(
                    result: .init(rawValue: 1),
                    entry: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        let root = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[.init(rawValue: 1)] = .init(
            index: .init(rawValue: 1),
            key: root.key,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(hasExternalSideEffects: true)
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "entry_apply calls an externally side-effecting operation from a pure function"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("try_apply accepts handled throws and rejects malformed error edges")
    func validatesTryApplyControlFlow() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.int64, .string])
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .entryTryApply(
                            entry: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)],
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 1)],
                    instructions: [.returnValue(.init(rawValue: 1))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 2)],
                    instructions: [
                        .destroyValue(.init(rawValue: 2)),
                        .returnValue(.init(rawValue: 0)),
                    ]
                ),
            ]
        }
        let root = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[.init(rawValue: 1)] = .init(
            index: .init(rawValue: 1),
            key: root.key,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(mayThrow: true)
        )
        fixture.module.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.shell.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.policy.acceptedCapabilities.formUnion([.stringsV1, .untypedThrowsV1])

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        fixture.module.functions[0].registerTypes[2] = .int64
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "try_apply error target must accept one untyped String error"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Local nominal tables and enum control flow fail closed")
    func validatesLocalNominalContracts() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Payload")
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.local(key), .int64])
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeEnum(
                            result: .init(rawValue: 1),
                            caseIndex: 0,
                            payload: .init(rawValue: 0)
                        ),
                        .switchEnum(
                            enumeration: .init(rawValue: 1),
                            cases: [
                                .init(caseIndex: 0, target: .init(rawValue: 1)),
                            ],
                            defaultTarget: nil
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 2)],
                    instructions: [.returnValue(.init(rawValue: 2))]
                ),
            ]
        }
        fixture.module.localTypes = [
            .init(
                key: key,
                kind: .enumeration(
                    cases: [.init(name: "value", payloadType: .int64)]
                )
            ),
        ]
        fixture.module.capabilities.insert(.localNominalsV1)
        fixture.shell.capabilities.insert(.localNominalsV1)
        fixture.policy.acceptedCapabilities.insert(.localNominalsV1)

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var wrongPayload = fixture.module
        wrongPayload.localTypes[0].kind = .enumeration(
            cases: [.init(name: "value", payloadType: .bool)]
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_enum payload does not match the local enum case"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongPayload),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var nonexhaustive = fixture.module
        nonexhaustive.localTypes[0].kind = .enumeration(
            cases: [
                .init(name: "value", payloadType: .int64),
                .init(name: "none"),
            ]
        )
        nonexhaustive.functions[0].blocks[0].instructions[1] = .switchEnum(
            enumeration: .init(rawValue: 1),
            cases: [.init(caseIndex: 0, target: .init(rawValue: 1))],
            defaultTarget: nil
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "switch_enum without a default must be exhaustive"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nonexhaustive),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var nativeMember = fixture.module
        nativeMember.localTypes[0].kind = .enumeration(
            cases: [
                .init(
                    name: "value",
                    payloadType: .native(.init(rawValue: .sha256("forged-local-native")))
                ),
            ]
        )
        #expect(
            throws: Verification.Error.invalidModule(
                "HLBC local types cannot contain native values"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nativeMember),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var recursive = fixture.module
        recursive.localTypes[0].kind = .enumeration(
            cases: [.init(name: "next", payloadType: .local(key))]
        )
        #expect(
            throws: Verification.Error.invalidModule(
                "local type graph is recursive at \(key); "
                    + "recursive HLBC local values are unsupported"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(recursive),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        let existentialKey = Bytecode.LocalTypeKey(
            rawValue: "Fixture.ErrorContainer"
        )
        var existentialMember = fixture.module
        existentialMember.localTypes.append(
            .init(
                key: existentialKey,
                kind: .enumeration(
                    cases: [.init(name: "wrapped", payloadType: .error)]
                )
            )
        )
        #expect(throws: Verification.Error.capabilityDenied(.structuredErrorsV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(existentialMember),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
        existentialMember.capabilities.insert(.structuredErrorsV1)
        fixture.shell.capabilities.insert(.structuredErrorsV1)
        fixture.policy.acceptedCapabilities.insert(.structuredErrorsV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(existentialMember),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("A nonescaping closure body with copyable captures is accepted")
    func acceptsClosureContract() throws {
        var fixture = try makeClosureFixture()
        fixture.module.functions[0].registerTypes[1] = .closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.borrowed],
                result: .int64
            )
        )
        fixture.module.functions[1].parameterConventions = [.borrowed, .borrowed]
        fixture.module.capabilities.insert(.borrowCallsV1)
        fixture.shell.capabilities.insert(.borrowCallsV1)
        fixture.policy.acceptedCapabilities.insert(.borrowCallsV1)

        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(image.module.functions[1].kind == .closureBody)
        #expect(image.module.capabilities.contains(.closureValuesV1))
    }

    @Test("A synchronous throwing closure has verified normal and error edges")
    func validatesThrowingClosureControlFlow() throws {
        var fixture = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64,
            effects: .init(mayThrow: true)
        )
        fixture.module.functions[0].registerTypes = [
            .int64,
            .closure(signature),
            .int64,
            .string,
        ]
        fixture.module.functions[0].blocks = [
            .init(
                id: .init(rawValue: 0),
                parameters: [.init(rawValue: 0)],
                instructions: [
                    .makeClosure(
                        result: .init(rawValue: 1),
                        function: .init(rawValue: 1),
                        captures: [.init(rawValue: 0)]
                    ),
                    .closureTryApply(
                        closure: .init(rawValue: 1),
                        arguments: [.init(rawValue: 0)],
                        normalTarget: .init(rawValue: 1),
                        errorTarget: .init(rawValue: 2)
                    ),
                ]
            ),
            .init(
                id: .init(rawValue: 1),
                parameters: [.init(rawValue: 2)],
                instructions: [.returnValue(.init(rawValue: 2))]
            ),
            .init(
                id: .init(rawValue: 2),
                parameters: [.init(rawValue: 3)],
                instructions: [.returnValue(.init(rawValue: 0))]
            ),
        ]
        fixture.module.functions[1].effects = .init(mayThrow: true)
        fixture.module.functions[1].thrownType = .string
        fixture.module.capabilities.formUnion([.untypedThrowsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.untypedThrowsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([
            .untypedThrowsV1, .stringsV1,
        ])

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var nonthrowing = fixture.module
        let nonthrowingSignature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        nonthrowing.functions[0].registerTypes[1] = .closure(
            nonthrowingSignature
        )
        nonthrowing.functions[1].effects = .init()
        nonthrowing.functions[1].thrownType = nil
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "closure_try_apply requires a throwing closure"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nonthrowing),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Typed throwing closures require one exact Error ABI end to end")
    func validatesTypedThrowingClosureABI() throws {
        let typed = try makeTypedThrowingClosureFixture()
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(typed.fixture.module),
            shell: typed.fixture.shell,
            policy: typed.fixture.policy
        )

        var typedRoot = typed.fixture
        typedRoot.module.functions[0].effects.mayThrow = true
        typedRoot.module.functions[0].thrownType = .local(typed.errorKey)
        typedRoot.shell.entries[.init(rawValue: 0)]?.effects.mayThrow = true
        typedRoot.module.capabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        typedRoot.shell.capabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        typedRoot.policy.acceptedCapabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "typed throws cannot cross a Shell entry"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(typedRoot.module),
                shell: typedRoot.shell,
                policy: typedRoot.policy
            )
        }

        var mismatchedDirectPropagation = typed.fixture
        mismatchedDirectPropagation.module.functions[0].effects.mayThrow = true
        mismatchedDirectPropagation.module.functions[0].thrownType = .error
        mismatchedDirectPropagation.module.functions[0].blocks = [
            .init(
                id: .init(rawValue: 0),
                parameters: [.init(rawValue: 0)],
                instructions: [
                    .apply(
                        result: .init(rawValue: 2),
                        function: .init(rawValue: 1),
                        arguments: [
                            .init(rawValue: 0), .init(rawValue: 0),
                        ]
                    ),
                    .returnValue(.init(rawValue: 2)),
                ]
            ),
        ]
        mismatchedDirectPropagation.shell.entries[
            .init(rawValue: 0)
        ]?.effects.mayThrow = true
        mismatchedDirectPropagation.module.capabilities.insert(
            .structuredErrorsV1
        )
        mismatchedDirectPropagation.shell.capabilities.insert(
            .structuredErrorsV1
        )
        mismatchedDirectPropagation.policy.acceptedCapabilities.insert(
            .structuredErrorsV1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "hlbc_apply changes the propagated Error type without a concrete reabstraction"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(
                    mismatchedDirectPropagation.module
                ),
                shell: mismatchedDirectPropagation.shell,
                policy: mismatchedDirectPropagation.policy
            )
        }

        var mismatchedClosurePropagation = typed.fixture
        mismatchedClosurePropagation.module.functions[0].effects.mayThrow = true
        mismatchedClosurePropagation.module.functions[0].thrownType = .error
        mismatchedClosurePropagation.module.functions[0].blocks = [
            .init(
                id: .init(rawValue: 0),
                parameters: [.init(rawValue: 0)],
                instructions: [
                    .makeClosure(
                        result: .init(rawValue: 1),
                        function: .init(rawValue: 1),
                        captures: [.init(rawValue: 0)]
                    ),
                    .closureApply(
                        result: .init(rawValue: 2),
                        closure: .init(rawValue: 1),
                        arguments: [.init(rawValue: 0)]
                    ),
                    .returnValue(.init(rawValue: 2)),
                ]
            ),
        ]
        mismatchedClosurePropagation.shell.entries[
            .init(rawValue: 0)
        ]?.effects.mayThrow = true
        mismatchedClosurePropagation.module.capabilities.insert(
            .structuredErrorsV1
        )
        mismatchedClosurePropagation.shell.capabilities.insert(
            .structuredErrorsV1
        )
        mismatchedClosurePropagation.policy.acceptedCapabilities.insert(
            .structuredErrorsV1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "closure_apply changes the propagated Error type without a concrete reabstraction"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(
                    mismatchedClosurePropagation.module
                ),
                shell: mismatchedClosurePropagation.shell,
                policy: mismatchedClosurePropagation.policy
            )
        }

        var boundaryPropagation = typed.fixture
        boundaryPropagation.module.functions[0].blocks[0].instructions = [
            .tryApply(
                function: .init(rawValue: 1),
                arguments: [.init(rawValue: 0)],
                normalTarget: .init(rawValue: 1),
                errorTarget: .init(rawValue: 2)
            ),
        ]
        boundaryPropagation.module.functions[1] = .init(
            id: .init(rawValue: 1),
            name: "typedBoundaryPropagation",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            thrownType: .local(typed.errorKey),
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .entryApply(
                            result: .init(rawValue: 1),
                            entry: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )
        let rootEntry = try #require(
            boundaryPropagation.shell.entries[.init(rawValue: 0)]
        )
        boundaryPropagation.shell.entries[.init(rawValue: 1)] = .init(
            index: .init(rawValue: 1),
            key: rootEntry.key,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(mayThrow: true)
        )
        boundaryPropagation.module.capabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        boundaryPropagation.shell.capabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        boundaryPropagation.policy.acceptedCapabilities.formUnion([
            .stringsV1, .untypedThrowsV1,
        ])
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "entry_apply cannot propagate a boundary error through a typed-throws function"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(boundaryPropagation.module),
                shell: boundaryPropagation.shell,
                policy: boundaryPropagation.policy
            )
        }

        var missingCapability = typed.fixture
        missingCapability.module.capabilities.remove(.typedThrowsV1)
        missingCapability.shell.capabilities.remove(.typedThrowsV1)
        missingCapability.policy.acceptedCapabilities.remove(.typedThrowsV1)
        #expect(throws: Verification.Error.capabilityDenied(.typedThrowsV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(missingCapability.module),
                shell: missingCapability.shell,
                policy: missingCapability.policy
            )
        }

        var nonErrorNominal = typed.fixture
        nonErrorNominal.module.localTypes[0].conformsToError = false
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure signature has a non-Error thrown type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nonErrorNominal.module),
                shell: nonErrorNominal.shell,
                policy: nonErrorNominal.policy
            )
        }

        var inconsistentSignature = typed.fixture
        if case var .closure(signature) = inconsistentSignature.module
            .functions[0].registerTypes[1] {
            signature.thrownType = nil
            inconsistentSignature.module.functions[0].registerTypes[1] =
                .closure(signature)
        }
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure signature has inconsistent throwing ABI"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(inconsistentSignature.module),
                shell: inconsistentSignature.shell,
                policy: inconsistentSignature.policy
            )
        }

        var mismatchedBody = typed.fixture
        mismatchedBody.module.functions[1].thrownType = .error
        mismatchedBody.module.capabilities.insert(.structuredErrorsV1)
        mismatchedBody.shell.capabilities.insert(.structuredErrorsV1)
        mismatchedBody.policy.acceptedCapabilities.insert(.structuredErrorsV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure body result, thrown type, or callable effects do not match its closure signature"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatchedBody.module),
                shell: mismatchedBody.shell,
                policy: mismatchedBody.policy
            )
        }

        var wrongContinuation = typed.fixture
        wrongContinuation.module.functions[0].registerTypes[3] = .error
        wrongContinuation.module.capabilities.insert(.structuredErrorsV1)
        wrongContinuation.shell.capabilities.insert(.structuredErrorsV1)
        wrongContinuation.policy.acceptedCapabilities.insert(
            .structuredErrorsV1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "try_apply error target does not match the callee's thrown type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongContinuation.module),
                shell: wrongContinuation.shell,
                policy: wrongContinuation.policy
            )
        }

        var wrongPayload = typed.fixture
        wrongPayload.module.functions[1].blocks[0].instructions[1] =
            .throwError(.init(rawValue: 0))
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "throw_error payload does not match the function's thrown type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongPayload.module),
                shell: wrongPayload.shell,
                policy: wrongPayload.policy
            )
        }
    }

    @Test("Mutable closure cells require their capability and exact pointee types")
    func validatesMutableClosureCells() throws {
        let cellType = Bytecode.ValueType.mutableCell(.int64)
        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .int64
        )
        var fixture = try makeFixture { function in
            function.registerTypes = [
                .int64, cellType, .closure(signature), .int64,
            ]
            function.blocks[0].instructions = [
                .makeMutableCell(
                    result: .init(rawValue: 1),
                    initialValue: .init(rawValue: 0)
                ),
                .makeClosure(
                    result: .init(rawValue: 2),
                    function: .init(rawValue: 1),
                    captures: [.init(rawValue: 1)]
                ),
                .closureApply(
                    result: .init(rawValue: 3),
                    closure: .init(rawValue: 2),
                    arguments: []
                ),
                .returnValue(.init(rawValue: 3)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "mutableClosureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [cellType, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .loadMutableCell(
                                result: .init(rawValue: 1),
                                cell: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        fixture.module.capabilities.formUnion([
            .closureValuesV1, .mutableCapturesV1,
        ])
        fixture.shell.capabilities.formUnion([
            .closureValuesV1, .mutableCapturesV1,
        ])
        fixture.policy.acceptedCapabilities.formUnion([
            .closureValuesV1, .mutableCapturesV1,
        ])

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var missingCapability = fixture.module
        missingCapability.capabilities.remove(.mutableCapturesV1)
        #expect(
            throws: Verification.Error.capabilityDenied(.mutableCapturesV1)
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(missingCapability),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var mismatchedPointee = fixture.module
        mismatchedPointee.functions[1].registerTypes[1] = .bool
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "load_mutable_cell result must match a copyable pointee"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatchedPointee),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Mutable cells verify field-sensitive initialization")
    func validatesFieldSensitiveMutableCellInitialization() throws {
        let tupleType = Bytecode.ValueType.tuple([.int64, .int64])
        let tupleCell = Bytecode.ValueType.mutableCell(tupleType)
        let fieldCell = Bytecode.ValueType.mutableCell(.int64)
        var fixture = try makeFixture { function in
            function.registerTypes = [
                .int64, tupleCell, fieldCell, fieldCell, tupleType,
                .int64, .int64,
            ]
            function.blocks[0].instructions = [
                .makeMutableCell(
                    result: .init(rawValue: 1),
                    initialValue: nil
                ),
                .projectMutableCell(
                    result: .init(rawValue: 2),
                    cell: .init(rawValue: 1),
                    fieldIndex: 0
                ),
                .projectMutableCell(
                    result: .init(rawValue: 3),
                    cell: .init(rawValue: 1),
                    fieldIndex: 1
                ),
                .storeMutableCell(
                    cell: .init(rawValue: 2),
                    source: .init(rawValue: 0),
                    mode: .initialize
                ),
                .storeMutableCell(
                    cell: .init(rawValue: 3),
                    source: .init(rawValue: 0),
                    mode: .initialize
                ),
                .loadMutableCell(
                    result: .init(rawValue: 4),
                    cell: .init(rawValue: 1)
                ),
                .unpackTuple(
                    results: [.init(rawValue: 5), .init(rawValue: 6)],
                    tuple: .init(rawValue: 4)
                ),
                .returnValue(.init(rawValue: 5)),
            ]
        }
        fixture.module.capabilities.insert(.mutableCapturesV1)
        fixture.shell.capabilities.insert(.mutableCapturesV1)
        fixture.policy.acceptedCapabilities.insert(.mutableCapturesV1)

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var incomplete = fixture.module
        incomplete.functions[0].blocks[0].instructions.remove(at: 4)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "mutable cell is used before initialization"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(incomplete),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var duplicate = fixture.module
        duplicate.functions[0].blocks[0].instructions.insert(
            .storeMutableCell(
                cell: .init(rawValue: 2),
                source: .init(rawValue: 0),
                mode: .initialize
            ),
            at: 4
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "store_mutable_cell.initialize targets an initialized cell"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(duplicate),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array builders are linear invocation-local implementation values")
    func validatesLinearArrayBuilders() throws {
        let builderType = Bytecode.ValueType.arrayState(
            kind: .builder,
            element: .int64
        )
        var fixture = try makeFixture { function in
            function.resultType = .array(.int64)
            function.registerTypes = [
                .int64, builderType, .array(.int64),
            ]
            function.blocks[0].instructions = [
                .makeArrayBuilder(result: .init(rawValue: 1)),
                .arrayBuilderAppend(
                    builder: .init(rawValue: 1),
                    value: .init(rawValue: 0)
                ),
                .finishArrayBuilder(
                    result: .init(rawValue: 2),
                    builder: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: entry.parameterTypes,
            resultType: .array(.int64),
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var batched = fixture.module
        batched.functions[0].registerTypes.append(.array(.int64))
        batched.functions[0].blocks[0].instructions.insert(
            .makeArray(
                result: .init(rawValue: 3),
                elements: [.init(rawValue: 0)]
            ),
            at: 0
        )
        batched.functions[0].blocks[0].instructions.insert(
            .arrayBuilderAppendContents(
                builder: .init(rawValue: 1),
                array: .init(rawValue: 3)
            ),
            at: 3
        )
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(batched),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var mismatchedBatch = fixture.module
        mismatchedBatch.functions[0].registerTypes.append(.array(.bool))
        mismatchedBatch.functions[0].blocks[0].instructions.insert(
            .makeArray(result: .init(rawValue: 3), elements: []),
            at: 0
        )
        mismatchedBatch.functions[0].blocks[0].instructions.insert(
            .arrayBuilderAppendContents(
                builder: .init(rawValue: 1),
                array: .init(rawValue: 3)
            ),
            at: 2
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "array_builder_append_contents requires a matching copyable Array"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatchedBatch),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var copied = fixture.module
        copied.functions[0].registerTypes.append(builderType)
        copied.functions[0].blocks[0].instructions.insert(
            .copyValue(
                result: .init(rawValue: 3),
                source: .init(rawValue: 1)
            ),
            at: 1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "copy_value requires a copyable type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(copied),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var unfinished = fixture.module
        unfinished.functions[0].blocks[0].instructions = [
            .makeArrayBuilder(result: .init(rawValue: 1)),
            .makeArray(result: .init(rawValue: 2), elements: []),
            .returnValue(.init(rawValue: 2)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "owned values remain live at return"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(unfinished),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var finishedTwice = fixture.module
        finishedTwice.functions[0].registerTypes.append(.array(.int64))
        finishedTwice.functions[0].blocks[0].instructions.insert(
            .finishArrayBuilder(
                result: .init(rawValue: 3),
                builder: .init(rawValue: 1)
            ),
            at: 3
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(finishedTwice),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var parameter = fixture.module
        parameter.functions[0].parameterRegisters = [.init(rawValue: 1)]
        parameter.functions[0].parameterConventions = [.owned]
        parameter.functions[0].blocks[0].parameters = [.init(rawValue: 1)]
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(parameter),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary builders are typed, linear, and invocation-local")
    func validatesLinearDictionaryBuilders() throws {
        let pairType = Bytecode.ValueType.tuple([.int64, .int64])
        let dictionaryType = Bytecode.ValueType.dictionary(
            key: .int64,
            value: .int64
        )
        let builderType = Bytecode.ValueType.dictionaryState(
            key: .int64,
            value: .int64
        )
        var fixture = try makeFixture { function in
            function.resultType = dictionaryType
            function.registerTypes = [
                .int64,
                pairType,
                .array(pairType),
                dictionaryType,
                builderType,
                .optional(.int64),
                dictionaryType,
            ]
            function.blocks[0].instructions = [
                .makeTuple(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0), .init(rawValue: 0)]
                ),
                .makeArray(
                    result: .init(rawValue: 2),
                    elements: [.init(rawValue: 1)]
                ),
                .makeDictionary(
                    result: .init(rawValue: 3),
                    pairs: .init(rawValue: 2)
                ),
                .makeDictionaryBuilder(
                    result: .init(rawValue: 4),
                    initialValue: .init(rawValue: 3)
                ),
                .dictionaryBuilderGet(
                    result: .init(rawValue: 5),
                    builder: .init(rawValue: 4),
                    key: .init(rawValue: 0)
                ),
                .dictionaryBuilderSet(
                    builder: .init(rawValue: 4),
                    key: .init(rawValue: 0),
                    value: .init(rawValue: 0)
                ),
                .finishDictionaryBuilder(
                    result: .init(rawValue: 6),
                    builder: .init(rawValue: 4)
                ),
                .returnValue(.init(rawValue: 6)),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: entry.parameterTypes,
            resultType: dictionaryType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        let groupedDictionaryType = Bytecode.ValueType.dictionary(
            key: .int64,
            value: .array(.int64)
        )
        let groupedBuilderType = Bytecode.ValueType.dictionaryState(
            key: .int64,
            value: .array(.int64)
        )
        var grouped = try makeFixture { function in
            function.resultType = groupedDictionaryType
            function.registerTypes = [
                .int64,
                groupedBuilderType,
                groupedDictionaryType,
            ]
            function.blocks[0].instructions = [
                .makeDictionaryBuilder(
                    result: .init(rawValue: 1),
                    initialValue: nil
                ),
                .dictionaryBuilderAppendArrayElement(
                    builder: .init(rawValue: 1),
                    key: .init(rawValue: 0),
                    element: .init(rawValue: 0)
                ),
                .finishDictionaryBuilder(
                    result: .init(rawValue: 2),
                    builder: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        grouped.module.capabilities.insert(.collectionsV1)
        grouped.shell.capabilities.insert(.collectionsV1)
        grouped.policy.acceptedCapabilities.insert(.collectionsV1)
        let groupedEntry = try #require(
            grouped.shell.entries[.init(rawValue: 0)]
        )
        grouped.shell.entries[groupedEntry.index] = .init(
            index: groupedEntry.index,
            key: groupedEntry.key,
            parameterTypes: groupedEntry.parameterTypes,
            resultType: groupedDictionaryType,
            effects: groupedEntry.effects
        )
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(grouped.module),
            shell: grouped.shell,
            policy: grouped.policy
        )

        var invalidGrouped = grouped.module
        invalidGrouped.functions[0].registerTypes[1] = builderType
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidGrouped),
                shell: grouped.shell,
                policy: grouped.policy
            )
        }

        var copied = fixture.module
        copied.functions[0].registerTypes.append(builderType)
        copied.functions[0].blocks[0].instructions.insert(
            .copyValue(
                result: .init(rawValue: 7),
                source: .init(rawValue: 4)
            ),
            at: 4
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "copy_value requires a copyable type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(copied),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var unfinished = fixture.module
        unfinished.functions[0].blocks[0].instructions = Array(
            unfinished.functions[0].blocks[0].instructions.prefix(4)
        ) + [.returnValue(.init(rawValue: 3))]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "owned values remain live at return"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(unfinished),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var finishedTwice = fixture.module
        finishedTwice.functions[0].registerTypes.append(dictionaryType)
        finishedTwice.functions[0].blocks[0].instructions.insert(
            .finishDictionaryBuilder(
                result: .init(rawValue: 7),
                builder: .init(rawValue: 4)
            ),
            at: 7
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 7,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(finishedTwice),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var parameter = fixture.module
        parameter.functions[0].parameterRegisters = [.init(rawValue: 4)]
        parameter.functions[0].parameterConventions = [.owned]
        parameter.functions[0].blocks[0].parameters = [.init(rawValue: 4)]
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(parameter),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array mutation state is typed, linear, and invocation-local")
    func validatesLinearArrayMutationState() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let stateType = Bytecode.ValueType.arrayState(
            kind: .mutation,
            element: .int64
        )
        var fixture = try makeFixture { function in
            function.resultType = arrayType
            function.registerTypes = [
                .int64,
                arrayType,
                stateType,
                .int64,
                arrayType,
            ]
            function.blocks[0].instructions = [
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0)]
                ),
                .makeArrayMutationState(
                    result: .init(rawValue: 2),
                    array: .init(rawValue: 1)
                ),
                .arrayMutationGet(
                    result: .init(rawValue: 3),
                    state: .init(rawValue: 2),
                    index: .init(rawValue: 0)
                ),
                .arrayMutationSwap(
                    state: .init(rawValue: 2),
                    lhsIndex: .init(rawValue: 0),
                    rhsIndex: .init(rawValue: 0)
                ),
                .finishArrayMutation(
                    result: .init(rawValue: 4),
                    state: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 4)),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: entry.parameterTypes,
            resultType: arrayType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var wrongKind = fixture.module
        wrongKind.functions[0].registerTypes[2] = .arrayState(
            kind: .stableSort,
            element: .int64
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "make_array_mutation_state requires a matching copyable Array"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongKind),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var wrongElement = fixture.module
        wrongElement.functions[0].registerTypes[3] = .bool
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "array_mutation_get requires its matching state, element, and Int index"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongElement),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var copied = fixture.module
        copied.functions[0].registerTypes.append(stateType)
        copied.functions[0].blocks[0].instructions.insert(
            .copyValue(
                result: .init(rawValue: 5),
                source: .init(rawValue: 2)
            ),
            at: 2
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "copy_value requires a copyable type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(copied),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var leaked = fixture.module
        leaked.functions[0].blocks[0].instructions = [
            .makeArray(
                result: .init(rawValue: 1),
                elements: [.init(rawValue: 0)]
            ),
            .makeArrayMutationState(
                result: .init(rawValue: 2),
                array: .init(rawValue: 1)
            ),
            .makeArray(result: .init(rawValue: 4), elements: []),
            .returnValue(.init(rawValue: 4)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "owned values remain live at return"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(leaked),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var finishedTwice = fixture.module
        finishedTwice.functions[0].registerTypes.append(arrayType)
        finishedTwice.functions[0].blocks[0].instructions.insert(
            .finishArrayMutation(
                result: .init(rawValue: 5),
                state: .init(rawValue: 2)
            ),
            at: 5
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 5,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(finishedTwice),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var noCapability = fixture
        noCapability.module.capabilities.remove(.collectionsV1)
        noCapability.shell.capabilities.remove(.collectionsV1)
        noCapability.policy.acceptedCapabilities.remove(.collectionsV1)
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(noCapability.module),
                shell: noCapability.shell,
                policy: noCapability.policy
            )
        }

        var boundaryShell = fixture.shell
        boundaryShell.entries[entry.index]?.parameterTypes = [stateType]
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: boundaryShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array sort state is typed, linear, and invocation-local")
    func validatesLinearArraySortState() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let stateType = Bytecode.ValueType.arrayState(
            kind: .stableSort,
            element: .int64
        )
        let pairType = Bytecode.ValueType.tuple([.int64, .int64])
        var fixture = try makeFixture { function in
            function.resultType = arrayType
            function.registerTypes = [
                .int64,
                arrayType,
                stateType,
                .optional(pairType),
                pairType,
                .int64,
                .int64,
                .bool,
                arrayType,
            ]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeArray(
                            result: .init(rawValue: 1),
                            elements: [.init(rawValue: 0)]
                        ),
                        .makeArraySortState(
                            result: .init(rawValue: 2),
                            array: .init(rawValue: 1)
                        ),
                        .branch(target: .init(rawValue: 1), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .arraySortNextComparison(
                            result: .init(rawValue: 3),
                            state: .init(rawValue: 2)
                        ),
                        .switchOptional(
                            optional: .init(rawValue: 3),
                            someTarget: .init(rawValue: 2),
                            noneTarget: .init(rawValue: 3)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [
                        .unpackTuple(
                            results: [
                                .init(rawValue: 5),
                                .init(rawValue: 6),
                            ],
                            tuple: .init(rawValue: 4)
                        ),
                        .compare(
                            result: .init(rawValue: 7),
                            predicate: .lessThan,
                            lhs: .init(rawValue: 5),
                            rhs: .init(rawValue: 6)
                        ),
                        .arraySortAcceptComparison(
                            state: .init(rawValue: 2),
                            rightPrecedesLeft: .init(rawValue: 7)
                        ),
                        .branch(target: .init(rawValue: 1), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [
                        .finishArraySort(
                            result: .init(rawValue: 8),
                            state: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 8)),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: entry.parameterTypes,
            resultType: arrayType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var copied = fixture.module
        copied.functions[0].registerTypes.append(stateType)
        copied.functions[0].blocks[0].instructions.insert(
            .copyValue(
                result: .init(rawValue: 9),
                source: .init(rawValue: 2)
            ),
            at: 2
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "copy_value requires a copyable type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(copied),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var mismatched = fixture.module
        mismatched.functions[0].registerTypes[3] = .optional(
            .tuple([.bool, .int64])
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 1),
                offset: 0,
                reason: "array_sort_next_comparison requires its matching state"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatched),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var leaked = fixture.module
        leaked.functions[0].blocks[3].instructions = [
            .makeArray(result: .init(rawValue: 8), elements: []),
            .returnValue(.init(rawValue: 8)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 1,
                reason: "owned values remain live at return"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(leaked),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var finishedTwice = fixture.module
        finishedTwice.functions[0].registerTypes.append(arrayType)
        finishedTwice.functions[0].blocks[3].instructions.insert(
            .finishArraySort(
                result: .init(rawValue: 9),
                state: .init(rawValue: 2)
            ),
            at: 1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 1,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(finishedTwice),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var noCapability = fixture
        noCapability.module.capabilities.remove(.collectionsV1)
        noCapability.shell.capabilities.remove(.collectionsV1)
        noCapability.policy.acceptedCapabilities.remove(.collectionsV1)
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(noCapability.module),
                shell: noCapability.shell,
                policy: noCapability.policy
            )
        }

        var boundaryShell = fixture.shell
        boundaryShell.entries[entry.index]?.parameterTypes = [stateType]
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: boundaryShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array split state is kind-safe, linear, and invocation-local")
    func validatesLinearArraySplitState() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let resultType = Bytecode.ValueType.array(arrayType)
        let stateType = Bytecode.ValueType.arrayState(
            kind: .split,
            element: .int64
        )
        var fixture = try makeFixture { function in
            function.resultType = resultType
            function.registerTypes = [
                .int64,
                arrayType,
                .int64,
                .bool,
                stateType,
                .optional(.int64),
                .int64,
                resultType,
            ]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeArray(
                            result: .init(rawValue: 1),
                            elements: [.init(rawValue: 0)]
                        ),
                        .constantInteger(
                            result: .init(rawValue: 2),
                            bitPattern: 1
                        ),
                        .constantBool(
                            result: .init(rawValue: 3),
                            value: true
                        ),
                        .makeArraySplitState(
                            result: .init(rawValue: 4),
                            array: .init(rawValue: 1),
                            maxSplits: .init(rawValue: 2),
                            omittingEmptySubsequences: .init(rawValue: 3)
                        ),
                        .branch(target: .init(rawValue: 1), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .arraySplitNextElement(
                            result: .init(rawValue: 5),
                            state: .init(rawValue: 4)
                        ),
                        .switchOptional(
                            optional: .init(rawValue: 5),
                            someTarget: .init(rawValue: 2),
                            noneTarget: .init(rawValue: 3)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 6)],
                    instructions: [
                        .arraySplitAcceptElement(
                            state: .init(rawValue: 4),
                            isSeparator: .init(rawValue: 3)
                        ),
                        .branch(target: .init(rawValue: 1), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [
                        .finishArraySplit(
                            result: .init(rawValue: 7),
                            state: .init(rawValue: 4)
                        ),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: entry.parameterTypes,
            resultType: resultType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var wrongKind = fixture.module
        wrongKind.functions[0].registerTypes[4] = .arrayState(
            kind: .stableSort,
            element: .int64
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "make_array_split_state requires a matching copyable Array, Int maximum, and Bool omission flag"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongKind),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var wrongNext = fixture.module
        wrongNext.functions[0].registerTypes[5] = .optional(.bool)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 1),
                offset: 0,
                reason: "array_split_next_element requires its matching split state"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongNext),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var copied = fixture.module
        copied.functions[0].registerTypes.append(stateType)
        copied.functions[0].blocks[0].instructions.insert(
            .copyValue(
                result: .init(rawValue: 8),
                source: .init(rawValue: 4)
            ),
            at: 4
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "copy_value requires a copyable type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(copied),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var leaked = fixture.module
        leaked.functions[0].blocks[3].instructions = [
            .makeArray(result: .init(rawValue: 7), elements: []),
            .returnValue(.init(rawValue: 7)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 1,
                reason: "owned values remain live at return"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(leaked),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var finishedTwice = fixture.module
        finishedTwice.functions[0].registerTypes.append(resultType)
        finishedTwice.functions[0].blocks[3].instructions.insert(
            .finishArraySplit(
                result: .init(rawValue: 8),
                state: .init(rawValue: 4)
            ),
            at: 1
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                offset: 1,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(finishedTwice),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var noCapability = fixture
        noCapability.module.capabilities.remove(.collectionsV1)
        noCapability.shell.capabilities.remove(.collectionsV1)
        noCapability.policy.acceptedCapabilities.remove(.collectionsV1)
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(noCapability.module),
                shell: noCapability.shell,
                policy: noCapability.policy
            )
        }

        var boundaryShell = fixture.shell
        boundaryShell.entries[entry.index]?.parameterTypes = [stateType]
        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: boundaryShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Borrowed closure ownership is explicit and exact")
    func validatesBorrowedLinearClosureParameter() throws {
        var fixture = try makeFixture { _ in }
        let typeID = Core.TypeID.derive(
            namespace: .derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        let signature = Bytecode.ClosureSignature(
            parameters: [.native(typeID)],
            parameterConventions: [.borrowed],
            result: .int64
        )
        fixture.module.functions[0].registerTypes = [
            .native(typeID), .closure(signature), .int64,
        ]
        fixture.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: []
            ),
            .closureApply(
                result: .init(rawValue: 2),
                closure: .init(rawValue: 1),
                arguments: [.init(rawValue: 0)]
            ),
            .destroyValue(.init(rawValue: 0)),
            .returnValue(.init(rawValue: 2)),
        ]
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "borrowedNativeClosureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0)],
                parameterConventions: [.borrowed],
                resultType: .int64,
                registerTypes: [.native(typeID), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 1),
                                bitPattern: 1
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        let capabilities: Set<Core.Capability> = [
            .borrowCallsV1, .closureValuesV1, .nativeTypesV1,
        ]
        fixture.module.capabilities.formUnion(capabilities)
        fixture.shell.capabilities.formUnion(capabilities)
        fixture.policy.acceptedCapabilities.formUnion(capabilities)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entry = try #require(
            fixture.shell.entries[.init(rawValue: 0)]
        )
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: entry.resultType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var mismatched = fixture.module
        mismatched.functions[0].registerTypes[1] = .closure(
            .init(
                parameters: [.native(typeID)],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure body invocation ownership does not match its closure signature"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(mismatched),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Copyable linear captures require a borrowed closure-capture ABI")
    func validatesBorrowedLinearClosureCapture() throws {
        var fixture = try makeFixture { _ in }
        let typeID = Core.TypeID.derive(
            namespace: .derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "linear-capture"
            ),
            canonicalType: "Fixture.CapturedReference"
        )
        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .int64
        )
        fixture.module.functions[0].registerTypes = [
            .native(typeID), .closure(signature), .int64,
        ]
        fixture.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            .closureApply(
                result: .init(rawValue: 2),
                closure: .init(rawValue: 1),
                arguments: []
            ),
            .destroyValue(.init(rawValue: 0)),
            .returnValue(.init(rawValue: 2)),
        ]
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "borrowedNativeCaptureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0)],
                parameterConventions: [.borrowed],
                resultType: .int64,
                registerTypes: [.native(typeID), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 1),
                                bitPattern: 1
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        let capabilities: Set<Core.Capability> = [
            .borrowCallsV1, .closureValuesV1, .nativeTypesV1,
        ]
        fixture.module.capabilities.formUnion(capabilities)
        fixture.shell.capabilities.formUnion(capabilities)
        fixture.policy.acceptedCapabilities.formUnion(capabilities)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.CapturedReference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.CapturedReference.layout"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entry = try #require(
            fixture.shell.entries[.init(rawValue: 0)]
        )
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: entry.resultType,
            effects: entry.effects
        )

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var consuming = fixture.module
        consuming.functions[1].parameterConventions = [.owned]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "linear closure captures require a borrowed capture ABI"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(consuming),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var noncopyableShell = fixture.shell
        noncopyableShell.types[typeID]?.isCopyable = false
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure captures must be copyable"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: noncopyableShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Closure construction requires an exact closure-body contract")
    func rejectsMalformedClosureBodyContract() throws {
        var wrongKind = try makeClosureFixture()
        wrongKind.module.functions[1].kind = .ordinary
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_closure target must be a closure body"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongKind.module),
                shell: wrongKind.shell,
                policy: wrongKind.policy
            )
        }

        var wrongCapture = try makeClosureFixture()
        wrongCapture.module.functions[1].registerTypes[1] = .bool
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure body parameters must equal invocation parameters followed by captures"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongCapture.module),
                shell: wrongCapture.shell,
                policy: wrongCapture.policy
            )
        }
    }

    @Test("Closure bodies permit static calls and internal closure returns require capability")
    func validatesClosureEscapeAndDirectCall() throws {
        var directCall = try makeClosureFixture()
        directCall.module.functions[0].blocks[0].instructions = [
            .apply(
                result: .init(rawValue: 2),
                function: .init(rawValue: 1),
                arguments: [.init(rawValue: 0), .init(rawValue: 0)]
            ),
            .returnValue(.init(rawValue: 2)),
        ]
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(directCall.module),
            shell: directCall.shell,
            policy: directCall.policy
        )

        var escaping = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        escaping.module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "escapingClosure",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .closure(signature),
                registerTypes: [.int64, .closure(signature)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .makeClosure(
                                result: .init(rawValue: 1),
                                function: .init(rawValue: 1),
                                captures: [.init(rawValue: 0)]
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        #expect(
            throws: Verification.Error.capabilityDenied(.escapingClosureValuesV1)
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(escaping.module),
                shell: escaping.shell,
                policy: escaping.policy
            )
        }
        escaping.module.capabilities.insert(.escapingClosureValuesV1)
        escaping.shell.capabilities.insert(.escapingClosureValuesV1)
        escaping.policy.acceptedCapabilities.insert(.escapingClosureValuesV1)
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(escaping.module),
            shell: escaping.shell,
            policy: escaping.policy
        )
        #expect(image.module.functions[2].resultType == .closure(signature))
    }

    @Test("Closure construction gates target authority outside its callable type")
    func validatesClosureTargetAuthority() throws {
        let formal = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .int64
        )
        let authority = Core.Effects(
            mayAllocate: true,
            hasExternalSideEffects: true
        )
        var fixture = try makeFixture { root in
            root.registerTypes.append(contentsOf: [
                .closure(formal), .int64,
            ])
            root.blocks[0].instructions = [
                .makeClosure(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    captures: [.init(rawValue: 0)]
                ),
                .apply(
                    result: .init(rawValue: 2),
                    function: .init(rawValue: 2),
                    arguments: [.init(rawValue: 1)]
                ),
                .returnValue(.init(rawValue: 2)),
            ]
            root.effects = authority
        }
        fixture.module.functions.append(contentsOf: [
            .init(
                id: .init(rawValue: 1),
                name: "authorizedClosureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ],
                effects: authority
            ),
            .init(
                id: .init(rawValue: 2),
                name: "invoke",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.closure(formal), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .closureApply(
                                result: .init(rawValue: 1),
                                closure: .init(rawValue: 0),
                                arguments: []
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            ),
        ])
        fixture.module.capabilities.insert(.closureValuesV1)
        fixture.shell.capabilities.insert(.closureValuesV1)
        fixture.policy.acceptedCapabilities.insert(.closureValuesV1)
        fixture.shell.entries[.init(rawValue: 0)]?.effects = authority

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var unauthorized = fixture
        unauthorized.module.functions[0].effects = .init()
        unauthorized.shell.entries[.init(rawValue: 0)]?.effects = .init()
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_closure captures allocating target authority "
                    + "in a nonallocating function"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(unauthorized.module),
                shell: unauthorized.shell,
                policy: unauthorized.policy
            )
        }

        var authorityInType = fixture
        var invalidSignature = formal
        invalidSignature.effects.mayAllocate = true
        authorityInType.module.functions[0].registerTypes[1] = .closure(
            invalidSignature
        )
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure signature cannot carry execution authority"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(authorityInType.module),
                shell: authorityInType.shell,
                policy: authorityInType.policy
            )
        }

        var actorMismatch = fixture
        var actorFormal = formal
        actorFormal.effects.requiresMainActor = true
        actorMismatch.module.functions[2].registerTypes[0] = .closure(
            actorFormal
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "call argument type mismatch"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(actorMismatch.module),
                shell: actorMismatch.shell,
                policy: actorMismatch.policy
            )
        }
    }

    @Test("A closure may capture another closure only with escaping capability")
    func validatesNestedClosureCaptureCapability() throws {
        var fixture = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        fixture.module.functions[0].registerTypes.append(contentsOf: [
            .closure(signature),
            .int64,
        ])
        fixture.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            .makeClosure(
                result: .init(rawValue: 3),
                function: .init(rawValue: 2),
                captures: [.init(rawValue: 1)]
            ),
            .closureApply(
                result: .init(rawValue: 4),
                closure: .init(rawValue: 3),
                arguments: [.init(rawValue: 0)]
            ),
            .returnValue(.init(rawValue: 4)),
        ]
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "nestedClosureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .int64,
                registerTypes: [.int64, .closure(signature), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [
                            .closureApply(
                                result: .init(rawValue: 2),
                                closure: .init(rawValue: 1),
                                arguments: [.init(rawValue: 0)]
                            ),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
        )

        #expect(
            throws: Verification.Error.capabilityDenied(
                .escapingClosureValuesV1
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
        fixture.module.capabilities.insert(.escapingClosureValuesV1)
        fixture.shell.capabilities.insert(.escapingClosureValuesV1)
        fixture.policy.acceptedCapabilities.insert(.escapingClosureValuesV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Nested closure storage is capability-gated and shape-checked")
    func validatesNestedClosureStorage() throws {
        let leaf = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        var gated = try makeClosureFixture()
        gated.module.functions[0].registerTypes.append(
            .optional(.closure(leaf))
        )
        #expect(
            throws: Verification.Error.capabilityDenied(
                .escapingClosureValuesV1
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(gated.module),
                shell: gated.shell,
                policy: gated.policy
            )
        }

        gated.module.capabilities.insert(.escapingClosureValuesV1)
        gated.shell.capabilities.insert(.escapingClosureValuesV1)
        gated.policy.acceptedCapabilities.insert(.escapingClosureValuesV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(gated.module),
            shell: gated.shell,
            policy: gated.policy
        )

        var malformed = gated
        malformed.module.functions[0].registerTypes[3] = .optional(
            .closure(
                .init(
                    parameters: [.closure(leaf)],
                    parameterConventions: [],
                    result: .closure(leaf)
                )
            )
        )
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure signature has invalid parameter ownership"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(malformed.module),
                shell: malformed.shell,
                policy: malformed.policy
            )
        }

        var asynchronous = gated
        asynchronous.module.functions[0].registerTypes[3] = .optional(
            .closure(
                .init(
                    parameters: [],
                    parameterConventions: [],
                    result: .void,
                    effects: .init(isAsync: true)
                )
            )
        )
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "async closures require a suspension-aware closure contract"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(asynchronous.module),
                shell: asynchronous.shell,
                policy: asynchronous.policy
            )
        }
    }

    @Test("Local nominal fields may store synchronous closure values")
    func validatesClosureValuedLocalNominals() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .void
        )
        var fixture = try makeFixture()
        fixture.module.localTypes = [
            .init(
                key: .init(rawValue: "Fixture.Callbacks"),
                kind: .structure(
                    fields: [
                        .init(name: "callback", type: .closure(signature)),
                    ]
                )
            ),
        ]
        for capability in [
            Core.Capability.localNominalsV1,
            .closureValuesV1,
            .escapingClosureValuesV1,
        ] {
            fixture.module.capabilities.insert(capability)
            fixture.shell.capabilities.insert(capability)
            fixture.policy.acceptedCapabilities.insert(capability)
        }
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        fixture.module.capabilities.remove(.escapingClosureValuesV1)
        fixture.shell.capabilities.remove(.escapingClosureValuesV1)
        fixture.policy.acceptedCapabilities.remove(.escapingClosureValuesV1)
        #expect(
            throws: Verification.Error.capabilityDenied(
                .escapingClosureValuesV1
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dynamic closure scopes are paired and cannot be reused")
    func validatesDynamicClosureScopes() throws {
        var valid = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        valid.module.functions[0].registerTypes.append(.closure(signature))
        valid.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            .beginClosureScope(
                result: .init(rawValue: 3),
                closure: .init(rawValue: 1)
            ),
            .closureApply(
                result: .init(rawValue: 2),
                closure: .init(rawValue: 3),
                arguments: [.init(rawValue: 0)]
            ),
            .endClosureScope(closure: .init(rawValue: 3)),
            .returnValue(.init(rawValue: 2)),
        ]
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(valid.module),
            shell: valid.shell,
            policy: valid.policy
        )

        var nested = valid
        nested.module.functions[0].registerTypes.append(.closure(signature))
        nested.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            .beginClosureScope(
                result: .init(rawValue: 3),
                closure: .init(rawValue: 1)
            ),
            .beginClosureScope(
                result: .init(rawValue: 4),
                closure: .init(rawValue: 3)
            ),
            .closureApply(
                result: .init(rawValue: 2),
                closure: .init(rawValue: 4),
                arguments: [.init(rawValue: 0)]
            ),
            .endClosureScope(closure: .init(rawValue: 4)),
            .endClosureScope(closure: .init(rawValue: 3)),
            .returnValue(.init(rawValue: 2)),
        ]
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(nested.module),
            shell: nested.shell,
            policy: nested.policy
        )

        var wrongNestedOrder = nested
        wrongNestedOrder.module.functions[0].blocks[0].instructions.swapAt(
            4,
            5
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "an outer closure scope cannot end before its nested scope"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongNestedOrder.module),
                shell: wrongNestedOrder.shell,
                policy: wrongNestedOrder.policy
            )
        }

        var splitExit = valid
        splitExit.module.functions[0].registerTypes.append(.bool)
        splitExit.module.functions[0].blocks = [
            .init(
                id: .init(rawValue: 0),
                parameters: [.init(rawValue: 0)],
                instructions: [
                    .makeClosure(
                        result: .init(rawValue: 1),
                        function: .init(rawValue: 1),
                        captures: [.init(rawValue: 0)]
                    ),
                    .beginClosureScope(
                        result: .init(rawValue: 3),
                        closure: .init(rawValue: 1)
                    ),
                    .constantBool(result: .init(rawValue: 4), value: true),
                    .conditionalBranch(
                        condition: .init(rawValue: 4),
                        trueTarget: .init(rawValue: 1),
                        trueArguments: [],
                        falseTarget: .init(rawValue: 2),
                        falseArguments: []
                    ),
                ]
            ),
            .init(
                id: .init(rawValue: 1),
                instructions: [
                    .endClosureScope(closure: .init(rawValue: 3)),
                    .returnValue(.init(rawValue: 0)),
                ]
            ),
            .init(
                id: .init(rawValue: 2),
                instructions: [
                    .endClosureScope(closure: .init(rawValue: 3)),
                    .returnValue(.init(rawValue: 0)),
                ]
            ),
        ]
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(splitExit.module),
            shell: splitExit.shell,
            policy: splitExit.policy
        )

        var missingEnd = valid
        missingEnd.module.functions[0].blocks[0].instructions.remove(at: 3)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "a dynamic closure scope reaches a normal function exit"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(missingEnd.module),
                shell: missingEnd.shell,
                policy: missingEnd.policy
            )
        }

        var unmatchedEnd = valid
        unmatchedEnd.module.functions[0].blocks[0].instructions.remove(at: 1)
        unmatchedEnd.module.functions[0].blocks[0].instructions[1] =
            .closureApply(
                result: .init(rawValue: 2),
                closure: .init(rawValue: 1),
                arguments: [.init(rawValue: 0)]
            )
        unmatchedEnd.module.functions[0].blocks[0].instructions[2] =
            .endClosureScope(closure: .init(rawValue: 1))
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "end_closure_scope has no matching open scope"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(unmatchedEnd.module),
                shell: unmatchedEnd.shell,
                policy: unmatchedEnd.policy
            )
        }

        var useAfterEnd = valid
        useAfterEnd.module.functions[0].blocks[0].instructions.swapAt(2, 3)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "closed dynamic closure scope %3 is reused"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(useAfterEnd.module),
                shell: useAfterEnd.shell,
                policy: useAfterEnd.policy
            )
        }
    }

    @Test("Compiler-generated specializations cannot become Shell entries")
    func rejectsSpecializationEntry() throws {
        var fixture = try makeFixture()
        fixture.module.functions[0].kind = .concreteSpecialization
        fixture.module.capabilities.insert(.compilerSpecializationsV1)
        fixture.shell.capabilities.insert(.compilerSpecializationsV1)
        fixture.policy.acceptedCapabilities.insert(.compilerSpecializationsV1)

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure bodies and compiler specializations cannot be patch entries"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Async effects are entry-only, capability-gated, and cannot be called synchronously")
    func verifiesAsyncLeafContract() throws {
        var accepted = try makeFixture()
        accepted.module.functions[0].effects.isAsync = true
        accepted.module.capabilities.insert(.asyncLeafEntriesV1)
        accepted.shell.entries[.init(rawValue: 0)]?.effects.isAsync = true
        accepted.shell.capabilities.insert(.asyncLeafEntriesV1)
        accepted.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(accepted.module),
            shell: accepted.shell,
            policy: accepted.policy
        )

        var missingCapability = accepted
        missingCapability.module.capabilities.remove(.asyncLeafEntriesV1)
        #expect(throws: Verification.Error.capabilityDenied(.asyncLeafEntriesV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(missingCapability.module),
                shell: missingCapability.shell,
                policy: missingCapability.policy
            )
        }

        var helper = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        helper.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "async helper",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ],
                effects: .init(isAsync: true)
            )
        )
        helper.module.capabilities.insert(.asyncLeafEntriesV1)
        helper.shell.capabilities.insert(.asyncLeafEntriesV1)
        helper.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "hlbc_apply calls an async entry without a suspension contract"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(helper.module),
                shell: helper.shell,
                policy: helper.policy
            )
        }
    }

    @Test("Async closure signatures remain outside the non-suspending entry capability")
    func rejectsAsyncClosureSignature() throws {
        var fixture = try makeClosureFixture()
        fixture.module.functions[0].registerTypes[1] = .closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64,
                effects: .init(isAsync: true)
            )
        )
        fixture.module.capabilities.insert(.asyncLeafEntriesV1)
        fixture.shell.capabilities.insert(.asyncLeafEntriesV1)
        fixture.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "async closures require a suspension-aware closure contract"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Representation-level numeric instructions enforce exact shapes")
    func rejectsMalformedRepresentationNumericInstructions() throws {
        let badFloatProperty = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .float(bitWidth: 32),
                .integer(bitWidth: 32, signed: true),
            ])
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), bitPattern: 0),
                .floatingIntegerProperty(
                    result: .init(rawValue: 2),
                    operation: .significandBitPattern,
                    operand: .init(rawValue: 1)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "floating integer property has an operation-specific result type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badFloatProperty.module),
                shell: badFloatProperty.shell,
                policy: badFloatProperty.policy
            )
        }

        let badTernary = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .float(bitWidth: 32),
                .float(bitWidth: 64),
                .float(bitWidth: 32),
                .float(bitWidth: 32),
            ])
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), bitPattern: 0),
                .constantFloat(result: .init(rawValue: 2), bitPattern: 0),
                .constantFloat(result: .init(rawValue: 3), bitPattern: 0),
                .floatingTernary(
                    result: .init(rawValue: 4),
                    operation: .fusedMultiplyAdd,
                    multiplicand: .init(rawValue: 1),
                    multiplier: .init(rawValue: 2),
                    addend: .init(rawValue: 3)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "floating ternary operands and result must use one float type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badTernary.module),
                shell: badTernary.shell,
                policy: badTernary.policy
            )
        }

        let badBinaryPredicate = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .float(bitWidth: 32),
                .float(bitWidth: 64),
                .bool,
            ])
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), bitPattern: 0),
                .constantFloat(result: .init(rawValue: 2), bitPattern: 0),
                .floatingBinaryPredicate(
                    result: .init(rawValue: 3),
                    operation: .isTotallyOrderedBelowOrEqual,
                    lhs: .init(rawValue: 1),
                    rhs: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "floating binary predicate requires one float type and Bool result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badBinaryPredicate.module),
                shell: badBinaryPredicate.shell,
                policy: badBinaryPredicate.policy
            )
        }

        let badFullWidthMultiply = try makeFixture { function in
            let signed32 = Bytecode.ValueType.integer(
                bitWidth: 32,
                signed: true
            )
            function.registerTypes.append(contentsOf: [
                signed32, signed32, signed32, signed32,
            ])
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                .constantInteger(result: .init(rawValue: 2), bitPattern: 2),
                .integerFullWidthMultiply(
                    high: .init(rawValue: 3),
                    low: .init(rawValue: 4),
                    lhs: .init(rawValue: 1),
                    rhs: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "full-width multiply requires matching operands, high result, and unsigned low result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badFullWidthMultiply.module),
                shell: badFullWidthMultiply.shell,
                policy: badFullWidthMultiply.policy
            )
        }

        let badFullWidthDivide = try makeFixture { function in
            let signed32 = Bytecode.ValueType.integer(
                bitWidth: 32,
                signed: true
            )
            function.registerTypes.append(contentsOf: [
                signed32, signed32, signed32, signed32, signed32,
            ])
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), bitPattern: 0),
                .constantInteger(result: .init(rawValue: 2), bitPattern: 1),
                .constantInteger(result: .init(rawValue: 3), bitPattern: 1),
                .integerFullWidthDivide(
                    quotient: .init(rawValue: 4),
                    remainder: .init(rawValue: 5),
                    dividendHigh: .init(rawValue: 1),
                    dividendLow: .init(rawValue: 2),
                    divisor: .init(rawValue: 3)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "full-width divide requires a same-type high/divisor/result and unsigned low word"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(badFullWidthDivide.module),
                shell: badFullWidthDivide.shell,
                policy: badFullWidthDivide.policy
            )
        }
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private func makeFixture(
        mutate: ((inout Bytecode.Function) -> Void)? = nil
    ) throws -> Fixture {
        let shellHash = Core.Digest.sha256("verifier-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier",
            buildNumber: "1",
            seed: "fixture"
        )
        let lowered = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_: Int) -> Int",
            loweredSignature: lowered,
            role: .function
        )
        var function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        mutate?(&function)
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-verifier-fixture"
        )
        let module = Bytecode.Module(
            name: "VerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            functions: [function],
            entries: [.init(entryIndex: .init(rawValue: 0), functionKey: key, functionID: function.id)]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        return Fixture(module: module, shell: shell, policy: .init())
    }

    private func makeClosureFixture() throws -> Fixture {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.closure(signature), .int64])
            function.blocks[0].instructions = [
                .makeClosure(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    captures: [.init(rawValue: 0)]
                ),
                .closureApply(
                    result: .init(rawValue: 2),
                    closure: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "closureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .int64,
                registerTypes: [.int64, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )
        fixture.module.capabilities.insert(.closureValuesV1)
        fixture.shell.capabilities.insert(.closureValuesV1)
        fixture.policy.acceptedCapabilities.insert(.closureValuesV1)
        return fixture
    }

    private func makeTypedThrowingClosureFixture() throws -> (
        fixture: Fixture,
        errorKey: Bytecode.LocalTypeKey
    ) {
        let errorKey = Bytecode.LocalTypeKey(
            rawValue: "Fixture.TypedClosureError"
        )
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64,
            thrownType: .local(errorKey),
            effects: .init(mayThrow: true)
        )
        var fixture = try makeClosureFixture()
        fixture.module.functions[0].registerTypes = [
            .int64,
            .closure(signature),
            .int64,
            .local(errorKey),
        ]
        fixture.module.functions[0].blocks = [
            .init(
                id: .init(rawValue: 0),
                parameters: [.init(rawValue: 0)],
                instructions: [
                    .makeClosure(
                        result: .init(rawValue: 1),
                        function: .init(rawValue: 1),
                        captures: [.init(rawValue: 0)]
                    ),
                    .closureTryApply(
                        closure: .init(rawValue: 1),
                        arguments: [.init(rawValue: 0)],
                        normalTarget: .init(rawValue: 1),
                        errorTarget: .init(rawValue: 2)
                    ),
                ]
            ),
            .init(
                id: .init(rawValue: 1),
                parameters: [.init(rawValue: 2)],
                instructions: [.returnValue(.init(rawValue: 2))]
            ),
            .init(
                id: .init(rawValue: 2),
                parameters: [.init(rawValue: 3)],
                instructions: [.returnValue(.init(rawValue: 0))]
            ),
        ]
        fixture.module.functions[1] = .init(
            id: .init(rawValue: 1),
            name: "typedClosureBody",
            kind: .closureBody,
            parameterRegisters: [
                .init(rawValue: 0),
                .init(rawValue: 1),
            ],
            resultType: .int64,
            thrownType: .local(errorKey),
            registerTypes: [
                .int64,
                .int64,
                .local(errorKey),
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0),
                        .init(rawValue: 1),
                    ],
                    instructions: [
                        .makeEnum(
                            result: .init(rawValue: 2),
                            caseIndex: 0,
                            payload: .init(rawValue: 0)
                        ),
                        .throwError(.init(rawValue: 2)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )
        fixture.module.localTypes = [
            .init(
                key: errorKey,
                kind: .enumeration(
                    cases: [
                        .init(name: "rejected", payloadType: .int64),
                    ]
                ),
                conformsToError: true
            ),
        ]
        let capabilities: Set<Core.Capability> = [
            .localNominalsV1,
            .typedThrowsV1,
        ]
        fixture.module.capabilities.formUnion(capabilities)
        fixture.shell.capabilities.formUnion(capabilities)
        fixture.policy.acceptedCapabilities.formUnion(capabilities)
        return (fixture, errorKey)
    }
}
}
