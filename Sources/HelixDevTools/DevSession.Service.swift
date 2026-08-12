#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import Network
import HelixCore
import HelixDevProtocol

extension DevSession {
/// Listener policy for the long-running, multi-project Helix service.
public struct ServiceConfiguration: Hashable, Sendable {
    /// TCP port, or zero to let the operating system allocate one.
    public var listenPort: UInt16
    /// Whether the single listener is advertised over Bonjour.
    public var advertiseBonjour: Bool
    /// Maximum TLS connections allowed to wait for their first pairing frame.
    public var maximumPendingConnections: Int
    /// Deadline for receiving the first pairing frame.
    public var pairingTimeoutNanoseconds: UInt64

    public init(
        listenPort: UInt16 = 0,
        advertiseBonjour: Bool = true,
        maximumPendingConnections: Int = 64,
        pairingTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.listenPort = listenPort
        self.advertiseBonjour = advertiseBonjour
        self.maximumPendingConnections = maximumPendingConnections
        self.pairingTimeoutNanoseconds = pairingTimeoutNanoseconds
    }

    public func validate() throws {
        guard (1...1_024).contains(maximumPendingConnections),
              (100_000_000...60_000_000_000).contains(pairingTimeoutNanoseconds)
        else {
            throw DevSession.ServiceError.invalidConfiguration
        }
    }
}

/// Stable trust pin and current dynamic port of a running service.
public struct ServiceEndpoint: Hashable, Sendable {
    public var port: UInt16
    public var spkiSHA256: Core.Digest
    public var bonjourAdvertised: Bool

    public init(
        port: UInt16,
        spkiSHA256: Core.Digest,
        bonjourAdvertised: Bool
    ) throws {
        guard port > 0 else { throw DevSession.ServiceError.invalidConfiguration }
        self.port = port
        self.spkiSHA256 = spkiSHA256
        self.bonjourAdvertised = bonjourAdvertised
    }
}

public enum ServiceState: String, Hashable, Sendable {
    case stopped
    case starting
    case running
    case stopping
}

public struct ServiceSnapshot: Hashable, Sendable {
    public var state: DevSession.ServiceState
    public var endpoint: DevSession.ServiceEndpoint?
    public var openConnectionCount: Int
    public var pendingPairingCount: Int
}

/// Events suitable for the CLI, Hub UI, and structured diagnostics.
public enum ServiceEvent: Sendable {
    case listening(DevSession.ServiceEndpoint)
    case pairingStarted
    case paired(DevProtocol.ShellID, DevProtocol.PeerID)
    case pairingRejected(Pairing.Rejection)
    case contextRegistered(DevSession.BuildContext)
    case contextRemoved(DevProtocol.ShellID)
    case session(DevSession.HostEvent)
    case stopped
}

public enum ServiceError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case notRunning
    case invalidConfiguration
    case unexpectedPairingMessage

    public var description: String {
        switch self {
        case .alreadyRunning: "the Helix service is already running"
        case .notRunning: "the Helix service is not running"
        case .invalidConfiguration: "the Helix service configuration is invalid"
        case .unexpectedPairingMessage: "the peer sent an unexpected pairing message"
        }
    }
}

