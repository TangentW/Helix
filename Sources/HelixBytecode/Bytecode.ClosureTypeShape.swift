extension Bytecode {
/// A closure value stored directly or behind one Optional layer.
public struct DirectClosureShape: Hashable, Sendable {
    public var signature: Bytecode.ClosureSignature
    public var isOptional: Bool

    public init(signature: Bytecode.ClosureSignature, isOptional: Bool) {
        self.signature = signature
        self.isOptional = isOptional
    }
}
}

extension Bytecode.ValueType {
    /// Resolves a direct closure value or an Optional wrapping exactly one closure.
    public var directClosureShape: Bytecode.DirectClosureShape? {
        switch self {
        case let .closure(signature):
            .init(signature: signature, isOptional: false)
        case let .optional(.closure(signature)):
            .init(signature: signature, isOptional: true)
        default:
            nil
        }
    }

    /// Whether this storage shape contains a first-class closure at any depth,
    /// including inside another closure's callable signature.
    public var containsClosureValue: Bool {
        var pending = [self]
        while let type = pending.popLast() {
            switch type {
            case .closure:
                return true
            case let .optional(wrapped), let .array(wrapped), let .set(wrapped),
                 let .address(wrapped), let .mutableCell(wrapped),
                 let .nonOwningReference(_, wrapped),
                 let .arrayState(_, wrapped):
                pending.append(wrapped)
            case let .dictionary(key, value),
                 let .dictionaryState(key, value):
                pending.append(key)
                pending.append(value)
            case let .tuple(elements):
                pending.append(contentsOf: elements)
            case .void, .never, .bool, .integer, .float, .string, .any,
                 .native, .local, .error:
                break
            }
        }
        return false
    }

    /// A direct closure register can be invocation-scoped. A closure nested in
    /// its signature or another storage shape is first-class escaping storage
    /// and therefore requires the stronger capability gate.
    public var containsNestedClosureValue: Bool {
        switch self {
        case let .closure(signature):
            signature.componentTypes.contains(
                where: \.containsClosureValue
            )
        case let .optional(wrapped), let .array(wrapped), let .set(wrapped),
             let .address(wrapped), let .mutableCell(wrapped),
             let .nonOwningReference(_, wrapped),
             let .arrayState(_, wrapped):
            wrapped.containsClosureValue
        case let .dictionary(key, value),
             let .dictionaryState(key, value):
            key.containsClosureValue || value.containsClosureValue
        case let .tuple(elements):
            elements.contains(where: \.containsClosureValue)
        case .void, .never, .bool, .integer, .float, .string, .any, .native,
             .local, .error:
            false
        }
    }
}
