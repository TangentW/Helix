import Foundation
import HelixCore
import HelixInterface
import HelixPatch

extension ReleasePipeline {
/// Checked-in audit metadata for Xcode's quick-patch action. Volatile target
/// identity (Mach-O UUID, architecture, platform, version, and timestamps) is
/// resolved from the archived Xcode build and emitted beside the signed HLXP.
public struct QuickPatchRecipe: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var packageID: String
    public var campaignID: String
    public var revision: UInt64
    public var validityDurationSeconds: UInt64
    public var purpose: String
    public var incidentID: String
    public var ownerTeam: String
    public var distributionPolicy: Core.DistributionPolicy
    public var distributionPolicyApprovalID: String
    public var maximumTestedOSVersion: Core.SemanticVersion
    public var payloadPath: String
    public var rollout: PatchPackage.Rollout
    public var rollback: PatchPackage.RollbackPlan
    public var approvalPolicyID: String
    public var antiRollbackCounter: UInt64
    public var emergencyPolicyEpoch: UInt64
    public var requestedResources: Core.ResourceLimits

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        packageID: String,
        campaignID: String,
        revision: UInt64,
        validityDurationSeconds: UInt64 = 24 * 60 * 60,
        purpose: String,
        incidentID: String,
        ownerTeam: String,
        distributionPolicy: Core.DistributionPolicy = .internalHLBC,
        distributionPolicyApprovalID: String,
        maximumTestedOSVersion: Core.SemanticVersion,
        payloadPath: String = "payloads/patch.hlbc",
        rollout: PatchPackage.Rollout,
        rollback: PatchPackage.RollbackPlan = .init(),
        approvalPolicyID: String,
        antiRollbackCounter: UInt64,
        emergencyPolicyEpoch: UInt64 = 0,
        requestedResources: Core.ResourceLimits = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.campaignID = campaignID
        self.revision = revision
        self.validityDurationSeconds = validityDurationSeconds
        self.purpose = purpose
        self.incidentID = incidentID
        self.ownerTeam = ownerTeam
        self.distributionPolicy = distributionPolicy
        self.distributionPolicyApprovalID = distributionPolicyApprovalID
        self.maximumTestedOSVersion = maximumTestedOSVersion
        self.payloadPath = payloadPath
        self.rollout = rollout
        self.rollback = rollback
        self.approvalPolicyID = approvalPolicyID
        self.antiRollbackCounter = antiRollbackCounter
        self.emergencyPolicyEpoch = emergencyPolicyEpoch
        self.requestedResources = requestedResources
    }

    public func validate() throws {
        let strings = [
            campaignID, purpose, incidentID, ownerTeam,
            distributionPolicyApprovalID, approvalPolicyID,
        ]
        guard schemaVersion == Self.currentSchemaVersion,
              packageID.hasPrefix("HLX-"), packageID.utf8.count <= 256,
              strings.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              revision > 0,
              (60...31_536_000).contains(validityDurationSeconds),
              distributionPolicy == .internalHLBC
                  || distributionPolicy == .enterpriseHLBC,
              antiRollbackCounter > 0,
              rollout.percentageBasisPoints <= 10_000,
              rollout.cohortSalt.count >= 16,
              rollout.installationAllowlist.isDisjoint(
                  with: rollout.installationDenylist
              ),
              Self.isSafePayloadPath(payloadPath)
        else {
            throw ReleasePipeline.Error.invalidConfiguration(
                "quick-patch recipe is incomplete or outside supported policy"
            )
        }
    }

    public func resolve(
        archive: InterfaceArchive.Archive,
        certificate: PatchPackage.SigningCertificate,
        marketingVersion: String,
        architecture: String,
        platform: PatchPackage.Platform,
        nowUnixSeconds: Int64
    ) throws -> ReleasePipeline.Configuration {
        try validate()
        try archive.validate()
        guard !marketingVersion.isEmpty, marketingVersion.utf8.count <= 256,
              !architecture.isEmpty, architecture.utf8.count <= 128,
              archive.metadata.machOUUIDs.count == 1,
              nowUnixSeconds > 0,
              validityDurationSeconds <= UInt64(Int64.max),
              nowUnixSeconds <= Int64.max - Int64(validityDurationSeconds)
        else {
            throw ReleasePipeline.Error.invalidConfiguration(
                "Xcode target identity cannot resolve one patch target"
            )
        }
        return .init(
            packageID: packageID,
            campaignID: campaignID,
            revision: revision,
            createdAtUnixSeconds: nowUnixSeconds,
            notBeforeUnixSeconds: nowUnixSeconds,
            expiresAtUnixSeconds: nowUnixSeconds + Int64(validityDurationSeconds),
            purpose: purpose,
            incidentID: incidentID,
            ownerTeam: ownerTeam,
            distributionPolicy: distributionPolicy,
            distributionPolicyApprovalID: distributionPolicyApprovalID,
            target: .init(
                marketingVersion: marketingVersion,
                machOUUID: archive.metadata.machOUUIDs[0],
                architecture: architecture,
                platform: platform,
                maximumTestedOSVersion: maximumTestedOSVersion
            ),
            payloadPath: payloadPath,
            rollout: rollout,
            rollback: rollback,
            security: .init(
                signerKeyID: certificate.keyID,
                approvalPolicyID: approvalPolicyID,
                antiRollbackCounter: antiRollbackCounter,
                emergencyPolicyEpoch: emergencyPolicyEpoch
            ),
            requestedResources: requestedResources
        )
    }

    private static func isSafePayloadPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains(".")
            && !components.contains("..")
    }
}
}
