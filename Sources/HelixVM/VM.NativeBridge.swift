import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension VM {
public enum NativeInvocationResult: Equatable, Sendable {
    case returned(VM.Value?)
    case businessError(String)
}

public protocol NativeInvoker: Sendable {
    var id: Core.NativeImportID { get }
    var key: Core.NativeImportKey { get }
    var parameterTypes: [Bytecode.ValueType] { get }
    var resultType: Bytecode.ValueType { get }
    var effects: Core.Effects { get }
    var contract: Core.NativeImportContract { get }
    func invoke(
        arguments: [VM.Value],
        context: VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult
}

/// A synchronous import's only authority to consume work and observe deadlines.
/// Cooperative factories must checkpoint at least once before returning.
public struct NativeInvocationContext: Sendable {
    /// The context may be handed through a generated `@Sendable` invoker. All
    /// mutable admission state is lock-protected, and every operation also
    /// rejects use after the synchronous native invocation has finished.
    private final class State: @unchecked Sendable {
        let id: Core.NativeImportID
        let budget: VM.InvocationBudget
        let deadlineNanoseconds: UInt64
        let requiresCooperation: Bool
        let requiresMainActor: Bool
        let callbackByParameter: [Int: Core.NativeImportCallback]
        let parameterTypes: [Bytecode.ValueType]
        let callbackHost: VM.NativeCallbackHost?
        let callbackEpoch: VM.NativeCallbackEpoch?
        let lock = NSLock()
        var checkpointCount: UInt32 = 0
        var isFinished = false

        init(
            id: Core.NativeImportID,
            budget: VM.InvocationBudget,
            deadlineNanoseconds: UInt64,
            requiresCooperation: Bool,
            requiresMainActor: Bool,
            callbacks: [Core.NativeImportCallback],
            parameterTypes: [Bytecode.ValueType],
            callbackHost: VM.NativeCallbackHost?
        ) {
            self.id = id
            self.budget = budget
            self.deadlineNanoseconds = deadlineNanoseconds
            self.requiresCooperation = requiresCooperation
            self.requiresMainActor = requiresMainActor
            callbackByParameter = callbacks.isEmpty ? [:] : Dictionary(
                uniqueKeysWithValues: callbacks.map {
                    (Int($0.parameterIndex), $0)
                }
            )
            self.parameterTypes = callbacks.isEmpty ? [] : parameterTypes
            self.callbackHost = callbacks.isEmpty ? nil : callbackHost
            callbackEpoch = callbacks.isEmpty
                ? nil
                : VM.NativeCallbackEpoch(budget: budget)
        }
    }

    private let state: State

    init(
        id: Core.NativeImportID,
        budget: VM.InvocationBudget,
        deadlineNanoseconds: UInt64,
        requiresCooperation: Bool,
        requiresMainActor: Bool,
        callbacks: [Core.NativeImportCallback],
        parameterTypes: [Bytecode.ValueType],
        callbackHost: VM.NativeCallbackHost?
    ) {
        state = State(
            id: id,
            budget: budget,
            deadlineNanoseconds: deadlineNanoseconds,
            requiresCooperation: requiresCooperation,
            requiresMainActor: requiresMainActor,
            callbacks: callbacks,
            parameterTypes: parameterTypes,
            callbackHost: callbackHost
        )
    }

    /// Exports one VM closure through the lifetime frozen for a NativeImport parameter.
    public func makeCallback(
        parameterIndex: Int,
        from value: VM.Value
    ) throws -> VM.NativeCallback {
        // Keep liveness validation, graph inspection, and handle publication
        // atomic with finish() so no callback can be exported after teardown.
        try state.lock.withLock {
            guard !state.isFinished else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native invocation context escaped its synchronous call"
                )
            }
            guard let callback = state.callbackByParameter[parameterIndex] else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native import parameter \(parameterIndex) is not authorized as a callback"
                )
            }
            guard let host = state.callbackHost else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native callback export has no pinned Runtime host"
                )
            }
            guard let epoch = state.callbackEpoch else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native callback export has no active callback epoch"
                )
            }
            guard state.parameterTypes.indices.contains(parameterIndex),
                  let expectedShape = state.parameterTypes[parameterIndex]
                    .directClosureShape,
                  case let .closure(closure) = value,
                  closure.isNativeCallbackTarget,
                  closure.signature == expectedShape.signature,
                  closure.signature.isNativeBridgeCallback
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native callback export received an unsupported closure value"
                )
            }
            if callback.lifetime == .escaping,
               try VM.ValueGraph.containsClosureScope(
                   in: value,
                   matching: { _ in true },
                   budget: state.budget
               ) {
                throw VM.RuntimeTrap.nativeFailure(
                    "a dynamically scoped closure cannot escape through NativeImport"
                )
            }
            return VM.NativeCallback(
                closure: closure,
                lifetime: callback.lifetime,
                epoch: epoch,
                host: host
            )
        }
    }

    public func checkpoint(workUnits: UInt64 = 0) throws {
        try state.lock.withLock {
            guard !state.isFinished else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native invocation context escaped its synchronous call"
                )
            }
            try state.budget.checkpointNativeInvocation(
                id: state.id,
                deadlineNanoseconds: state.deadlineNanoseconds,
                workUnits: workUnits
            )
            let next = state.checkpointCount.addingReportingOverflow(1)
            guard !next.overflow else {
                throw VM.RuntimeTrap.instructionFuelExhausted
            }
            state.checkpointCount = next.partialValue
        }
    }

    package var resourceLimits: Core.ResourceLimits {
        state.budget.resourceLimits
    }

    /// Polls both the root and exact NativeImport deadlines without satisfying
    /// a cooperative-import checkpoint. Result encoding occurs after the
    /// native operation, so it must not mask a factory that failed to cooperate
    /// while doing its own work.
    package func checkResultEncodingDeadline() throws {
        try state.lock.withLock {
            guard !state.isFinished else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native invocation context escaped its synchronous call"
                )
            }
            try state.budget.checkNativeInvocationDeadline(
                id: state.id,
                deadlineNanoseconds: state.deadlineNanoseconds
            )
        }
    }

    /// Enters MainActor only for a descriptor that was frozen as MainActor-bound
    /// and after the interpreter has proved that the current thread is main.
    public func withMainActor<Result: Sendable>(
        _ operation: @MainActor () throws -> Result
    ) throws -> Result {
        try state.lock.withLock {
            guard !state.isFinished else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native invocation context escaped its synchronous call"
                )
            }
            guard state.requiresMainActor else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native import is not authorized to assume MainActor"
                )
            }
        }
        guard Thread.isMainThread else { throw VM.RuntimeTrap.mainActorViolation }
        try checkpoint()
        return try MainActor.assumeIsolated(operation)
    }

    func finish(requireCooperation: Bool) throws {
        let snapshot = try state.lock.withLock { () -> UInt32 in
            guard !state.isFinished else {
                throw VM.RuntimeTrap.nativeFailure("native invocation context finished twice")
            }
            state.isFinished = true
            return state.checkpointCount
        }
        let callbackFailure = state.callbackEpoch?.finish()
        try state.budget.finishNativeInvocation(
            id: state.id,
            deadlineNanoseconds: state.deadlineNanoseconds,
            requiresCooperation: requireCooperation && state.requiresCooperation,
            checkpointCount: snapshot
        )
        if let callbackFailure { throw callbackFailure }
    }
}

