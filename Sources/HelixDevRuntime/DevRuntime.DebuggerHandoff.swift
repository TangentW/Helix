import Foundation
import HelixDevProtocol
import HelixDevRuntimeProbe

extension DevRuntime {
/// A bounded, Debug-only rendezvous for Xcode versions that source a custom
/// LLDB init before the real application target is available. The probe gives
/// the installer a stable image-loaded signal; credential injection itself is
/// performed directly while LLDB has briefly stopped the process.
enum DebuggerHandoff {
    static let readyEnvironmentName = "HLX_DEV_HANDOFF_READY"
    static let defaultMaximumAttempts =
        DevProtocol.DebuggerHandoffTiming.runtimeMaximumAttempts
    static let defaultIntervalNanoseconds =
        DevProtocol.DebuggerHandoffTiming.pollIntervalNanoseconds

    static func waitForEnvironment(
        maximumAttempts: Int = defaultMaximumAttempts,
        intervalNanoseconds: UInt64 = defaultIntervalNanoseconds,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) async -> [String: String]? {
        guard maximumAttempts > 0 else { return nil }
        for attempt in 0..<maximumAttempts {
            probe()
            let snapshot = environment()
            if let sessionID = snapshot["HLX_DEV_SESSION_ID"],
               snapshot[readyEnvironmentName] == sessionID
            {
                return snapshot
            }
            guard attempt + 1 < maximumAttempts else { break }
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return nil
            }
        }
        return nil
    }

    @inline(never)
    private static func probe() {
        helixDevRuntimeHandoffProbe()
    }
}
}
