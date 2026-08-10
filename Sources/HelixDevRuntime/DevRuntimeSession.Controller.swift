import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

public enum DevRuntimeSession {}

extension DevRuntimeSession {
public enum Event: Hashable, Sendable {
    case authenticated
    case compileStarted(DevProtocol.SourceRevision)
    case diagnostics([DevProtocol.Diagnostic])
    case transferAccepted(DevProtocol.SourceRevision, DevProtocol.GenerationID)
    case activationCompleted(DevProtocol.ActivationResult)
    case closed(String)
}

/// App-side owner of one outbound, authenticated Dev connection.
public actor Controller {
    public typealias EventHandler = @Sendable (DevRuntimeSession.Event) async -> Void
    public typealias ManualReloadHandler = @Sendable (
        LiveReload.Context
    ) async -> (DevProtocol.UIReloadStatus, String?)

    public let identity: DevProtocol.SessionIdentity
    public let tlsTranscriptHash: Core.Digest
    public let liveness: DevProtocol.LivenessConfiguration

    private let sessionSecret: Data
    private let activation: DevActivation.Controller
    private let eventHandler: EventHandler
    private let manualReloadHandler: ManualReloadHandler

    public init(
        identity: DevProtocol.SessionIdentity,
        sessionSecret: Data,
        tlsTranscriptHash: Core.Digest,
        activation: DevActivation.Controller,
        liveness: DevProtocol.LivenessConfiguration = .init(),
        eventHandler: @escaping EventHandler = { _ in },
        manualReloadHandler: @escaping ManualReloadHandler = { _ in
            (.manualRefreshRequired, "no manual UI reload handler is installed")
        }
    ) throws {
        try identity.validate()
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        try liveness.validate()
        self.identity = identity
        self.sessionSecret = sessionSecret
        self.tlsTranscriptHash = tlsTranscriptHash
        self.liveness = liveness
        self.activation = activation
        self.eventHandler = eventHandler
        self.manualReloadHandler = manualReloadHandler
    }

    public func run(channel: any DevProtocol.MessageChannel) async throws {
        do {
            try await authenticate(channel: channel)
            await eventHandler(.authenticated)
            try await serve(channel: channel)
            await channel.close()
        } catch {
            await activation.abort()
            await eventHandler(.closed(String(describing: error)))
            await channel.close()
            throw error
        }
    }

    private func authenticate(channel: any DevProtocol.MessageChannel) async throws {
        let currentIdentity = await activation.currentSessionIdentity()
        guard identity.matchesProcess(of: currentIdentity) else {
            throw DevProtocol.Diagnostic.sessionMismatch(
                "activation state no longer belongs to this App process"
            )
        }
        let clientNonce = try DevProtocol.SecureRandom.bytes(count: 32)
        try await channel.send(.hello(identity: currentIdentity, clientNonce: clientNonce))
        let message = try await DevProtocol.Liveness.receive(
            from: channel,
            configuration: liveness
        )
        guard case let .helloAck(peerIdentity, serverNonce, proof) = message else {
            throw DevProtocol.Diagnostic.sessionMismatch(
                "Mac did not return a Dev Session handshake acknowledgement"
            )
        }
        guard currentIdentity.matchesProcess(of: peerIdentity),
              try DevProtocol.Handshake.verify(
                  proof: proof,
                  sessionSecret: sessionSecret,
                  clientNonce: clientNonce,
                  serverNonce: serverNonce,
                  identity: currentIdentity,
                  tlsTranscriptHash: tlsTranscriptHash
              )
        else {
            throw DevProtocol.Error.invalidAuthentication
        }
    }

    private func serve(channel: any DevProtocol.MessageChannel) async throws {
        while true {
            let message = try await DevProtocol.Liveness.receive(
                from: channel,
                configuration: liveness
            )
            switch message {
            case let .compileStarted(revision):
                await eventHandler(.compileStarted(revision))
            case let .diagnostics(diagnostics):
                await eventHandler(.diagnostics(diagnostics))
            case let .patchOffer(offer):
                do {
                    let token = try await activation.accept(offer)
                    try await channel.send(.patchAccept(token))
                    await eventHandler(
                        .transferAccepted(offer.sourceRevision, offer.generationID)
                    )
                } catch let diagnostic as DevProtocol.Diagnostic {
                    try await channel.send(.patchReject(diagnostic))
                } catch {
                    try await channel.send(
                        .patchReject(
                            .init(
                                code: "HLXLR401",
                                message: String(describing: error),
                                sourceRevision: offer.sourceRevision,
                                generationID: offer.generationID,
                                backend: offer.backend,
                                nextAction: "retry after correcting the transfer precondition"
                            )
                        )
                    )
                }
            case let .patchChunk(chunk):
                do {
                    try await activation.append(chunk)
                } catch let diagnostic as DevProtocol.Diagnostic {
                    await activation.abort(chunk.token)
                    try? await channel.send(.patchReject(diagnostic))
                    throw diagnostic
                } catch {
                    await activation.abort(chunk.token)
                    let diagnostic = DevProtocol.Diagnostic(
                        code: "HLXLR402",
                        message: String(describing: error),
                        nextAction: "terminate the malformed transfer and reconnect"
                    )
                    try? await channel.send(.patchReject(diagnostic))
                    throw error
                }
            case let .patchCommit(token):
                let before = await activation.snapshot()
                guard before.hasPendingTransfer, let pendingGenerationID = before.pendingGenerationID else {
                    throw DevProtocol.Error.malformedMessage("commit has no pending transfer")
                }
                try await channel.send(
                    .activationStarted(
                        before.highestOfferedRevision,
                        pendingGenerationID
                    )
                )
                let result = await activation.commit(token)
                try await channel.send(.activationResult(result))
                await eventHandler(.activationCompleted(result))
            case let .reloadRequest(context):
                let (status, detail) = await manualReloadHandler(context)
                try await channel.send(.reloadResult(status, detail))
            case let .heartbeat(value):
                try await channel.send(.heartbeat(value))
            case let .sessionClose(reason):
                await activation.abort()
                try await channel.send(.sessionCloseAcknowledged)
                await eventHandler(.closed(reason))
                return
            case .hello, .helloAck, .patchAccept, .patchReject,
                 .activationStarted, .activationResult, .reloadResult,
                 .sessionCloseAcknowledged:
                throw DevProtocol.Error.malformedMessage(
                    "message is invalid for the App-side session state"
                )
            }
        }
    }
}
}
