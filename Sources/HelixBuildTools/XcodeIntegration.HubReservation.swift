import Foundation
import HelixCore
import HelixDevProtocol

extension XcodeIntegration {
/// Private handoff from the Build pre-action to the Run registration action.
public struct HubReservationDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let relativePath = "HubReservation.json"

    public var schemaVersion: UInt16
    public var reservation: Pairing.Reservation
    public var spkiSHA256: Core.Digest

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        reservation: Pairing.Reservation,
        spkiSHA256: Core.Digest
    ) throws {
        self.schemaVersion = schemaVersion
        self.reservation = reservation
        self.spkiSHA256 = spkiSHA256
        try validate()
    }

    public func validate() throws {
        try reservation.validate()
        guard schemaVersion == Self.currentSchemaVersion,
              reservation.kind == .automaticXcode
        else {
            throw XcodeIntegration.Error.invalidPlan
        }
    }
}
}
