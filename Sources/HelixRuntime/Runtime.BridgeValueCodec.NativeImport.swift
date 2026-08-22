#if canImport(HelixCore)
import HelixBytecode
import HelixVM
#endif

extension Runtime.BridgeValueCodec {
/// Encodes one non-Void NativeImport result before its invocation context is
/// closed. The same scoped encoder now governs ordinary values and returned
/// native callables, so generated adapters cannot bypass host allocation,
/// signed resource, exact-shape, or import-deadline checks by result kind.
public static func encodeNativeImportResult(
    expectedType: Bytecode.ValueType,
    context: VM.NativeInvocationContext,
    encode: (Runtime.BridgeValueCodec.Encoder) throws -> VM.Value
) throws -> VM.Value {
    guard expectedType != .void,
          expectedType.isNativeImportBridgeResult
    else {
        throw Runtime.BridgeInputError.encodedTypeMismatch(
            expected: "a supported non-Void NativeImport result",
            actual: expectedType.description
        )
    }
    let encoder = Runtime.BridgeValueCodec.Encoder(
        limits: Runtime.BridgeInputLimits().constrained(
            by: context.resourceLimits
        ),
        checkDeadline: { try context.checkResultEncodingDeadline() }
    )
    let value = try encode(encoder)
    guard value.matches(expectedType) else {
        throw Runtime.BridgeInputError.encodedTypeMismatch(
            expected: expectedType.description,
            actual: value.type.description
        )
    }
    try encoder.finalize(arguments: [value])
    return value
}
}
