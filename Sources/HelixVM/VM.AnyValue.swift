#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// A VM-owned existential. It deliberately stores a stable HLBC type rather
/// than Swift metadata or an ABI existential container.
public struct AnyValue: Hashable, Sendable {
    /// Verified HLBC identity of the erased payload.
    public let concreteType: Bytecode.ValueType
    /// VM-owned value whose shape must match `concreteType`.
    public let payload: VM.Value

    /// Creates an existential value, flattening a redundant Any-in-Any box.
    public init(concreteType: Bytecode.ValueType, payload: VM.Value) {
        if concreteType == .any, case let .any(erased) = payload {
            self = erased
        } else {
            self.concreteType = concreteType
            self.payload = payload
        }
    }
}

enum ValueLimits {
    /// Generated boundaries use the same limit. Keeping it below the verifier's
    /// bounded recursive work prevents adversarial existential type cycles from
    /// exhausting the native stack.
    static let maximumNestingDepth = 64
}
}
