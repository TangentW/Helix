import CryptoKit
import Foundation
import HelixCore

extension PatchPackage {
public enum Backend: String, Codable, Hashable, Sendable {
    case hlbc
    case controlledNative
}

public enum Platform: String, Codable, Hashable, Sendable {
    case iOS
    case iOSSimulator
}

public struct Target: Codable, Hashable, Sendable {
    public var bundleID: String
    public var marketingVersion: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var machOUUID: UUID
    public var shellInterfaceHash: Core.Digest
    public var architecture: String
    public var platform: PatchPackage.Platform
    public var minimumOSVersion: Core.SemanticVersion
    public var maximumTestedOSVersion: Core.SemanticVersion
    public var compatibility: Core.Compatibility

    public init(
        bundleID: String,
        marketingVersion: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        machOUUID: UUID,
        shellInterfaceHash: Core.Digest,
        architecture: String,
        platform: PatchPackage.Platform,
        minimumOSVersion: Core.SemanticVersion,
        maximumTestedOSVersion: Core.SemanticVersion,
        compatibility: Core.Compatibility
    ) {
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.machOUUID = machOUUID
        self.shellInterfaceHash = shellInterfaceHash
        self.architecture = architecture
        self.platform = platform
        self.minimumOSVersion = minimumOSVersion
        self.maximumTestedOSVersion = maximumTestedOSVersion
        self.compatibility = compatibility
    }
}

public struct PayloadDescriptor: Codable, Hashable, Sendable {
    public var backend: PatchPackage.Backend
    public var targetIndex: UInt32
    public var path: String
    public var byteLength: UInt64
    public var sha256: Core.Digest
    public var changedFunctionKeys: [Core.FunctionKey]
    public var entryIndices: [Core.EntryIndex]
    public var capabilities: Set<Core.Capability>
    public var quotas: Core.ResourceLimits

    public init(
        backend: PatchPackage.Backend,
        targetIndex: UInt32,
        path: String,
        byteLength: UInt64,
        sha256: Core.Digest,
        changedFunctionKeys: [Core.FunctionKey],
        entryIndices: [Core.EntryIndex],
        capabilities: Set<Core.Capability>,
        quotas: Core.ResourceLimits
    ) {
        self.backend = backend
        self.targetIndex = targetIndex
        self.path = path
        self.byteLength = byteLength
        self.sha256 = sha256
        self.changedFunctionKeys = changedFunctionKeys
        self.entryIndices = entryIndices
        self.capabilities = capabilities
        self.quotas = quotas
    }
}

public struct Rollout: Codable, Hashable, Sendable {
    public var cohortSalt: Data
    public var percentageBasisPoints: UInt16
    public var installationAllowlist: Set<String>
    public var installationDenylist: Set<String>

    public init(
        cohortSalt: Data,
        percentageBasisPoints: UInt16,
        installationAllowlist: Set<String> = [],
        installationDenylist: Set<String> = []
    ) {
        self.cohortSalt = cohortSalt
        self.percentageBasisPoints = percentageBasisPoints
        self.installationAllowlist = installationAllowlist
        self.installationDenylist = installationDenylist
    }

    public func includes(installationID: String, packageID: String) -> Bool {
        if installationDenylist.contains(installationID) { return false }
        if installationAllowlist.contains(installationID) { return true }
        guard percentageBasisPoints > 0 else { return false }
        guard percentageBasisPoints < 10_000 else { return true }

        let key = SymmetricKey(data: cohortSalt)
        let message = Data("\(installationID)\u{0}\(packageID)".utf8)
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let bucket = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 10_000
        return bucket < UInt64(percentageBasisPoints)
    }
}

public struct RollbackPlan: Codable, Hashable, Sendable {
    public var parentGenerationPackageHash: Core.Digest?
    public var mutuallyExclusivePackageIDs: Set<String>

