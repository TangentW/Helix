import CryptoKit
import Foundation
import HelixCore

extension PatchPackage {
public struct SigningRequest: Hashable, Sendable {
    public struct Payload: Hashable, Sendable {
        public var path: String
        public var byteLength: UInt64
        public var sha256: Core.Digest

        public init(path: String, byteLength: UInt64, sha256: Core.Digest) {
            self.path = path
            self.byteLength = byteLength
            self.sha256 = sha256
        }
    }

    public var manifest: PatchPackage.Manifest
    public var canonicalManifestBytes: Data
    public var payloads: [Payload]
    public var signatureMaterial: Data

    public static func make(
        manifest: PatchPackage.Manifest,
        payloads: [String: Data]
    ) throws -> Self {
        try manifest.validateStructure()
        let expectedPaths = Set(manifest.payloads.map(\.path))
        guard expectedPaths == Set(payloads.keys) else {
            throw PatchPackage.Error.invalidManifest(
                "signing request payloads do not match the manifest"
            )
        }
        for descriptor in manifest.payloads {
            guard let bytes = payloads[descriptor.path],
                  descriptor.byteLength == UInt64(bytes.count),
                  descriptor.sha256.constantTimeEquals(.sha256(bytes))
            else {
                throw PatchPackage.Error.payloadHashMismatch(descriptor.path)
            }
        }
        let manifestBytes = try Core.CanonicalJSON.encode(manifest)
        let identities = payloads.keys.sorted().compactMap { path -> Payload? in
            guard let bytes = payloads[path] else { return nil }
            return .init(
                path: path,
                byteLength: UInt64(bytes.count),
                sha256: .sha256(bytes)
            )
        }
        return .init(
            manifest: manifest,
            canonicalManifestBytes: manifestBytes,
            payloads: identities,
            signatureMaterial: try PatchPackage.SignatureMaterial.make(
                manifestBytes: manifestBytes,
                payloads: payloads
            )
        )
    }
}

public protocol SignatureProviding: Sendable {
    var certificate: PatchPackage.SigningCertificate { get }
    func sign(_ request: PatchPackage.SigningRequest) throws -> PatchPackage.SignatureEnvelope
}

public struct PrivateKey: @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    public init() {
        key = Curve25519.Signing.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKeyRepresentation: Data { key.publicKey.rawRepresentation }

    public func signature(for bytes: Data) throws -> Data {
        try key.signature(for: bytes)
    }
}

public struct TrustedRoot: Codable, Hashable, Sendable {
    public var keyID: String
    public var publicKey: Data
    public var validFromUnixSeconds: Int64
    public var validUntilUnixSeconds: Int64
    public var allowedDistributionPolicies: Set<Core.DistributionPolicy>
    public var allowedBackends: Set<PatchPackage.Backend>

