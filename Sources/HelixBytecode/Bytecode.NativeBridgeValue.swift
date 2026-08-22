extension Bytecode.ValueType {
    /// Whether this value shape embeds Swift's Error existential. NativeImport
    /// supports it only as an SDK callback argument, where generated block
    /// thunks can normalize NSError-backed values into the bounded VM proxy.
    public var containsErrorExistential: Bool {
        switch self {
        case .error:
            true
        case let .array(element), let .optional(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element), let .arrayState(_, element):
            element.containsErrorExistential
        case let .dictionary(key, value), let .dictionaryState(key, value):
            key.containsErrorExistential || value.containsErrorExistential
        case let .tuple(elements):
            elements.contains(where: \.containsErrorExistential)
        case let .closure(signature):
            signature.componentTypes.contains(
                where: \.containsErrorExistential
            )
        case .void, .never, .bool, .integer, .float, .string, .any, .native,
             .local:
            false
        }
    }

    /// Values that generated Swift adapters can encode and decode without
    /// exposing image-local storage or callable values. Error existentials are
    /// normalized at the boundary and never expose their native payload graph.
    public var isNativeBridgeValue: Bool {
        switch self {
        case .bool, .integer, .float, .string, .any, .native, .error:
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
        case .void, .never, .local, .address, .mutableCell,
             .nonOwningReference, .arrayState, .dictionaryState, .closure:
            false
        }
    }

    /// A regular NativeImport slot excludes callable values and Error. Error
    /// is intentionally narrower: it is valid only inside a callback's
    /// compiler-proven parameter signature.
    public var isOrdinaryNativeImportBridgeValue: Bool {
        !containsClosureValue
            && !containsErrorExistential
            && isNativeBridgeValue
    }

    public var isNativeImportBridgeResult: Bool {
        self == .void || isOrdinaryNativeImportBridgeValue
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
        case .any, .native, .error:
            true
        case let .array(element), let .optional(element), let .set(element):
            element.requiresNativeCallbackBorrowing
        case let .dictionary(key, value):
            key.requiresNativeCallbackBorrowing
                || value.requiresNativeCallbackBorrowing
        case let .tuple(elements):
            elements.contains(where: \.requiresNativeCallbackBorrowing)
        case .void, .never, .bool, .integer, .float, .string, .local,
             .address, .mutableCell, .nonOwningReference,
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
            && hasCanonicalThrownType
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
