import Foundation
import HelixCore

extension PatchPackage {
public struct TargetContext: Sendable, Hashable {
    public var bundleID: String
    public var marketingVersion: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var machOUUID: UUID
    public var shellInterfaceHash: Core.Digest
    public var architecture: String
    public var platform: PatchPackage.Platform
    public var operatingSystemVersion: Core.SemanticVersion
    public var compatibility: Core.Compatibility
    public var installationID: String

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

public struct AcceptancePolicy: Sendable, Hashable {
    public var acceptedDistributionPolicies: Set<Core.DistributionPolicy>
    public var approvedDistributionPolicyIDs: Set<String>
    public var productionChannelEnabled: Bool
    public var allowOperatingSystemsNewerThanTested: Bool
    public var clockSkewAllowanceSeconds: Int64

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

public struct AntiRollbackState: Codable, Hashable, Sendable {
    public var campaignID: String
    public var shellInterfaceHash: Core.Digest
    public var highestSeenRevision: UInt64
    public var highestSeenCounter: UInt64
    public var highestSeenPackageHash: Core.Digest?
    public var emergencyPolicyEpoch: UInt64
    public var revokedPackageHashes: Set<Core.Digest>

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

public struct VerifiedPackage: Sendable {
    public var package: PatchPackage.Container
    public var encodedBytes: Data
    public var packageHash: Core.Digest
    public var selectedTargetIndex: UInt32
    public var selectedTarget: PatchPackage.Target
    public var selectedPayloads: [PatchPackage.PayloadDescriptor]

    public func payload(for descriptor: PatchPackage.PayloadDescriptor) throws -> Data {
        guard let payload = package.payloads[descriptor.path] else {
            throw PatchPackage.Error.missingPayload(descriptor.path)
        }
        return payload
    }
}

public struct Verifier: Sendable {
    public var decodingLimits: PatchPackage.DecodingLimits

    public init(decodingLimits: PatchPackage.DecodingLimits = .init()) {
        self.decodingLimits = decodingLimits
    }

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
