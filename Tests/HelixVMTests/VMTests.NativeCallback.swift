import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Native callback lifetime")
struct NativeCallback {
    @Test("Native callbacks admit only exact or stricter MainActor signatures")
    func callbackRequiresCanonicalSignature() throws {
        let box = InvocationBox()
        let expected = closure().signature
        let value = VM.Value.closure(.init(
            functionID: .init(rawValue: 7),
            signature: expected,
            captures: []
        ))
        #expect(expected.hasCanonicalCallableEffects)
        #expect(value.matches(.closure(expected)))
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(expected)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        _ = try context.makeCallback(
            parameterIndex: 0,
            from: value
        )
        try context.finish(requireCooperation: true)

        var authorityInType = expected
        authorityInType.effects.mayAllocate = true
        authorityInType.effects.hasExternalSideEffects = true
        #expect(!authorityInType.hasCanonicalCallableEffects)
        let authorityBudget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let authorityContext = try authorityBudget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(expected)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        #expect(throws: VM.RuntimeTrap.self) {
            try authorityContext.makeCallback(
                parameterIndex: 0,
                from: .closure(.init(
                    functionID: .init(rawValue: 7),
                    signature: authorityInType,
                    captures: []
                ))
            )
        }
        try authorityContext.finish(requireCooperation: true)

