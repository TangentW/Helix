import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Native block bridge recognition")
struct NativeBlockBridge {
    @Test("Recognizes only compiler block-storage and noescape thunks")
    func recognizesCompilerThunks() {
        let storage = "$@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed "
            + "(Swift.Bool) -> (), Swift.Bool) -> ()"
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_ToTR",
            loweredType: storage
        ) == .storageInvoke)
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_To",
            loweredType: storage
        ) == nil)

        let adapter = "$@convention(thin) "
            + "(@guaranteed @noescape @callee_guaranteed @Sendable "
            + "@MainActor (Swift.Bool) -> ()) -> ()"
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_TR",
            loweredType: adapter
        ) == .nonescapingAdapter)
        #expect(CanonicalSIL.ClosureReabstraction
            .nonescapingAdapterClosureType(in: adapter)
            == "@MainActor (Swift.Bool) -> ()")
    }

    @Test("Rejects malformed or semantically different noescape adapters")
    func rejectsInvalidAdapters() {
        let invalid = [
            "$@convention(thin) (@callee_guaranteed (Swift.Bool) -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool) -> (), Swift.Int) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool) -> Swift.Int) -> ()",
            "$@convention(method) (@noescape @callee_guaranteed () -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed @Fixture.CustomActor () -> ()) -> ()",
        ]
        for type in invalid {
            #expect(CanonicalSIL.ClosureReabstraction
                .nonescapingAdapterClosureType(in: type) == nil)
            #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
                symbol: "$s7FixtureyyFTR",
                loweredType: type
            ) == nil)
        }
    }

    @Test("Block headers cannot substitute a different invoke thunk ABI")
    func rejectsMismatchedBlockHeaderThunk() {
        let referenced = "@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed () -> ()) -> ()"
        let substituted = "@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed "
            + "(Swift.Bool) -> (), Swift.Bool) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyyyXEF",
            loweredType: "@convention(thin) "
                + "(@owned @callee_guaranteed () -> ()) -> ()",
            body: """
            bb0(%0 : $@owned @callee_guaranteed () -> ()):
              %1 = alloc_stack $@block_storage @callee_guaranteed () -> ()
              %2 = function_ref @$s7Fixture3runyyyyXEFU_ToTR : $\(referenced)
              %3 = init_block_storage_header %1, invoke %2 : $\(substituted), type $@convention(block) () -> ()
              %4 = tuple ()
              return %4
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.run"
            )
        }
    }

    @Test("Read-only indirect callback parameters use one logical borrowed ABI")
    func normalizesIndirectCallbackParameters() throws {
        let notification = Core.TypeID(
            rawValue: .sha256("Foundation.Notification")
        )
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Notification": notification],
                kinds: [notification: .value]
            )
        let callee = Bytecode.FunctionID(rawValue: 7)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: "$s7Fixture7inspectyy10Foundation12NotificationVF",
                parameterTypes: [.native(notification)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(callee)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyy10Foundation12NotificationVYbcfU_",
            loweredType: "$@convention(thin) @Sendable "
                + "(@in_guaranteed Notification) -> ()",
            body: """
            bb0(%0 : $*Notification):
              %1 = function_ref @$s7Fixture7inspectyy10Foundation12NotificationVF : $@convention(thin) (@in_guaranteed Notification) -> ()
              %2 = apply %1(%0) : $@convention(thin) (@in_guaranteed Notification) -> ()
              %3 = tuple ()
              return %3
            """
        )

        let discovered = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: environment,
            symbol: function.mangledName,
            kind: .closureBody
        )
        #expect(discovered.parameters == [.native(notification)])
        #expect(discovered.parameterConventions == [.borrowed])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "Fixture.run callback",
            kind: .closureBody,
            directCalls: calls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        #expect(lowered.parameterConventions == [.borrowed])
        #expect(lowered.registerTypes[Int(parameter.rawValue)]
            == .native(notification))
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .apply(_, function, arguments) = instruction else {
                return false
            }
            return function == callee && arguments == [parameter]
        })
    }

    @Test("Type-erased callback payloads preserve borrowed ownership recursively")
    func borrowsTypeErasedCallbackPayloads() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyypSayypGSScfU_",
            loweredType: "$@convention(thin) "
                + "(@in_guaranteed Any, @guaranteed Array<Any>, "
                + "@guaranteed String) -> ()",
            body: """
            bb0(%0 : $*Any, %1 : @guaranteed $Array<Any>, %2 : @guaranteed $String):
              %3 = tuple ()
              return %3
            """
        )

        let signature = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: .empty,
            symbol: function.mangledName,
            kind: .closureBody
        )
        #expect(signature.parameters == [
            .any, .array(.any), .string,
        ])
        #expect(signature.parameterConventions == [
            .borrowed, .borrowed, .owned,
        ])
        #expect(Bytecode.ClosureSignature(
            parameters: signature.parameters,
            parameterConventions: signature.parameterConventions,
            result: signature.result,
            effects: Bytecode.ClosureSignature.callableEffects(
                from: signature.effects
            )
        ).isNativeBridgeCallback)
    }

    @Test("Static-method metatypes do not shift closure lifetime indices")
    func erasesStaticMethodMetatype() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let loweredType = "$@convention(method) "
            + "(@guaranteed @noescape @callee_guaranteed () -> (), "
            + "@thin Fixture.Type) -> ()"
        #expect(try CanonicalSIL.Lowerer().parseParameterConventions(
            loweredType,
            parameterTypes: [.closure(signature)],
            preservingClosureOwnership: true
        ) == [.borrowed])
        #expect(try CanonicalSIL.Lowerer().parseNativeCallbackLifetimes(
            loweredType,
            parameterTypes: [.closure(signature)]
        ) == [0: .nonescaping])
    }

    @Test("Nonescaping callbacks reject a consuming physical parameter ABI")
    func rejectsOwnedPhysicalNonescapingCallback() throws {
        let callbackSignature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 0, lifetime: .nonescaping),
            ]
        )
        let loweredSignature = Core.LoweredSignature(
            parameters: ["() -> Swift.Void"],
            result: "Swift.Void"
        )
        let key = try Core.NativeImportKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.callback-physical-ownership",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalCallee: "Fixture.invokeNow(_:)",
            signature: loweredSignature,
            effects: effects,
            contract: contract
        )
        let symbol = "$s7Fixture9invokeNowyyyyXEF"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.closure(callbackSignature)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .nativeImport(.init(
                    id: .init(rawValue: 0),
                    key: key,
                    signature: loweredSignature,
                    effects: effects,
                    contract: contract
                ))
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyF",
            loweredType: "$@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(symbol) : $@convention(thin) (@owned @noescape @callee_guaranteed () -> ()) -> ()
              %1 = tuple ()
              return %1
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.run",
                directCalls: calls
            )
        }
    }

    @Test("Rejects malformed callback binding metadata before lowering")
    func rejectsMalformedCallbackBindings() throws {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.DirectCallTable([
                .init(
                    mangledName: "$s7Fixture3runyySiF",
                    parameterTypes: [.int64],
                    parameterConventions: [],
                    resultType: .void,
                    target: .function(.init(rawValue: 0))
                ),
            ])
        }

        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 1, lifetime: .escaping),
            ]
        )
        let lowered = Core.LoweredSignature(
            parameters: ["() -> Swift.Void"],
            result: "Swift.Void"
        )
        let key = try Core.NativeImportKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.callback-table",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalCallee: "Fixture.run(_:)",
            signature: lowered,
            effects: effects,
            contract: contract
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 0),
            key: key,
            signature: lowered,
            effects: effects,
            contract: contract
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.DirectCallTable([
                .init(
                    mangledName: "$s7Fixture3runyyyyXEF",
                    parameterTypes: [.closure(signature)],
                    resultType: .void,
                    target: .nativeImport(requirement)
                ),
            ])
        }

        for (lifetime, invalidConvention) in [
            (
                Core.NativeImportCallbackLifetime.nonescaping,
                Bytecode.ParameterConvention.owned
            ),
            (
                Core.NativeImportCallbackLifetime.escaping,
                Bytecode.ParameterConvention.borrowed
            ),
        ] {
            let lifetimeContract = Core.NativeImportContract.bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 500,
                allowsMainThread: false,
                callbacks: [
                    .init(parameterIndex: 0, lifetime: lifetime),
                ]
            )
            let lifetimeSignature = Core.LoweredSignature(
                parameters: [
                    lifetime == .escaping
                        ? "@escaping () -> Swift.Void"
                        : "() -> Swift.Void",
                ],
                result: "Swift.Void"
            )
            let lifetimeKey = try Core.NativeImportKey.derive(
                namespace: .derive(
                    bundleID: "dev.helix.callback-table",
                    buildNumber: "1",
                    seed: "lifetime-\(lifetime.rawValue)"
                ),
                canonicalCallee: "Fixture.run(_:)",
                signature: lifetimeSignature,
                effects: effects,
                contract: lifetimeContract
            )
            let lifetimeRequirement = Bytecode.ImportRequirement(
                id: .init(rawValue: 0),
                key: lifetimeKey,
                signature: lifetimeSignature,
                effects: effects,
                contract: lifetimeContract
            )
            #expect(throws: CanonicalSIL.LoweringError.self) {
                try CanonicalSIL.DirectCallTable([
                    .init(
                        mangledName: "$s7Fixture3runyyyyXEF",
                        parameterTypes: [.closure(signature)],
                        parameterConventions: [invalidConvention],
                        resultType: .void,
                        target: .nativeImport(lifetimeRequirement)
                    ),
                ])
            }
        }
    }
}
}
