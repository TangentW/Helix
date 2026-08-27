import CryptoKit
import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension PatchPackage {
/// Payload execution format stored in a patch package.
public enum Backend: String, Codable, Hashable, Sendable {
    /// Verified Helix bytecode interpreted by the production Runtime.
    case hlbc
    /// A controlled native image restricted to separately qualified channels.
    case controlledNative
}

/// Apple platform targeted by one manifest entry.
public enum Platform: String, Codable, Hashable, Sendable {
    /// A physical iOS device build.
    case iOS
    /// An iOS Simulator build.
    case iOSSimulator
}

/// Exact Shell build that may consume a package payload.
public struct Target: Codable, Hashable, Sendable {
    /// Target App bundle identifier.
    public var bundleID: String
    /// Target App marketing version.
    public var marketingVersion: String
    /// Target App build number.
    public var buildNumber: String
    /// Stable namespace of the target Shell.
    public var shellNamespaceID: Core.ShellNamespaceID
    /// Mach-O UUID of the target App executable.
    public var machOUUID: UUID
    /// Exact callable interface hash of the target Shell.
    public var shellInterfaceHash: Core.Digest
    /// Canonical native capability table embedded in the target App.
    public var nativeCapabilityManifestHash: Core.Digest
    /// Target architecture.
    public var architecture: String
    /// Target Apple platform.
    public var platform: PatchPackage.Platform
    /// Oldest OS version accepted by this target.
    public var minimumOSVersion: Core.SemanticVersion
    /// Newest OS version qualified when the package was built.
    public var maximumTestedOSVersion: Core.SemanticVersion
    /// Runtime, bytecode, archive, and compiler compatibility facts.
    public var compatibility: Core.Compatibility

    /// Creates an exact package target.
    public init(
        bundleID: String,
        marketingVersion: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        machOUUID: UUID,
        shellInterfaceHash: Core.Digest,
        nativeCapabilityManifestHash: Core.Digest,
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
        self.nativeCapabilityManifestHash = nativeCapabilityManifestHash
        self.architecture = architecture
        self.platform = platform
        self.minimumOSVersion = minimumOSVersion
        self.maximumTestedOSVersion = maximumTestedOSVersion
        self.compatibility = compatibility
    }
}

/// Signed metadata for one package payload file.
public struct PayloadDescriptor: Codable, Hashable, Sendable {
    /// Execution backend required by the payload.
    public var backend: PatchPackage.Backend
    /// Index into ``Manifest/targets``.
    public var targetIndex: UInt32
    /// Safe relative path of the payload inside the container.
    public var path: String
    /// Exact encoded payload length.
    public var byteLength: UInt64
    /// SHA-256 of payload bytes.
    public var sha256: Core.Digest
    /// Stable functions changed by this payload.
    public var changedFunctionKeys: [Core.FunctionKey]
    /// Dense Shell entries routed by this payload.
    public var entryIndices: [Core.EntryIndex]
    /// Runtime capabilities required by this payload.
    public var capabilities: Set<Core.Capability>
    /// Execution and allocation limits requested by this payload.
    public var quotas: Core.ResourceLimits

    /// Creates a signed payload descriptor.
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

/// Deterministic installation-level rollout rules for a package.
public struct Rollout: Codable, Hashable, Sendable {
    /// Campaign-specific salt used for cohort hashing.
    public var cohortSalt: Data
    /// Percentage in basis points, from `0` through `10_000`.
    public var percentageBasisPoints: UInt16
    /// Installations included regardless of percentage.
    public var installationAllowlist: Set<String>
    /// Installations excluded regardless of percentage or allowlist.
    public var installationDenylist: Set<String>

    /// Creates rollout rules.
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

    /// Returns whether an installation belongs to this package's rollout cohort.
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

/// Manifest-declared lineage and package conflicts used during rollback checks.
public struct RollbackPlan: Codable, Hashable, Sendable {
    /// Expected hash of the parent generation package, or `nil` for App original.
    public var parentGenerationPackageHash: Core.Digest?
    /// Package IDs that must not coexist with this package.
    public var mutuallyExclusivePackageIDs: Set<String>

    /// Creates a rollback plan.
    public init(
        parentGenerationPackageHash: Core.Digest? = nil,
        mutuallyExclusivePackageIDs: Set<String> = []
    ) {
        self.parentGenerationPackageHash = parentGenerationPackageHash
        self.mutuallyExclusivePackageIDs = mutuallyExclusivePackageIDs
    }
}

/// Security counters and approval identities covered by the package signature.
public struct Security: Codable, Hashable, Sendable {
    /// Leaf key expected in the signature envelope.
    public var signerKeyID: String
    /// Incident or release approval policy authorizing this package.
    public var approvalPolicyID: String
    /// Monotonic counter scoped to the signer or campaign.
    public var antiRollbackCounter: UInt64
    /// Monotonic epoch for emergency policy changes.
    public var emergencyPolicyEpoch: UInt64

    /// Creates package security metadata.
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

/// Canonical, signed policy and content index for one `.hlxp` package.
///
/// Release tooling creates manifests; shipping applications validate them and
/// should not mutate decoded values before verification.
public struct Manifest: Codable, Hashable, Sendable {
    /// Manifest schema emitted by this framework version.
    public static let currentSchemaVersion: UInt16 = 1

    /// Encoded manifest schema.
    public var schemaVersion: UInt16
    /// Globally unique package identifier.
    public var packageID: String
    /// Stable incident or rollout campaign identifier.
    public var campaignID: String
    /// Monotonic revision within the campaign.
    public var revision: UInt64
    /// Package creation time as Unix seconds.
    public var createdAtUnixSeconds: Int64
    /// Earliest accepted activation time as Unix seconds.
    public var notBeforeUnixSeconds: Int64
    /// Latest accepted activation time as Unix seconds.
    public var expiresAtUnixSeconds: Int64
    /// Human-readable reason for the patch.
    public var purpose: String
    /// Incident or change-management identifier.
    public var incidentID: String
    /// Team accountable for this package.
    public var ownerTeam: String
    /// Distribution channel under which the package is authorized.
    public var distributionPolicy: Core.DistributionPolicy
    /// Product-owned approval identifier for the distribution policy.
    public var distributionPolicyApprovalID: String
    /// Exact Shell builds that may consume payloads.
    public var targets: [PatchPackage.Target]
    /// Signed payload inventory.
    public var payloads: [PatchPackage.PayloadDescriptor]
    /// Deterministic installation rollout rules.
    public var rollout: PatchPackage.Rollout
    /// Parent lineage and conflict rules.
    public var rollback: PatchPackage.RollbackPlan
    /// Signer identity and anti-rollback counters.
    public var security: PatchPackage.Security

    /// Creates a manifest value. Call ``validateStructure()`` before signing.
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

    /// Validates canonical ordering, uniqueness, bounds, paths, and policy fields.
    ///
    /// Cryptographic trust and process target matching are performed later by
    /// ``PatchPackage/Verifier``.
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

/// Fail-closed package decoding, trust, policy, and activation errors.
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// The manifest or container schema is not supported by this Runtime.
    case unsupportedSchema(UInt16)
    /// A manifest invariant failed.
    case invalidManifest(String)
    /// A payload path is absolute, traversing, malformed, or duplicated.
    case unsafePayloadPath(String)
    /// The binary container framing is malformed.
    case malformedContainer(String)
    /// A configured decode or allocation ceiling was exceeded.
    case limitExceeded(String)
    /// The container encodes the same payload path more than once.
    case duplicatePayload(String)
    /// A manifest descriptor has no corresponding payload bytes.
    case missingPayload(String)
    /// Payload bytes do not have the signed length.
    case payloadLengthMismatch(String)
    /// Payload bytes do not have the signed SHA-256.
    case payloadHashMismatch(String)
    /// Manifest JSON is valid but not canonically encoded.
    case nonCanonicalManifest
    /// Signature envelope JSON is valid but not canonically encoded.
    case nonCanonicalSignatureEnvelope
    /// The declared signature algorithm is unknown or disabled.
    case unsupportedSignatureAlgorithm(String)
    /// A leaf certificate names a root absent from the trust store.
    case unknownSigningRoot(String)
    /// A signing certificate is malformed, expired, or has an invalid signature.
    case invalidSigningCertificate(String)
    /// A snapshot names an authority absent from the trust store.
    case unknownRevocationAuthority(String)
    /// A revocation snapshot is malformed, expired, or has an invalid signature.
    case invalidRevocationSnapshot(String)
    /// A revocation snapshot attempts to move to an older epoch.
    case revocationEpochRollback(highestSeen: UInt64, received: UInt64)
    /// The package was signed by a revoked root or leaf key.
    case signingKeyRevoked(String)
    /// The complete package hash appears in trusted revocation state.
    case packageRevoked(Core.Digest)
    /// The package hash was blocked locally after an activation failure.
    case packageLocallyBlocked(Core.Digest)
    /// The leaf signature does not match canonical package material.
    case invalidPackageSignature
    /// The certificate scope does not authorize this package.
    case signerScopeDenied(String)
    /// No manifest target exactly matches the running App and Shell.
    case targetMismatch
    /// The package validity window has not opened.
    case notYetValid
    /// The package validity window has closed.
    case expired
    /// The application policy rejects the package's distribution channel.
    case distributionPolicyDenied(Core.DistributionPolicy)
    /// The application does not recognize the declared approval policy.
    case distributionApprovalMissing(String)
    /// The current installation is outside the rollout cohort.
    case rolloutExcluded
    /// The campaign revision would move backwards or fork an accepted revision.
    case rollbackRevision(highestSeen: UInt64, received: UInt64)
    /// The emergency policy epoch would move backwards.
    case emergencyPolicyRollback(highestSeen: UInt64, received: UInt64)
    /// The selected target has no applicable payload.
    case noPayloadForTarget
    /// Runtime activation succeeded or failed but durable state could not commit.
    case activationPersistence(String)

    /// A diagnostic suitable for logs and package rejection telemetry.
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

    /// Decodes a payload descriptor while rejecting duplicate set members.
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

    /// Encodes function, entry, and capability collections deterministically.
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

    /// Decodes rollout membership while rejecting duplicate installation IDs.
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

    /// Encodes rollout allowlists and denylists in deterministic order.
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

    /// Decodes rollback constraints while rejecting duplicate package IDs.
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

    /// Encodes mutually exclusive package IDs in deterministic order.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(parentGenerationPackageHash, forKey: .parentGenerationPackageHash)
        try container.encode(mutuallyExclusivePackageIDs.sorted(), forKey: .mutuallyExclusivePackageIDs)
    }
}