/// Implemented by App code that explicitly exposes one typed operation to an
/// HLBC patch. The generated Shell supplies the immutable ID and key.
public protocol NativeImportFactory {
    static func make(
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> any VM.NativeInvoker
}

/// A small concrete invoker for factory implementations that do not need a
/// dedicated nominal type. Descriptor checks still occur before execution.
public struct ClosureNativeInvoker: VM.NativeInvoker {
    public let id: Core.NativeImportID
    public let key: Core.NativeImportKey
    public let parameterTypes: [Bytecode.ValueType]
    public let resultType: Bytecode.ValueType
    public let effects: Core.Effects
    public let contract: Core.NativeImportContract
    private let body: @Sendable (
        [VM.Value],
        VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult

    public init(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        contract: Core.NativeImportContract,
        invoke: @escaping @Sendable (
            [VM.Value],
            VM.NativeInvocationContext
        ) throws -> VM.NativeInvocationResult
    ) {
        self.id = id
        self.key = key
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.effects = effects
        self.contract = contract
        body = invoke
    }

    public func invoke(
        arguments: [VM.Value],
        context: VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult {
        try body(arguments, context)
    }
}

public struct NativeCatalog: Sendable {
    private let invokers: [Core.NativeImportID: any VM.NativeInvoker]

    public init() {
        invokers = [:]
    }

    public init(_ invokers: [any VM.NativeInvoker]) throws {
        var table: [Core.NativeImportID: any VM.NativeInvoker] = [:]
        for invoker in invokers {
            do {
                try invoker.contract.validate(effects: invoker.effects)
            } catch {
                throw VM.RuntimeTrap.nativeFailure(
                    "invalid native import \(invoker.id) contract: \(error)"
                )
            }
            guard table.updateValue(invoker, forKey: invoker.id) == nil else {
                throw VM.RuntimeTrap.nativeFailure("duplicate native import \(invoker.id)")
            }
        }
        self.invokers = table
    }

    public subscript(id: Core.NativeImportID) -> (any VM.NativeInvoker)? {
        invokers[id]
    }
}

public typealias EntryInvocation = @Sendable (
    _ entry: Core.EntryIndex,
    _ arguments: [VM.Value],
    _ budget: VM.InvocationBudget
) -> VM.EntryInvocationResult
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
