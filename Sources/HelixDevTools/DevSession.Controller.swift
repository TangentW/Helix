import Foundation
import HelixCore
import HelixDevProtocol

public enum DevSession {}

extension DevSession {
public enum State: String, Codable, Hashable, Sendable {
    case disconnected
    case authenticating
    case ready
    case transferring
    case closing
    case closed
}

public struct Snapshot: Hashable, Sendable {
    public var state: DevSession.State
    public var peerIdentity: DevProtocol.SessionIdentity?
    public var highestOfferedRevision: DevProtocol.SourceRevision
    public var highestAppliedRevision: DevProtocol.SourceRevision
    public var activeGenerationID: DevProtocol.GenerationID?
    public var transferredPayloadBytes: UInt64
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidState(expected: DevSession.State, actual: DevSession.State)
    case buildIdentityMismatch
    case handshakeRejected
    case unexpectedMessage(String)
    case artifactIdentityMismatch
    case superseded(DevProtocol.SourceRevision)

    public var description: String {
        switch self {
        case let .invalidState(expected, actual):
            "Dev Session expected \(expected.rawValue), but is \(actual.rawValue)"
        case .buildIdentityMismatch: "App process does not match the prepared Dev Shell identity"
        case .handshakeRejected: "App rejected the transcript-bound Dev Session handshake"
        case let .unexpectedMessage(message): "unexpected Dev Protocol message: \(message)"
        case .artifactIdentityMismatch: "Live artifact does not belong to this session or revision"
        case let .superseded(revision): "source revision \(revision) was superseded"
        }
    }
}

/// Mac-side owner of one authenticated App process connection.
public actor Controller {
    private enum CloseHandshakeOutcome: Equatable, Sendable {
        case acknowledged
        case failed
        case timedOut
    }

    private static let maximumCloseHandshakeNanoseconds: UInt64 = 1_000_000_000

    public let expectedBuildIdentity: DevProtocol.BuildIdentity
    public let tlsTranscriptHash: Core.Digest
    public let chunkByteCount: Int
    public let liveness: DevProtocol.LivenessConfiguration

    private let sessionSecret: Data
    private var channel: (any DevProtocol.MessageChannel)?
    private var state: DevSession.State = .disconnected
    private var peerIdentity: DevProtocol.SessionIdentity?
    private var highestOfferedRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var highestAppliedRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var activeGenerationID: DevProtocol.GenerationID?
    private var transferredPayloadBytes: UInt64 = 0
    private var highestRequestedRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var inbox: DevSession.Inbox?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatSequence: UInt64 = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        expectedIdentity: DevProtocol.SessionIdentity,
        sessionSecret: Data,
        tlsTranscriptHash: Core.Digest,
        chunkByteCount: Int = 256 * 1_024,
        liveness: DevProtocol.LivenessConfiguration = .init()
    ) throws {
        try self.init(
            expectedBuildIdentity: expectedIdentity.buildIdentity,
            sessionSecret: sessionSecret,
            tlsTranscriptHash: tlsTranscriptHash,
            chunkByteCount: chunkByteCount,
            liveness: liveness
        )
    }

    public init(
        expectedBuildIdentity: DevProtocol.BuildIdentity,
        sessionSecret: Data,
        tlsTranscriptHash: Core.Digest,
        chunkByteCount: Int = 256 * 1_024,
        liveness: DevProtocol.LivenessConfiguration = .init()
    ) throws {
        try expectedBuildIdentity.validate()
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        try liveness.validate()
        guard (1...1_024 * 1_024).contains(chunkByteCount) else {
            throw DevProtocol.Error.frameTooLarge
        }
        self.expectedBuildIdentity = expectedBuildIdentity
        self.sessionSecret = sessionSecret
        self.tlsTranscriptHash = tlsTranscriptHash
        self.chunkByteCount = chunkByteCount
        self.liveness = liveness
        highestAppliedRevision = .init(rawValue: 0)
        highestRequestedRevision = .init(rawValue: 0)
        activeGenerationID = nil
    }

