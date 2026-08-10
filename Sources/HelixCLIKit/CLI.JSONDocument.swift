import Foundation

extension CLI {
enum JSONDocument {
    enum Kind {
        case releaseConfiguration
        case signingCertificate
        case signingKey
        case trustedRoot
        case quickPatchRecipe
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        kind: Kind
    ) throws -> T {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw CLI.Error.input("JSON document root must be an object")
            }
            try validate(root, kind: kind)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CLI.Error {
            throw error
        } catch {
            throw CLI.Error.input("JSON decoding failed: \(error.localizedDescription)")
        }
    }

    private static func validate(_ root: [String: Any], kind: Kind) throws {
        switch kind {
        case .releaseConfiguration:
            try exactKeys(
                root,
                [
                    "schemaVersion", "packageID", "campaignID", "revision",
                    "createdAtUnixSeconds", "notBeforeUnixSeconds", "expiresAtUnixSeconds",
                    "purpose", "incidentID", "ownerTeam", "distributionPolicy",
                    "distributionPolicyApprovalID", "target", "payloadPath", "rollout",
                    "rollback", "security", "requestedResources",
                ],
                context: "release configuration"
            )
            try exactObject(
                root["target"],
                keys: [
                    "marketingVersion", "machOUUID", "architecture", "platform",
                    "maximumTestedOSVersion",
                ],
                context: "release target"
            )
            if let target = root["target"] as? [String: Any] {
                try exactObject(
                    target["maximumTestedOSVersion"],
                    keys: ["major", "minor", "patch"],
                    context: "maximum tested OS version"
                )
            }
            try exactObject(
                root["rollout"],
                keys: [
                    "cohortSalt", "percentageBasisPoints", "installationAllowlist",
                    "installationDenylist",
                ],
                context: "rollout"
            )
            try exactObject(
                root["rollback"],
                keys: ["parentGenerationPackageHash", "mutuallyExclusivePackageIDs"],
                context: "rollback"
            )
            try exactObject(
                root["security"],
                keys: [
                    "signerKeyID", "approvalPolicyID", "antiRollbackCounter",
                    "emergencyPolicyEpoch",
                ],
                context: "security"
            )
            try exactObject(
                root["requestedResources"],
                keys: [
                    "instructionFuelPerEntry", "maxCallDepth", "maxFrameRegisters",
                    "maxVMHeapBytes", "maxNativeOwnedBytes", "maxNativeCallsPerEntry",
                    "maxWallTimeMainThreadMilliseconds", "maxWallTimeBackgroundMilliseconds",
                    "maxSuspendedFrames",
                ],
                context: "requested resources"
            )
        case .signingCertificate:
            try exactKeys(
                root,
                [
                    "schemaVersion", "algorithm", "keyID", "issuerKeyID", "publicKey",
                    "validFromUnixSeconds", "validUntilUnixSeconds",
                    "allowedDistributionPolicies", "allowedBackends", "allowedBundleIDs",
                    "maximumPayloadBytes", "issuerSignature",
                ],
                context: "signing certificate"
            )
        case .signingKey:
            try exactKeys(
                root,
                ["schemaVersion", "algorithm", "rawRepresentation"],
                context: "signing key"
            )
        case .trustedRoot:
            try exactKeys(
                root,
                [
                    "keyID", "publicKey", "validFromUnixSeconds", "validUntilUnixSeconds",
                    "allowedDistributionPolicies", "allowedBackends",
                ],
                context: "trusted root"
            )
        case .quickPatchRecipe:
            try exactKeys(
                root,
                [
                    "schemaVersion", "packageID", "campaignID", "revision",
                    "validityDurationSeconds", "purpose", "incidentID", "ownerTeam",
                    "distributionPolicy", "distributionPolicyApprovalID",
                    "maximumTestedOSVersion", "payloadPath", "rollout", "rollback",
                    "approvalPolicyID", "antiRollbackCounter", "emergencyPolicyEpoch",
                    "requestedResources",
                ],
                context: "quick-patch recipe"
            )
            try exactObject(
                root["maximumTestedOSVersion"],
                keys: ["major", "minor", "patch"],
                context: "maximum tested OS version"
            )
            try exactObject(
                root["rollout"],
                keys: [
                    "cohortSalt", "percentageBasisPoints", "installationAllowlist",
                    "installationDenylist",
                ],
                context: "rollout"
            )
            try exactObject(
                root["rollback"],
                keys: ["parentGenerationPackageHash", "mutuallyExclusivePackageIDs"],
                context: "rollback"
            )
            try exactObject(
                root["requestedResources"],
                keys: [
                    "instructionFuelPerEntry", "maxCallDepth", "maxFrameRegisters",
                    "maxVMHeapBytes", "maxNativeOwnedBytes", "maxNativeCallsPerEntry",
                    "maxWallTimeMainThreadMilliseconds",
                    "maxWallTimeBackgroundMilliseconds", "maxSuspendedFrames",
                ],
                context: "requested resources"
            )
        }
    }

    private static func exactObject(
        _ value: Any?,
        keys: Set<String>,
        context: String
    ) throws {
        guard let object = value as? [String: Any] else {
            throw CLI.Error.input("\(context) must be an object")
        }
        try exactKeys(object, keys, context: context)
    }

    private static func exactKeys(
        _ object: [String: Any],
        _ allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw CLI.Error.input("unknown \(context) field: \(unknown[0])")
        }
    }
}
}
