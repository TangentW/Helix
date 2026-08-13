#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import HelixCore
import HelixDevProtocol

extension DevSession {
/// Authenticated connection facts handed from the pairing service to one Shell host.
public struct SessionAuthorization: Sendable {
    /// Exact Build Context selected by pairing.
    public let context: DevSession.BuildContext
    /// Process identity proven by the pairing request.
    public let peerIdentity: DevProtocol.PeerIdentity
    /// Per-lease secret used by the authenticated Dev Protocol.
    public let sessionSecret: Data
    /// Exporter digest for the TLS connection that carried the pairing exchange.
    public let tlsExporterHash: Core.Digest

    /// Creates an authorization only when every identity refers to one Shell.
    public init(
        context: DevSession.BuildContext,
        peerIdentity: DevProtocol.PeerIdentity,
        sessionSecret: Data,
        tlsExporterHash: Core.Digest
    ) throws {
        try context.validate()
        try peerIdentity.validate()
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard context.matches(peerIdentity.build) else {
            throw DevSession.HostError.pairingIdentityMismatch
        }
        self.context = context
        self.peerIdentity = peerIdentity
        self.sessionSecret = sessionSecret
        self.tlsExporterHash = tlsExporterHash
    }
}

/// Observable events emitted by all Shell hosts behind one Helix service.
public enum HostEvent: Sendable {
    case authenticating(DevProtocol.ShellID, DevProtocol.PeerID)
    case connected(DevProtocol.ShellID, DevProtocol.SessionIdentity)
    case pipeline(DevProtocol.ShellID, DevSession.PipelineEvent)
    case result(DevProtocol.ShellID, DevSession.PipelineResult)
    case disconnected(DevProtocol.ShellID)
    case connectionRejected(DevProtocol.ShellID, String)
}

public enum HostError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case pairingIdentityMismatch
    case handshakeIdentityMismatch
    case missingPeerIdentity
    case unavailableBuildContext
    case stopped

    public var description: String {
        switch self {
        case .pairingIdentityMismatch:
            "pairing identity does not belong to the selected Dev Shell"
        case .handshakeIdentityMismatch:
            "the authenticated Dev Protocol hello differs from the paired process"
        case .missingPeerIdentity:
            "the authenticated App did not expose a process identity"
        case .unavailableBuildContext:
            "the selected Build Context is unavailable or no longer valid"
        case .stopped:
            "the Shell session host has stopped"
        }
    }
}

/// Pluggable boundary between the unified listener and per-Shell live sessions.
public protocol SessionServing: Sendable {
    /// Validates and warms the exact Build Context before a grant is sent.
    func prepare(context: DevSession.BuildContext) async throws

    /// Owns the post-pairing transport until its App process disconnects.
    func accept(
        authorization: DevSession.SessionAuthorization,
        transport: NetworkTransport.ByteTransport
    ) async throws

    /// Stops and discards compiler state for one removed Shell.
    func remove(shellID: DevProtocol.ShellID) async

    /// Stops every active Shell session and releases cached compiler state.
    func stopAll() async
}

