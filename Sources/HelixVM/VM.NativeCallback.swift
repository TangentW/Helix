import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension VM {
/// Serializes native callback execution until Helix models Swift `Sendable`
/// closure semantics. The recursive lock admits ordinary same-thread callback
/// re-entry while rejecting overlapping work from another thread.
package final class NativeCallbackExecutionGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    package init() {}

    func tryEnter() -> Bool {
        lock.try()
    }

    func leave() {
        lock.unlock()
    }
}

/// Runtime-owned route used by a NativeImport callback to re-enter its pinned image.
public struct NativeCallbackHost: Sendable {
    let resourceLimits: Core.ResourceLimits
    private let executionGate: VM.NativeCallbackExecutionGate
    private let invocation: @Sendable (
        VM.Closure,
        [VM.Value],
        VM.InvocationBudget?
    ) -> VM.ExecutionResult
    private let failureReporter: @Sendable (VM.RuntimeTrap) -> Void

    public init(
        resourceLimits: Core.ResourceLimits = .init(),
        invoke: @escaping @Sendable (
            VM.Closure,
            [VM.Value],
            VM.InvocationBudget?
        ) -> VM.ExecutionResult,
        reportFailure: @escaping @Sendable (VM.RuntimeTrap) -> Void = { _ in }
    ) {
        self.init(
            resourceLimits: resourceLimits,
            executionGate: .init(),
            invoke: invoke,
            reportFailure: reportFailure
        )
    }

    package init(
        resourceLimits: Core.ResourceLimits,
        executionGate: VM.NativeCallbackExecutionGate,
        invoke: @escaping @Sendable (
            VM.Closure,
            [VM.Value],
            VM.InvocationBudget?
        ) -> VM.ExecutionResult,
        reportFailure: @escaping @Sendable (VM.RuntimeTrap) -> Void = { _ in }
    ) {
        self.resourceLimits = resourceLimits
        self.executionGate = executionGate
        invocation = invoke
        failureReporter = reportFailure
    }

    func invoke(
        closure: VM.Closure,
        arguments: [VM.Value],
        preferredBudget: VM.InvocationBudget?
    ) -> VM.ExecutionResult {
        invocation(closure, arguments, preferredBudget)
    }

    func reportFailure(_ trap: VM.RuntimeTrap) {
        failureReporter(trap)
    }

    func tryEnterExecution() -> Bool {
        executionGate.tryEnter()
    }

    func leaveExecution() {
        executionGate.leave()
    }
}

/// A Sendable native-facing handle for one verified VM closure.
///
/// Generated adapters expose typed Swift closures around this handle. The handle
/// itself owns neither Swift ABI casts nor framework-specific behavior.
public final class NativeCallback: @unchecked Sendable {
    public let signature: Bytecode.ClosureSignature
    public let lifetime: Core.NativeImportCallbackLifetime
    /// Signed generation limits used to bound generated native-argument
    /// encoding before the resulting VM values enter the interpreter.
    public let resourceLimits: Core.ResourceLimits

    private let closure: VM.Closure
    private let epoch: VM.NativeCallbackEpoch
    private let host: VM.NativeCallbackHost

    init(
        closure: VM.Closure,
        lifetime: Core.NativeImportCallbackLifetime,
        epoch: VM.NativeCallbackEpoch,
        host: VM.NativeCallbackHost
    ) {
        signature = closure.signature
        self.lifetime = lifetime
        resourceLimits = host.resourceLimits
        self.closure = closure
        self.epoch = epoch
        self.host = host
    }

