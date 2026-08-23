import Foundation

extension VM {
/// One logical value copied back to a Swift `inout` argument after a Shell
/// entry completes. Parameter indices refer to the frozen logical entry ABI,
/// never to an HLBC register or a Swift address.
public struct EntryWriteback: Equatable, Sendable {
    public var parameterIndex: UInt32
    public var value: VM.Value

    public init(parameterIndex: UInt32, value: VM.Value) {
        self.parameterIndex = parameterIndex
        self.value = value
    }
}

/// A Shell entry outcome plus its transactional copy-out values. Successful
/// and declared-error exits carry the complete writeback set; traps carry none
/// so an invalid or partially executed patch cannot mutate caller storage.
public struct EntryInvocationResult: Equatable, Sendable {
    public var outcome: VM.ExecutionResult
    public var writebacks: [VM.EntryWriteback]

    public init(
        outcome: VM.ExecutionResult,
        writebacks: [VM.EntryWriteback] = []
    ) {
        self.outcome = outcome
        self.writebacks = writebacks
    }

    public static func returned(_ value: VM.Value?) -> Self {
        .init(outcome: .returned(value))
    }

    public static func businessError(_ message: String) -> Self {
        .init(outcome: .businessError(message))
    }

    public static func trapped(_ trap: VM.RuntimeTrap) -> Self {
        .init(outcome: .trapped(trap))
    }
}
}
