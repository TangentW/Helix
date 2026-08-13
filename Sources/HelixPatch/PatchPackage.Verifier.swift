import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension PatchPackage {
/// Exact App and Shell identity used when selecting a package target.
///
/// ``PatchRuntime/ApplicationSession`` constructs this automatically. Custom
/// control planes may log it for diagnostics but must not replace measured
/// fields with server-provided values.
public struct TargetContext: Sendable, Hashable {
    /// Running App bundle identifier.
    public var bundleID: String
    /// Running App marketing version.
    public var marketingVersion: String
    /// Audited App build number.
    public var buildNumber: String
    /// Stable namespace of the audited Shell.
    public var shellNamespaceID: Core.ShellNamespaceID
    /// Mach-O UUID of the running App executable.
    public var machOUUID: UUID
    /// Exact callable interface hash of the linked Shell.
    public var shellInterfaceHash: Core.Digest
    /// Running process architecture.
    public var architecture: String
    /// Running Apple platform.
    public var platform: PatchPackage.Platform
    /// Current operating-system version.
    public var operatingSystemVersion: Core.SemanticVersion
    /// Runtime and bytecode compatibility requirements.
    public var compatibility: Core.Compatibility
    /// Stable installation identity used for deterministic rollout selection.
    public var installationID: String

    /// Creates an explicit target context.
    public init(
        bundleID: String,
        marketingVersion: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        machOUUID: UUID,
        shellInterfaceHash: Core.Digest,
        architecture: String,
        platform: PatchPackage.Platform,
        operatingSystemVersion: Core.SemanticVersion,
        compatibility: Core.Compatibility,
        installationID: String
    ) {
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.machOUUID = machOUUID
        self.shellInterfaceHash = shellInterfaceHash
        self.architecture = architecture
        self.platform = platform
        self.operatingSystemVersion = operatingSystemVersion
        self.compatibility = compatibility
        self.installationID = installationID
    }
}

/// Product-owned policy applied after cryptographic package verification.
///
/// A package must satisfy every field in addition to signature, target,
/// anti-rollback, and rollout checks.
///
/// ```swift
/// let policy = PatchPackage.AcceptancePolicy(
///     acceptedDistributionPolicies: [.internalHLBC],
///     approvedDistributionPolicyIDs: ["incident-response-v1"]
/// )
/// ```
public struct AcceptancePolicy: Sendable, Hashable {
    /// Distribution channels this App build is willing to accept.
    public var acceptedDistributionPolicies: Set<Core.DistributionPolicy>
    /// Approval policy identifiers recognized by the application.
    public var approvedDistributionPolicyIDs: Set<String>
    /// Whether the App explicitly enables an App Store HLBC production channel.
    public var productionChannelEnabled: Bool
    /// Whether OS versions above a manifest's tested maximum may proceed.
    public var allowOperatingSystemsNewerThanTested: Bool
    /// Allowed wall-clock skew around package validity boundaries.
    public var clockSkewAllowanceSeconds: Int64

    /// Creates an acceptance policy. Defaults remain conservative and do not
    /// enable a production channel.
    public init(
        acceptedDistributionPolicies: Set<Core.DistributionPolicy> = [.internalHLBC],
        approvedDistributionPolicyIDs: Set<String> = [],
        productionChannelEnabled: Bool = false,
        allowOperatingSystemsNewerThanTested: Bool = false,
        clockSkewAllowanceSeconds: Int64 = 300
    ) {
        self.acceptedDistributionPolicies = acceptedDistributionPolicies
        self.approvedDistributionPolicyIDs = approvedDistributionPolicyIDs
        self.productionChannelEnabled = productionChannelEnabled
        self.allowOperatingSystemsNewerThanTested = allowOperatingSystemsNewerThanTested
        self.clockSkewAllowanceSeconds = clockSkewAllowanceSeconds
    }
}

/// Persisted monotonic state that prevents installing older package revisions.
public struct AntiRollbackState: Codable, Hashable, Sendable {
    /// Campaign whose revisions this state tracks.
    public var campaignID: String
    /// Shell interface to which the state is bound.
    public var shellInterfaceHash: Core.Digest
    /// Highest accepted manifest revision.
    public var highestSeenRevision: UInt64
    /// Highest accepted signer anti-rollback counter.
    public var highestSeenCounter: UInt64
    /// Hash accepted at `highestSeenRevision`, if any.
    public var highestSeenPackageHash: Core.Digest?
    /// Highest accepted emergency policy epoch.
    public var emergencyPolicyEpoch: UInt64
    /// Package hashes blocked by durable revocation state.
    public var revokedPackageHashes: Set<Core.Digest>

    /// Creates anti-rollback state for one campaign and Shell.
    public init(
        campaignID: String,
        shellInterfaceHash: Core.Digest,
        highestSeenRevision: UInt64 = 0,
        highestSeenCounter: UInt64 = 0,
        highestSeenPackageHash: Core.Digest? = nil,
        emergencyPolicyEpoch: UInt64 = 0,
        revokedPackageHashes: Set<Core.Digest> = []
    ) {
        self.campaignID = campaignID
        self.shellInterfaceHash = shellInterfaceHash
        self.highestSeenRevision = highestSeenRevision
        self.highestSeenCounter = highestSeenCounter
        self.highestSeenPackageHash = highestSeenPackageHash
        self.emergencyPolicyEpoch = emergencyPolicyEpoch
        self.revokedPackageHashes = revokedPackageHashes
    }
}

/// A package that passed signature, policy, target, rollout, and revision checks.
public struct VerifiedPackage: Sendable {
    /// Decoded canonical package container.
    public var package: PatchPackage.Container
    /// Original encoded bytes whose digest was verified.
    public var encodedBytes: Data
    /// SHA-256 of ``encodedBytes``.
    public var packageHash: Core.Digest
    /// Index of the target selected for this process.
    public var selectedTargetIndex: UInt32
    /// Target selected for this process.
    public var selectedTarget: PatchPackage.Target
    /// Payload descriptors applicable to the selected target.
    public var selectedPayloads: [PatchPackage.PayloadDescriptor]

    /// Returns verified payload bytes for a selected descriptor.
    public func payload(for descriptor: PatchPackage.PayloadDescriptor) throws -> Data {
        guard let payload = package.payloads[descriptor.path] else {
            throw PatchPackage.Error.missingPayload(descriptor.path)
        }
        return payload
    }
}

/// Performs fail-closed verification of a complete `.hlxp` package.
///
/// Most applications use ``PatchRuntime/ApplicationSession/install(packageBytes:nowUnixSeconds:)``.
/// Use this type directly only when building a custom activation pipeline.
public struct Verifier: Sendable {
    /// Decode and allocation ceilings applied before trusting package metadata.
    public var decodingLimits: PatchPackage.DecodingLimits

    /// Creates a verifier with bounded container limits.
    public init(decodingLimits: PatchPackage.DecodingLimits = .init()) {
        self.decodingLimits = decodingLimits
    }

    /// Verifies a package without activating it.
    ///
    /// - Returns: A package narrowed to the target and payloads for this process.
    /// - Throws: ``PatchPackage/Error`` for any cryptographic, structural,
    ///   compatibility, rollout, time, or anti-rollback failure.
    public func verify(
        bytes: Data,
        trustStore: PatchPackage.TrustStore,
        targetContext: PatchPackage.TargetContext,
        acceptancePolicy: PatchPackage.AcceptancePolicy,
        antiRollbackState: PatchPackage.AntiRollbackState?,
        nowUnixSeconds: Int64
    ) throws -> PatchPackage.VerifiedPackage {
        if let antiRollbackState,
           !antiRollbackState.shellInterfaceHash.constantTimeEquals(
               targetContext.shellInterfaceHash
           ) {
            throw PatchPackage.Error.invalidManifest(
                "anti-rollback state Shell interface mismatch"
            )
        }
        let packageHash = Core.Digest.sha256(bytes)
        if trustStore.revokedPackageHashes.contains(packageHash)
            || antiRollbackState?.revokedPackageHashes.contains(packageHash) == true
        {
            throw PatchPackage.Error.packageRevoked(packageHash)
        }
        let package = try PatchPackage.Container.decode(bytes, limits: decodingLimits)
        let manifestBytes = try Core.CanonicalJSON.encode(package.manifest)
        let material = try PatchPackage.SignatureMaterial.make(
            manifestBytes: manifestBytes,
            payloads: package.payloads
        )
        try trustStore.verify(
            envelope: package.signatureEnvelope,
            material: material,
            manifest: package.manifest,
            packageHash: packageHash,
            nowUnixSeconds: nowUnixSeconds
        )

        try verifyTime(
            package.manifest,
            nowUnixSeconds: nowUnixSeconds,
            skew: acceptancePolicy.clockSkewAllowanceSeconds
        )
        try verifyDistribution(package.manifest, policy: acceptancePolicy)
        try verifyAntiRollback(
            package.manifest,
            packageHash: packageHash,
            state: antiRollbackState
        )

        guard let match = package.manifest.targets.enumerated().first(where: {
            targetMatches(
                $0.element,
                context: targetContext,
                allowNewerOS: acceptancePolicy.allowOperatingSystemsNewerThanTested
            )
        }) else {
            throw PatchPackage.Error.targetMismatch
        }
        guard match.offset <= Int(UInt32.max) else {
            throw PatchPackage.Error.invalidManifest("target index overflow")
        }
        // Target compatibility must be established even when rollout is paused.
        // Release self-verification relies on this ordering for zero-percent packages.
        guard package.manifest.rollout.includes(
            installationID: targetContext.installationID,
            packageID: package.manifest.packageID
        ) else {
            throw PatchPackage.Error.rolloutExcluded
        }
        let selectedIndex = UInt32(match.offset)
        let selectedPayloads = package.manifest.payloads.filter { $0.targetIndex == selectedIndex }
        guard !selectedPayloads.isEmpty else {
            throw PatchPackage.Error.noPayloadForTarget
        }
        if selectedPayloads.contains(where: { $0.backend == .controlledNative }),
           package.manifest.distributionPolicy != .controlledNative
        {
            throw PatchPackage.Error.distributionPolicyDenied(package.manifest.distributionPolicy)
        }
        return .init(
            package: package,
            encodedBytes: bytes,
            packageHash: packageHash,
            selectedTargetIndex: selectedIndex,
            selectedTarget: match.element,
            selectedPayloads: selectedPayloads
        )
    }

    private func verifyTime(
        _ manifest: PatchPackage.Manifest,
        nowUnixSeconds: Int64,
        skew: Int64
    ) throws {
        let nonnegativeSkew = max(0, skew)
        let latestAcceptedStart = nowUnixSeconds.addingReportingOverflow(nonnegativeSkew)
        guard !latestAcceptedStart.overflow,
              latestAcceptedStart.partialValue >= manifest.notBeforeUnixSeconds
        else {
            throw PatchPackage.Error.notYetValid
        }
        let earliestAcceptedEnd = nowUnixSeconds.subtractingReportingOverflow(nonnegativeSkew)
        guard !earliestAcceptedEnd.overflow,
              earliestAcceptedEnd.partialValue <= manifest.expiresAtUnixSeconds
        else {
            throw PatchPackage.Error.expired
        }
    }

    private func verifyDistribution(
        _ manifest: PatchPackage.Manifest,
        policy: PatchPackage.AcceptancePolicy
    ) throws {
        guard policy.acceptedDistributionPolicies.contains(manifest.distributionPolicy) else {
            throw PatchPackage.Error.distributionPolicyDenied(manifest.distributionPolicy)
        }
        guard policy.approvedDistributionPolicyIDs.contains(manifest.distributionPolicyApprovalID) else {
            throw PatchPackage.Error.distributionApprovalMissing(manifest.distributionPolicyApprovalID)
        }
        if manifest.distributionPolicy == .appStoreHLBC, !policy.productionChannelEnabled {
            throw PatchPackage.Error.distributionPolicyDenied(.appStoreHLBC)
        }
    }

    private func verifyAntiRollback(
        _ manifest: PatchPackage.Manifest,
        packageHash: Core.Digest,
        state: PatchPackage.AntiRollbackState?
    ) throws {
        guard let state else { return }
        guard state.campaignID == manifest.campaignID else {
            throw PatchPackage.Error.invalidManifest("anti-rollback state campaign mismatch")
        }
        if manifest.revision < state.highestSeenRevision
            || (manifest.revision == state.highestSeenRevision
                && state.highestSeenPackageHash != nil
                && state.highestSeenPackageHash != packageHash)
        {
            throw PatchPackage.Error.rollbackRevision(
                highestSeen: state.highestSeenRevision,
                received: manifest.revision
            )
        }
        if manifest.security.antiRollbackCounter < state.highestSeenCounter {
            throw PatchPackage.Error.rollbackRevision(
                highestSeen: state.highestSeenCounter,
                received: manifest.security.antiRollbackCounter
            )
        }
        if manifest.security.emergencyPolicyEpoch < state.emergencyPolicyEpoch {
            throw PatchPackage.Error.emergencyPolicyRollback(
                highestSeen: state.emergencyPolicyEpoch,
                received: manifest.security.emergencyPolicyEpoch
            )
        }
    }

    private func targetMatches(
        _ target: PatchPackage.Target,
        context: PatchPackage.TargetContext,
        allowNewerOS: Bool
    ) -> Bool {
        guard target.bundleID == context.bundleID,
              target.marketingVersion == context.marketingVersion,
              target.buildNumber == context.buildNumber,
              target.shellNamespaceID == context.shellNamespaceID,
              target.machOUUID == context.machOUUID,
              target.shellInterfaceHash.constantTimeEquals(context.shellInterfaceHash),
              target.architecture == context.architecture,
              target.platform == context.platform,
              context.operatingSystemVersion >= target.minimumOSVersion,
              allowNewerOS || context.operatingSystemVersion <= target.maximumTestedOSVersion,
              target.compatibility == context.compatibility
        else {
            return false
        }
        return true
    }
}
}

