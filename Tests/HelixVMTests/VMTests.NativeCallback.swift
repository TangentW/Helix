import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVM

extension VMTests {
@Suite("Native callback lifetime")
struct NativeCallback {
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

    @Test("Returning while a nonescaping callback executes fails the import")
    func nonescapingCallbackCannotOverlapReturn() throws {
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
            contract: contract(lifetime: .nonescaping),
            parameterTypes: [.closure(closure().signature)],
            callbackHost: .init(invoke: { _, _, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                return .returned(nil)
            }),
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
        try #require(entered.wait(timeout: .now() + 10) == .success)

        #expect(throws: VM.RuntimeTrap.nativeFailure(
            "nonescaping native callback was still executing when its importing call returned"
        )) {
            try context.finish(requireCooperation: true)
        }
        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)
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

    private func closure() -> VM.Closure {
        .init(
            functionID: .init(rawValue: 7),
            signature: .init(
                parameters: [.bool],
                parameterConventions: [.owned],
                result: .void
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