/// Lazily creates one reusable host per exact linked Shell.
public actor SessionHostPool: DevSession.SessionServing {
    public typealias EventHandler = @Sendable (DevSession.HostEvent) async -> Void

    private struct Entry {
        var context: DevSession.BuildContext
        var host: DevSession.SessionHost
    }

    private let eventHandler: EventHandler
    private var hosts: [DevProtocol.ShellID: Entry] = [:]
    private var preparationEpoch: UInt64 = 0
    private var shellEpochs: [DevProtocol.ShellID: UInt64] = [:]

    public init(eventHandler: @escaping EventHandler = { _ in }) {
        self.eventHandler = eventHandler
    }

    public func prepare(context: DevSession.BuildContext) async throws {
        let shellID = context.shellIdentity.shellID
        if hosts[shellID]?.context == context { return }
        let epoch = preparationEpoch
        let shellEpoch = shellEpochs[shellID, default: 0]

        let prepared = try await Task.detached(priority: .userInitiated) {
            try context.loadPreparedConfiguration()
        }.value
        guard epoch == preparationEpoch,
              shellEpoch == shellEpochs[shellID, default: 0]
        else {
            throw DevSession.HostError.stopped
        }
        guard prepared.shellIdentity == context.shellIdentity else {
            throw DevSession.HostError.unavailableBuildContext
        }

        // Another connection may have completed the same preparation while
        // this actor was suspended on filesystem and compiler validation.
        if let current = hosts[shellID],
           current.context.registeredAt >= context.registeredAt {
            return
        }
        let replacement = DevSession.SessionHost(
            prepared: prepared,
            eventHandler: eventHandler
        )
        let previous = hosts.updateValue(
            .init(context: context, host: replacement),
            forKey: shellID
        )
        await previous?.host.stop()
    }

    public func accept(
        authorization: DevSession.SessionAuthorization,
        transport: NetworkTransport.ByteTransport
    ) async throws {
        let shellID = authorization.context.shellIdentity.shellID
        if hosts[shellID]?.context != authorization.context {
            try await prepare(context: authorization.context)
        }
        guard let entry = hosts[shellID], entry.context == authorization.context else {
            throw DevSession.HostError.unavailableBuildContext
        }
        try await entry.host.accept(authorization: authorization, transport: transport)
    }

    public func remove(shellID: DevProtocol.ShellID) async {
        shellEpochs[shellID, default: 0] &+= 1
        guard let removed = hosts.removeValue(forKey: shellID) else { return }
        await removed.host.stop()
    }

    public func stopAll() async {
        preparationEpoch &+= 1
        let current = hosts.values.map(\.host)
        hosts.removeAll()
        shellEpochs.removeAll(keepingCapacity: false)
        for host in current { await host.stop() }
    }

    /// Number of exact Shell hosts currently retained by the pool.
    public func hostCount() -> Int { hosts.count }
}

