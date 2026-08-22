extension Bytecode.ValueType {
    /// Values that generated Swift adapters can encode and decode without
    /// exposing image-local storage, Error channels, or callable values.
    public var isNativeBridgeValue: Bool {
        switch self {
        case .bool, .integer, .float, .string, .any, .native:
            true
        case let .array(element), let .optional(element):
            element.isNativeBridgeValue
        case let .set(element):
            element.isVMHashable && element.isNativeBridgeValue
        case let .dictionary(key, value):
            key.isVMHashable
                && key.isNativeBridgeValue
                && value.isNativeBridgeValue
        case let .tuple(elements):
            !elements.isEmpty && elements.allSatisfy(\.isNativeBridgeValue)
        case .void, .never, .local, .error, .address, .mutableCell,
             .nonOwningReference, .arrayState, .dictionaryState, .closure:
            false
        }
    }

    /// Swift closure calls borrow values whose VM representation can carry a
    /// managed identity. This includes opaque native handles, type-erased
    /// payloads, and aggregates that contain either. Other copyable VM values
    /// retain the simpler owned convention because their SIL borrow
    /// distinction has no VM ownership semantics.
    public var nativeCallbackParameterConvention: Bytecode.ParameterConvention {
        requiresNativeCallbackBorrowing ? .borrowed : .owned
    }

    private var requiresNativeCallbackBorrowing: Bool {
        switch self {
        case .any, .native:
            true
        case let .array(element), let .optional(element), let .set(element):
            element.requiresNativeCallbackBorrowing
        case let .dictionary(key, value):
            key.requiresNativeCallbackBorrowing
                || value.requiresNativeCallbackBorrowing
        case let .tuple(elements):
            elements.contains(where: \.requiresNativeCallbackBorrowing)
        case .void, .never, .bool, .integer, .float, .string, .local,
             .error, .address, .mutableCell, .nonOwningReference,
             .arrayState, .dictionaryState, .closure:
            false
        }
    }
}

extension Bytecode.ClosureSignature {
    /// The callback surface supported by generated NativeImport adapters.
    /// Executor isolation remains part of the callable signature; coroutine,
    /// throwing, inout, higher-order, and result-producing callbacks do not
    /// cross this synchronous boundary.
    public var isNativeBridgeCallback: Bool {
        hasCanonicalCallableEffects
            && result == .void
            && !effects.mayThrow
            && !effects.isAsync
            && parameterConventions
                == parameters.map(\.nativeCallbackParameterConvention)
            && parameters.allSatisfy {
                !$0.containsClosureValue && $0.isNativeBridgeValue
            }
    }
}
