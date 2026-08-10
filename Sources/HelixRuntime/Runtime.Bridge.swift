import Foundation
import HelixCore
import HelixVM

extension Runtime {
public enum BridgeDispatchResult<Result> {
    case originalRequired
    case returned(Result)
}

public final class Bridge: @unchecked Sendable {
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
    private let originalBypassKey: String
    private let installation = Runtime.AtomicReference<Installation>()

    public init() {
        originalBypassKey = "dev.helix.original-bypass.\(UUID().uuidString)"
    }

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

    public func invoke(entry: Core.EntryIndex, arguments: [VM.Value]) -> VM.ExecutionResult {
        let runtime = installation.loadAcquire()?.runtime
        guard let runtime else {
            return .trapped(.explicit("Helix Bridge was invoked before bootstrap"))
        }
        return runtime.invoke(entry: entry, arguments: arguments)
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
        _ = isolation
        let runtime = installation.loadAcquire()?.runtime
        guard let runtime else {
            throw Runtime.BridgeDispatchError.notInstalled
        }
        guard runtime.requiresRouting else { return .originalRequired }
        // The bypass lookup is needed only while a generation is active or
        // pinned. Keeping it off the normal Shell path avoids a second TLS map
        // lookup on every unpatched call.
        if isBypassingOriginal(entry) { return .originalRequired }
        let result: VM.ExecutionResult
        switch try runtime.routeEncodedFromBridge(entry: entry, arguments: arguments) {
        case .originalRequired:
            return .originalRequired
        case let .executed(executed):
            result = executed
        }
        switch result {
        case let .returned(value):
            return .returned(try decodeResult(value))
        case let .businessError(message):
            throw Runtime.BridgeDispatchError.businessError(message)
        case let .trapped(trap):
            throw trap
        }
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

    public var nativeTypeCatalog: VM.NativeTypeCatalog? {
        installation.loadAcquire()?.runtime.nativeTypeCatalog
    }

    public func requireNativeTypeCatalog() throws -> VM.NativeTypeCatalog {
        guard let catalog = nativeTypeCatalog else {
            throw Runtime.BridgeDispatchError.notInstalled
        }
        return catalog
    }

    public static func terminate(_ error: any Swift.Error) -> Never {
        fatalError("Helix permanent bridge could not complete a nonthrowing call: \(error)")
    }

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

public enum BridgeBootstrapError: Error, Equatable, Sendable, CustomStringConvertible {
    case runtimeHasNoShellIdentity
    case interfaceHashMismatch
    case registrationCountMismatch(expected: UInt32, actual: Int)
    case conflictingInstallation

    public var description: String {
        switch self {
        case .runtimeHasNoShellIdentity:
            "Runtime.Engine was created without a frozen Shell interface hash"
        case .interfaceHashMismatch:
            "generated Bridge and Runtime.Engine target different Shell interfaces"
        case let .registrationCountMismatch(expected, actual):
            "generated Bridge registers \(expected) entries, Runtime has \(actual) originals"
        case .conflictingInstallation:
            "a different Runtime or Bridge is already installed"
        }
    }
}

public enum BridgeDispatchError: Error, Equatable, Sendable, CustomStringConvertible {
    case notInstalled
    case businessError(String)

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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