extension PatchPackage.AntiRollbackState {
    private enum CodingKeys: String, CodingKey {
        case campaignID, shellInterfaceHash, highestSeenRevision
        case highestSeenCounter, highestSeenPackageHash
        case emergencyPolicyEpoch, revokedPackageHashes
    }

    /// Decodes anti-rollback state while rejecting duplicate revoked hashes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        campaignID = try container.decode(String.self, forKey: .campaignID)
        shellInterfaceHash = try container.decode(Core.Digest.self, forKey: .shellInterfaceHash)
        highestSeenRevision = try container.decode(UInt64.self, forKey: .highestSeenRevision)
        highestSeenCounter = try container.decode(UInt64.self, forKey: .highestSeenCounter)
        highestSeenPackageHash = try container.decodeIfPresent(
            Core.Digest.self,
            forKey: .highestSeenPackageHash
        )
        emergencyPolicyEpoch = try container.decode(UInt64.self, forKey: .emergencyPolicyEpoch)
        let hashes = try container.decode([Core.Digest].self, forKey: .revokedPackageHashes)
        guard Set(hashes).count == hashes.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .revokedPackageHashes,
                in: container,
                debugDescription: "duplicate revoked package hash"
            )
        }
        revokedPackageHashes = Set(hashes)
    }

    /// Encodes revoked package hashes in deterministic order.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(campaignID, forKey: .campaignID)
        try container.encode(shellInterfaceHash, forKey: .shellInterfaceHash)
        try container.encode(highestSeenRevision, forKey: .highestSeenRevision)
        try container.encode(highestSeenCounter, forKey: .highestSeenCounter)
        try container.encodeIfPresent(highestSeenPackageHash, forKey: .highestSeenPackageHash)
        try container.encode(emergencyPolicyEpoch, forKey: .emergencyPolicyEpoch)
        try container.encode(revokedPackageHashes.sorted(), forKey: .revokedPackageHashes)
    }
}