    public init(
        keyID: String,
        publicKey: Data,
        validFromUnixSeconds: Int64,
        validUntilUnixSeconds: Int64,
        allowedDistributionPolicies: Set<Core.DistributionPolicy>,
        allowedBackends: Set<PatchPackage.Backend>
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.validFromUnixSeconds = validFromUnixSeconds
        self.validUntilUnixSeconds = validUntilUnixSeconds
        self.allowedDistributionPolicies = allowedDistributionPolicies
        self.allowedBackends = allowedBackends
    }
}

public struct SigningCertificate: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var algorithm: String
    public var keyID: String
    public var issuerKeyID: String
    public var publicKey: Data
    public var validFromUnixSeconds: Int64
    public var validUntilUnixSeconds: Int64
    public var allowedDistributionPolicies: Set<Core.DistributionPolicy>
    public var allowedBackends: Set<PatchPackage.Backend>
    public var allowedBundleIDs: Set<String>
    public var maximumPayloadBytes: UInt64
    public var issuerSignature: Data

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        algorithm: String = "ed25519",
        keyID: String,
        issuerKeyID: String,
        publicKey: Data,
        validFromUnixSeconds: Int64,
        validUntilUnixSeconds: Int64,
        allowedDistributionPolicies: Set<Core.DistributionPolicy>,
        allowedBackends: Set<PatchPackage.Backend>,
        allowedBundleIDs: Set<String>,
        maximumPayloadBytes: UInt64,
        issuerSignature: Data = Data()
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyID = keyID
        self.issuerKeyID = issuerKeyID
        self.publicKey = publicKey
        self.validFromUnixSeconds = validFromUnixSeconds
        self.validUntilUnixSeconds = validUntilUnixSeconds
        self.allowedDistributionPolicies = allowedDistributionPolicies
        self.allowedBackends = allowedBackends
        self.allowedBundleIDs = allowedBundleIDs
        self.maximumPayloadBytes = maximumPayloadBytes
        self.issuerSignature = issuerSignature
    }

    public static func issue(
        keyID: String,
        leafPublicKey: Data,
        issuerKeyID: String,
        issuerPrivateKey: PatchPackage.PrivateKey,
        validFromUnixSeconds: Int64,
        validUntilUnixSeconds: Int64,
        allowedDistributionPolicies: Set<Core.DistributionPolicy>,
        allowedBackends: Set<PatchPackage.Backend>,
        allowedBundleIDs: Set<String>,
        maximumPayloadBytes: UInt64
    ) throws -> Self {
        var certificate = Self(
            keyID: keyID,
            issuerKeyID: issuerKeyID,
            publicKey: leafPublicKey,
            validFromUnixSeconds: validFromUnixSeconds,
            validUntilUnixSeconds: validUntilUnixSeconds,
            allowedDistributionPolicies: allowedDistributionPolicies,
            allowedBackends: allowedBackends,
            allowedBundleIDs: allowedBundleIDs,
            maximumPayloadBytes: maximumPayloadBytes
        )
        certificate.issuerSignature = try issuerPrivateKey.signature(for: certificate.signingBytes())
        try certificate.validate()
        return certificate
    }

    func signingBytes() throws -> Data {
        var unsigned = self
        unsigned.issuerSignature = Data()
        var hasher = Core.StableHasher(domain: "HLX.SigningCertificate.v1")
        hasher.append(try Core.CanonicalJSON.encode(unsigned))
        return hasher.finalize().data
    }
}

public struct SignatureEnvelope: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var algorithm: String
    public var certificate: PatchPackage.SigningCertificate
    public var signature: Data

    public init(
        schemaVersion: UInt16 = 1,
        algorithm: String = "ed25519",
        certificate: PatchPackage.SigningCertificate,
        signature: Data
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.certificate = certificate
        self.signature = signature
    }
}

public struct Signer: PatchPackage.SignatureProviding, Sendable {
    public var certificate: PatchPackage.SigningCertificate
    public var privateKey: PatchPackage.PrivateKey

    public init(certificate: PatchPackage.SigningCertificate, privateKey: PatchPackage.PrivateKey) throws {
        guard certificate.publicKey == privateKey.publicKeyRepresentation else {
            throw PatchPackage.Error.invalidSigningCertificate("leaf private key does not match certificate")
        }
        self.certificate = certificate
        self.privateKey = privateKey
    }

    public func sign(_ request: PatchPackage.SigningRequest) throws -> PatchPackage.SignatureEnvelope {
        guard request.manifest.security.signerKeyID == certificate.keyID else {
            throw PatchPackage.Error.invalidSigningCertificate(
                "signing request names a different leaf key"
            )
        }
        return .init(
            certificate: certificate,
            signature: try privateKey.signature(for: request.signatureMaterial)
        )
    }
}

public struct TrustStore: Sendable {
    public var roots: [String: PatchPackage.TrustedRoot]
    public var revocationAuthorities: [String: PatchPackage.RevocationAuthority]
    public var revocationEpoch: UInt64
    public var revokedKeyIDs: Set<String>
    public var revokedPackageHashes: Set<Core.Digest>

    public init(
        roots: [PatchPackage.TrustedRoot],
        revocationAuthorities: [PatchPackage.RevocationAuthority] = [],
        revocationEpoch: UInt64 = 0,
        revokedKeyIDs: Set<String> = [],
        revokedPackageHashes: Set<Core.Digest> = []
    ) throws {
        var mapped: [String: PatchPackage.TrustedRoot] = [:]
        for root in roots {
            try root.validate()
            guard mapped.updateValue(root, forKey: root.keyID) == nil else {
                throw PatchPackage.Error.invalidSigningCertificate("duplicate root key ID \(root.keyID)")
            }
        }
        var mappedAuthorities: [String: PatchPackage.RevocationAuthority] = [:]
        for authority in revocationAuthorities {
            try authority.validate()
            guard mappedAuthorities.updateValue(authority, forKey: authority.keyID) == nil else {
                throw PatchPackage.Error.invalidRevocationSnapshot(
                    "duplicate revocation authority key ID \(authority.keyID)"
                )
            }
        }
        guard !revokedKeyIDs.contains("") else {
            throw PatchPackage.Error.invalidSigningCertificate("empty revoked key ID")
        }
        self.roots = mapped
        self.revocationAuthorities = mappedAuthorities
        self.revocationEpoch = revocationEpoch
        self.revokedKeyIDs = revokedKeyIDs
        self.revokedPackageHashes = revokedPackageHashes
    }