    public func accept(channel: any DevProtocol.MessageChannel) async throws {
        guard state == .disconnected || state == .closed else {
            throw DevSession.Error.invalidState(expected: .disconnected, actual: state)
        }
        state = .authenticating
        self.channel = channel
        do {
            let message = try await DevProtocol.Liveness.receive(
                from: channel,
                configuration: liveness
            )
            guard case let .hello(identity, clientNonce) = message else {
                throw DevSession.Error.unexpectedMessage(String(describing: message))
            }
            try identity.validate()
            guard expectedBuildIdentity.matches(identity) else {
                throw DevSession.Error.buildIdentityMismatch
            }
            let serverNonce = try DevProtocol.SecureRandom.bytes(count: 32)
            let proof = try DevProtocol.Handshake.proof(
                sessionSecret: sessionSecret,
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                identity: identity,
                tlsTranscriptHash: tlsTranscriptHash
            )
            try await channel.send(
                .helloAck(identity: identity, serverNonce: serverNonce, proof: proof)
            )
            peerIdentity = identity
            highestAppliedRevision = identity.highestAppliedSourceRevision
            highestRequestedRevision = identity.highestAppliedSourceRevision
            activeGenerationID = identity.activeGenerationID
            state = .ready
            let inbox = DevSession.Inbox()
            try await inbox.start(
                channel: channel,
                liveness: liveness,
                terminalHandler: { [weak self] error in
                    await self?.connectionDidFail(error)
                }
            )
            self.inbox = inbox
            startHeartbeatLoop()
        } catch {
            state = .closed
            self.channel = nil
            await channel.close()
            throw error
        }
    }

    public func announceCompile(_ revision: DevProtocol.SourceRevision) async throws {
        guard state == .ready, let channel else {
            throw DevSession.Error.invalidState(expected: .ready, actual: state)
        }
        guard revision > highestRequestedRevision else {
            throw DevProtocol.Diagnostic.staleRevision(
                revision,
                highest: highestRequestedRevision
            )
        }
        highestRequestedRevision = revision
        try await channel.send(.compileStarted(revision))
    }

    public func sendDiagnostics(_ diagnostics: [DevProtocol.Diagnostic]) async throws {
        guard state == .ready, let channel else {
            throw DevSession.Error.invalidState(expected: .ready, actual: state)
        }
        try await channel.send(.diagnostics(diagnostics))
    }

    public func supersede(with revision: DevProtocol.SourceRevision) {
        if revision > highestRequestedRevision { highestRequestedRevision = revision }
    }

    public func transfer(
        _ artifact: DevProtocol.LiveArtifact
    ) async throws -> DevProtocol.ActivationResult {
        guard state == .ready, let channel else {
            throw DevSession.Error.invalidState(expected: .ready, actual: state)
        }
        try artifact.offer.validate()
        guard artifact.offer.sessionID == expectedBuildIdentity.sessionID,
              artifact.offer.sourceRevision > highestOfferedRevision,
              artifact.offer.sourceRevision > highestAppliedRevision,
              artifact.offer.payloadByteLength == UInt64(artifact.payload.count),
              artifact.offer.payloadSHA256.constantTimeEquals(.sha256(artifact.payload))
        else {
            throw DevSession.Error.artifactIdentityMismatch
        }
        if artifact.offer.sourceRevision < highestRequestedRevision {
            throw DevSession.Error.superseded(artifact.offer.sourceRevision)
        }

        state = .transferring
        highestOfferedRevision = artifact.offer.sourceRevision
        do {
            try await channel.send(.patchOffer(artifact.offer))
            let token = try await waitForOfferResponse()
            var offset = 0
            while offset < artifact.payload.count {
                if artifact.offer.sourceRevision < highestRequestedRevision {
                    throw DevSession.Error.superseded(artifact.offer.sourceRevision)
                }
                let end = min(offset + chunkByteCount, artifact.payload.count)
                let bytes = artifact.payload.subdata(in: offset..<end)
                try await channel.send(
                    .patchChunk(
                        .init(token: token, offset: UInt64(offset), bytes: bytes)
                    )
                )
                offset = end
                transferredPayloadBytes += UInt64(bytes.count)
            }
            try await channel.send(.patchCommit(token))
            let result = try await waitForActivationResult(offer: artifact.offer)
            if result.codeStatus == .codeActive {
                highestAppliedRevision = result.sourceRevision
                activeGenerationID = result.generationID
            }
            state = .ready
            return result
        } catch {
            if state != .closed { state = .ready }
            throw error
        }
    }

