#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import Network
import HelixCore
import HelixDevProtocol

extension DevSession {
public enum LaunchTarget: String, Codable, Hashable, Sendable {
    case simulator
    case device
}

public struct Bootstrap: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var sessionID: UUID
    public var protocolVersion: UInt16
    public var serviceName: String
    public var port: UInt16
    public var spkiSHA256: Core.Digest
    public var sessionSecret: Data
    public var bonjourAdvertised: Bool

    public init(
        sessionID: UUID,
        protocolVersion: UInt16,
        serviceName: String,
        port: UInt16,
        spkiSHA256: Core.Digest,
        sessionSecret: Data,
        bonjourAdvertised: Bool
    ) throws {
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard !serviceName.isEmpty, serviceName.utf8.count <= 63, port > 0 else {
            throw DevSession.DaemonError.invalidListenerConfiguration
        }
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
        self.serviceName = serviceName
        self.port = port
        self.spkiSHA256 = spkiSHA256
        self.sessionSecret = sessionSecret
        self.bonjourAdvertised = bonjourAdvertised
    }

    public func environment(
        for target: DevSession.LaunchTarget,
        deviceHost: String? = nil
    ) -> [String: String]? {
        guard target == .simulator || deviceHost != nil || bonjourAdvertised else {
            return nil
        }
        var values = [
            "HLX_DEV_PROTOCOL_VERSION": String(protocolVersion),
            "HLX_DEV_SESSION_ID": sessionID.uuidString,
            "HLX_DEV_SERVICE_NAME": serviceName,
            "HLX_DEV_SPKI_SHA256": spkiSHA256.hex,
            "HLX_DEV_SESSION_SECRET": sessionSecret.hexString,
        ]
        if target == .simulator {
            values["HLX_DEV_HOST"] = "127.0.0.1"
            values["HLX_DEV_PORT"] = String(port)
        } else if let deviceHost {
            values["HLX_DEV_HOST"] = deviceHost
            values["HLX_DEV_PORT"] = String(port)
        }
        return values
    }

    public var description: String {
        "DevSession.Bootstrap(sessionID: \(sessionID), port: \(port), sessionSecret: <redacted>)"
    }

    public var debugDescription: String { description }
}

public enum DaemonEvent: Sendable {
    case listening(DevSession.Bootstrap)
    case authenticating
    case connected(DevProtocol.SessionIdentity)
    case pipeline(DevSession.PipelineEvent)
    case result(DevSession.PipelineResult)
    case disconnected
    case connectionRejected(String)
    case stopped
}

public enum DaemonError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case notRunning
    case invalidListenerConfiguration
    case invalidDisconnectPolicy
    case missingPeerIdentity

    public var description: String {
        switch self {
        case .alreadyRunning: "the Dev Session daemon is already running"
        case .notRunning: "the Dev Session daemon is not running"
        case .invalidListenerConfiguration: "the Dev Session listener configuration is invalid"
        case .invalidDisconnectPolicy: "the Dev Session disconnect policy is invalid"
        case .missingPeerIdentity: "the authenticated App did not expose a process identity"
        }
    }
}

public enum DisconnectPolicy: Hashable, Sendable {
    /// Keep accepting replacement App processes until an explicit stop.
    case waitForReplacement

    /// Preserve a short reconnect window, then bind daemon lifetime to the
    /// authenticated App. Xcode supervision uses this because Launch
    /// post-actions are not guaranteed to run after an explicit Stop.
    case stopAfterGracePeriod(nanoseconds: UInt64)

    fileprivate func validate() throws {
        guard case let .stopAfterGracePeriod(nanoseconds) = self else { return }
        guard (100_000_000...300_000_000_000).contains(nanoseconds) else {
            throw DevSession.DaemonError.invalidDisconnectPolicy
        }
    }
}

