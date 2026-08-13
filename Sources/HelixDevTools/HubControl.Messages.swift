#if os(macOS) && canImport(CryptoKit)
import CryptoKit
import Foundation
import HelixCore
import HelixDevProtocol

/// Owner-local control plane used by Xcode build phases and the thin Hub UI.
public enum HubControl {}

extension HubControl {
/// Private rendezvous data published by the running Helix service.
public struct Rendezvous: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2

    public var schemaVersion: UInt16
    public var processIdentifier: Int32
    public var port: UInt16
    public var spkiSHA256: Core.Digest
    public var controlSecret: Data
    public var toolExecutablePath: String
    public var startedAt: Date

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        processIdentifier: Int32,
        port: UInt16,
        spkiSHA256: Core.Digest,
        controlSecret: Data,
        toolExecutablePath: String,
        startedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.processIdentifier = processIdentifier
        self.port = port
        self.spkiSHA256 = spkiSHA256
        self.controlSecret = controlSecret
        self.toolExecutablePath = toolExecutablePath
        self.startedAt = startedAt
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              processIdentifier > 1,
              port > 0,
              controlSecret.count == 32,
              toolExecutablePath.utf8.count <= 4_096,
              toolExecutablePath.hasPrefix("/"),
              URL(fileURLWithPath: toolExecutablePath).standardizedFileURL.path
                == toolExecutablePath,
              !toolExecutablePath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              startedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw HubControl.Error.invalidRendezvous
        }
    }
}

/// The minimal set of mutations Xcode is allowed to request.
public enum Command: Codable, Hashable, Sendable {
    /// Reserve the code embedded into the App before its final link.
    case reserveAutomaticInvitation
    /// Persist an exact Build Context and bind its pre-link reservation.
    case registerAndActivate(
        invitationID: DevProtocol.InvitationID,
        context: DevSession.BuildContext
    )
    /// Read lifecycle and socket counts for the thin Hub UI.
    case serviceSnapshot
    /// List exact Build Contexts, optionally scoped to one project.
    case buildContexts(workspacePathHash: Core.Digest?)
    /// Create a short-lived code for explicit entry in an App debug page.
    case createManualInvitation(workspacePathHash: Core.Digest?)
    /// Invalidate a code displayed by the Hub UI.
    case cancelManualInvitation(invitationID: DevProtocol.InvitationID)
    /// List the active manual codes owned by the service.
    case manualInvitations