    public init(
        parentGenerationPackageHash: Core.Digest? = nil,
        mutuallyExclusivePackageIDs: Set<String> = []
    ) {
        self.parentGenerationPackageHash = parentGenerationPackageHash
        self.mutuallyExclusivePackageIDs = mutuallyExclusivePackageIDs
    }
}

public struct Security: Codable, Hashable, Sendable {
    public var signerKeyID: String
    public var approvalPolicyID: String
    public var antiRollbackCounter: UInt64
    public var emergencyPolicyEpoch: UInt64

    public init(
        signerKeyID: String,
        approvalPolicyID: String,
        antiRollbackCounter: UInt64,
        emergencyPolicyEpoch: UInt64 = 0
    ) {
        self.signerKeyID = signerKeyID
        self.approvalPolicyID = approvalPolicyID
        self.antiRollbackCounter = antiRollbackCounter
        self.emergencyPolicyEpoch = emergencyPolicyEpoch
    }
}

public struct Manifest: Codable, Hashable, Sendable {
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
    public var targets: [PatchPackage.Target]
    public var payloads: [PatchPackage.PayloadDescriptor]
    public var rollout: PatchPackage.Rollout
    public var rollback: PatchPackage.RollbackPlan
    public var security: PatchPackage.Security

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
        targets: [PatchPackage.Target],
        payloads: [PatchPackage.PayloadDescriptor],
        rollout: PatchPackage.Rollout,
        rollback: PatchPackage.RollbackPlan = .init(),
        security: PatchPackage.Security
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
        self.targets = targets
        self.payloads = payloads
        self.rollout = rollout
        self.rollback = rollback
        self.security = security
    }

