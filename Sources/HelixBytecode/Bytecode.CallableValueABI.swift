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

    /// Whether `self` is the representation-preserving callable restriction
    /// that requires an otherwise identical unrestricted closure to execute
    /// on MainActor. Removing actor isolation is intentionally not accepted.
    public func isMainActorRestriction(
        of source: Bytecode.ClosureSignature
    ) -> Bool {
        guard parameters == source.parameters,
              parameterConventions == source.parameterConventions,
              result == source.result,
              thrownType == source.thrownType,
              hasCanonicalCallableEffects,
              source.hasCanonicalCallableEffects,
              hasCanonicalThrownType,
              source.hasCanonicalThrownType,
              !source.effects.requiresMainActor,
              effects.requiresMainActor
        else { return false }
        var restricted = effects
        restricted.requiresMainActor = false
        return restricted == source.effects
    }

    /// A callable value may impose a stricter MainActor invocation contract
    /// than its concrete target, but it may never erase target isolation.
    public func safelyRestricts(
        targetEffects: Core.Effects
    ) -> Bool {
        let target = Self.callableEffects(from: targetEffects)
        return effects == target || isMainActorRestriction(
            of: .init(
                parameters: parameters,
                parameterConventions: parameterConventions,
                result: result,
                thrownType: thrownType,
                effects: target
            )
        )
    }
}

extension Bytecode.Function {
    public var hasCanonicalThrownType: Bool {
        effects.mayThrow == (thrownType != nil)
    }
}
