#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode.ClosureSignature {
    /// Swift callable types encode throwing, executor, and async behavior.
    /// Allocation and external-side-effect authority belongs to the concrete
    /// target function and its verified image, never to a closure value type.
    public static func callableEffects(
        from executionEffects: Core.Effects
    ) -> Core.Effects {
        .init(
            mayThrow: executionEffects.mayThrow,
            requiresMainActor: executionEffects.requiresMainActor,
            isAsync: executionEffects.isAsync
        )
    }

    public var hasCanonicalCallableEffects: Bool {
        effects == Self.callableEffects(from: effects)
    }

    /// Callable effects and the concrete error-result channel are redundant
    /// by design so policy checks can inspect effects without importing a
    /// bytecode type. Verification requires both views to agree.
    public var hasCanonicalThrownType: Bool {
        effects.mayThrow == (thrownType != nil)
    }
}

extension Bytecode.Function {
    public var hasCanonicalThrownType: Bool {
        effects.mayThrow == (thrownType != nil)
    }
}
