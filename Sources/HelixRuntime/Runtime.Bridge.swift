import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Result of asking Runtime to route one exact-ABI generated wrapper.
public enum BridgeDispatchResult<Result> {
    /// The wrapper must call its lexical previous/original Swift implementation.
    case originalRequired
    /// Patched code returned a decoded Swift result.
    case returned(Result)
}

/// Stable gateway called by compiler-generated wrappers in the App binary.
///
/// The bridge is installed once with a compatible ``Engine``. Unpatched calls
/// stay on a low-cost original path; patched calls lazily encode arguments only
/// after route resolution proves that a generation supplies the entry.
public final class Bridge: @unchecked Sendable {
    /// Process-wide bridge used by generated App wrappers.
    public static let shared = Runtime.Bridge()

    private final class OriginalBypassState: NSObject {
        var depths: [Core.EntryIndex: Int] = [:]
    }

    private final class Installation: @unchecked Sendable {
        let runtime: Runtime.Engine
        let runtimeID: ObjectIdentifier
        let interfaceHash: Core.Digest
        let registrationCount: UInt32

        init(
            runtime: Runtime.Engine,
            runtimeID: ObjectIdentifier,
            interfaceHash: Core.Digest,
            registrationCount: UInt32
        ) {
            self.runtime = runtime
            self.runtimeID = runtimeID
            self.interfaceHash = interfaceHash
            self.registrationCount = registrationCount
        }
    }

    private let lock = NSLock()
    private let bridgeID: UUID
    private let originalBypassKey: String
    private let installation = Runtime.AtomicReference<Installation>()

    /// Creates an independent bridge, primarily for generated integration tests.
    public init() {
        bridgeID = UUID()
        originalBypassKey = "dev.helix.original-bypass.\(UUID().uuidString)"
    }

    /// Installs one Runtime engine after checking interface and registration identity.
    ///
    /// Reinstalling the exact same engine is idempotent. Installing a different
    /// engine or Bridge contract into the same instance fails closed.
    public func install(
        runtime: Runtime.Engine,
        interfaceHash: Core.Digest,
        registrationCount: UInt32
    ) throws {
        guard let runtimeHash = runtime.shellInterfaceHash else {
            throw Runtime.BridgeBootstrapError.runtimeHasNoShellIdentity
        }
        guard runtimeHash.constantTimeEquals(interfaceHash) else {
            throw Runtime.BridgeBootstrapError.interfaceHashMismatch
        }
        guard UInt32(exactly: runtime.originals.count) == registrationCount,
              runtime.originals.indices.enumerated().allSatisfy({ offset, entry in
                  UInt32(exactly: offset) == entry.rawValue
              })
        else {
            throw Runtime.BridgeBootstrapError.registrationCountMismatch(
                expected: registrationCount,
                actual: runtime.originals.count
            )
        }
        try lock.withLock {
            let runtimeID = ObjectIdentifier(runtime)
            if let current = installation.loadAcquire() {
                guard current.runtimeID == runtimeID,
                      current.interfaceHash.constantTimeEquals(interfaceHash),
                      current.registrationCount == registrationCount
                else {
                    throw Runtime.BridgeBootstrapError.conflictingInstallation
                }
                return
            }
            installation.storeOnce(Installation(
                runtime: runtime,
                runtimeID: runtimeID,
                interfaceHash: interfaceHash,
                registrationCount: registrationCount
            ))
        }
    }