    fileprivate func validate() throws {
        switch self {
        case .reserveAutomaticInvitation, .serviceSnapshot,
             .buildContexts, .createManualInvitation, .manualInvitations:
            break
        case let .registerAndActivate(invitationID, context):
            guard invitationID.rawValue != Self.zeroUUID else {
                throw HubControl.Error.invalidMessage
            }
            try context.validate()
        case let .cancelManualInvitation(invitationID):
            guard invitationID.rawValue != Self.zeroUUID else {
                throw HubControl.Error.invalidMessage
            }
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Authenticated request sent only over pinned, loopback TLS.
public struct Request: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var command: HubControl.Command
    public var controlSecret: Data

    public init(
        requestID: UUID = UUID(),
        command: HubControl.Command,
        controlSecret: Data
    ) {
        self.requestID = requestID
        self.command = command
        self.controlSecret = controlSecret
    }

    public func validate() throws {
        guard requestID != Self.zeroUUID, controlSecret.count == 32 else {
            throw HubControl.Error.invalidMessage
        }
        try command.validate()
    }

    /// Constant-time credential comparison after structural validation.
    public func authenticate(with expectedSecret: Data) throws -> Bool {
        try validate()
        guard expectedSecret.count == 32 else {
            throw HubControl.Error.invalidCredential
        }
        return zip(controlSecret, expectedSecret).reduce(UInt8(0)) {
            $0 | ($1.0 ^ $1.1)
        } == 0
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Successful result returned to one matching request.
public enum Success: Codable, Hashable, Sendable {
    case automaticInvitationReserved(Pairing.Reservation)
    case automaticInvitationActivated(Pairing.Invitation)
    case serviceSnapshot(DevSession.ServiceSnapshot)
    case buildContexts([DevSession.BuildContext])
    case manualInvitationCreated(DevSession.ManualInvitation)
    case manualInvitationCancelled(DevProtocol.InvitationID)
    case manualInvitations([DevSession.ManualInvitation])

    fileprivate func validate() throws {
        switch self {
        case let .automaticInvitationReserved(reservation):
            try reservation.validate()
            guard reservation.kind == .automaticXcode else {
                throw HubControl.Error.invalidMessage
            }
        case let .automaticInvitationActivated(invitation):
            try invitation.validate()
            guard invitation.kind == .automaticXcode else {
                throw HubControl.Error.invalidMessage
            }
        case let .serviceSnapshot(snapshot):
            guard snapshot.openConnectionCount >= 0,
                  snapshot.pendingPairingCount >= 0,
                  snapshot.pendingPairingCount <= snapshot.openConnectionCount,
                  (snapshot.state == .running) == (snapshot.endpoint != nil)
            else { throw HubControl.Error.invalidMessage }
        case let .buildContexts(contexts):
            guard contexts.count <= 4_096,
                  Set(contexts.map(\.shellIdentity.shellID)).count == contexts.count
            else { throw HubControl.Error.invalidMessage }
            try contexts.forEach { try $0.validate() }
        case let .manualInvitationCreated(invitation):
            try invitation.validate()
        case let .manualInvitationCancelled(invitationID):
            guard invitationID.rawValue != Self.zeroUUID else {
                throw HubControl.Error.invalidMessage
            }
        case let .manualInvitations(invitations):
            guard invitations.count <= 4_096,
                  Set(invitations.map(\.reservation.invitationID)).count
                    == invitations.count,
                  Set(invitations.map(\.code)).count == invitations.count
            else { throw HubControl.Error.invalidMessage }
            try invitations.forEach { try $0.validate() }
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Bounded failure safe to display in Xcode.
public struct Failure: Codable, Hashable, Sendable {
    public var code: String
    public var detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }

    fileprivate func validate() throws {
        guard Self.isSafe(code, maximumBytes: 64),
              Self.isSafe(detail, maximumBytes: 4_096)
        else {
            throw HubControl.Error.invalidMessage
        }
    }

    private static func isSafe(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

/// Correlated response for a single control request.
public enum Response: Codable, Hashable, Sendable {
    case success(requestID: UUID, value: HubControl.Success)
    case failure(requestID: UUID, failure: HubControl.Failure)

    public var requestID: UUID {
        switch self {
        case let .success(requestID, _), let .failure(requestID, _):
            requestID
        }
    }

    public func validate() throws {
        guard requestID != Self.zeroUUID else {
            throw HubControl.Error.invalidMessage
        }
        switch self {
        case let .success(_, value):
            try value.validate()
        case let .failure(_, failure):
            try failure.validate()
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidRendezvous
    case invalidMessage
    case invalidCredential
    case nonCanonicalMessage
    case serviceUnavailable
    case serviceAlreadyRunning
    case responseMismatch
    case requestFailed(code: String, detail: String)
    case storageFailure(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "Helix local control configuration is invalid"
        case .invalidRendezvous:
            "Helix local control rendezvous is invalid"
        case .invalidMessage:
            "Helix local control message is invalid"
        case .invalidCredential:
            "Helix local control credential is invalid"
        case .nonCanonicalMessage:
            "Helix local control message is noncanonical"
        case .serviceUnavailable:
            "Helix is not running; open the Helix app and try again"
        case .serviceAlreadyRunning:
            "another Helix service already owns the local control rendezvous"
        case .responseMismatch:
            "Helix local control response does not match its request"
        case let .requestFailed(code, detail):
            "\(code): \(detail)"
        case let .storageFailure(detail):
            "Helix local control storage failed: \(detail)"
        }
    }
}
}
#endif
