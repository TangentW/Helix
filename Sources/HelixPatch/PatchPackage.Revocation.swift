import CryptoKit
import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension PatchPackage {
/// Public authority permitted to sign monotonic revocation snapshots.
public struct RevocationAuthority: Codable, Hashable, Sendable {
    /// Stable authority key identifier.
    public var keyID: String
    /// Ed25519 public-key bytes.
    public var publicKey: Data
    /// First Unix second at which the authority is valid.
    public var validFromUnixSeconds: Int64
    /// Last Unix second at which the authority is valid.
    public var validUntilUnixSeconds: Int64

    /// Creates a revocation authority.
    public init(
        keyID: String,
        publicKey: Data,
        validFromUnixSeconds: Int64,
        validUntilUnixSeconds: Int64
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.validFromUnixSeconds = validFromUnixSeconds
        self.validUntilUnixSeconds = validUntilUnixSeconds
    }

    func validate() throws {
        guard !keyID.isEmpty, validFromUnixSeconds < validUntilUnixSeconds else {
            throw PatchPackage.Error.invalidRevocationSnapshot("invalid authority validity")
        }
        do {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw PatchPackage.Error.invalidRevocationSnapshot("invalid authority public key")
        }
    }
}

/// Canonical, authority-signed key and package revocations.
public struct RevocationSnapshot: Codable, Hashable, Sendable {
    /// Snapshot schema emitted by this framework version.
    public static let currentSchemaVersion: UInt16 = 1

    /// Encoded snapshot schema.
    public var schemaVersion: UInt16
    /// Signature algorithm, currently `ed25519`.
    public var algorithm: String
    /// Authority expected to verify this snapshot.
    public var authorityKeyID: String
    /// Monotonically increasing revocation epoch.
    public var epoch: UInt64
    /// Snapshot issue time.
    public var issuedAtUnixSeconds: Int64
    /// Snapshot expiration time.
    public var expiresAtUnixSeconds: Int64
    /// Root or leaf key identifiers revoked by the snapshot.
    public var revokedKeyIDs: Set<String>
    /// Complete package hashes revoked by the snapshot.
    public var revokedPackageHashes: Set<Core.Digest>
    /// Authority signature over the canonical unsigned snapshot.
    public var signature: Data

    /// Creates a snapshot value. Prefer the static `issue` method when
    /// producing a usable signed snapshot.
    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        algorithm: String = "ed25519",
        authorityKeyID: String,
        epoch: UInt64,
        issuedAtUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64,
        revokedKeyIDs: Set<String>,
        revokedPackageHashes: Set<Core.Digest>,
        signature: Data = Data()
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.authorityKeyID = authorityKeyID
        self.epoch = epoch
        self.issuedAtUnixSeconds = issuedAtUnixSeconds
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
        self.revokedKeyIDs = revokedKeyIDs
        self.revokedPackageHashes = revokedPackageHashes
        self.signature = signature
    }

    /// Issues a signed snapshot on trusted control-plane infrastructure.
    public static func issue(
        authorityKeyID: String,
        authorityPrivateKey: PatchPackage.PrivateKey,
        epoch: UInt64,
        issuedAtUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64,
        revokedKeyIDs: Set<String> = [],
        revokedPackageHashes: Set<Core.Digest> = []
    ) throws -> Self {
        var snapshot = Self(
            authorityKeyID: authorityKeyID,
            epoch: epoch,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: expiresAtUnixSeconds,
            revokedKeyIDs: revokedKeyIDs,
            revokedPackageHashes: revokedPackageHashes
        )
        try snapshot.validateStructure(requireSignature: false)
        snapshot.signature = try authorityPrivateKey.signature(for: snapshot.signingBytes())
        return snapshot
    }

    /// Encodes this snapshot as canonical JSON after structural validation.
    public func encoded() throws -> Data {
        try validateStructure()
        return try Core.CanonicalJSON.encode(self)
    }

    /// Decodes bounded canonical JSON without yet establishing authority trust.
    public static func decode(
        _ bytes: Data,
        maximumBytes: Int = 256 * 1_024
    ) throws -> Self {
        guard bytes.count <= maximumBytes else {
            throw PatchPackage.Error.limitExceeded("revocation snapshot bytes")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: bytes)
        } catch {
            throw PatchPackage.Error.invalidRevocationSnapshot("malformed JSON")
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                "schemaVersion", "algorithm", "authorityKeyID", "epoch",
                "issuedAtUnixSeconds", "expiresAtUnixSeconds", "revokedKeyIDs",
                "revokedPackageHashes", "signature",
              ]
        else {
            throw PatchPackage.Error.invalidRevocationSnapshot("unknown or missing fields")
        }
        let snapshot: Self
        do {
            snapshot = try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw PatchPackage.Error.invalidRevocationSnapshot("schema decoding failed: \(error)")
        }
        try snapshot.validateStructure()
        guard try Core.CanonicalJSON.encode(snapshot) == bytes else {
            throw PatchPackage.Error.invalidRevocationSnapshot("snapshot is not canonical JSON")
        }
        return snapshot
    }

    func signingBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = Data()
        var hasher = Core.StableHasher(domain: "HLX.RevocationSnapshot.v1")
        hasher.append(try Core.CanonicalJSON.encode(unsigned))
        return hasher.finalize().data
    }

    func validateStructure(requireSignature: Bool = true) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              algorithm == "ed25519",
              !authorityKeyID.isEmpty,
              epoch > 0,
              issuedAtUnixSeconds < expiresAtUnixSeconds,
              !revokedKeyIDs.contains(""),
              !revokedKeyIDs.isEmpty || !revokedPackageHashes.isEmpty,
              !requireSignature || !signature.isEmpty
        else {
            throw PatchPackage.Error.invalidRevocationSnapshot("invalid schema, validity, or contents")
        }
    }
}
}

