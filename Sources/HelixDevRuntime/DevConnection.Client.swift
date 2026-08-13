#if canImport(Network) && canImport(Security)
import Foundation
import Network
#if canImport(HelixCore)
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
#endif

extension DevConnection {
/// Bounded retry, discovery, TLS, and pairing deadlines.
public struct ReconnectPolicy: Hashable, Sendable {
    /// Maximum reconnects after the initial attempt.
    public var maximumAttempts: Int
    /// Delay before the first reconnect, in nanoseconds.
    public var initialDelayNanoseconds: UInt64
    /// Upper bound for exponential backoff, in nanoseconds.
    public var maximumDelayNanoseconds: UInt64
    /// Deadline for each Bonjour discovery attempt, in nanoseconds.
    public var discoveryTimeoutNanoseconds: UInt64
    /// Deadline for each candidate TLS connection, in nanoseconds.
    public var connectionTimeoutNanoseconds: UInt64
    /// Deadline for invitation or reconnect-lease authentication, in nanoseconds.
    public var pairingTimeoutNanoseconds: UInt64

    /// Creates bounded connection timing. `maximumAttempts` counts retries,
    /// so zero still permits one initial connection attempt.
    public init(
        maximumAttempts: Int = 20,
        initialDelayNanoseconds: UInt64 = 250_000_000,
        maximumDelayNanoseconds: UInt64 = 5_000_000_000,
        discoveryTimeoutNanoseconds: UInt64 = 10_000_000_000,
        connectionTimeoutNanoseconds: UInt64 = 10_000_000_000,
        pairingTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.discoveryTimeoutNanoseconds = discoveryTimeoutNanoseconds
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
        self.pairingTimeoutNanoseconds = pairingTimeoutNanoseconds
    }

    /// Rejects unbounded, zero, or internally inconsistent timing values.
    public func validate() throws {
        let maximumTimeout: UInt64 = 5 * 60 * 1_000_000_000
        guard (0...10_000).contains(maximumAttempts),
              initialDelayNanoseconds > 0,
              initialDelayNanoseconds <= maximumDelayNanoseconds,
              maximumDelayNanoseconds <= maximumTimeout,
              discoveryTimeoutNanoseconds > 0,
              discoveryTimeoutNanoseconds <= maximumTimeout,
              connectionTimeoutNanoseconds > 0,
              connectionTimeoutNanoseconds <= maximumTimeout,
              pairingTimeoutNanoseconds > 0,
              pairingTimeoutNanoseconds <= maximumTimeout
        else { throw DevConnection.Error.invalidConfiguration }
    }
}

/// Identity and activation state selected after a pairing grant names its Shell.
public struct SessionContext: Sendable {
    /// Full App identity bound to the granted Shell.
    public let identity: DevProtocol.SessionIdentity
    /// Activation state retained across transport reconnects.
    public let activation: DevActivation.Controller

