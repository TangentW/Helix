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
}
}
