#if canImport(Network) && canImport(Security)
import Foundation
import Network
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

extension DevConnection {
/// Bounded exponential-backoff behavior for transient connection failures.
public struct ReconnectPolicy: Hashable, Sendable {
    /// Maximum number of reconnects after the initial attempt.
    public var maximumAttempts: Int
    /// Delay before the first reconnect, in nanoseconds.
    public var initialDelayNanoseconds: UInt64
    /// Upper bound for the doubled reconnect delay, in nanoseconds.
    public var maximumDelayNanoseconds: UInt64
    /// Bonjour discovery deadline for each attempt, in nanoseconds.
    public var discoveryTimeoutNanoseconds: UInt64
    /// Network connection readiness deadline for each attempt, in nanoseconds.
    public var connectionTimeoutNanoseconds: UInt64

    /// Creates a reconnect policy.
    public init(
        maximumAttempts: Int = 20,
        initialDelayNanoseconds: UInt64 = 250_000_000,
        maximumDelayNanoseconds: UInt64 = 5_000_000_000,
        discoveryTimeoutNanoseconds: UInt64 = 10_000_000_000,
        connectionTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.discoveryTimeoutNanoseconds = discoveryTimeoutNanoseconds
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
    }

    /// Validates attempt bounds, positive deadlines, and backoff ordering.
    public func validate() throws {
        let maximumTimeout: UInt64 = 5 * 60 * 1_000_000_000
        guard (0...10_000).contains(maximumAttempts),
              initialDelayNanoseconds > 0,
              initialDelayNanoseconds <= maximumDelayNanoseconds,
              maximumDelayNanoseconds <= maximumTimeout,
              discoveryTimeoutNanoseconds > 0,
              discoveryTimeoutNanoseconds <= maximumTimeout,
              connectionTimeoutNanoseconds > 0,
              connectionTimeoutNanoseconds <= maximumTimeout
        else { throw DevConnection.Error.invalidEnvironment }
    }
}

/// Lifecycle event emitted by ``Client`` for status UI and diagnostics.
public enum ClientEvent: Sendable {
    /// A discovery or transport attempt is starting. Attempts are one-based.
    case connecting(attempt: Int)
    /// Event emitted by an authenticated protocol session.
    case session(DevRuntimeSession.Event)
    /// A transient failure will be retried after the supplied delay.
    case reconnectScheduled(attempt: Int, delayNanoseconds: UInt64, reason: String)
    /// The client was intentionally stopped.
    case stopped
}

/// Establishes an authenticated session from launch-only credentials. Native
/// and HLBC generations live in DevActivation, so a transport reconnect never
/// rolls back already active code.
public actor Client {
    /// Async lifecycle callback. Keep handlers lightweight and non-blocking.
    public typealias EventHandler = @Sendable (DevConnection.ClientEvent) async -> Void

    /// Validated endpoint and ephemeral launch credentials.
    public let configuration: DevConnection.Configuration
    /// App process identity authenticated to the paired daemon.
    public let identity: DevProtocol.SessionIdentity
    /// Retry and backoff limits used by ``run()``.
    public let reconnectPolicy: DevConnection.ReconnectPolicy
    /// Heartbeat, inactivity, and clock-skew limits for authenticated messages.
    public let liveness: DevProtocol.LivenessConfiguration

    private let activation: DevActivation.Controller
    private let eventHandler: EventHandler
    private let manualReloadHandler: DevRuntimeSession.Controller.ManualReloadHandler
    private var currentTransport: NetworkTransport.ByteTransport?
    private var currentBrowser: NetworkTransport.Browser?
    private var retryDelayTask: Task<Void, any Swift.Error>?
    private var isRunning = false
    private var isStopping = false

    /// Creates a client around an existing activation controller.
    ///
    /// `configuration` and `identity` must refer to the same session and protocol
    /// version. TLS pinning and frame authentication are mandatory.
    public init(
        configuration: DevConnection.Configuration,
        identity: DevProtocol.SessionIdentity,
        activation: DevActivation.Controller,
        reconnectPolicy: DevConnection.ReconnectPolicy = .init(),
        liveness: DevProtocol.LivenessConfiguration = .init(),
        eventHandler: @escaping EventHandler = { _ in },
        manualReloadHandler: @escaping DevRuntimeSession.Controller.ManualReloadHandler = { _ in
            (.manualRefreshRequired, "no manual UI reload handler is installed")
        }
    ) throws {
        try configuration.validate()
        try identity.validate()
        try reconnectPolicy.validate()
        try liveness.validate()
        guard configuration.sessionID == identity.sessionID,
              configuration.protocolVersion == identity.protocolVersion
        else { throw DevConnection.Error.sessionIdentityMismatch }
        self.configuration = configuration
        self.identity = identity
        self.activation = activation
        self.reconnectPolicy = reconnectPolicy
        self.liveness = liveness
        self.eventHandler = eventHandler
        self.manualReloadHandler = manualReloadHandler
    }

    /// Runs discovery, pinned TLS, authentication, and message processing.
    ///
    /// The call remains suspended until the peer closes, the client is stopped,
    /// or a terminal error occurs. Reconnectable transport failures use the
    /// configured exponential backoff; active code is not rolled back.
    public func run() async throws {
        guard !isRunning else { throw DevConnection.Error.alreadyRunning }
        isRunning = true
        isStopping = false
        defer {
            currentBrowser?.cancel()
            currentBrowser = nil
            retryDelayTask?.cancel()
            retryDelayTask = nil
            currentTransport = nil
            isRunning = false
            isStopping = false
        }

        var retryCount = 0
        var delay = reconnectPolicy.initialDelayNanoseconds
        while !Task.isCancelled, !isStopping {
            await eventHandler(.connecting(attempt: retryCount + 1))
            do {
                let endpoint = try await resolveEndpoint()
                guard !isStopping else { return }
                let transport = NetworkTransport.ByteTransport.pinnedTLSClient(
                    endpoint: endpoint,
                    expectedSPKIHash: configuration.expectedSPKIHash
                )
                currentTransport = transport
                try await start(transport)
                let exporter = try transport.tlsExporterHash()
                let channel = try DevProtocol.AuthenticatedChannel(
                    transport: transport,
                    sessionSecret: configuration.sessionSecret
                )
                let session = try DevRuntimeSession.Controller(
                    identity: identity,
                    sessionSecret: configuration.sessionSecret,
                    tlsTranscriptHash: exporter,
                    activation: activation,
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
                if let currentTransport { await currentTransport.close() }
                currentTransport = nil
                return
            } catch {
                if let currentTransport { await currentTransport.close() }
                currentTransport = nil
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
                let retryDelayTask = Task { [delay] in
                    try await Task.sleep(nanoseconds: delay)
                }
                self.retryDelayTask = retryDelayTask
                do {
                    try await retryDelayTask.value
                } catch is CancellationError {
                    self.retryDelayTask = nil
                    if isStopping || Task.isCancelled { return }
                    throw CancellationError()
                }
                self.retryDelayTask = nil
                let doubled = delay.multipliedReportingOverflow(by: 2)
                delay = doubled.overflow
                    ? reconnectPolicy.maximumDelayNanoseconds
                    : min(doubled.partialValue, reconnectPolicy.maximumDelayNanoseconds)
            }
        }
    }

    /// Idempotently cancels discovery, backoff, and the active transport.
    public func stop() async {
        guard isRunning, !isStopping else { return }
        isStopping = true
        currentBrowser?.cancel()
        currentBrowser = nil
        retryDelayTask?.cancel()
        retryDelayTask = nil
        if let currentTransport { await currentTransport.close() }
        currentTransport = nil
        await eventHandler(.stopped)
    }

    private func resolveEndpoint() async throws -> NWEndpoint {
        switch configuration.endpoint {
        case let .direct(host, port):
            guard let networkPort = NWEndpoint.Port(rawValue: port) else {
                throw DevConnection.Error.invalidEnvironment
            }
            return .hostPort(host: NWEndpoint.Host(host), port: networkPort)
        case let .bonjour(serviceName):
            let stream = AsyncStream.makeStream(
                of: [NetworkTransport.DiscoveredService].self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let browser = NetworkTransport.Browser { services in
                stream.continuation.yield(services)
            }
            currentBrowser = browser
            defer {
                browser.cancel()
                stream.continuation.finish()
                currentBrowser = nil
            }
            try await start(browser)
            return try await withThrowingTaskGroup(of: NWEndpoint.self) { group in
                group.addTask {
                    for await services in stream.stream {
                        if let service = services.first(where: {
                            $0.name == serviceName && $0.type == "_helix-live._tcp"
                        }) {
                            return service.endpoint
                        }
                    }
                    throw DevConnection.Error.stopped
                }
                group.addTask { [timeout = reconnectPolicy.discoveryTimeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: timeout)
                    throw DevConnection.Error.discoveryTimedOut
                }
                defer { group.cancelAll() }
                guard let endpoint = try await group.next() else {
                    throw DevConnection.Error.discoveryTimedOut
                }
                return endpoint
            }
        }
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

    private static func isReconnectable(_ error: any Swift.Error) -> Bool {
        if error is NetworkTransport.Error { return true }
        if let error = error as? DevConnection.Error {
            return error == .discoveryTimedOut || error == .connectionTimedOut
        }
        if let error = error as? DevProtocol.Error {
            return error == .sessionTimedOut || error == .truncatedFrame
        }
        return false
    }
}
}
#endif