    /// Invokes a callback whose frozen result is Void.
    ///
    /// Native nonthrowing callback ABIs have no error channel. Failures are
    /// therefore captured by the enclosing synchronous NativeImport when it is
    /// still active, or reported to Runtime telemetry after an escaping call.
    public func invokeVoid(
        arguments encodeArguments: () throws -> [VM.Value]
    ) {
        let admission: VM.NativeCallbackEpoch.Admission
        do {
            admission = try epoch.begin(lifetime: lifetime)
        } catch let trap as VM.RuntimeTrap {
            if !epoch.recordFailure(trap) { host.reportFailure(trap) }
            return
        } catch {
            host.reportFailure(.nativeFailure(String(describing: error)))
            return
        }
        defer { epoch.end(admission) }
        guard host.tryEnterExecution() else {
            record(
                .nativeFailure(
                    "concurrent invocation of a non-Sendable native callback is unsupported"
                ),
                admittedDuringNativeInvocation: admission.wasActive
            )
            return
        }
        defer { host.leaveExecution() }

        let arguments: [VM.Value]
        do {
            arguments = try encodeArguments()
        } catch let trap as VM.RuntimeTrap {
            record(trap, admittedDuringNativeInvocation: admission.wasActive)
            return
        } catch {
            record(
                .nativeFailure("native callback argument encoding failed: \(error)"),
                admittedDuringNativeInvocation: admission.wasActive
            )
            return
        }
        guard arguments.count == signature.parameters.count,
              zip(arguments, signature.parameters).allSatisfy({
                  $0.matches($1)
              })
        else {
            record(
                .typeMismatch(
                    expected: .tuple(signature.parameters),
                    actual: .tuple(arguments.map(\.type))
                ),
                admittedDuringNativeInvocation: admission.wasActive
            )
            return
        }

        let result = host.invoke(
            closure: closure,
            arguments: arguments,
            preferredBudget: admission.budget
        )
        switch result {
        case .returned(nil):
            break
        case .returned(.some(let value)):
            record(
                .typeMismatch(expected: .void, actual: value.type),
                admittedDuringNativeInvocation: admission.wasActive
            )
        case let .businessError(message):
            record(
                .nativeFailure("nonthrowing native callback raised an error: \(message)"),
                admittedDuringNativeInvocation: admission.wasActive
            )
        case let .trapped(trap):
            // The host reports interpreter traps with their deepest program
            // counter. Only retain the failure for a still-active importer.
            if admission.wasActive { epoch.recordFailure(trap) }
        }
    }

    /// Polls the originating invocation deadline while it is still active.
    /// A detached escaping callback receives a fresh deadline from Runtime's
    /// bounded input encoder instead.
    public func checkInputEncodingDeadline() throws {
        try epoch.checkActiveDeadline()
    }

    private func record(
        _ trap: VM.RuntimeTrap,
        admittedDuringNativeInvocation: Bool
    ) {
        if admittedDuringNativeInvocation {
            if !epoch.recordFailure(trap) { host.reportFailure(trap) }
        } else {
            host.reportFailure(trap)
        }
    }
}
}

extension VM {
final class NativeCallbackEpoch: @unchecked Sendable {
    struct Admission {
        var budget: VM.InvocationBudget?
        var wasActive: Bool
        var isNonescaping: Bool
    }

    private let lock = NSLock()
    private let originatingThread = ObjectIdentifier(Thread.current)
    private var budget: VM.InvocationBudget?
    private var isActive = true
    private var activeNonescapingCalls = 0
    private var firstFailure: VM.RuntimeTrap?

    init(budget: VM.InvocationBudget) {
        self.budget = budget
    }

    func begin(
        lifetime: Core.NativeImportCallbackLifetime
    ) throws -> Admission {
        try lock.withLock {
            if lifetime == .nonescaping, !isActive {
                throw VM.RuntimeTrap.nativeFailure(
                    "nonescaping native callback outlived its importing call"
                )
            }
            if isActive,
               ObjectIdentifier(Thread.current) != originatingThread {
                throw VM.RuntimeTrap.nativeFailure(
                    "concurrent invocation of a non-Sendable native callback is unsupported"
                )
            }
            if lifetime == .nonescaping { activeNonescapingCalls += 1 }
            return Admission(
                budget: isActive ? budget : nil,
                wasActive: isActive,
                isNonescaping: lifetime == .nonescaping
            )
        }
    }

    func end(_ admission: Admission) {
        guard admission.isNonescaping else { return }
        lock.withLock {
            precondition(activeNonescapingCalls > 0)
            activeNonescapingCalls -= 1
        }
    }

    @discardableResult
    func recordFailure(_ trap: VM.RuntimeTrap) -> Bool {
        lock.withLock {
            guard isActive else { return false }
            if firstFailure == nil { firstFailure = trap }
            return true
        }
    }

    func finish() -> VM.RuntimeTrap? {
        lock.withLock {
            precondition(isActive, "native callback epoch finished twice")
            isActive = false
            budget = nil
            if activeNonescapingCalls > 0, firstFailure == nil {
                firstFailure = .nativeFailure(
                    "nonescaping native callback was still executing when its importing call returned"
                )
            }
            return firstFailure
        }
    }

    func checkActiveDeadline() throws {
        let activeBudget = lock.withLock { isActive ? budget : nil }
        try activeBudget?.checkDeadline()
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