/// Owns the Mac-side listener and exactly one active App process. A newly
/// authenticated process replaces the previous connection; unauthenticated
/// sockets can never evict a working session.
public actor Daemon {
    public typealias EventHandler = @Sendable (DevSession.DaemonEvent) async -> Void

    private struct ActiveSession {
        var id: UUID
        var controller: DevSession.Controller
        var loop: DevSession.LiveLoop
    }

    private enum Lifecycle {
        case stopped
        case starting
        case running
        case stopping
    }

    public let prepared: DevSession.PreparedConfiguration
    public let serverIdentity: NetworkTransport.EphemeralIdentity

    private let sessionSecret: Data
    private let disconnectPolicy: DevSession.DisconnectPolicy
    private let eventHandler: EventHandler
    private var listener: NetworkTransport.Listener?
    private var activeSession: ActiveSession?
    private var bootstrap: DevSession.Bootstrap?
    private var lifecycle = Lifecycle.stopped
    private var latestAuthenticatedCandidate: UUID?
    private var disconnectStopTask: Task<Void, Never>?
    private var disconnectStopToken: UUID?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        prepared: DevSession.PreparedConfiguration,
        disconnectPolicy: DevSession.DisconnectPolicy = .waitForReplacement,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        try disconnectPolicy.validate()
        self.prepared = prepared
        serverIdentity = try NetworkTransport.IdentityFactory.makeEphemeralServerIdentity()
        sessionSecret = try DevProtocol.SecureRandom.bytes(count: 32)
        self.disconnectPolicy = disconnectPolicy
        self.eventHandler = eventHandler
    }

    public init(
        configurationURL: URL,
        disconnectPolicy: DevSession.DisconnectPolicy = .waitForReplacement,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        try self.init(
            prepared: DevSession.PreparedConfiguration.load(
                configurationURL: configurationURL
            ),
            disconnectPolicy: disconnectPolicy,
            eventHandler: eventHandler
        )
    }

    @discardableResult
    public func start() async throws -> DevSession.Bootstrap {
        guard lifecycle == .stopped else { throw DevSession.DaemonError.alreadyRunning }
        let document = prepared.resolved.document
        try FileManager.default.createDirectory(
            at: prepared.resolved.nativeOutputDirectoryURL,
            withIntermediateDirectories: true
        )
        let parameters = try NetworkTransport.ByteTransport.tlsServerParameters(
            identity: serverIdentity.identity
        )
        let serviceName = "Helix-" + prepared.manifest.sessionBuildID.uuidString
        let service: NWListener.Service? = document.advertiseBonjour
            ? .init(
                name: serviceName,
                type: "_helix-live._tcp",
                domain: nil,
                txtRecord: NetService.data(
                    fromTXTRecord: [
                        "v": Data(String(DevProtocol.SessionIdentity.currentProtocolVersion).utf8),
                        "sid": Data(prepared.manifest.sessionBuildID.uuidString.utf8),
                    ]
                )
            )
            : nil
        let requestedPort: NWEndpoint.Port? = document.listenPort == 0
            ? nil : NWEndpoint.Port(rawValue: document.listenPort)
        guard document.listenPort == 0 || requestedPort != nil else {
            throw DevSession.DaemonError.invalidListenerConfiguration
        }
        let listener = try NetworkTransport.Listener(
            parameters: parameters,
            port: requestedPort,
            service: service
        ) { [weak self] transport in
            await self?.handle(transport)
        }
        lifecycle = .starting
        self.listener = listener
        do {
            try await listener.start()
            guard lifecycle == .starting else {
                throw DevSession.DaemonError.notRunning
            }
            guard let actualPort = listener.port?.rawValue else {
                throw DevSession.DaemonError.invalidListenerConfiguration
            }
            let bootstrap = try DevSession.Bootstrap(
                sessionID: prepared.manifest.sessionBuildID,
                protocolVersion: DevProtocol.SessionIdentity.currentProtocolVersion,
                serviceName: serviceName,
                port: actualPort,
                spkiSHA256: serverIdentity.spkiHash,
                sessionSecret: sessionSecret,
                bonjourAdvertised: document.advertiseBonjour
            )
            self.bootstrap = bootstrap
            lifecycle = .running
            await eventHandler(.listening(bootstrap))
            return bootstrap
        } catch {
            listener.cancel()
            self.listener = nil
            if lifecycle == .starting { lifecycle = .stopped }
            throw error
        }
    }

    public func currentBootstrap() throws -> DevSession.Bootstrap {
        guard lifecycle == .running, let bootstrap else {
            throw DevSession.DaemonError.notRunning
        }
        return bootstrap
    }

    public func waitUntilStopped() async {
        guard lifecycle != .stopped else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    public func stop() async {
        guard lifecycle != .stopped, lifecycle != .stopping else { return }
        lifecycle = .stopping
        cancelDisconnectStop()
        listener?.cancel()
        listener = nil
        bootstrap = nil
        latestAuthenticatedCandidate = nil
        if let activeSession {
            await activeSession.loop.stop()
            await activeSession.controller.close(reason: "Helix Dev Session stopped")
        }
        activeSession = nil
        lifecycle = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await eventHandler(.stopped)
    }

    private func handle(_ transport: NetworkTransport.ByteTransport) async {
        guard lifecycle == .running else {
            await transport.close()
            return
        }
        await eventHandler(.authenticating)
        var authenticatedCandidateID: UUID?
        do {
            let exporter = try transport.tlsExporterHash()
            let channel = try DevProtocol.AuthenticatedChannel(
                transport: transport,
                sessionSecret: sessionSecret
            )
            let controller = try DevSession.Controller(
                expectedBuildIdentity: prepared.buildIdentity,
                sessionSecret: sessionSecret,
                tlsTranscriptHash: exporter
            )
            try await controller.accept(channel: channel)
            guard lifecycle == .running else {
                await controller.close(reason: "Helix Dev Session is stopping")
                return
            }
            guard let peer = await controller.snapshot().peerIdentity else {
                throw DevSession.DaemonError.missingPeerIdentity
            }
            let candidateID = UUID()
            authenticatedCandidateID = candidateID
            latestAuthenticatedCandidate = candidateID
            cancelDisconnectStop()
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
                    await eventHandler(.pipeline(event))
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
                    await eventHandler(.result(result))
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
            cancelDisconnectStop()
            await loop.start()
            guard isCurrentCandidate(candidateID) else {
                await discard(controller: controller, loop: loop)
                return
            }
            await eventHandler(.connected(peer))
            await controller.waitUntilClosed()
            await sessionEnded(id: candidateID)
        } catch {
            await transport.close()
            if let candidateID = authenticatedCandidateID,
               latestAuthenticatedCandidate == candidateID {
                // A replacement can authenticate and still fail while its
                // compiler pipeline is being constructed. Restore ownership
                // to the session that remains usable so its later disconnect
                // can start a fresh supervised grace period.
                latestAuthenticatedCandidate = activeSession?.id
                if activeSession == nil {
                    scheduleDisconnectStopIfNeeded()
                }
            }
            await eventHandler(.connectionRejected(String(describing: error)))
        }
    }

    private func sessionEnded(id: UUID) async {
        guard let activeSession, activeSession.id == id else { return }
        await activeSession.loop.stop()
        self.activeSession = nil
        await eventHandler(.disconnected)
        if latestAuthenticatedCandidate == id {
            scheduleDisconnectStopIfNeeded()
        }
    }

    private func isCurrentCandidate(_ id: UUID) -> Bool {
        lifecycle == .running && latestAuthenticatedCandidate == id
    }

    private func scheduleDisconnectStopIfNeeded() {
        guard lifecycle == .running,
              activeSession == nil,
              case let .stopAfterGracePeriod(nanoseconds) = disconnectPolicy
        else { return }
        cancelDisconnectStop()
        let token = UUID()
        disconnectStopToken = token
        disconnectStopTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.stopAfterDisconnect(token: token)
        }
    }

    private func stopAfterDisconnect(token: UUID) async {
        guard lifecycle == .running,
              activeSession == nil,
              disconnectStopToken == token
        else { return }
        await stop()
    }

    private func cancelDisconnectStop() {
        disconnectStopTask?.cancel()
        disconnectStopTask = nil
        disconnectStopToken = nil
    }

    private func discard(
        controller: DevSession.Controller,
        loop: DevSession.LiveLoop
    ) async {
        await loop.stop()
        await controller.close(reason: "a newer authenticated App connection won the session")
        if activeSession?.id == latestAuthenticatedCandidate {
            return
        }
        if activeSession?.controller === controller {
            activeSession = nil
        }
    }
}
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
