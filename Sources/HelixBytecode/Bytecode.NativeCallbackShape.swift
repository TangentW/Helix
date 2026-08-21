extension Bytecode {
/// The two Swift parameter shapes that can directly carry one native callback.
public struct NativeCallbackShape: Hashable, Sendable {
    public var signature: Bytecode.ClosureSignature
    public var isOptional: Bool

    public init(signature: Bytecode.ClosureSignature, isOptional: Bool) {
        self.signature = signature
        self.isOptional = isOptional
    }
}
}

extension Bytecode.ValueType {
    /// Resolves a direct closure parameter or an Optional wrapping exactly one closure.
    public var nativeCallbackShape: Bytecode.NativeCallbackShape? {
        switch self {
        case let .closure(signature):
            .init(signature: signature, isOptional: false)
        case let .optional(.closure(signature)):
            .init(signature: signature, isOptional: true)
        default:
            nil
        }
    }

    public var containsClosure: Bool {
        switch self {
        case .closure:
            true
        case let .array(element), let .optional(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element), let .arrayState(_, element):
            element.containsClosure
        case let .dictionary(key, value), let .dictionaryState(key, value):
            key.containsClosure || value.containsClosure
        case let .tuple(elements):
            elements.contains(where: \.containsClosure)
        case .void, .never, .bool, .integer, .float, .string, .any, .native,
             .local, .error:
            false
        }
    }
}
