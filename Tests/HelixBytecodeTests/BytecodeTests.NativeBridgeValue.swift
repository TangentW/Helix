import HelixCore
import Testing
@testable import HelixBytecode

extension BytecodeTests {
@Suite("Native bridge callback results")
struct NativeBridgeValue {
    @Test("Deterministic callback failure values are derived by value shape")
    func derivesFailureValues() {
        let native = Bytecode.ValueType.native(
            .init(rawValue: .sha256("native-callback-result"))
        )
        for type: Bytecode.ValueType in [
            .void,
            .bool,
            .int64,
            .float(bitWidth: 64),
            .string,
            .any,
            .optional(native),
            .array(native),
            .dictionary(key: .string, value: native),
            .set(.string),
            .tuple([.bool, .optional(native)]),
        ] {
            #expect(type.hasNativeCallbackFailureValue)
            #expect(type.isNativeBridgeCallbackResult)
        }

        for type: Bytecode.ValueType in [
            .never,
            native,
            .error,
            .tuple([.bool, native]),
            .array(.error),
        ] {
            #expect(!type.isNativeBridgeCallbackResult)
        }
    }

    @Test("Native callback eligibility admits safe results without weakening effects")
    func validatesCallbackSignatures() {
        var callback = Bytecode.ClosureSignature(
            parameters: [.string],
            parameterConventions: [.owned],
            result: .bool
        )
        #expect(callback.isNativeBridgeCallback)

        callback.result = .native(
            .init(rawValue: .sha256("nondefaultable-native-result"))
        )
        #expect(!callback.isNativeBridgeCallback)

        callback.result = .optional(callback.result)
        #expect(callback.isNativeBridgeCallback)

        callback.effects.mayThrow = true
        callback.thrownType = .error
        #expect(!callback.isNativeBridgeCallback)
    }

    @Test("Native callback eligibility admits one safe callable argument layer")
    func validatesNativeCallableArguments() {
        let completion = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        #expect(completion.isNativeBridgeCallableArgument)
        #expect(
            Bytecode.ValueType.closure(completion)
                .nativeCallbackParameterConvention == .owned
        )
        #expect(
            Bytecode.ValueType.optional(.closure(completion))
                .nativeCallbackParameterConvention == .owned
        )

        var callback = Bytecode.ClosureSignature(
            parameters: [.closure(completion)],
            parameterConventions: [.owned],
            result: .void
        )
        #expect(callback.isNativeBridgeCallback)

        callback.parameters = [.optional(.closure(completion))]
        #expect(callback.isNativeBridgeCallback)

        callback.parameterConventions = [.borrowed]
        #expect(!callback.isNativeBridgeCallback)

        let recursive = Bytecode.ClosureSignature(
            parameters: [.closure(completion)],
            parameterConventions: [.owned],
            result: .void
        )
        #expect(!recursive.isNativeBridgeCallableArgument)
        #expect(
            !Bytecode.ValueType.array(.closure(completion))
                .isNativeBridgeCallbackArgument
        )

        var nativeResult = completion
        nativeResult.result = .native(
            .init(rawValue: .sha256("native-callable-result"))
        )
        #expect(nativeResult.isNativeBridgeCallableArgument)
        #expect(!nativeResult.isNativeBridgeCallback)
    }
}
}
