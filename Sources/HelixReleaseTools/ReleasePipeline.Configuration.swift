import Foundation
import HelixCore
import HelixPatch

public enum ReleasePipeline {}

extension ReleasePipeline {
public struct TargetConfiguration: Codable, Hashable, Sendable {
    public var marketingVersion: String
    public var machOUUID: UUID
    public var architecture: String
    public var platform: PatchPackage.Platform
    public var maximumTestedOSVersion: Core.SemanticVersion

    public init(
        marketingVersion: String,
        machOUUID: UUID,
        architecture: String,
        platform: PatchPackage.Platform,
        maximumTestedOSVersion: Core.SemanticVersion
    ) {
        self.marketingVersion = marketingVersion
        self.machOUUID = machOUUID
        self.architecture = architecture
        self.platform = platform
        self.maximumTestedOSVersion = maximumTestedOSVersion
    }
}

public struct Configuration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var packageID: String
    public var campaignID: String
    public var revision: UInt64
    public var createdAtUnixSeconds: Int64
    public var notBeforeUnixSeconds: Int64
    public var expiresAtUnixSeconds: Int64
    public var purpose: String
    public var incidentID: String
    public var ownerTeam: String
    public var distributionPolicy: Core.DistributionPolicy
    public var distributionPolicyApprovalID: String
    public var target: ReleasePipeline.TargetConfiguration
    public var payloadPath: String
    public var rollout: PatchPackage.Rollout
    public var rollback: PatchPackage.RollbackPlan
    public var security: PatchPackage.Security
    public var requestedResources: Core.ResourceLimits

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        packageID: String,
        campaignID: String,
        revision: UInt64,
        createdAtUnixSeconds: Int64,
        notBeforeUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64,
        purpose: String,
        incidentID: String,
        ownerTeam: String,
        distributionPolicy: Core.DistributionPolicy,
        distributionPolicyApprovalID: String,
        target: ReleasePipeline.TargetConfiguration,
        payloadPath: String = "payloads/patch.hlbc",
        rollout: PatchPackage.Rollout,
        rollback: PatchPackage.RollbackPlan = .init(),
        security: PatchPackage.Security,
        requestedResources: Core.ResourceLimits = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.campaignID = campaignID
        self.revision = revision
        self.createdAtUnixSeconds = createdAtUnixSeconds
        self.notBeforeUnixSeconds = notBeforeUnixSeconds
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
        self.purpose = purpose
        self.incidentID = incidentID
        self.ownerTeam = ownerTeam
        self.distributionPolicy = distributionPolicy
        self.distributionPolicyApprovalID = distributionPolicyApprovalID
        self.target = target
        self.payloadPath = payloadPath
        self.rollout = rollout
        self.rollback = rollback
        self.security = security
        self.requestedResources = requestedResources
    }
}

public struct SigningKeyDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var algorithm: String
    public var rawRepresentation: Data

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        algorithm: String = "ed25519",
        rawRepresentation: Data
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.rawRepresentation = rawRepresentation
    }

    public func privateKey() throws -> PatchPackage.PrivateKey {
        guard schemaVersion == Self.currentSchemaVersion, algorithm == "ed25519" else {
            throw ReleasePipeline.Error.invalidConfiguration("unsupported signing key document")
        }
        do {
            return try PatchPackage.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw ReleasePipeline.Error.invalidConfiguration("invalid Ed25519 private key")
        }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case appStoreDistributionBlocked
    case targetUUIDNotInArchive(UUID)
    case targetTripleMismatch(String)
    case signerKeyIDMismatch(expected: String, actual: String)
    case rootKeyIDMismatch(expected: String, actual: String)
    case selfVerificationFailed(String)

    public var description: String {
        switch self {
        case let .invalidConfiguration(reason): "invalid release configuration: \(reason)"
        case .appStoreDistributionBlocked:
            "App Store HLBC package construction is policy-blocked"
        case let .targetUUIDNotInArchive(uuid):
            "target Mach-O UUID \(uuid.uuidString) is absent from HLXI"
        case let .targetTripleMismatch(reason): "target does not match HLXI triple: \(reason)"
        case let .signerKeyIDMismatch(expected, actual):
            "configuration signer key ID \(expected) does not match certificate \(actual)"
        case let .rootKeyIDMismatch(expected, actual):
            "certificate issuer \(expected) does not match trusted root \(actual)"
        case let .selfVerificationFailed(reason):
            "built package failed release self-verification: \(reason)"
        }
    }
}
}
