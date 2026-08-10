import Foundation
import HelixCore
import HelixPatch

extension ReleasePipeline {
/// Ephemeral local trust material for demos and isolated internal testing.
/// The issuer private key is deliberately discarded after issuing one leaf.
public struct DevelopmentIdentity: Sendable {
    public var trustedRoot: PatchPackage.TrustedRoot
    public var certificate: PatchPackage.SigningCertificate
    public var signingKey: ReleasePipeline.SigningKeyDocument

    public init(
        bundleID: String,
        nowUnixSeconds: Int64,
        validityDurationSeconds: UInt64 = 365 * 24 * 60 * 60,
        maximumPayloadBytes: UInt64 = 8 * 1_024 * 1_024
    ) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 4_096,
              nowUnixSeconds > 300,
              (3_600...157_680_000).contains(validityDurationSeconds),
              validityDurationSeconds <= UInt64(Int64.max),
              nowUnixSeconds <= Int64.max - Int64(validityDurationSeconds),
              maximumPayloadBytes > 0
        else {
            throw ReleasePipeline.Error.invalidConfiguration(
                "development identity scope or validity is invalid"
            )
        }
        let rootKey = PatchPackage.PrivateKey()
        let leafKey = PatchPackage.PrivateKey()
        let rootID = "dev-root-" + Core.Digest.sha256(rootKey.publicKeyRepresentation)
            .hex.prefix(16)
        let leafID = "dev-leaf-" + Core.Digest.sha256(leafKey.publicKeyRepresentation)
            .hex.prefix(16)
        let validFrom = nowUnixSeconds - 300
        let validUntil = nowUnixSeconds + Int64(validityDurationSeconds)
        trustedRoot = .init(
            keyID: rootID,
            publicKey: rootKey.publicKeyRepresentation,
            validFromUnixSeconds: validFrom,
            validUntilUnixSeconds: validUntil,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc]
        )
        certificate = try .issue(
            keyID: leafID,
            leafPublicKey: leafKey.publicKeyRepresentation,
            issuerKeyID: rootID,
            issuerPrivateKey: rootKey,
            validFromUnixSeconds: validFrom,
            validUntilUnixSeconds: validUntil,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc],
            allowedBundleIDs: [bundleID],
            maximumPayloadBytes: maximumPayloadBytes
        )
        signingKey = .init(rawRepresentation: leafKey.rawRepresentation)
    }

    public var publicArtifacts: [String: Data] {
        get throws {
            [
                "TrustedRoot.json": try Core.CanonicalJSON.encode(trustedRoot),
                "SigningCertificate.json": try Core.CanonicalJSON.encode(certificate),
            ]
        }
    }

    public var privateKeyBytes: Data {
        get throws { try Core.CanonicalJSON.encode(signingKey) }
    }
}
}
