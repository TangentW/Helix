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
}
