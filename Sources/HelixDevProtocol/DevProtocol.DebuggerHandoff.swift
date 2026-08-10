extension DevProtocol {
/// Shared timing contract for the Xcode LLDB rendezvous.
package enum DebuggerHandoffTiming {
    package static let installerTimeoutSeconds = 15
    package static let runtimePollingSeconds = 20
    package static let pollIntervalNanoseconds: UInt64 = 50_000_000

    package static let runtimeMaximumAttempts =
        runtimePollingSeconds * 1_000_000_000 / Int(pollIntervalNanoseconds) + 1
}
}
