import Darwin
import Foundation

extension CanonicalSIL {
/// Executes unusually stack-intensive compiler passes on a stack with an
/// explicit lower bound. Swift concurrency workers intentionally use compact
/// stacks, while the canonical-SIL dispatcher still contains a broad set of
/// instruction forms whose debug build needs more space than those workers
/// guarantee.
enum LoweringStack {
    static let minimumBytes = 4 * 1_024 * 1_024
    private static let entryHeadroomBytes = 256 * 1_024

    private final class ResultBox<Success: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Success, any Error>?

        // The condition establishes the only cross-thread ownership handoff.
        // `Error` itself is not Sendable, but the producer releases all access
        // before the waiting compiler thread resumes and consumes the result.

        func publish(_ result: Result<Success, any Error>) {
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Result<Success, any Error> {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let result {
                    return result
                }
                condition.wait()
            }
        }
    }

    static func run<Success: Sendable>(
        minimumBytes: Int = minimumBytes,
        _ operation: @escaping @Sendable () throws -> Success
    ) throws -> Success {
        precondition(minimumBytes > 0)
        if availableBytes() >= minimumBytes {
            return try operation()
        }

        let stackBytes = dedicatedStackBytes(for: minimumBytes)
        let result = ResultBox<Success>()
        let thread = Thread {
            let outcome = autoreleasepool {
                Result(catching: operation)
            }
            result.publish(outcome)
        }
        thread.name = "dev.helix.canonical-sil-lowering"
        thread.qualityOfService = Thread.current.qualityOfService
        thread.stackSize = stackBytes
        thread.start()
        return try result.wait().get()
    }

    private static func availableBytes() -> Int {
        let thread = pthread_self()
        let upperAddress = Int(bitPattern: pthread_get_stackaddr_np(thread))
        let lowerAddress = upperAddress - pthread_get_stacksize_np(thread)
        var marker = 0
        let currentAddress = withUnsafePointer(to: &marker) {
            Int(bitPattern: $0)
        }
        return max(0, currentAddress - lowerAddress)
    }

    private static func dedicatedStackBytes(for minimumBytes: Int) -> Int {
        let (withHeadroom, overflowed) = minimumBytes.addingReportingOverflow(
            entryHeadroomBytes
        )
        precondition(!overflowed)
        let pageBytes = Int(getpagesize())
        let (roundingValue, roundingOverflowed) = withHeadroom
            .addingReportingOverflow(pageBytes - 1)
        precondition(!roundingOverflowed)
        return max(Int(PTHREAD_STACK_MIN), roundingValue / pageBytes * pageBytes)
    }
}
}