extension PatchPackage.TrustStore {
    /// Verifies and applies a monotonic revocation snapshot.
    ///
    /// The returned store contains the union of all accepted revocations.
    public func applying(
        _ snapshot: PatchPackage.RevocationSnapshot,
        nowUnixSeconds: Int64,
        clockSkewAllowanceSeconds: Int64 = 300
    ) throws -> Self {
        try snapshot.validateStructure()
        guard let authority = revocationAuthorities[snapshot.authorityKeyID] else {
            throw PatchPackage.Error.unknownRevocationAuthority(snapshot.authorityKeyID)
        }
        let skew = max(0, clockSkewAllowanceSeconds)
        let latestStart = nowUnixSeconds.addingReportingOverflow(skew)
        let earliestEnd = nowUnixSeconds.subtractingReportingOverflow(skew)
        guard !latestStart.overflow,
              !earliestEnd.overflow,
              latestStart.partialValue >= snapshot.issuedAtUnixSeconds,
              earliestEnd.partialValue <= snapshot.expiresAtUnixSeconds,
              snapshot.issuedAtUnixSeconds >= authority.validFromUnixSeconds,
              snapshot.expiresAtUnixSeconds <= authority.validUntilUnixSeconds
        else {
            throw PatchPackage.Error.invalidRevocationSnapshot("snapshot is outside its validity window")
        }
        guard snapshot.epoch >= revocationEpoch else {
            throw PatchPackage.Error.revocationEpochRollback(
                highestSeen: revocationEpoch,
                received: snapshot.epoch
            )
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: authority.publicKey)
        } catch {
            throw PatchPackage.Error.invalidRevocationSnapshot("invalid authority public key")
        }
        guard publicKey.isValidSignature(snapshot.signature, for: try snapshot.signingBytes()) else {
            throw PatchPackage.Error.invalidRevocationSnapshot("authority signature failed")
        }
        if snapshot.epoch == revocationEpoch {
            guard snapshot.revokedKeyIDs.isSubset(of: revokedKeyIDs),
                  snapshot.revokedPackageHashes.isSubset(of: revokedPackageHashes)
            else {
                throw PatchPackage.Error.invalidRevocationSnapshot(
                    "an existing epoch cannot introduce different revocations"
                )
            }
            return self
        }
        var updated = self
        updated.revocationEpoch = snapshot.epoch
        updated.revokedKeyIDs.formUnion(snapshot.revokedKeyIDs)
        updated.revokedPackageHashes.formUnion(snapshot.revokedPackageHashes)
        return updated
    }

    /// Merges revocation state previously verified and persisted by Helix.
    public func mergingPersistedRevocations(
        epoch: UInt64,
        revokedKeyIDs: Set<String>,
        revokedPackageHashes: Set<Core.Digest>
    ) -> Self {
        var updated = self
        updated.revocationEpoch = max(updated.revocationEpoch, epoch)
        updated.revokedKeyIDs.formUnion(revokedKeyIDs)
        updated.revokedPackageHashes.formUnion(revokedPackageHashes)
        return updated
    }
}

extension PatchPackage.RevocationSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithm, authorityKeyID, epoch
        case issuedAtUnixSeconds, expiresAtUnixSeconds
        case revokedKeyIDs, revokedPackageHashes, signature
    }

    /// Decodes a snapshot while rejecting duplicate key and package revocations.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        authorityKeyID = try container.decode(String.self, forKey: .authorityKeyID)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        issuedAtUnixSeconds = try container.decode(Int64.self, forKey: .issuedAtUnixSeconds)
        expiresAtUnixSeconds = try container.decode(Int64.self, forKey: .expiresAtUnixSeconds)
        let keyIDs = try container.decode([String].self, forKey: .revokedKeyIDs)
        let packageHashes = try container.decode([Core.Digest].self, forKey: .revokedPackageHashes)
        guard Set(keyIDs).count == keyIDs.count,
              Set(packageHashes).count == packageHashes.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .revokedKeyIDs,
                in: container,
                debugDescription: "duplicate revocation"
            )
        }
        revokedKeyIDs = Set(keyIDs)
        revokedPackageHashes = Set(packageHashes)
        signature = try container.decode(Data.self, forKey: .signature)
    }

    /// Encodes revoked keys and package hashes in deterministic order.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(authorityKeyID, forKey: .authorityKeyID)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(issuedAtUnixSeconds, forKey: .issuedAtUnixSeconds)
        try container.encode(expiresAtUnixSeconds, forKey: .expiresAtUnixSeconds)
        try container.encode(revokedKeyIDs.sorted(), forKey: .revokedKeyIDs)
        try container.encode(revokedPackageHashes.sorted(), forKey: .revokedPackageHashes)
        try container.encode(signature, forKey: .signature)
    }
}