    func verify(
        envelope: PatchPackage.SignatureEnvelope,
        material: Data,
        manifest: PatchPackage.Manifest,
        packageHash: Core.Digest,
        nowUnixSeconds: Int64
    ) throws {
        guard envelope.schemaVersion == 1, envelope.algorithm == "ed25519" else {
            throw PatchPackage.Error.unsupportedSignatureAlgorithm(envelope.algorithm)
        }
        let certificate = envelope.certificate
        guard certificate.schemaVersion == 1, certificate.algorithm == "ed25519" else {
            throw PatchPackage.Error.unsupportedSignatureAlgorithm(certificate.algorithm)
        }
        guard manifest.security.signerKeyID == certificate.keyID else {
            throw PatchPackage.Error.invalidSigningCertificate("manifest signer key ID does not match envelope")
        }
        guard !revokedPackageHashes.contains(packageHash) else {
            throw PatchPackage.Error.packageRevoked(packageHash)
        }
        if let revoked = [certificate.keyID, certificate.issuerKeyID].first(where: {
            revokedKeyIDs.contains($0)
        }) {
            throw PatchPackage.Error.signingKeyRevoked(revoked)
        }
        guard let root = roots[certificate.issuerKeyID] else {
            throw PatchPackage.Error.unknownSigningRoot(certificate.issuerKeyID)
        }
        guard nowUnixSeconds >= root.validFromUnixSeconds,
              nowUnixSeconds <= root.validUntilUnixSeconds,
              nowUnixSeconds >= certificate.validFromUnixSeconds,
              nowUnixSeconds <= certificate.validUntilUnixSeconds,
              certificate.validFromUnixSeconds < certificate.validUntilUnixSeconds,
              certificate.validFromUnixSeconds >= root.validFromUnixSeconds,
              certificate.validUntilUnixSeconds <= root.validUntilUnixSeconds
        else {
            throw PatchPackage.Error.invalidSigningCertificate("certificate or root is outside its validity window")
        }
        try certificate.validate()
        guard root.allowedDistributionPolicies.contains(manifest.distributionPolicy),
              certificate.allowedDistributionPolicies.contains(manifest.distributionPolicy)
        else {
            throw PatchPackage.Error.signerScopeDenied("distribution policy")
        }
        let backends = Set(manifest.payloads.map(\.backend))
        guard backends.isSubset(of: root.allowedBackends),
              backends.isSubset(of: certificate.allowedBackends)
        else {
            throw PatchPackage.Error.signerScopeDenied("backend")
        }
        let bundleIDs = Set(manifest.targets.map(\.bundleID))
        guard bundleIDs.isSubset(of: certificate.allowedBundleIDs) else {
            throw PatchPackage.Error.signerScopeDenied("bundle ID")
        }
        let totalBytes = manifest.payloads.reduce(UInt64(0)) { partial, descriptor in
            partial.addingReportingOverflow(descriptor.byteLength).overflow
                ? UInt64.max
                : partial + descriptor.byteLength
        }
        guard totalBytes <= certificate.maximumPayloadBytes else {
            throw PatchPackage.Error.signerScopeDenied("payload byte limit")
        }

        let rootPublicKey: Curve25519.Signing.PublicKey
        let leafPublicKey: Curve25519.Signing.PublicKey
        do {
            rootPublicKey = try .init(rawRepresentation: root.publicKey)
            leafPublicKey = try .init(rawRepresentation: certificate.publicKey)
        } catch {
            throw PatchPackage.Error.invalidSigningCertificate("invalid Ed25519 public key")
        }
        guard rootPublicKey.isValidSignature(
            certificate.issuerSignature,
            for: try certificate.signingBytes()
        ) else {
            throw PatchPackage.Error.invalidSigningCertificate("issuer signature failed")
        }
        guard leafPublicKey.isValidSignature(envelope.signature, for: material) else {
            throw PatchPackage.Error.invalidPackageSignature
        }
    }
}
}

