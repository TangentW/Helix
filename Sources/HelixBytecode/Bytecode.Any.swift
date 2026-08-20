extension Bytecode.ValueType {
    /// The closed set that HLBC 1.0 may store inside its VM-owned `Any` value.
    /// Native handles and other lifetime-bearing values require a separate ABI.
    public var isAnyPayloadV1: Bool {
        switch self {
        case .bool, .integer, .float, .string, .local:
            true
        case let .array(element), let .optional(element):
            element.isAnyPayloadOrExistentialV1
        case let .dictionary(key, value):
            key.isAnyDictionaryKeyV1 && value.isAnyPayloadOrExistentialV1
        case let .tuple(elements):
            !elements.isEmpty
                && elements.allSatisfy(\.isAnyPayloadOrExistentialV1)
        case .void, .never, .any, .set, .native, .error, .address, .mutableCell,
             .arrayBuilder, .arraySortState, .closure:
            false
        }
    }

    /// `Any` may occur inside a supported aggregate, but a direct box is
    /// flattened so an erased value always records a concrete payload type.
    public var isAnyPayloadOrExistentialV1: Bool {
        self == .any || isAnyPayloadV1
    }

    public var isAnyCastTargetV1: Bool {
        isAnyPayloadOrExistentialV1
    }

    private var isAnyDictionaryKeyV1: Bool {
        switch self {
        case .bool, .integer, .string:
            true
        default:
            false
        }
    }
}
