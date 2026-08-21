#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// A VM-owned existential. It stores a verified, recursive source-level
/// identity rather than Swift metadata or an ABI existential container.
public struct AnyValue: Hashable, Sendable {
    /// Verified Swift identity and its deterministic HLBC storage mapping.
    public let dynamicType: Bytecode.DynamicType
    /// VM-owned value whose shape must match `dynamicType.storageType` and all
    /// logical invariants carried by `dynamicType`.
    public let payload: VM.Value

    /// Creates an existential value, flattening a redundant Any-in-Any box.
    public init(dynamicType: Bytecode.DynamicType, payload: VM.Value) {
        if dynamicType == .any, case let .any(erased) = payload {
            self = erased
        } else {
            self.dynamicType = dynamicType
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