private extension PatchPackage.TrustedRoot {
    func validate() throws {
        guard !keyID.isEmpty,
              validFromUnixSeconds < validUntilUnixSeconds,
              !allowedDistributionPolicies.isEmpty,
              !allowedBackends.isEmpty
        else {
            throw PatchPackage.Error.invalidSigningCertificate("invalid trusted root scope or validity")
        }
        do {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw PatchPackage.Error.invalidSigningCertificate("invalid trusted root public key")
        }
    }
}

private extension PatchPackage.SigningCertificate {
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              algorithm == "ed25519",
              !keyID.isEmpty,
              !issuerKeyID.isEmpty,
              keyID != issuerKeyID,
              validFromUnixSeconds < validUntilUnixSeconds,
              !allowedDistributionPolicies.isEmpty,
              !allowedBackends.isEmpty,
              !allowedBundleIDs.isEmpty,
              !allowedBundleIDs.contains(""),
              maximumPayloadBytes > 0,
              !issuerSignature.isEmpty
        else {
            throw PatchPackage.Error.invalidSigningCertificate("invalid leaf scope or validity")
        }
        do {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw PatchPackage.Error.invalidSigningCertificate("invalid leaf public key")
        }
    }
}

extension PatchPackage {
enum SignatureMaterial {
    static func make(manifestBytes: Data, payloads: [String: Data]) throws -> Data {
        var hasher = Core.StableHasher(domain: "HLX.PatchSignature.v1")
        hasher.append(manifestBytes)
        for path in payloads.keys.sorted() {
            guard let payload = payloads[path] else { continue }
            hasher.append(path)
            hasher.append(UInt64(payload.count))
            hasher.append(Core.Digest.sha256(payload))
        }
        return hasher.finalize().data
    }
}
}

extension PatchPackage.SigningCertificate {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithm, keyID, issuerKeyID, publicKey
        case validFromUnixSeconds, validUntilUnixSeconds
        case allowedDistributionPolicies, allowedBackends, allowedBundleIDs
        case maximumPayloadBytes, issuerSignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        keyID = try container.decode(String.self, forKey: .keyID)
        issuerKeyID = try container.decode(String.self, forKey: .issuerKeyID)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        validFromUnixSeconds = try container.decode(Int64.self, forKey: .validFromUnixSeconds)
        validUntilUnixSeconds = try container.decode(Int64.self, forKey: .validUntilUnixSeconds)
        let policies = try container.decode(
            [Core.DistributionPolicy].self,
            forKey: .allowedDistributionPolicies
        )
        let backends = try container.decode([PatchPackage.Backend].self, forKey: .allowedBackends)
        let bundleIDs = try container.decode([String].self, forKey: .allowedBundleIDs)
        guard Set(policies).count == policies.count,
              Set(backends).count == backends.count,
              Set(bundleIDs).count == bundleIDs.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .allowedBundleIDs,
                in: container,
                debugDescription: "duplicate signing scope"
            )
        }
        allowedDistributionPolicies = Set(policies)
        allowedBackends = Set(backends)
        allowedBundleIDs = Set(bundleIDs)
        maximumPayloadBytes = try container.decode(UInt64.self, forKey: .maximumPayloadBytes)
        issuerSignature = try container.decode(Data.self, forKey: .issuerSignature)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(issuerKeyID, forKey: .issuerKeyID)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(validFromUnixSeconds, forKey: .validFromUnixSeconds)
        try container.encode(validUntilUnixSeconds, forKey: .validUntilUnixSeconds)
        try container.encode(
            allowedDistributionPolicies.sorted { $0.rawValue < $1.rawValue },
            forKey: .allowedDistributionPolicies
        )
        try container.encode(
            allowedBackends.sorted { $0.rawValue < $1.rawValue },
            forKey: .allowedBackends
        )
        try container.encode(allowedBundleIDs.sorted(), forKey: .allowedBundleIDs)
        try container.encode(maximumPayloadBytes, forKey: .maximumPayloadBytes)
        try container.encode(issuerSignature, forKey: .issuerSignature)
    }
}
