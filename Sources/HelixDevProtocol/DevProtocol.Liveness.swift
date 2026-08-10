import Foundation

extension DevProtocol {
public struct LivenessConfiguration: Hashable, Sendable {
    public var heartbeatIntervalNanoseconds: UInt64
    public var receiveTimeoutNanoseconds: UInt64

    public init(
        heartbeatIntervalNanoseconds: UInt64 = 10_000_000_000,
        receiveTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.receiveTimeoutNanoseconds = receiveTimeoutNanoseconds
    }

    public func validate() throws {
        guard heartbeatIntervalNanoseconds > 0,
              receiveTimeoutNanoseconds > heartbeatIntervalNanoseconds,
              receiveTimeoutNanoseconds <= 300_000_000_000
        else {
            throw DevProtocol.Error.malformedMessage(
                "liveness intervals must be positive, ordered, and at most five minutes"
            )
        }
    }
}

public enum Liveness {
    /// Receives one message or closes the channel on inactivity. Closing is
    /// intentional: it unblocks transports whose pending read is not directly
    /// task-cancellable.
    public static func receive(
        from channel: any DevProtocol.MessageChannel,
        configuration: DevProtocol.LivenessConfiguration
    ) async throws -> DevProtocol.Message {
        try configuration.validate()
        let timeout = TimeoutState()
        return try await withThrowingTaskGroup(of: DevProtocol.Message.self) { group in
            group.addTask {
                try await channel.receive()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: configuration.receiveTimeoutNanoseconds
                )
                try Task.checkCancellation()
                await timeout.markTimedOut()
                await channel.close()
                throw DevProtocol.Error.sessionTimedOut
            }
            do {
                guard let message = try await group.next() else {
                    throw DevProtocol.Error.truncatedFrame
                }
                group.cancelAll()
                return message
            } catch {
                group.cancelAll()
                if await timeout.didTimeOut {
                    throw DevProtocol.Error.sessionTimedOut
                }
                throw error
            }
        }
    }
}
}

private actor TimeoutState {
    private(set) var didTimeOut = false

    func markTimedOut() {
        didTimeOut = true
    }
}
