import Foundation

#if canImport(Darwin)
import Darwin
#endif

extension DevRuntime {
/// Network-activation policy locked once for the lifetime of an App process.
public enum LaunchMode: String, Codable, Hashable, Sendable {
    /// Xcode launched this process under a debugger; pairing starts immediately.
    case automaticXcode
    /// The installed test App was opened directly; explicit code entry is required.
    case manual

    /// Deterministic policy mapping used by tests and alternate launch adapters.
    public static func resolve(debuggerAttached: Bool) -> Self {
        debuggerAttached ? .automaticXcode : .manual
    }

    /// Measures whether the current process is actually debugger-traced.
    public static func current() -> Self {
        .resolve(debuggerAttached: DebuggerAttachment.isCurrentProcessTraced())
    }
}
}

private enum DebuggerAttachment {
    static func isCurrentProcessTraced() -> Bool {
        #if canImport(Darwin)
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = query.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &process, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else {
            // Failure must never enable networking in a directly opened App.
            return false
        }
        return process.kp_proc.p_flag & P_TRACED != 0
        #else
        return false
        #endif
    }
}