/// One TLS/Bonjour service that routes every App to its exact Build Context.
public actor Service {
    public typealias EventHandler = @Sendable (DevSession.ServiceEvent) async -> Void

    public let configuration: DevSession.ServiceConfiguration
    public let serverIdentity: NetworkTransport.ServerIdentity

    private let broker: DevSession.ConnectionBroker
    private let sessionServer: any DevSession.SessionServing
    private let contextStore: DevSession.ContextStore?
    private let eventHandler: EventHandler
    private var listener: NetworkTransport.Listener?
    private var endpoint: DevSession.ServiceEndpoint?
    private var state = DevSession.ServiceState.stopped
    private var connections: [UUID: NetworkTransport.ByteTransport] = [:]
    private var pendingPairings: Set<UUID> = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a service from reusable core components.
    ///
    /// Pass `contextStore: nil` for an intentionally ephemeral test service.
    public init(
        configuration: DevSession.ServiceConfiguration = .init(),
        serverIdentity: NetworkTransport.ServerIdentity,
        broker: DevSession.ConnectionBroker,
        sessionServer: any DevSession.SessionServing,
        contextStore: DevSession.ContextStore? = nil,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.serverIdentity = serverIdentity
        self.broker = broker
        self.sessionServer = sessionServer
        self.contextStore = contextStore
        self.eventHandler = eventHandler
    }

    /// Opens the owner-only persistent stores used by CLI and Helix Hub frontends.
    public static func persistent(
        configuration: DevSession.ServiceConfiguration = .init(),
        authorityConfiguration: Pairing.AuthorityConfiguration = .init(),
        eventHandler: @escaping EventHandler = { _ in }
    ) throws -> DevSession.Service {
        let identityStore = try NetworkTransport.HostIdentityStore.applicationSupportStore()
        let contextStore = try DevSession.ContextStore.applicationSupportStore()
        let registry = try DevSession.ContextRegistry(contexts: contextStore.load())
        let authority = try Pairing.Authority(configuration: authorityConfiguration)
        let broker = DevSession.ConnectionBroker(registry: registry, authority: authority)
        let sessionServer = DevSession.SessionHostPool { event in
            await eventHandler(.session(event))
        }
        return try .init(
            configuration: configuration,
            serverIdentity: identityStore.loadOrCreate(),
            broker: broker,
            sessionServer: sessionServer,
            contextStore: contextStore,
            eventHandler: eventHandler
        )
    }

    /// Starts TLS 1.3 and advertises one `_helix._tcp` Bonjour service.
    @discardableResult
    public func start() async throws -> DevSession.ServiceEndpoint {
        guard state == .stopped else { throw DevSession.ServiceError.alreadyRunning }
        state = .starting
        let parameters = try NetworkTransport.ByteTransport.tlsServerParameters(
            identity: serverIdentity.identity
        )
        let service: NWListener.Service? = configuration.advertiseBonjour
            ? .init(
                name: NetworkTransport.ServiceDiscovery.visibleName,
                type: NetworkTransport.ServiceDiscovery.type,
                domain: nil,
                txtRecord: NetService.data(
                    fromTXTRecord: [
                        "v": Data(String(DevProtocol.Metadata.currentProtocolVersion).utf8),
                    ]
                )
            )
            : nil
        let requestedPort = configuration.listenPort == 0
            ? nil : NWEndpoint.Port(rawValue: configuration.listenPort)
        let listener = try NetworkTransport.Listener(
            parameters: parameters,
            port: requestedPort,
            service: service
        ) { [weak self] transport in
            await self?.handle(transport)
        }
        self.listener = listener
        do {
            try await listener.start()
            guard state == .starting, let port = listener.port?.rawValue else {
                throw DevSession.ServiceError.invalidConfiguration
            }
            let endpoint = try DevSession.ServiceEndpoint(
                port: port,
                spkiSHA256: serverIdentity.spkiHash,
                bonjourAdvertised: configuration.advertiseBonjour
            )
            self.endpoint = endpoint
            state = .running
            await eventHandler(.listening(endpoint))
            return endpoint
        } catch {
            listener.cancel()
            self.listener = nil
            endpoint = nil
            state = .stopped
            throw error
        }
    }

    /// Returns the current lifecycle, endpoint, and in-flight socket count.
    public func snapshot() -> DevSession.ServiceSnapshot {
        .init(
            state: state,
            endpoint: endpoint,
            openConnectionCount: connections.count,
            pendingPairingCount: pendingPairings.count
        )
    }

    /// Suspends until an explicit service stop completes.
    public func waitUntilStopped() async {
        guard state != .stopped else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    /// Stops discovery, unauthenticated sockets, and every active Shell host.
    public func stop() async {
        guard state != .stopped, state != .stopping else { return }
        state = .stopping
        listener?.cancel()
        listener = nil
        endpoint = nil
        let transports = Array(connections.values)
        connections.removeAll()
        pendingPairings.removeAll()
        for transport in transports { await transport.close() }
        await broker.invalidateAll()
        await sessionServer.stopAll()
        state = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await eventHandler(.stopped)
    }

    /// Registers an exact Shell and atomically updates persistent Build Contexts.
    @discardableResult
    public func registerBuildContext(
        _ context: DevSession.BuildContext
    ) async throws -> Bool {
        let changed: Bool
        if let contextStore {
            changed = try await broker.registry.register(
                context,
                persistingTo: contextStore
            )
        } else {
            changed = try await broker.registry.register(context)
        }
        if changed { await eventHandler(.contextRegistered(context)) }
        return changed
    }

    /// Removes one exact Shell from memory and persistent Build Contexts.
    @discardableResult
    public func removeBuildContext(
        shellID: DevProtocol.ShellID
    ) async throws -> DevSession.BuildContext? {
        let removed: DevSession.BuildContext?
        if let contextStore {
            removed = try await broker.registry.remove(
                shellID: shellID,
                persistingTo: contextStore
            )
        } else {
            removed = await broker.registry.remove(shellID: shellID)
        }
        if removed != nil {
            await broker.authority.revoke(shellID: shellID)
            await sessionServer.remove(shellID: shellID)
            await eventHandler(.contextRemoved(shellID))
        }
        return removed
    }

    /// Lists registered Shells newest-first for Hub project selection.
    public func buildContexts(
        workspacePathHash: Core.Digest? = nil
    ) async -> [DevSession.BuildContext] {
        await broker.registry.contexts(workspacePathHash: workspacePathHash)
    }

    /// Creates the four-character code displayed by Helix Hub.
    public func createManualInvitation(
        workspacePathHash: Core.Digest? = nil
    ) async throws -> DevSession.ManualInvitation {
        guard state == .running else { throw DevSession.ServiceError.notRunning }
        return try await broker.createManualInvitation(
            workspacePathHash: workspacePathHash
        )
    }

    /// Cancels a code currently displayed by Helix Hub.
    public func cancelManualInvitation(
        invitationID: DevProtocol.InvitationID
    ) async {
        await broker.cancelManualInvitation(invitationID: invitationID)
    }

    /// Lists non-expired codes for Hub presentation.
    public func manualInvitations() async -> [DevSession.ManualInvitation] {
        await broker.manualInvitations()
    }

    /// Reserves the one-time code embedded during an Xcode build.
    public func reserveAutomaticInvitation() async throws -> Pairing.Reservation {
        guard state == .running else { throw DevSession.ServiceError.notRunning }
        return try await broker.reserveAutomaticInvitation()
    }

    /// Imports a reservation made by another same-user build helper.
    public func registerAutomaticReservation(
        _ reservation: Pairing.Reservation
    ) async throws {
        guard state == .running else { throw DevSession.ServiceError.notRunning }
        try await broker.registerAutomaticReservation(reservation)
    }

    /// Binds a pre-link reservation to the final exact Shell.
    public func activateAutomaticInvitation(
        invitationID: DevProtocol.InvitationID,
        shellID: DevProtocol.ShellID
    ) async throws -> Pairing.Invitation {
        guard state == .running else { throw DevSession.ServiceError.notRunning }
        return try await broker.activateAutomaticInvitation(
            invitationID: invitationID,
            shellID: shellID
        )
    }

    private func handle(_ transport: NetworkTransport.ByteTransport) async {
        guard state == .running,
              pendingPairings.count < configuration.maximumPendingConnections
        else {
            await transport.close()
            return
        }
        let connectionID = UUID()
        connections[connectionID] = transport
        pendingPairings.insert(connectionID)
        await eventHandler(.pairingStarted)
        let channel = Pairing.Channel(transport: transport)
        var transitionedToSession = false
        var ungrantedLeaseID: DevProtocol.LeaseID?

        do {
            let exporter = try transport.tlsExporterHash()
            let message = try await Self.receivePairingMessage(
                from: channel,
                timeoutNanoseconds: configuration.pairingTimeoutNanoseconds
            )
            let authorization: DevSession.SessionAuthorization
            switch message {
            case let .redeem(request):
                let established = try await broker.redeem(
                    request,
                    rateLimitKey: .init(stableSource: transport.remoteSourceIdentifier),
                    tlsExporterHash: exporter
                )
                ungrantedLeaseID = established.session.grant.leaseID
                do {
                    try await sessionServer.prepare(context: established.context)
                } catch {
                    await broker.authority.revoke(leaseID: established.session.grant.leaseID)
                    ungrantedLeaseID = nil
                    throw Pairing.Failure(
                        reason: .buildMismatch,
                        detail: "the selected Build Context is no longer usable"
                    )
                }
                guard state == .running else {
                    await broker.authority.revoke(leaseID: established.session.grant.leaseID)
                    ungrantedLeaseID = nil
                    throw DevSession.ServiceError.notRunning
                }
                authorization = try .init(
                    context: established.context,
                    peerIdentity: established.session.peerIdentity,
                    sessionSecret: established.session.grant.sessionSecret,
                    tlsExporterHash: exporter
                )
                try await channel.send(.sessionGranted(established.session.grant))
                transitionedToSession = true
                ungrantedLeaseID = nil
                pendingPairings.remove(connectionID)

            case let .resume(request):
                let resumed = try await broker.resume(
                    request,
                    tlsExporterHash: exporter
                )
                do {
                    try await sessionServer.prepare(context: resumed.context)
                } catch {
                    await broker.authority.revoke(leaseID: resumed.session.grant.leaseID)
                    throw Pairing.Failure(
                        reason: .buildMismatch,
                        detail: "the selected Build Context is no longer usable"
                    )
                }
                guard state == .running else {
                    await broker.authority.revoke(leaseID: resumed.session.grant.leaseID)
                    throw DevSession.ServiceError.notRunning
                }
                authorization = try .init(
                    context: resumed.context,
                    peerIdentity: resumed.session.peerIdentity,
                    sessionSecret: resumed.session.sessionSecret,
                    tlsExporterHash: exporter
                )
                try await channel.send(.sessionResumed(resumed.session.grant))
                transitionedToSession = true
                pendingPairings.remove(connectionID)

            case .sessionGranted, .sessionResumed, .rejected:
                throw Pairing.Failure(
                    reason: .protocolMismatch,
                    detail: DevSession.ServiceError.unexpectedPairingMessage.description
                )
            }

            await eventHandler(
                .paired(
                    authorization.context.shellIdentity.shellID,
                    authorization.peerIdentity.peerID
                )
            )
            try await sessionServer.accept(
                authorization: authorization,
                transport: transport
            )
        } catch {
            if let leaseID = ungrantedLeaseID {
                await broker.authority.revoke(leaseID: leaseID)
            }
            if !transitionedToSession {
                let rejection = Self.rejection(for: error)
                try? await channel.send(.rejected(rejection))
                await eventHandler(.pairingRejected(rejection))
            }
        }

        connections[connectionID] = nil
        pendingPairings.remove(connectionID)
        await transport.close()
    }

    private static func receivePairingMessage(
        from channel: Pairing.Channel<NetworkTransport.ByteTransport>,
        timeoutNanoseconds: UInt64
    ) async throws -> Pairing.Message {
        try await withThrowingTaskGroup(of: Pairing.Message.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                try Task.checkCancellation()
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
                throw error
            }
        }
    }

    private static func rejection(for error: any Swift.Error) -> Pairing.Rejection {
        if let failure = error as? Pairing.Failure {
            return .init(
                reason: failure.reason,
                detail: boundedDetail(failure.detail)
            )
        }
        if error is DevProtocol.Error {
            return .init(
                reason: .protocolMismatch,
                detail: "the pairing message is malformed or incompatible"
            )
        }
        return .init(
            reason: .invalidInvitation,
            detail: boundedDetail(String(describing: error))
        )
    }

    private static func boundedDetail(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\0", with: "")
        guard !clean.isEmpty else { return "pairing failed" }
        return String(clean.prefix(1_024))
    }
}
}
#endif