    /// Dispatches a generated exact-Swift-ABI wrapper. Arguments are encoded
    /// lazily, so the normal no-generation path calls `previous` without
    /// allocating a VM frame or value array. The scoped encoder reserves
    /// aggregate work before materializing the VM-side copy.
    public func dispatch<Result>(
        isolation: isolated (any Actor)? = #isolation,
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value],
        decodeResult: (VM.Value?) throws -> Result
    ) throws -> Runtime.BridgeDispatchResult<Result> {
        try dispatchImpl(
            isolation: isolation,
            entry: entry,
            arguments: arguments,
            decodeResult: decodeResult,
            acceptsWritebacks: false,
            applyWritebacks: { writebacks in
                guard writebacks.isEmpty else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "non-inout generated Bridge received writebacks"
                    )
                }
            }
        )
    }

    /// Resolves and encodes an async generated wrapper before its first await.
    /// `nil` means the wrapper must immediately call its lexical original.
    /// A non-`nil` value pins the selected generation and is one-shot.
    public func prepareAsyncDispatch(
        isolation: isolated (any Actor)? = #isolation,
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value]
    ) throws -> Runtime.PreparedAsyncBridgeDispatch? {
        _ = isolation
        // Automatic App startup is intentionally scheduled onto the main
        // actor. A wrapper may run before that task, in which case no patch can
        // be active and the lexical original is the only valid route.
        guard let runtime = installation.loadAcquire()?.runtime else { return nil }
        guard runtime.originals[entry]?.effects.isAsync == true else {
            throw VM.RuntimeTrap.nativeFailure(
                "synchronous entry reached the generated async Bridge"
            )
        }
        return try runtime.prepareEncodedFromBridgeAsync(
            bridgeID: bridgeID,
            entry: entry,
            arguments: arguments
        )
    }

    /// Executes a prepared async wrapper route. Safe patch failure fallback is
    /// handled through the async OriginalCatalog inside Runtime, so generated
    /// source never calls a lexical original after it has suspended.
    public func dispatchAsync<Result>(
        isolation: isolated (any Actor)? = #isolation,
        prepared: Runtime.PreparedAsyncBridgeDispatch,
        decodeResult: (VM.Value?) throws -> Result
    ) async throws -> Result {
        guard let runtime = installation.loadAcquire()?.runtime else {
            throw Runtime.BridgeDispatchError.notInstalled
        }
        let payload = try prepared.consume(
            bridgeID: bridgeID,
            runtime: runtime
        )
        let result = await runtime.routePreparedFromBridgeAsync(
            isolation: isolation,
            payload: payload
        )
        guard result.writebacks.isEmpty else {
            throw VM.RuntimeTrap.nativeFailure(
                "async generated Bridge received forbidden writebacks"
            )
        }
        switch result.outcome {
        case let .returned(value):
            return try decodeResult(value)
        case let .businessError(message):
            throw Runtime.BridgeDispatchError.businessError(message)
        case let .trapped(trap):
            throw trap
        }
    }

    /// Dispatches a wrapper with one generated transactional copy-out region.
    /// The closure must decode every writeback before mutating Swift storage.
    public func dispatch<Result>(
        isolation: isolated (any Actor)? = #isolation,
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value],
        decodeResult: (VM.Value?) throws -> Result,
        applyWritebacks: ([VM.EntryWriteback]) throws -> Void
    ) throws -> Runtime.BridgeDispatchResult<Result> {
        try dispatchImpl(
            isolation: isolation,
            entry: entry,
            arguments: arguments,
            decodeResult: decodeResult,
            acceptsWritebacks: true,
            applyWritebacks: applyWritebacks
        )
    }

    private func dispatchImpl<Result>(
        isolation: isolated (any Actor)?,
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value],
        decodeResult: (VM.Value?) throws -> Result,
        acceptsWritebacks: Bool,
        applyWritebacks: ([VM.EntryWriteback]) throws -> Void
    ) throws -> Runtime.BridgeDispatchResult<Result> {
        _ = isolation
        // Fail open only to the compiled lexical original while automatic
        // bootstrap is pending. Installation itself remains permanent and all
        // incompatible runtime or interface attempts still fail closed.
        guard let runtime = installation.loadAcquire()?.runtime else {
            return .originalRequired
        }
        if !acceptsWritebacks,
           runtime.originals[entry]?.parameterConventions.contains(.inout) == true {
            throw VM.RuntimeTrap.nativeFailure(
                "an inout Shell entry requires the writeback-aware generated Bridge"
            )
        }
        guard runtime.requiresRouting else { return .originalRequired }
        // The bypass lookup is needed only while a generation is active or
        // pinned. Keeping it off the normal Shell path avoids a second TLS map
        // lookup on every unpatched call.
        if isBypassingOriginal(entry) { return .originalRequired }
        let result: VM.EntryInvocationResult
        switch try runtime.routeEncodedFromBridge(entry: entry, arguments: arguments) {
        case .originalRequired:
            return .originalRequired
        case let .executed(executed):
            result = executed
        }
        switch result.outcome {
        case let .returned(value):
            let decoded = try decodeResult(value)
            try applyWritebacks(result.writebacks)
            return .returned(decoded)
        case let .businessError(message):
            try applyWritebacks(result.writebacks)
            throw Runtime.BridgeDispatchError.businessError(message)
        case let .trapped(trap):
            guard result.writebacks.isEmpty else {
                throw VM.RuntimeTrap.nativeFailure(
                    "trapped Shell entry returned forbidden writebacks"
                )
            }
            throw trap
        }
    }

    /// Materializes arguments supplied by a native callback with the same
    /// pre-allocation limits used by generated Shell entry bridges.
    public func encodeNativeCallbackArguments(
        for callback: VM.NativeCallback,
        count: Int,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value]
    ) throws -> [VM.Value] {
        guard let runtime = installation.loadAcquire()?.runtime else {
            throw Runtime.BridgeDispatchError.notInstalled
        }
        return try runtime.encodeNativeCallbackArguments(
            for: callback,
            count: count,
            arguments: arguments
        )
    }

    /// Runs a generated replacement as an exact-ABI gateway to its lexical
    /// previous implementation. The entry-scoped thread-local depth prevents
    /// that gateway from routing back into the same VM entry.
    public func withOriginalBypass<Result>(
        isolation: isolated (any Actor)? = #isolation,
        entry: Core.EntryIndex,
        operation: () throws -> Result
    ) rethrows -> Result {
        _ = isolation
        let state = originalBypassState()
        state.depths[entry, default: 0] += 1
        defer {
            if let depth = state.depths[entry] {
                if depth == 1 {
                    state.depths.removeValue(forKey: entry)
                } else {
                    state.depths[entry] = depth - 1
                }
            }
            if state.depths.isEmpty {
                Thread.current.threadDictionary.removeObject(forKey: originalBypassKey)
            }
        }
        return try operation()
    }

    /// Native type catalog of the installed Runtime, or `nil` before bootstrap.
    public var nativeTypeCatalog: VM.NativeTypeCatalog? {
        installation.loadAcquire()?.runtime.nativeTypeCatalog
    }

    /// Returns the installed native type catalog or throws before bootstrap.
    public func requireNativeTypeCatalog() throws -> VM.NativeTypeCatalog {
        guard let catalog = nativeTypeCatalog else {
            throw Runtime.BridgeDispatchError.notInstalled
        }
        return catalog
    }

    /// Terminates when a nonthrowing generated Swift signature cannot be honored.
    ///
    /// Only compiler-generated wrappers should call this method. Throwing Shell
    /// entries propagate errors normally instead.
    public static func terminate(_ error: any Swift.Error) -> Never {
        fatalError("Helix permanent bridge could not complete a nonthrowing call: \(error)")
    }

    /// Shell interface identity of the installed engine, or `nil` before bootstrap.
    public var installedInterfaceHash: Core.Digest? {
        installation.loadAcquire()?.interfaceHash
    }

    private func isBypassingOriginal(_ entry: Core.EntryIndex) -> Bool {
        guard let state = Thread.current.threadDictionary[originalBypassKey]
            as? OriginalBypassState
        else {
            return false
        }
        return state.depths[entry, default: 0] > 0
    }

    private func originalBypassState() -> OriginalBypassState {
        if let state = Thread.current.threadDictionary[originalBypassKey]
            as? OriginalBypassState {
            return state
        }
        let state = OriginalBypassState()
        Thread.current.threadDictionary[originalBypassKey] = state
        return state
    }
}

