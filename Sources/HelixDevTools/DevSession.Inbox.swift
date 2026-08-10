import Foundation
import HelixDevProtocol

extension DevSession {
/// The only post-handshake reader on the Mac side. It filters heartbeat
/// acknowledgements and serializes all protocol responses for session logic.
public actor Inbox {
    public typealias TerminalHandler = @Sendable (any Swift.Error) async -> Void

    private enum State {
        case idle
        case running
        case stopped
    }

    private var state = State.idle
    private var buffered: [DevProtocol.Message] = []
    private var waiters: [CheckedContinuation<DevProtocol.Message, any Swift.Error>] = []
    private var terminalError: (any Swift.Error)?
    private var readerTask: Task<Void, Never>?

    public init() {}

    public func start(
        channel: any DevProtocol.MessageChannel,
        liveness: DevProtocol.LivenessConfiguration,
        maximumBufferedMessages: Int = 128,
        terminalHandler: @escaping TerminalHandler
    ) throws {
        try liveness.validate()
        guard state == .idle, maximumBufferedMessages > 0 else {
            throw DevProtocol.Error.malformedMessage(
                "Dev Session inbox was started twice or has an invalid buffer limit"
            )
        }
        state = .running
        readerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await DevProtocol.Liveness.receive(
                        from: channel,
                        configuration: liveness
                    )
                    if case .heartbeat = message { continue }
                    guard let self else { return }
                    try await self.deliver(
                        message,
                        maximumBufferedMessages: maximumBufferedMessages
                    )
                }
            } catch is CancellationError {
                // An explicit stop owns waiter completion.
            } catch {
                await channel.close()
                guard let self else { return }
                await self.finish(error: error, notify: terminalHandler)
            }
        }
    }

    public func receive() async throws -> DevProtocol.Message {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let terminalError { throw terminalError }
        guard state == .running else { throw DevProtocol.Error.truncatedFrame }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func stop(error: any Swift.Error = CancellationError()) {
        guard state != .stopped else { return }
        state = .stopped
        readerTask?.cancel()
        readerTask = nil
        terminalError = error
        buffered.removeAll(keepingCapacity: false)
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(throwing: error) }
    }

    private func deliver(
        _ message: DevProtocol.Message,
        maximumBufferedMessages: Int
    ) throws {
        guard state == .running else { return }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: message)
            return
        }
        guard buffered.count < maximumBufferedMessages else {
            throw DevProtocol.Error.malformedMessage(
                "peer exceeded the Dev Session response buffer limit"
            )
        }
        buffered.append(message)
    }

    private func finish(
        error: any Swift.Error,
        notify: TerminalHandler
    ) async {
        guard state == .running else { return }
        state = .stopped
        readerTask = nil
        terminalError = error
        buffered.removeAll(keepingCapacity: false)
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(throwing: error) }
        await notify(error)
    }
}
}
