extension Bytecode.ValueType {
    /// Whether this value shape embeds Swift's Error existential. NativeImport
    /// supports it only inside an exact native callable signature, where
    /// generated adapters normalize NSError-backed values into the bounded VM
    /// proxy.
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
        self == .void
            || isOrdinaryNativeImportBridgeValue
            || isNativeBridgeCallableValue
    }

    /// Whether a nonthrowing native callback can return a deterministic value
    /// after its VM body fails. The failure is still retained by the active
    /// NativeImport or reported to Runtime telemetry; this value only satisfies
    /// the native ABI while control unwinds back to the importing call.
    ///
    /// Empty containers and `nil` do not require a fallback for their element
    /// type. A direct native value has no universally valid Swift instance and
    /// therefore remains unsupported unless it is wrapped in Optional or an
    /// empty container.
    public var hasNativeCallbackFailureValue: Bool {
        switch self {
        case .void, .bool, .integer, .float, .string, .any,
             .optional, .array, .dictionary, .set:
            true
        case let .tuple(elements):
            !elements.isEmpty
                && elements.allSatisfy(\.hasNativeCallbackFailureValue)
        case .never, .native, .error, .local, .address, .mutableCell,
             .nonOwningReference, .arrayState, .dictionaryState, .closure:
            false
        }
    }

    /// Results admitted by generated nonthrowing NativeImport callbacks. A
    /// bridgeable result must also have a deterministic failure value because
    /// Swift's nonthrowing native closure ABI has no error channel.
    public var isNativeBridgeCallbackResult: Bool {
        self == .void
            || (isOrdinaryNativeImportBridgeValue
                && hasNativeCallbackFailureValue)
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

    /// A value admitted as one argument of an SDK callback. In addition to
    /// ordinary bridge values, the callback may hand Helix direct native
    /// callables (optionally wrapped). Containers of callables remain excluded:
    /// they require recursive lifetime metadata that the v1 Shell contract
    /// intentionally does not infer.
    public var isNativeBridgeCallbackArgument: Bool {
        if isNativeBridgeValue { return true }
        guard let shape = directClosureShape else { return false }
        return shape.signature.isNativeBridgeCallable
    }

    /// A direct native-origin callable or one Optional wrapping it. Returned
    /// function values are escaping by construction and use the same typed
    /// runtime target as callable arguments supplied by SDK callbacks.
    public var isNativeBridgeCallableValue: Bool {
        guard let shape = directClosureShape else { return false }
        return shape.signature.isNativeBridgeCallable
    }
}

extension Bytecode.ClosureSignature {
    /// A native-origin callable that an SDK callback or NativeImport result may
    /// supply to the VM.
    ///
    /// Invocation travels from VM to Swift, so bridge failures have a VM trap
    /// channel and the native result does not need the deterministic fallback
    /// required by a Swift callback that returns into an SDK frame. A second
    /// callable layer is deliberately rejected until its independent lifetime
    /// can be represented and enforced.
    public var isNativeBridgeCallable: Bool {
        hasCanonicalCallableEffects
            && hasCanonicalThrownType
            && (result == .void
                || (!result.containsClosureValue && result.isNativeBridgeValue))
            && !effects.mayThrow
            && !effects.isAsync
            && parameterConventions
                == parameters.map(\.nativeCallbackParameterConvention)
            && parameters.allSatisfy {
                !$0.containsClosureValue && $0.isNativeBridgeValue
            }
    }

    /// The callback surface supported by generated NativeImport adapters.
    /// Executor isolation remains part of the callable signature; coroutine,
    /// throwing, and inout callbacks do not cross this synchronous boundary.
    /// One native-origin callable argument is supported generically; its Swift
    /// spelling must independently prove an escaping lifetime. Result-producing
    /// callbacks additionally require a deterministic native failure value.
    public var isNativeBridgeCallback: Bool {
        hasCanonicalCallableEffects
            && hasCanonicalThrownType
            && result.isNativeBridgeCallbackResult
            && !effects.mayThrow
            && !effects.isAsync
            && parameterConventions
                == parameters.map(\.nativeCallbackParameterConvention)
            && parameters.allSatisfy(\.isNativeBridgeCallbackArgument)
    }
}