    public func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PatchPackage.Error.unsupportedSchema(schemaVersion)
        }
        guard packageID.hasPrefix("HLX-"), !campaignID.isEmpty, revision > 0 else {
            throw PatchPackage.Error.invalidManifest("package ID, campaign ID, or revision is invalid")
        }
        guard createdAtUnixSeconds <= notBeforeUnixSeconds,
              notBeforeUnixSeconds < expiresAtUnixSeconds
        else {
            throw PatchPackage.Error.invalidManifest("manifest time window is invalid")
        }
        guard !purpose.isEmpty, !incidentID.isEmpty, !ownerTeam.isEmpty,
              !distributionPolicyApprovalID.isEmpty,
              !security.signerKeyID.isEmpty,
              !security.approvalPolicyID.isEmpty,
              security.antiRollbackCounter > 0
        else {
            throw PatchPackage.Error.invalidManifest("required audit or security metadata is missing")
        }
        guard !targets.isEmpty, !payloads.isEmpty else {
            throw PatchPackage.Error.invalidManifest("at least one target and payload are required")
        }
        guard rollout.percentageBasisPoints <= 10_000, rollout.cohortSalt.count >= 16 else {
            throw PatchPackage.Error.invalidManifest("rollout percentage or cohort salt is invalid")
        }
        guard rollout.installationAllowlist.isDisjoint(with: rollout.installationDenylist),
              !rollout.installationAllowlist.contains(""),
              !rollout.installationDenylist.contains("")
        else {
            throw PatchPackage.Error.invalidManifest("rollout installation lists conflict or contain an empty ID")
        }

        var paths = Set<String>()
        for (index, target) in targets.enumerated() {
            guard !target.bundleID.isEmpty, !target.buildNumber.isEmpty, !target.architecture.isEmpty,
                  target.minimumOSVersion <= target.maximumTestedOSVersion
            else {
                throw PatchPackage.Error.invalidManifest("target \(index) is incomplete")
            }
        }
        for descriptor in payloads {
            guard Int(descriptor.targetIndex) < targets.count else {
                throw PatchPackage.Error.invalidManifest("payload \(descriptor.path) references a missing target")
            }
            guard Self.isSafeRelativePath(descriptor.path), paths.insert(descriptor.path).inserted else {
                throw PatchPackage.Error.unsafePayloadPath(descriptor.path)
            }
            guard descriptor.byteLength > 0 else {
                throw PatchPackage.Error.invalidManifest("payload \(descriptor.path) is empty")
            }
            if descriptor.backend == .hlbc, !descriptor.capabilities.contains(.baselineV1) {
                throw PatchPackage.Error.invalidManifest("HLBC payload \(descriptor.path) lacks baseline capability")
            }
            guard Set(descriptor.entryIndices).count == descriptor.entryIndices.count,
                  Set(descriptor.changedFunctionKeys).count == descriptor.changedFunctionKeys.count
            else {
                throw PatchPackage.Error.invalidManifest("payload \(descriptor.path) contains duplicate identities")
            }
            if descriptor.backend == .hlbc,
               descriptor.entryIndices.count != descriptor.changedFunctionKeys.count {
                throw PatchPackage.Error.invalidManifest(
                    "HLBC payload \(descriptor.path) has mismatched function and entry identities"
                )
            }
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 512,
              !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt16)
    case invalidManifest(String)
    case unsafePayloadPath(String)
    case malformedContainer(String)
    case limitExceeded(String)
    case duplicatePayload(String)
    case missingPayload(String)
    case payloadLengthMismatch(String)
    case payloadHashMismatch(String)
    case nonCanonicalManifest
    case nonCanonicalSignatureEnvelope
    case unsupportedSignatureAlgorithm(String)
    case unknownSigningRoot(String)
    case invalidSigningCertificate(String)
    case unknownRevocationAuthority(String)
    case invalidRevocationSnapshot(String)
    case revocationEpochRollback(highestSeen: UInt64, received: UInt64)
    case signingKeyRevoked(String)
    case packageRevoked(Core.Digest)
    case packageLocallyBlocked(Core.Digest)
    case invalidPackageSignature
    case signerScopeDenied(String)
    case targetMismatch
    case notYetValid
    case expired
    case distributionPolicyDenied(Core.DistributionPolicy)
    case distributionApprovalMissing(String)
    case rolloutExcluded
    case rollbackRevision(highestSeen: UInt64, received: UInt64)
    case emergencyPolicyRollback(highestSeen: UInt64, received: UInt64)
    case noPayloadForTarget
    case activationPersistence(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(value): "unsupported patch schema \(value)"
        case let .invalidManifest(reason): "invalid patch manifest: \(reason)"
        case let .unsafePayloadPath(path): "unsafe or duplicate payload path \(path)"
        case let .malformedContainer(reason): "malformed .hlxp container: \(reason)"
        case let .limitExceeded(reason): ".hlxp limit exceeded: \(reason)"
        case let .duplicatePayload(path): "duplicate payload \(path)"
        case let .missingPayload(path): "missing payload \(path)"
        case let .payloadLengthMismatch(path): "payload length mismatch for \(path)"
        case let .payloadHashMismatch(path): "payload hash mismatch for \(path)"
        case .nonCanonicalManifest: "manifest is not canonical JSON"
        case .nonCanonicalSignatureEnvelope: "signature envelope is not canonical JSON"
        case let .unsupportedSignatureAlgorithm(value): "unsupported signature algorithm \(value)"
        case let .unknownSigningRoot(key): "unknown signing root \(key)"
        case let .invalidSigningCertificate(reason): "invalid signing certificate: \(reason)"
        case let .unknownRevocationAuthority(key): "unknown revocation authority \(key)"
        case let .invalidRevocationSnapshot(reason): "invalid revocation snapshot: \(reason)"
        case let .revocationEpochRollback(highest, received):
            "revocation epoch rollback: highest \(highest), received \(received)"
        case let .signingKeyRevoked(key): "signing key \(key) is revoked"
        case let .packageRevoked(hash): "package \(hash) is revoked"
        case let .packageLocallyBlocked(hash): "package \(hash) is locally blocked"
        case .invalidPackageSignature: "invalid package signature"
        case let .signerScopeDenied(reason): "signer scope denied: \(reason)"
        case .targetMismatch: "package has no target for this executable"
        case .notYetValid: "patch is not valid yet"
        case .expired: "patch has expired"
        case let .distributionPolicyDenied(policy): "distribution policy \(policy.rawValue) is denied"
        case let .distributionApprovalMissing(id): "distribution approval \(id) is unavailable"
        case .rolloutExcluded: "installation is outside the rollout cohort"
        case let .rollbackRevision(highest, received): "revision rollback: highest \(highest), received \(received)"
        case let .emergencyPolicyRollback(highest, received): "policy epoch rollback: highest \(highest), received \(received)"
        case .noPayloadForTarget: "package has no payload for the selected target"
        case let .activationPersistence(reason): "activation persistence failed: \(reason)"
        }
    }
}
}