    public func snapshot() -> DevSession.Snapshot {
        .init(
            state: state,
            peerIdentity: peerIdentity,
            highestOfferedRevision: highestOfferedRevision,
            highestAppliedRevision: highestAppliedRevision,
            activeGenerationID: activeGenerationID,
            transferredPayloadBytes: transferredPayloadBytes
        )
    }

    public func waitUntilClosed() async {
        guard state != .closed else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    public func close(reason: String = "Mac Dev Session ended") async {
        guard state != .closed else { return }
        state = .closing
        let heartbeat = heartbeatTask
        heartbeatTask = nil
        heartbeat?.cancel()
        await heartbeat?.value
        if let channel {
            do {
                try await channel.send(.sessionClose(reason))
                await waitForCloseAcknowledgement()
            } catch {
                // Closing is best effort; transport cleanup below is authoritative.
            }
        }
        await inbox?.stop()
        inbox = nil
        if let channel { await channel.close() }
        channel = nil
        state = .closed
        resumeCloseWaiters()
    }

    private func waitForCloseAcknowledgement() async {
        guard let inbox else { return }
        let timeout = min(
            liveness.receiveTimeoutNanoseconds,
            Self.maximumCloseHandshakeNanoseconds
        )
        await withTaskGroup(of: CloseHandshakeOutcome.self) { group in
            group.addTask {
                do {
                    let message = try await inbox.receive()
                    return message == .sessionCloseAcknowledged ? .acknowledged : .failed
                } catch {
                    return .failed
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeout)
                    return .timedOut
                } catch {
                    return .failed
                }
            }
            guard let outcome = await group.next() else { return }
            group.cancelAll()
            if outcome != .acknowledged {
                // Inbox.receive is continuation based; stop it so the cancelled
                // task cannot keep the task group alive after the deadline.
                await inbox.stop()
            }
        }
    }

    private func waitForOfferResponse() async throws -> DevProtocol.OfferToken {
        guard let inbox else { throw DevProtocol.Error.truncatedFrame }
        while true {
            let message = try await inbox.receive()
            switch message {
            case let .patchAccept(token):
                return token
            case let .patchReject(diagnostic):
                throw diagnostic
            default:
                throw DevSession.Error.unexpectedMessage(String(describing: message))
            }
        }
    }

    private func waitForActivationResult(
        offer: DevProtocol.PatchOffer
    ) async throws -> DevProtocol.ActivationResult {
        guard let inbox else { throw DevProtocol.Error.truncatedFrame }
        var didStart = false
        while true {
            let message = try await inbox.receive()
            switch message {
            case let .activationStarted(revision, generation):
                guard !didStart,
                      revision == offer.sourceRevision,
                      generation == offer.generationID
                else {
                    throw DevSession.Error.artifactIdentityMismatch
                }
                didStart = true
            case let .activationResult(result):
                guard didStart,
                      result.sourceRevision == offer.sourceRevision,
                      result.generationID == offer.generationID
                else {
                    throw DevSession.Error.artifactIdentityMismatch
                }
                return result
            default:
                throw DevSession.Error.unexpectedMessage(String(describing: message))
            }
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let interval = liveness.heartbeatIntervalNanoseconds
        heartbeatTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: interval)
                    try Task.checkCancellation()
                    try await self?.sendHeartbeat()
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.connectionDidFail(error)
            }
        }
    }

    private func sendHeartbeat() async throws {
        guard state == .ready || state == .transferring, let channel else { return }
        heartbeatSequence &+= 1
        try await channel.send(.heartbeat(heartbeatSequence))
    }

    private func connectionDidFail(_ error: any Swift.Error) async {
        guard state != .closed else { return }
        let failedChannel = channel
        channel = nil
        state = .closed
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await inbox?.stop(error: error)
        inbox = nil
        if let failedChannel { await failedChannel.close() }
        resumeCloseWaiters()
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
}
