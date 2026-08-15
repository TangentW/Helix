import Darwin
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL lowering stack boundary")
struct LoweringStack {
    private struct Observation: Sendable {
        var outerThread: UInt32
        var innerThread: UInt32
        var stackBytes: Int
    }

    private enum FixtureError: Error {
        case rejected
    }

    @Test("A compact caller stack is replaced once and nested work reuses it")
    func providesBoundedStack() throws {
        let callerThread = pthread_mach_thread_np(pthread_self())
        let callerStackBytes = pthread_get_stacksize_np(pthread_self())
        let requestedBytes = max(
            CanonicalSIL.LoweringStack.minimumBytes,
            callerStackBytes + 1_024 * 1_024
        )

        let observation = try CanonicalSIL.LoweringStack.run(
            minimumBytes: requestedBytes
        ) {
            let outerThread = pthread_mach_thread_np(pthread_self())
            let stackBytes = pthread_get_stacksize_np(pthread_self())
            let innerThread = try CanonicalSIL.LoweringStack.run(
                minimumBytes: requestedBytes
            ) {
                pthread_mach_thread_np(pthread_self())
            }
            return Observation(
                outerThread: outerThread,
                innerThread: innerThread,
                stackBytes: stackBytes
            )
        }

        #expect(observation.outerThread != callerThread)
        #expect(observation.innerThread == observation.outerThread)
        #expect(observation.stackBytes >= requestedBytes)
    }

    @Test("Thrown compiler diagnostics cross the stack boundary unchanged")
    func propagatesErrors() {
        #expect(throws: FixtureError.self) {
            let _: Int = try CanonicalSIL.LoweringStack.run(
                minimumBytes: CanonicalSIL.LoweringStack.minimumBytes
            ) {
                throw FixtureError.rejected
            }
        }
    }
}
}
