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
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var processIdentifier: Int32
    public var port: UInt16
    public var spkiSHA256: Core.Digest
    public var controlSecret: Data
    public var startedAt: Date

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        processIdentifier: Int32,
        port: UInt16,
        spkiSHA256: Core.Digest,
        controlSecret: Data,
        startedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.processIdentifier = processIdentifier
        self.port = port
        self.spkiSHA256 = spkiSHA256
        self.controlSecret = controlSecret
        self.startedAt = startedAt
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              processIdentifier > 1,
              port > 0,
              controlSecret.count == 32,
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

    fileprivate func validate() throws {
        switch self {
        case .reserveAutomaticInvitation:
            break
        case let .registerAndActivate(invitationID, context):
            guard invitationID.rawValue != Self.zeroUUID else {
                throw HubControl.Error.invalidMessage
            }
            try context.validate()
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
        }
    }
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