    /// Creates a context only when activation and advertised identity agree.
    public init(
        identity: DevProtocol.SessionIdentity,
        activation: DevActivation.Controller
    ) throws {
        try identity.validate()
        guard activation.identity == identity else {
            throw DevConnection.Error.sessionIdentityMismatch
        }
        self.identity = identity
        self.activation = activation
    }
}

/// Lifecycle event emitted for status UI and diagnostics.
public enum ClientEvent: Sendable {
    /// A directly opened test App is offline until the developer enters a code.
    case awaitingManualPairing
    /// Bonjour discovery or pinned TLS connection is starting.
    case connecting(attempt: Int)
    /// A one-time invitation or reconnect lease is being authenticated.
    case pairing(attempt: Int)
    /// Pairing selected an exact Shell.
    case paired(DevProtocol.ShellID)
    /// Event emitted by an authenticated Dev Protocol session.
    case session(DevRuntimeSession.Event)
    /// A transient failure will be retried after the supplied delay.
    case reconnectScheduled(attempt: Int, delayNanoseconds: UInt64, reason: String)
    /// Setup, pairing, or authentication ended with a non-retryable failure.
    case failed(String)
    /// The client was intentionally stopped.
    case stopped
}

/// Discovers the single Helix Bonjour service, pins its persistent Host
/// Identity, redeems or resumes a session, then runs the Dev Protocol.
public actor Client {
    /// Async lifecycle callback used by diagnostics and status presentation.
    public typealias EventHandler = @Sendable (DevConnection.ClientEvent) async -> Void
    /// Lazily creates persistent activation state for the Shell selected by Hub.
    public typealias SessionFactory = @Sendable (
        DevProtocol.ShellID
    ) async throws -> DevConnection.SessionContext

    private struct Lease: Sendable {
        var shellID: DevProtocol.ShellID
        var leaseID: DevProtocol.LeaseID
        var sessionSecret: Data
        var expiresAt: Date
    }

    private struct Authorization: Sendable {
        var shellID: DevProtocol.ShellID
        var sessionSecret: Data
    }

    private let configuration: DevConnection.Configuration
    /// Immutable build and process facts presented before authorization.
    public let peerIdentity: DevProtocol.PeerIdentity
    /// Retry and deadline policy for discovery through pairing.
    public let reconnectPolicy: DevConnection.ReconnectPolicy
    /// Liveness policy used after Dev Protocol authentication.
    public let liveness: DevProtocol.LivenessConfiguration

    private let sessionFactory: SessionFactory
    private let eventHandler: EventHandler
    private let manualReloadHandler: DevRuntimeSession.Controller.ManualReloadHandler
    private var lease: Lease?
    private var currentTransport: NetworkTransport.ByteTransport?
    private var currentBrowser: NetworkTransport.Browser?
    private var discoveryContinuation:
        AsyncStream<[NetworkTransport.DiscoveredService]>.Continuation?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private var retryDelayTask: Task<Void, any Swift.Error>?
    private var isRunning = false
    private var isStopping = false

    /// Creates a client that always discovers `_helix._tcp` and pins the Hub key.
    ///
    /// Session state is requested only after Hub grants an exact Shell ID; this
    /// prevents an App from activating artifacts for a merely similar build.
    public init(
        configuration: DevConnection.Configuration,
        peerIdentity: DevProtocol.PeerIdentity,
        reconnectPolicy: DevConnection.ReconnectPolicy = .init(),
        liveness: DevProtocol.LivenessConfiguration = .init(),
        sessionFactory: @escaping SessionFactory,
        eventHandler: @escaping EventHandler = { _ in },
        manualReloadHandler: @escaping DevRuntimeSession.Controller.ManualReloadHandler = { _ in
            (.manualRefreshRequired, "no manual UI reload handler is installed")
        }
    ) throws {
        try configuration.validate()
        try peerIdentity.validate()
        try reconnectPolicy.validate()
        try liveness.validate()
        guard configuration.protocolVersion == peerIdentity.build.protocolVersion else {
            throw DevConnection.Error.protocolVersionMismatch
        }
        self.configuration = configuration
        self.peerIdentity = peerIdentity
        self.reconnectPolicy = reconnectPolicy
        self.liveness = liveness
        self.sessionFactory = sessionFactory
        self.eventHandler = eventHandler
        self.manualReloadHandler = manualReloadHandler
    }

    /// Runs until the authenticated peer closes, retry limits are exhausted,
    /// or ``stop()`` is called. Active code survives transport reconnections.
    public func run() async throws {
        guard !isRunning else { throw DevConnection.Error.alreadyRunning }
        isRunning = true
        isStopping = false
        defer { resetTransientState() }

        var retryCount = 0
        var delay = reconnectPolicy.initialDelayNanoseconds
        while !Task.isCancelled, !isStopping {
            await eventHandler(.connecting(attempt: retryCount + 1))
            do {
                let transport = try await connectToPinnedService()
                guard !isStopping else { return }
                currentTransport = transport
                let exporter = try transport.tlsExporterHash()
                await eventHandler(.pairing(attempt: retryCount + 1))
                let authorization = try await authorize(
                    transport: transport,
                    tlsExporterHash: exporter
                )
                let context = try await sessionFactory(authorization.shellID)
                try validate(context: context, shellID: authorization.shellID)
                await eventHandler(.paired(authorization.shellID))
                let channel = try DevProtocol.AuthenticatedChannel(
                    transport: transport,
                    sessionSecret: authorization.sessionSecret
                )
                let session = try DevRuntimeSession.Controller(
                    identity: context.identity,
                    sessionSecret: authorization.sessionSecret,
                    tlsTranscriptHash: exporter,
                    activation: context.activation,
                    liveness: liveness,
                    eventHandler: { [eventHandler] event in
                        await eventHandler(.session(event))
                    },
                    manualReloadHandler: manualReloadHandler
                )
                try await session.run(channel: channel)
                currentTransport = nil
                return
            } catch is CancellationError {
                await closeCurrentTransport()
                return
            } catch {
                await closeCurrentTransport()
                guard !isStopping else { return }
                guard Self.isReconnectable(error),
                      retryCount < reconnectPolicy.maximumAttempts
                else { throw error }
                retryCount += 1
                await eventHandler(
                    .reconnectScheduled(
                        attempt: retryCount,
                        delayNanoseconds: delay,
                        reason: String(describing: error)
                    )
                )
                let task = Task { [delay] in
                    try await Task.sleep(nanoseconds: delay)
                }
                retryDelayTask = task
                do {
                    try await task.value
                } catch is CancellationError {
                    retryDelayTask = nil
                    if isStopping || Task.isCancelled { return }
                    throw CancellationError()
                }
                retryDelayTask = nil
                let doubled = delay.multipliedReportingOverflow(by: 2)
                delay = doubled.overflow
                    ? reconnectPolicy.maximumDelayNanoseconds
                    : min(doubled.partialValue, reconnectPolicy.maximumDelayNanoseconds)
            }
        }
    }

    /// Idempotently cancels discovery, retry delay, and the current connection.
    public func stop() async {
        guard isRunning, !isStopping else { return }
        isStopping = true
        currentBrowser?.cancel()
        currentBrowser = nil
        discoveryContinuation?.finish()
        discoveryContinuation = nil
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        retryDelayTask?.cancel()
        retryDelayTask = nil
        await closeCurrentTransport()
        await eventHandler(.stopped)
    }

    private func connectToPinnedService() async throws -> NetworkTransport.ByteTransport {
        let stream = AsyncStream.makeStream(
            of: [NetworkTransport.DiscoveredService].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let browser = NetworkTransport.Browser { services in
            stream.continuation.yield(services)
        }
        currentBrowser = browser
        discoveryContinuation = stream.continuation
        defer {
            browser.cancel()
            stream.continuation.finish()
            currentBrowser = nil
            discoveryContinuation = nil
            discoveryTimeoutTask?.cancel()
            discoveryTimeoutTask = nil
        }
        try await start(browser)
        let timeoutTask = Task { [timeout = reconnectPolicy.discoveryTimeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeout)
                stream.continuation.finish()
                browser.cancel()
            } catch {
                // Successful connection or explicit stop owns cleanup.
            }
        }
        discoveryTimeoutTask = timeoutTask
        var attempted = Set<NWEndpoint>()
        for await services in stream.stream {
            guard !isStopping else { throw DevConnection.Error.stopped }
            for service in services
                where service.type == NetworkTransport.ServiceDiscovery.type
                    && attempted.insert(service.endpoint).inserted {
                let transport = NetworkTransport.ByteTransport.pinnedTLSClient(
                    endpoint: service.endpoint,
                    expectedSPKIHash: configuration.expectedSPKIHash
                )
                currentTransport = transport
                do {
                    try await start(transport)
                    try await transport.send(
                        NetworkTransport.ConnectionRoute.pairing.preamble
                    )
                    return transport
                } catch {
                    await transport.close()
                    currentTransport = nil
                }
            }
        }
        guard !isStopping else { throw DevConnection.Error.stopped }
        throw DevConnection.Error.discoveryTimedOut
    }

    private func authorize(
        transport: NetworkTransport.ByteTransport,
        tlsExporterHash: Core.Digest
    ) async throws -> Authorization {
        let channel = Pairing.Channel(transport: transport)
        if let lease {
            guard Date() <= lease.expiresAt else {
                throw DevConnection.Error.pairingRejected(
                    .invalidLease,
                    "the reconnect lease expired; enter a new Hub code"
                )
            }
            let request = try Pairing.ResumeRequest.signed(
                leaseID: lease.leaseID,
                peerIdentity: peerIdentity,
                sessionSecret: lease.sessionSecret,
                tlsExporterHash: tlsExporterHash
            )
            try await channel.send(.resume(request))
            let response = try await receivePairingMessage(from: channel)
            switch response {
            case let .sessionResumed(grant):
                guard grant.shellID == lease.shellID,
                      grant.leaseID == lease.leaseID,
                      try grant.verify(
                          request: request,
                          tlsExporterHash: tlsExporterHash,
                          sessionSecret: lease.sessionSecret,
                          now: Date()
                      )
                else { throw DevProtocol.Error.invalidAuthentication }
                self.lease?.expiresAt = grant.expiresAt
                return .init(
                    shellID: grant.shellID,
                    sessionSecret: lease.sessionSecret
                )
            case let .rejected(rejection):
                throw DevConnection.Error.pairingRejected(
                    rejection.reason,
                    rejection.detail
                )
            case .redeem, .resume, .sessionGranted:
                throw DevProtocol.Error.malformedMessage(
                    "unexpected response to a Helix lease resume"
                )
            }
        }

        let request = Pairing.RedeemRequest(
            code: configuration.pairingCode,
            peerIdentity: peerIdentity,
            clientNonce: try DevProtocol.SecureRandom.bytes(count: 32)
        )
        try await channel.send(.redeem(request))
        let response = try await receivePairingMessage(from: channel)
        switch response {
        case let .sessionGranted(grant):
            guard try grant.verify(
                request: request,
                tlsExporterHash: tlsExporterHash,
                now: Date()
            ) else { throw DevProtocol.Error.invalidAuthentication }
            lease = .init(
                shellID: grant.shellID,
                leaseID: grant.leaseID,
                sessionSecret: grant.sessionSecret,
                expiresAt: grant.expiresAt
            )
            return .init(
                shellID: grant.shellID,
                sessionSecret: grant.sessionSecret
            )
        case let .rejected(rejection):
            throw DevConnection.Error.pairingRejected(
                rejection.reason,
                rejection.detail
            )
        case .redeem, .resume, .sessionResumed:
            throw DevProtocol.Error.malformedMessage(
                "unexpected response to a Helix invitation"
            )
        }
    }

    private func receivePairingMessage(
        from channel: Pairing.Channel<NetworkTransport.ByteTransport>
    ) async throws -> Pairing.Message {
        try await withThrowingTaskGroup(of: Pairing.Message.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask { [timeout = reconnectPolicy.pairingTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeout)
                try Task.checkCancellation()
                await channel.close()
                throw DevConnection.Error.pairingTimedOut
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

    private func validate(
        context: DevConnection.SessionContext,
        shellID: DevProtocol.ShellID
    ) throws {
        let identity = context.identity
        guard identity.sessionID == shellID.rawValue,
              identity.protocolVersion == peerIdentity.build.protocolVersion,
              identity.bundleID == peerIdentity.build.bundleID,
              identity.executableUUID == peerIdentity.build.executableUUID,
              identity.processID == peerIdentity.processID,
              identity.platform == peerIdentity.build.platform,
              identity.architecture == peerIdentity.build.architecture,
              identity.operatingSystemBuild == peerIdentity.operatingSystemBuild,
              identity.xcodeBuild == peerIdentity.build.xcodeBuild,
              identity.swiftCompilerFingerprint
                == peerIdentity.build.swiftCompilerFingerprint,
              identity.liveReloadIndexHash == peerIdentity.build.liveReloadIndexHash,
              identity.supportedBackends == peerIdentity.supportedBackends
        else { throw DevConnection.Error.sessionIdentityMismatch }
    }

    private func start(_ transport: NetworkTransport.ByteTransport) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.start() }
            group.addTask { [timeout = reconnectPolicy.connectionTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeout)
                await transport.close()
                throw DevConnection.Error.connectionTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func start(_ browser: NetworkTransport.Browser) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await browser.start() }
            group.addTask { [timeout = reconnectPolicy.discoveryTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeout)
                browser.cancel()
                throw DevConnection.Error.discoveryTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func closeCurrentTransport() async {
        if let currentTransport { await currentTransport.close() }
        currentTransport = nil
    }

    private func resetTransientState() {
        currentBrowser?.cancel()
        currentBrowser = nil
        discoveryContinuation?.finish()
        discoveryContinuation = nil
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        retryDelayTask?.cancel()
        retryDelayTask = nil
        currentTransport = nil
        isRunning = false
        isStopping = false
    }

    private static func isReconnectable(_ error: any Swift.Error) -> Bool {
        if error is NetworkTransport.Error { return true }
        if let error = error as? DevConnection.Error {
            return error == .discoveryTimedOut
                || error == .connectionTimedOut
                || error == .pairingTimedOut
        }
        if let error = error as? DevProtocol.Error {
            return error == .sessionTimedOut || error == .truncatedFrame
        }
        return false
    }
}
}
#endif
