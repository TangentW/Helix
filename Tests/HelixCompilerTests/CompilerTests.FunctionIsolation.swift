import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL function isolation")
struct FunctionIsolation {
    @Test("Outer and nested MainActor annotations retain separate authority")
    func parsesLoweredActorAnnotations() throws {
        let lowerer = CanonicalSIL.Lowerer()
        let outer = try lowerer.parseFunctionType(
            "@convention(thin) @MainActor () -> ()"
        )
        #expect(outer.effects.requiresMainActor)

        let nested = try lowerer.parseFunctionType(
            "@convention(thin) "
                + "(@owned @Sendable @MainActor (Swift.Bool) -> ()) -> ()"
        )
        #expect(!nested.effects.requiresMainActor)
        guard case let .closure(callback) = nested.parameters.first else {
            Issue.record("nested parameter is not represented as a closure")
            return
        }
        #expect(callback.parameters == [.bool])
        #expect(callback.effects.requiresMainActor)
    }

    @Test("Unsupported lowered closure executors fail closed")
    func rejectsUnsupportedLoweredActorAnnotations() {
        let loweredTypes = [
            "@convention(thin) @Fixture.CustomActor () -> ()",
            "@convention(thin) (@owned @Fixture.CustomActor () -> ()) -> ()",
            "@convention(thin) (@owned @isolated(any) () -> ()) -> ()",
        ]
        for loweredType in loweredTypes {
            #expect(throws: CanonicalSIL.LoweringError.self) {
                try CanonicalSIL.Lowerer().parseFunctionType(loweredType)
            }
        }
    }

    @Test("Physical actor evidence cannot be erased by a call binding")
    func validatesPhysicalActorEvidence() throws {
        let callee = "$s7Fixture6renderyyF"
        let physicalActorType = "@convention(thin) @MainActor () -> ()"
        let nonisolatedCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: callee,
                parameterTypes: [],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let invalidRoot = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(callee) : $\(physicalActorType)
              %1 = apply %0() : $\(physicalActorType)
              return %1
            """
        )
        do {
            _ = try CanonicalSIL.Lowerer().lower(
                invalidRoot,
                displayName: "Fixture.root",
                directCalls: nonisolatedCalls
            )
            Issue.record("physical MainActor evidence was erased")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .callSignatureMismatch(_, symbol, _) = error else {
                Issue.record("unexpected lowering error: \(error)")
                return
            }
            #expect(symbol == callee)
        }

        let actorEffects = Core.Effects(requiresMainActor: true)
        let actorCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: callee,
                parameterTypes: [],
                resultType: .void,
                effects: actorEffects,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let erasedThunkRoot = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) @MainActor () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(callee) : $@convention(thin) () -> ()
              %1 = apply %0() : $@convention(thin) () -> ()
              return %1
            """
        )
        let lowered = try CanonicalSIL.Lowerer().lower(
            erasedThunkRoot,
            displayName: "Fixture.root",
            directCalls: actorCalls
        )
        #expect(lowered.effects.requiresMainActor)
    }

    @Test("MainActor isolation and rooted execution authority are independent")
    func preservesMainActorAndExecutionEnvelope() throws {
        let file = try CanonicalSIL.File(text: """
        sil_stage canonical

        // closure #1 in Fixture.root()
        // Isolation: global_actor. type: MainActor
        sil private @$s7Fixture4rootyyFyycfU_ : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function '$s7Fixture4rootyyFyycfU_'
        """)
        let function = try #require(file.functions.first)
        #expect(function.isolation == .globalActor("MainActor"))

        let signature = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: file.typeEnvironment,
            symbol: function.mangledName,
            kind: .closureBody,
            executionEffectEnvelope: .init(
                mayAllocate: true,
                hasExternalSideEffects: true
            )
        )
        #expect(signature.effects == .init(
            mayAllocate: true,
            hasExternalSideEffects: true,
            requiresMainActor: true
        ))
    }

    @Test("Unsupported actor executors fail closed")
    func rejectsUnsupportedActorIsolation() throws {
        for isolation in [
            "global_actor. type: Fixture.CustomActor",
            "actor_instance. name: self",
            "future_executor. payload: unknown",
        ] {
            let file = try CanonicalSIL.File(text: """
            // Isolation: \(isolation)
            sil private @$s7Fixture6helperyyF : $@convention(thin) () -> () {
            bb0:
              %0 = tuple ()
              return %0
            } // end sil function '$s7Fixture6helperyyF'
            """)
            let function = try #require(file.functions.first)
            #expect(throws: CanonicalSIL.ImageFunctions.DiscoveryError.self) {
                try CanonicalSIL.ImageFunctions.signature(
                    of: function,
                    environment: file.typeEnvironment,
                    symbol: function.mangledName,
                    kind: .closureBody
                )
            }
        }
    }

    @Test("Isolation metadata must be contiguous with its SIL declaration")
    func doesNotBorrowDetachedIsolationComment() throws {
        let file = try CanonicalSIL.File(text: """
        // Isolation: global_actor. type: MainActor

        sil private @$s7Fixture6helperyyF : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function '$s7Fixture6helperyyF'
        """)
        #expect(file.functions.first?.isolation == .unspecified)
    }

    @Test("Image helper discovery retains exact root provenance")
    func retainsRootProvenance() throws {
        let file = try CanonicalSIL.File(text: """
        sil @$s7Fixture5rootAyyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$s7Fixture7helperAyyF : $@convention(thin) () -> ()
          %1 = apply %0() : $@convention(thin) () -> ()
          return %1
        } // end sil function '$s7Fixture5rootAyyF'
        sil @$s7Fixture5rootByyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$s7Fixture7helperByyF : $@convention(thin) () -> ()
          %1 = apply %0() : $@convention(thin) () -> ()
          return %1
        } // end sil function '$s7Fixture5rootByyF'
        sil private @$s7Fixture7helperAyyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$s7Fixture6sharedyyF : $@convention(thin) () -> ()
          %1 = apply %0() : $@convention(thin) () -> ()
          return %1
        } // end sil function '$s7Fixture7helperAyyF'
        sil private @$s7Fixture7helperByyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$s7Fixture6sharedyyF : $@convention(thin) () -> ()
          %1 = apply %0() : $@convention(thin) () -> ()
          return %1
        } // end sil function '$s7Fixture7helperByyF'
        sil private @$s7Fixture6sharedyyF : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function '$s7Fixture6sharedyyF'
        """)
        let rootA = "$s7Fixture5rootAyyF"
        let rootB = "$s7Fixture5rootByyF"
        let discovered = try CanonicalSIL.ImageFunctions.discover(
            in: file,
            startingAt: [rootA, rootB],
            excluding: [rootA, rootB],
            environment: file.typeEnvironment,
            executionEffectsByRoot: [
                rootA: .init(mayAllocate: true),
                rootB: .init(hasExternalSideEffects: true),
            ],
            kindForSymbol: { _ in .ordinary }
        )
        #expect(discovered["$s7Fixture7helperAyyF"]?.executionEffectEnvelope
            == .init(mayAllocate: true))
        #expect(discovered["$s7Fixture7helperByyF"]?.executionEffectEnvelope
            == .init(hasExternalSideEffects: true))
        #expect(discovered["$s7Fixture6sharedyyF"]?.executionEffectEnvelope == .init(
            mayAllocate: true,
            hasExternalSideEffects: true
        ))
    }
}
}
