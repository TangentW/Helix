import Foundation
import HelixCore
import HelixDevProtocol

/// Secure discovery and transport configuration for development sessions.
public enum DevConnection {}

extension DevConnection {
/// How the App locates its paired Mac daemon.
public enum Endpoint: Hashable, Sendable {
    /// Connects to an explicit host and TCP port.
    case direct(host: String, port: UInt16)
    /// Discovers `_helix-live._tcp` and selects the named Bonjour service.
    case bonjour(serviceName: String)
}

/// Launch-only credentials and endpoint information for one development session.
///
/// Normal applications receive these values from the Helix launch command and
/// call ``load(environment:)`` indirectly through `DevRuntime.ApplicationSession`.
/// The textual descriptions deliberately redact ``sessionSecret``.
public struct Configuration: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Wire protocol version expected by both peers.
    public var protocolVersion: UInt16
    /// Ephemeral identifier shared by the daemon and this App launch.
    public var sessionID: UUID
    /// Direct or Bonjour endpoint selection.
    public var endpoint: DevConnection.Endpoint
    /// SHA-256 pin of the daemon certificate's Subject Public Key Info.
    public var expectedSPKIHash: Core.Digest
    /// 32-byte secret used for handshake proof and authenticated framing.
    ///
    /// Treat this value as sensitive launch credential material. Do not persist
    /// it, log it, or include it in crash diagnostics.
    public var sessionSecret: Data

    /// Creates and validates an explicit connection configuration.
    public init(
        protocolVersion: UInt16,
        sessionID: UUID,
        endpoint: DevConnection.Endpoint,
        expectedSPKIHash: Core.Digest,
        sessionSecret: Data
    ) throws {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.expectedSPKIHash = expectedSPKIHash
        self.sessionSecret = sessionSecret
        try validate()
    }

    /// Validates protocol, credential length, and endpoint bounds.
    public func validate() throws {
        guard protocolVersion == DevProtocol.SessionIdentity.currentProtocolVersion else {
            throw DevConnection.Error.protocolVersionMismatch
        }
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard sessionSecret.count == 32 else {
            throw DevConnection.Error.invalidEnvironment
        }
        switch endpoint {
        case let .direct(host, port):
            guard !host.isEmpty, host.utf8.count <= 255,
                  !host.unicodeScalars.contains(where: { $0.value == 0 }),
                  port > 0
            else { throw DevConnection.Error.invalidEnvironment }
        case let .bonjour(serviceName):
            guard !serviceName.isEmpty, serviceName.utf8.count <= 63,
                  !serviceName.unicodeScalars.contains(where: { $0.value == 0 })
            else { throw DevConnection.Error.invalidEnvironment }
        }
    }

    /// Loads connection values injected into the App's launch environment.
    ///
    /// Returns `nil` only when no Helix launch variables are present. A partial
    /// environment throws so a misconfigured development build never fails open.
    /// Tests can supply an isolated dictionary instead of reading process state:
    ///
    /// ```swift
    /// let configuration = try DevConnection.Configuration.load(
    ///     environment: testLaunchEnvironment
    /// )
    /// ```
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self? {
        let names = [
            "HLX_DEV_PROTOCOL_VERSION", "HLX_DEV_SESSION_ID",
            "HLX_DEV_SERVICE_NAME", "HLX_DEV_SPKI_SHA256",
            "HLX_DEV_SESSION_SECRET", "HLX_DEV_HOST", "HLX_DEV_PORT",
        ]
        guard names.contains(where: { environment[$0] != nil }) else { return nil }
        guard let versionText = environment["HLX_DEV_PROTOCOL_VERSION"],
              let version = UInt16(versionText),
              let sessionText = environment["HLX_DEV_SESSION_ID"],
              let sessionID = UUID(uuidString: sessionText),
              let serviceName = environment["HLX_DEV_SERVICE_NAME"],
              let pinText = environment["HLX_DEV_SPKI_SHA256"],
              let secretText = environment["HLX_DEV_SESSION_SECRET"]
        else {
            throw DevConnection.Error.invalidEnvironment
        }
        let pin: Core.Digest
        do {
            pin = try .init(hex: pinText)
        } catch {
            throw DevConnection.Error.invalidEnvironment
        }
        let secret = try decodeHex(secretText)
        let host = environment["HLX_DEV_HOST"]
        let portText = environment["HLX_DEV_PORT"]
        let endpoint: DevConnection.Endpoint
        switch (host, portText) {
        case let (.some(host), .some(portText)):
            guard let port = UInt16(portText), port > 0 else {
                throw DevConnection.Error.invalidEnvironment
            }
            endpoint = .direct(host: host, port: port)
        case (nil, nil):
            endpoint = .bonjour(serviceName: serviceName)
        default:
            throw DevConnection.Error.invalidEnvironment
        }
        return try .init(
            protocolVersion: version,
            sessionID: sessionID,
            endpoint: endpoint,
            expectedSPKIHash: pin,
            sessionSecret: secret
        )
    }

    private static func decodeHex(_ value: String) throws -> Data {
        guard value.utf8.count == 64 else {
            throw DevConnection.Error.invalidEnvironment
        }
        var data = Data()
        data.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw DevConnection.Error.invalidEnvironment
            }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Redacted diagnostic summary that never contains the session secret.
    public var description: String {
        "DevConnection.Configuration(sessionID: \(sessionID), endpoint: \(endpoint), sessionSecret: <redacted>)"
    }

    /// Redacted debug summary that never contains the session secret.
    public var debugDescription: String { description }
}

/// Connection setup and lifecycle failures surfaced to development integrations.
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// Required launch values, endpoint fields, secrets, or limits are malformed.
    case invalidEnvironment
    /// The App and daemon use different development protocol versions.
    case protocolVersionMismatch
    /// Connection credentials do not describe the App session identity.
    case sessionIdentityMismatch
    /// The named Bonjour service was not found before the configured deadline.
    case discoveryTimedOut
    /// A discovered or direct transport did not become ready before its deadline.
    case connectionTimedOut
    /// `run()` was called while the same client was already running.
    case alreadyRunning
    /// The client or discovery operation was intentionally stopped.
    case stopped

    /// Human-readable connection failure detail.
    public var description: String {
        switch self {
        case .invalidEnvironment: "Helix Dev launch environment is incomplete or malformed"
        case .protocolVersionMismatch: "Helix Dev Protocol versions do not match"
        case .sessionIdentityMismatch: "Helix launch credentials belong to another Dev Shell"
        case .discoveryTimedOut: "the matching Helix Bonjour service was not discovered in time"
        case .connectionTimedOut: "the Helix Dev TLS connection did not become ready in time"
        case .alreadyRunning: "the Helix Dev connection client is already running"
        case .stopped: "the Helix Dev connection client was stopped"
        }
    }
}
}