/// Permanent Bridge installation contract failures.
public enum BridgeBootstrapError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The supplied engine was not bound to a generated Shell interface.
    case runtimeHasNoShellIdentity
    /// The generated wrapper archive and Runtime target different interfaces.
    case interfaceHashMismatch
    /// Generated wrapper roots do not exactly cover the original entry catalog.
    case registrationCountMismatch(expected: UInt32, actual: Int)
    /// A different engine or contract is already installed.
    case conflictingInstallation

    /// Human-readable bootstrap failure detail.
    public var description: String {
        switch self {
        case .runtimeHasNoShellIdentity:
            "Runtime.Engine was created without a captured Shell interface hash"
        case .interfaceHashMismatch:
            "generated Bridge and Runtime.Engine target different Shell interfaces"
        case let .registrationCountMismatch(expected, actual):
            "generated Bridge registers \(expected) entries, Runtime has \(actual) originals"
        case .conflictingInstallation:
            "a different Runtime or Bridge is already installed"
        }
    }
}

/// Errors surfaced while a generated wrapper dispatches patched code.
public enum BridgeDispatchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Generated code reached a bridge that has not been installed.
    case notInstalled
    /// Patched code returned a declared business-error payload.
    case businessError(String)

    /// Human-readable bridge dispatch failure detail.
    public var description: String {
        switch self {
        case .notInstalled:
            "Helix Bridge was invoked before bootstrap"
        case let .businessError(message):
            "HLBC returned a business error through a Shell entry: \(message)"
        }
    }
}
}

extension Runtime.BridgeDispatchResult: Sendable where Result: Sendable {}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