/// Owns compiler state and at most one active App process for an exact Shell.
public actor SessionHost {
    public typealias EventHandler = @Sendable (DevSession.HostEvent) async -> Void

    private struct ActiveSession {
        var id: UUID
        var controller: DevSession.Controller
        var loop: DevSession.LiveLoop
    }

    public let prepared: DevSession.PreparedConfiguration
    private let eventHandler: EventHandler
    private var activeSession: ActiveSession?
    private var latestAuthenticatedCandidate: UUID?
    private var isStopped = false

    public init(
        prepared: DevSession.PreparedConfiguration,
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.prepared = prepared
        self.eventHandler = eventHandler
    }

    /// Authenticates the existing Dev Protocol on an already paired TLS stream.
    public func accept(
        authorization: DevSession.SessionAuthorization,
        transport: NetworkTransport.ByteTransport
    ) async throws {
        let shellID = prepared.shellIdentity.shellID
        guard !isStopped else {
            await transport.close()
            throw DevSession.HostError.stopped
        }
        guard authorization.context.shellIdentity == prepared.shellIdentity else {
            await transport.close()
            throw DevSession.HostError.pairingIdentityMismatch
        }

        await eventHandler(.authenticating(shellID, authorization.peerIdentity.peerID))
        var authenticatedCandidateID: UUID?
        var candidateController: DevSession.Controller?
        do {
            let channel = try DevProtocol.AuthenticatedChannel(
                transport: transport,
                sessionSecret: authorization.sessionSecret
            )
            let controller = try DevSession.Controller(
                expectedBuildIdentity: prepared.buildIdentity,
                sessionSecret: authorization.sessionSecret,
                tlsTranscriptHash: authorization.tlsExporterHash
            )
            candidateController = controller
            try await controller.accept(channel: channel)
            guard !isStopped else {
                await controller.close(reason: "Helix stopped this Shell session")
                throw DevSession.HostError.stopped
            }
            guard let peer = await controller.snapshot().peerIdentity else {
                throw DevSession.HostError.missingPeerIdentity
            }
            guard Self.sameProcess(peer, authorization.peerIdentity) else {
                throw DevSession.HostError.handshakeIdentityMismatch
            }

            let candidateID = UUID()
            authenticatedCandidateID = candidateID
            latestAuthenticatedCandidate = candidateID
            let router = try DevCompilation.Router.configured(
                identity: peer,
                archive: prepared.archive,
                manifest: prepared.manifest,
                reloadIndex: prepared.reloadIndex,
                compilerURL: prepared.resolved.compilerURL,
                nativeOutputDirectory: prepared.resolved.nativeOutputDirectoryURL,
                preference: prepared.resolved.document.backendPreference,
                deviceNativeMatrixQualified: prepared.resolved.document.deviceNativeMatrixQualified,
                nativeImageSoftLimit: prepared.resolved.document.nativeImageSoftLimit
            )
            let pipeline = try DevSession.Pipeline(
                identity: peer,
                manifest: prepared.manifest,
                reloadIndex: prepared.reloadIndex,
                builder: { try await router.build($0) },
                sender: { try await controller.transfer($0) },
                superseder: { await controller.supersede(with: $0) },
                eventHandler: { [eventHandler] event in
                    if case let .compiling(revision, _) = event {
                        try? await controller.announceCompile(revision)
                    }
                    await eventHandler(.pipeline(shellID, event))
                },
                activationHandler: { offer, result in
                    _ = await router.didReceiveActivation(offer: offer, result: result)
                }
            )
            let loop = try DevSession.LiveLoop(
                pipeline: pipeline,
                manifest: prepared.manifest,
                debounceNanoseconds: UInt64(
                    prepared.resolved.document.debounceMilliseconds
                ) * 1_000_000,
                maximumSourceBytes: prepared.resolved.document.maximumSourceBytes,
                resultHandler: { [eventHandler] result in
                    if let diagnostics = result.diagnosticsForApp {
                        try? await controller.sendDiagnostics(diagnostics)
                    }
                    await eventHandler(.result(shellID, result))
                }
            )

            if let previous = activeSession {
                await previous.loop.stop()
                guard isCurrentCandidate(candidateID) else {
                    await discard(controller: controller, loop: loop)
                    return
                }
                await previous.controller.close(
                    reason: "a newly authenticated App process replaced this connection"
                )
                guard isCurrentCandidate(candidateID) else {
                    await discard(controller: controller, loop: loop)
                    return
                }
            }
            activeSession = .init(id: candidateID, controller: controller, loop: loop)
            await loop.start()
            guard isCurrentCandidate(candidateID) else {
                await discard(controller: controller, loop: loop)
                return
            }
            await eventHandler(.connected(shellID, peer))
            await controller.waitUntilClosed()
            await sessionEnded(id: candidateID)
        } catch {
            if let candidateController {
                await candidateController.close(reason: "Helix rejected this App connection")
            } else {
                await transport.close()
            }
            if let candidateID = authenticatedCandidateID,
               latestAuthenticatedCandidate == candidateID {
                latestAuthenticatedCandidate = activeSession?.id
            }
            await eventHandler(.connectionRejected(shellID, String(describing: error)))
            throw error
        }
    }

    /// Stops the current App connection. The pool may discard this host afterwards.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        latestAuthenticatedCandidate = nil
        if let activeSession {
            await activeSession.loop.stop()
            await activeSession.controller.close(reason: "Helix stopped this Shell session")
        }
        activeSession = nil
    }

    private func sessionEnded(id: UUID) async {
        guard let activeSession, activeSession.id == id else { return }
        await activeSession.loop.stop()
        self.activeSession = nil
        await eventHandler(.disconnected(prepared.shellIdentity.shellID))
    }

    private func isCurrentCandidate(_ id: UUID) -> Bool {
        !isStopped && latestAuthenticatedCandidate == id
    }

    private func discard(
        controller: DevSession.Controller,
        loop: DevSession.LiveLoop
    ) async {
        await loop.stop()
        await controller.close(reason: "a newer authenticated App connection won the session")
        if activeSession?.controller === controller {
            activeSession = nil
        }
    }

    private static func sameProcess(
        _ session: DevProtocol.SessionIdentity,
        _ paired: DevProtocol.PeerIdentity
    ) -> Bool {
        session.processID == paired.processID
            && session.operatingSystemBuild == paired.operatingSystemBuild
            && session.supportedBackends == paired.supportedBackends
    }
}
}
#endif