        var actorMismatch = expected
        actorMismatch.effects.requiresMainActor = true
        let mismatchBudget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let mismatchContext = try mismatchBudget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(expected)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        let restricted = try mismatchContext.makeCallback(
            parameterIndex: 0,
            from: .closure(.init(
                functionID: .init(rawValue: 7),
                signature: actorMismatch,
                captures: []
            ))
        )
        #expect(restricted.signature == actorMismatch)
        try mismatchContext.finish(requireCooperation: true)
    }

    @Test("Nonescaping callback shares its import budget and expires on return")
    func nonescapingLifetime() throws {
        let box = InvocationBox()
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        callback.invokeVoid { [.bool(true)] }
        try context.finish(requireCooperation: true)

        #expect(box.arguments == [[.bool(true)]])
        #expect(box.budgets.count == 1)
        #expect(box.budgets[0] === budget)

        callback.invokeVoid { [.bool(false)] }
        #expect(box.arguments.count == 1)
        #expect(box.failures == [
            .nativeFailure("nonescaping native callback outlived its importing call"),
        ])
    }

    @Test("Escaping callback drops the completed import budget but remains callable")
    func escapingLifetime() throws {
        let box = InvocationBox()
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        try context.finish(requireCooperation: true)
        callback.invokeVoid { [.bool(true)] }

        #expect(box.arguments == [[.bool(true)]])
        #expect(box.budgets.count == 1)
        #expect(box.budgets[0] == nil)
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "native invocation context escaped its synchronous call"
            )
        ) {
            try context.makeCallback(
                parameterIndex: 0,
                from: .closure(closure())
            )
        }
    }

    @Test("Escaping callbacks reject lexical scopes hidden in deep capture graphs")
    func escapingRejectsNestedLexicalScope() throws {
        let box = InvocationBox()
        let signature = closure().signature
        let lexical = VM.Closure(
            target: .bytecode(.image(.init(rawValue: 8))),
            signature: signature,
            captures: [],
            dynamicScope: .init()
        )
        func outer(capturing value: VM.Value) -> VM.Closure {
            .init(
                target: .bytecode(.image(.init(rawValue: 7))),
                signature: signature,
                captures: [value],
                dynamicScope: nil
            )
        }
        func expectEscapingRejection(_ candidate: VM.Closure) throws {
            let budget = VM.InvocationBudget(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
                isMainThread: false,
                nowNanoseconds: { 0 }
            )
            let context = try budget.beginNativeInvocation(
                id: .init(rawValue: 0),
                effects: .init(),
                contract: contract(lifetime: .escaping),
                parameterTypes: [.closure(signature)],
                callbackHost: host(box: box),
                isMainThread: false
            )
            #expect(
                throws: VM.RuntimeTrap.nativeFailure(
                    "a dynamically scoped closure cannot escape through NativeImport"
                )
            ) {
                try context.makeCallback(
                    parameterIndex: 0,
                    from: .closure(candidate)
                )
            }
            try context.finish(requireCooperation: true)
        }

        let arrayCapture = VM.Value.array(
            [.closure(lexical)],
            elementType: .closure(signature)
        )
        try expectEscapingRejection(outer(capturing: arrayCapture))

        let cell = VM.MutableCell(
            initialValue: .closure(lexical),
            pointee: .closure(signature),
            shape: .leaf
        )
        try expectEscapingRejection(outer(capturing: .mutableCell(cell)))

        let weakType = Bytecode.LocalTypeKey(
            rawValue: "Fixture.WeakCapture"
        )
        let weakObject = VM.ObjectReference(
            typeKey: weakType,
            fieldCount: 1
        )
        let weakField = try weakObject.address(
            field: 0,
            pointee: .closure(signature)
        ).begin(.modify)
        try weakField.store(.closure(lexical), mode: .initialize)
        try weakField.end()
        let liveWeakReference = VM.NonOwningReference(
            kind: .weak,
            pointee: .optional(.local(weakType)),
            target: .local(weakType)
        )
        try liveWeakReference.store(
            object: weakObject,
            mode: .initialize
        )
        try expectEscapingRejection(
            outer(capturing: .nonOwningReference(liveWeakReference))
        )
        let liveUnownedReference = VM.NonOwningReference(
            kind: .unowned,
            pointee: .local(weakType),
            target: .local(weakType)
        )
        try liveUnownedReference.store(
            object: weakObject,
            mode: .initialize
        )
        try expectEscapingRejection(
            outer(capturing: .nonOwningReference(liveUnownedReference))
        )

        let deadWeakReference = VM.NonOwningReference(
            kind: .weak,
            pointee: .optional(.local(weakType)),
            target: .local(weakType)
        )
        do {
            let releasedObject = VM.ObjectReference(
                typeKey: weakType,
                fieldCount: 1
            )
            let releasedField = try releasedObject.address(
                field: 0,
                pointee: .closure(signature)
            ).begin(.modify)
            try releasedField.store(
                .closure(lexical),
                mode: .initialize
            )
            try releasedField.end()
            try deadWeakReference.store(
                object: releasedObject,
                mode: .initialize
            )
        }
        #expect(
            try deadWeakReference.loadObject(mode: .copy) == nil
        )
        let deadWeakBudget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let deadWeakContext = try deadWeakBudget.beginNativeInvocation(
            id: .init(rawValue: 2),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(signature)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        _ = try deadWeakContext.makeCallback(
            parameterIndex: 0,
            from: .closure(
                outer(capturing: .nonOwningReference(deadWeakReference))
            )
        )
        try deadWeakContext.finish(requireCooperation: true)

        let object = VM.ObjectReference(
            typeKey: .init(rawValue: "Fixture.RecursiveCapture"),
            fieldCount: 1
        )
        let cyclic = VM.Closure(
            target: .bytecode(.image(.init(rawValue: 7))),
            signature: signature,
            captures: [.object(object), .closure(lexical)],
            dynamicScope: nil
        )
        let field = try object.address(
            field: 0,
            pointee: .closure(signature)
        ).begin(.modify)
        try field.store(.closure(cyclic), mode: .initialize)
        try field.end()
        try expectEscapingRejection(cyclic)

        let nonescapingBudget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let nonescapingContext = try nonescapingBudget.beginNativeInvocation(
            id: .init(rawValue: 1),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(signature)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        _ = try nonescapingContext.makeCallback(
            parameterIndex: 0,
            from: .closure(outer(capturing: arrayCapture))
        )
        try nonescapingContext.finish(requireCooperation: true)
    }

    @Test("Synchronous callback failure becomes the importing VM trap")
    func synchronousFailurePropagation() throws {
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: .init(invoke: { _, _, _ in
                .trapped(.explicit("callback failed"))
            }),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        callback.invokeVoid { [.bool(true)] }
        #expect(throws: VM.RuntimeTrap.explicit("callback failed")) {
            try context.finish(requireCooperation: true)
        }
    }

    @Test("A result-producing callback decodes its exact VM result")
    func resultRoundTrip() throws {
        let signature = closure(result: .int64).signature
        let returned = try VM.Integer(
            signed: 42,
            bitWidth: 64,
            isSigned: true
        )
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(signature)],
            callbackHost: .init(invoke: { _, _, _ in
                .returned(.integer(returned))
            }),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure(result: .int64))
        )

        let value: Int64 = callback.invokeResult(
            arguments: { [.bool(true)] },
            decodeResult: { value in
                guard case let .integer(integer) = value else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: value.type
                    )
                }
                return integer.signedValue
            },
            failureResult: { -1 }
        )

        #expect(value == 42)
        try context.finish(requireCooperation: true)
    }

    @Test("A synchronous result failure returns fallback and fails its importer")
    func synchronousResultFailure() throws {
        let signature = closure(result: .bool).signature
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(signature)],
            callbackHost: .init(invoke: { _, _, _ in
                .trapped(.explicit("result callback failed"))
            }),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure(result: .bool))
        )

        let value: Bool = callback.invokeResult(
            arguments: { [.bool(true)] },
            decodeResult: { _ in true },
            failureResult: { false }
        )

        #expect(!value)
        #expect(throws: VM.RuntimeTrap.explicit("result callback failed")) {
            try context.finish(requireCooperation: true)
        }
    }

    @Test("A synchronous result decoding failure is retained by its importer")
    func synchronousResultDecodeFailure() throws {
        let signature = closure(result: .bool).signature
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(signature)],
            callbackHost: .init(invoke: { _, _, _ in
                .returned(.bool(true))
            }),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure(result: .bool))
        )

        let value: Bool = callback.invokeResult(
            arguments: { [.bool(true)] },
            decodeResult: { _ in
                throw VM.RuntimeTrap.explicit("result decode failed")
            },
            failureResult: { false }
        )

        #expect(!value)
        #expect(throws: VM.RuntimeTrap.explicit("result decode failed")) {
            try context.finish(requireCooperation: true)
        }
    }

    @Test("Detached result decoding failures return fallback and report telemetry")
    func detachedResultDecodeFailure() throws {
        let box = InvocationBox()
        let signature = closure(result: .bool).signature
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(signature)],
            callbackHost: .init(
                invoke: { _, arguments, callbackBudget in
                    box.record(arguments: arguments, budget: callbackBudget)
                    return .returned(.bool(true))
                },
                reportFailure: { box.record(failure: $0) }
            ),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure(result: .bool))
        )
        try context.finish(requireCooperation: true)

        let value: Bool = callback.invokeResult(
            arguments: { [.bool(true)] },
            decodeResult: { _ in
                throw VM.RuntimeTrap.explicit("result decode failed")
            },
            failureResult: { false }
        )

        #expect(!value)
        #expect(box.arguments == [[.bool(true)]])
        #expect(box.budgets.count == 1)
        #expect(box.budgets[0] == nil)
        #expect(box.failures == [.explicit("result decode failed")])
    }

    @Test("Same-thread recursive invocation is admitted by one callback handle")
    func sameThreadRecursion() throws {
        let box = InvocationBox()
        let callbackBox = CallbackBox()
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: .init(
                invoke: { _, arguments, callbackBudget in
                    box.record(arguments: arguments, budget: callbackBudget)
                    if arguments == [.bool(true)] {
                        callbackBox.value?.invokeVoid { [.bool(false)] }
                    }
                    return .returned(nil)
                },
                reportFailure: { box.record(failure: $0) }
            ),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        callbackBox.value = callback
        callback.invokeVoid { [.bool(true)] }
        try context.finish(requireCooperation: true)

        #expect(box.arguments == [[.bool(true)], [.bool(false)]])
        #expect(box.budgets.allSatisfy { $0 === budget })
        #expect(box.failures.isEmpty)
    }

    @Test("An active callback cannot cross threads before its import returns")
    func activeCallbackCannotCrossThread() throws {
        let box = InvocationBox()
        let finished = DispatchSemaphore(value: 0)
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: host(box: box),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        let worker = Thread {
            callback.invokeVoid { [.bool(true)] }
            finished.signal()
        }
        worker.start()
        try #require(finished.wait(timeout: .now() + 10) == .success)

        #expect(throws: VM.RuntimeTrap.nativeFailure(
            "concurrent invocation of a non-Sendable native callback is unsupported"
        )) {
            try context.finish(requireCooperation: true)
        }
        #expect(box.arguments.isEmpty)
        #expect(box.failures.isEmpty)
    }

    @Test("Overlapping cross-thread calls fail closed without entering the host twice")
    func rejectsConcurrentInvocation() throws {
        let box = InvocationBox()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: .init(
                invoke: { _, arguments, callbackBudget in
                    box.record(arguments: arguments, budget: callbackBudget)
                    entered.signal()
                    _ = release.wait(timeout: .now() + 10)
                    return .returned(nil)
                },
                reportFailure: { box.record(failure: $0) }
            ),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure())
        )
        try context.finish(requireCooperation: true)

        let worker = Thread {
            callback.invokeVoid { [.bool(true)] }
            finished.signal()
        }
        worker.start()
        try #require(entered.wait(timeout: .now() + 10) == .success)
        callback.invokeVoid { [.bool(false)] }
        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)

        #expect(box.arguments == [[.bool(true)]])
        #expect(box.failures == [
            .nativeFailure(
                "concurrent invocation of a non-Sendable native callback is unsupported"
            ),
        ])
    }

    @Test("Result decoding remains inside the serialized callback admission")
    func serializesResultDecoding() throws {
        let box = InvocationBox()
        let decoding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let signature = closure(result: .bool).signature
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract(lifetime: .escaping),
            parameterTypes: [.closure(signature)],
            callbackHost: .init(
                invoke: { _, arguments, callbackBudget in
                    box.record(arguments: arguments, budget: callbackBudget)
                    return .returned(.bool(true))
                },
                reportFailure: { box.record(failure: $0) }
            ),
            isMainThread: false
        )
        let callback = try context.makeCallback(
            parameterIndex: 0,
            from: .closure(closure(result: .bool))
        )
        try context.finish(requireCooperation: true)

        let worker = Thread {
            let _: Bool = callback.invokeResult(
                arguments: { [.bool(true)] },
                decodeResult: { _ in
                    decoding.signal()
                    _ = release.wait(timeout: .now() + 10)
                    return true
                },
                failureResult: { false }
            )
            finished.signal()
        }
        worker.start()
        try #require(decoding.wait(timeout: .now() + 10) == .success)
        let overlapping: Bool = callback.invokeResult(
            arguments: { [.bool(false)] },
            decodeResult: { _ in true },
            failureResult: { false }
        )
        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)

        #expect(!overlapping)
        #expect(box.arguments == [[.bool(true)]])
        #expect(box.failures == [
            .nativeFailure(
                "concurrent invocation of a non-Sendable native callback is unsupported"
            ),
        ])
    }

    @Test("Distinct escaping handles share one non-Sendable execution domain")
    func rejectsConcurrentInvocationAcrossHandles() throws {
        let box = InvocationBox()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let sharedHost = VM.NativeCallbackHost(
            invoke: { _, arguments, callbackBudget in
                box.record(arguments: arguments, budget: callbackBudget)
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                return .returned(nil)
            },
            reportFailure: { box.record(failure: $0) }
        )

        func makeCallback() throws -> VM.NativeCallback {
            let budget = VM.InvocationBudget(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
                isMainThread: false,
                nowNanoseconds: { 0 }
            )
            let context = try budget.beginNativeInvocation(
                id: .init(rawValue: 0),
                effects: .init(),
                contract: contract(lifetime: .escaping),
                parameterTypes: [.closure(closure().signature)],
                callbackHost: sharedHost,
                isMainThread: false
            )
            let callback = try context.makeCallback(
                parameterIndex: 0,
                from: .closure(closure())
            )
            try context.finish(requireCooperation: true)
            return callback
        }

        let first = try makeCallback()
        let second = try makeCallback()
        let worker = Thread {
            first.invokeVoid { [.bool(true)] }
            finished.signal()
        }
        worker.start()
        try #require(entered.wait(timeout: .now() + 10) == .success)
        second.invokeVoid { [.bool(false)] }
        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)

        #expect(box.arguments == [[.bool(true)]])
        #expect(box.failures == [
            .nativeFailure(
                "concurrent invocation of a non-Sendable native callback is unsupported"
            ),
        ])
    }

    private func contract(
        lifetime: Core.NativeImportCallbackLifetime
    ) -> Core.NativeImportContract {
        .bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [.init(parameterIndex: 0, lifetime: lifetime)]
        )
    }

    private func closure(result: Bytecode.ValueType = .void) -> VM.Closure {
        .init(
            functionID: .init(rawValue: 7),
            signature: .init(
                parameters: [.bool],
                parameterConventions: [.owned],
                result: result
            ),
            captures: []
        )
    }

    private func host(box: InvocationBox) -> VM.NativeCallbackHost {
        .init(
            invoke: { _, arguments, budget in
                box.record(arguments: arguments, budget: budget)
                return .returned(nil)
            },
            reportFailure: { box.record(failure: $0) }
        )
    }

    private final class InvocationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var argumentStorage: [[VM.Value]] = []
        private var budgetStorage: [VM.InvocationBudget?] = []
        private var failureStorage: [VM.RuntimeTrap] = []

        var arguments: [[VM.Value]] { lock.withLock { argumentStorage } }
        var budgets: [VM.InvocationBudget?] { lock.withLock { budgetStorage } }
        var failures: [VM.RuntimeTrap] { lock.withLock { failureStorage } }

        func record(arguments: [VM.Value], budget: VM.InvocationBudget?) {
            lock.withLock {
                argumentStorage.append(arguments)
                budgetStorage.append(budget)
            }
        }

        func record(failure: VM.RuntimeTrap) {
            lock.withLock { failureStorage.append(failure) }
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: VM.NativeCallback?

        var value: VM.NativeCallback? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