extension PatchPackage.PayloadDescriptor {
    private enum CodingKeys: String, CodingKey {
        case backend, targetIndex, path, byteLength, sha256
        case changedFunctionKeys, entryIndices, capabilities, quotas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decode(PatchPackage.Backend.self, forKey: .backend)
        targetIndex = try container.decode(UInt32.self, forKey: .targetIndex)
        path = try container.decode(String.self, forKey: .path)
        byteLength = try container.decode(UInt64.self, forKey: .byteLength)
        sha256 = try container.decode(Core.Digest.self, forKey: .sha256)
        changedFunctionKeys = try container.decode([Core.FunctionKey].self, forKey: .changedFunctionKeys)
        entryIndices = try container.decode([Core.EntryIndex].self, forKey: .entryIndices)
        let decodedCapabilities = try container.decode([Core.Capability].self, forKey: .capabilities)
        guard Set(decodedCapabilities).count == decodedCapabilities.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilities,
                in: container,
                debugDescription: "duplicate capability"
            )
        }
        capabilities = Set(decodedCapabilities)
        quotas = try container.decode(Core.ResourceLimits.self, forKey: .quotas)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(targetIndex, forKey: .targetIndex)
        try container.encode(path, forKey: .path)
        try container.encode(byteLength, forKey: .byteLength)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(changedFunctionKeys.sorted { $0.description < $1.description }, forKey: .changedFunctionKeys)
        try container.encode(entryIndices.sorted(), forKey: .entryIndices)
        try container.encode(capabilities.sorted(), forKey: .capabilities)
        try container.encode(quotas, forKey: .quotas)
    }
}

extension PatchPackage.Rollout {
    private enum CodingKeys: String, CodingKey {
        case cohortSalt, percentageBasisPoints, installationAllowlist, installationDenylist
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cohortSalt = try container.decode(Data.self, forKey: .cohortSalt)
        percentageBasisPoints = try container.decode(UInt16.self, forKey: .percentageBasisPoints)
        let allowlist = try container.decode([String].self, forKey: .installationAllowlist)
        let denylist = try container.decode([String].self, forKey: .installationDenylist)
        guard Set(allowlist).count == allowlist.count, Set(denylist).count == denylist.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .installationAllowlist,
                in: container,
                debugDescription: "duplicate rollout installation ID"
            )
        }
        installationAllowlist = Set(allowlist)
        installationDenylist = Set(denylist)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cohortSalt, forKey: .cohortSalt)
        try container.encode(percentageBasisPoints, forKey: .percentageBasisPoints)
        try container.encode(installationAllowlist.sorted(), forKey: .installationAllowlist)
        try container.encode(installationDenylist.sorted(), forKey: .installationDenylist)
    }
}

extension PatchPackage.RollbackPlan {
    private enum CodingKeys: String, CodingKey {
        case parentGenerationPackageHash, mutuallyExclusivePackageIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentGenerationPackageHash = try container.decodeIfPresent(
            Core.Digest.self,
            forKey: .parentGenerationPackageHash
        )
        let packageIDs = try container.decode([String].self, forKey: .mutuallyExclusivePackageIDs)
        guard Set(packageIDs).count == packageIDs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .mutuallyExclusivePackageIDs,
                in: container,
                debugDescription: "duplicate mutually exclusive package ID"
            )
        }
        mutuallyExclusivePackageIDs = Set(packageIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(parentGenerationPackageHash, forKey: .parentGenerationPackageHash)
        try container.encode(mutuallyExclusivePackageIDs.sorted(), forKey: .mutuallyExclusivePackageIDs)
    }
}
