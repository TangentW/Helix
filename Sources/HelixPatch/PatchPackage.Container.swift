import CryptoKit
import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension PatchPackage {
/// Hard ceilings applied before untrusted container fields are allocated.
public struct DecodingLimits: Sendable, Hashable {
    /// Maximum bytes in the complete `.hlxp`.
    public var maximumPackageBytes: Int
    /// Maximum canonical manifest bytes.
    public var maximumManifestBytes: Int
    /// Maximum canonical signature-envelope bytes.
    public var maximumSignatureBytes: Int
    /// Maximum number of payload files.
    public var maximumPayloadCount: Int
    /// Maximum bytes in any single payload.
    public var maximumPayloadBytes: Int

    /// Creates decode limits. Defaults are suitable for ordinary HLBC packages.
    public init(
        maximumPackageBytes: Int = 64 * 1_024 * 1_024,
        maximumManifestBytes: Int = 2 * 1_024 * 1_024,
        maximumSignatureBytes: Int = 128 * 1_024,
        maximumPayloadCount: Int = 64,
        maximumPayloadBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.maximumPackageBytes = maximumPackageBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumSignatureBytes = maximumSignatureBytes
        self.maximumPayloadCount = maximumPayloadCount
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

/// The decoded contents of one signed `.hlxp` container.
///
/// Use ``signed(manifest:payloads:signer:)`` on trusted build infrastructure
/// and ``decode(_:limits:)`` only as part of a verification pipeline.
public struct Container: Sendable {
    /// Binary file magic for `.hlxp` containers.
    public static let magic = Data([0x48, 0x4c, 0x58, 0x50, 0x00, 0x0d, 0x0a, 0x1a])
    /// Binary framing version emitted by this framework.
    public static let containerVersion: UInt16 = 1

    /// Canonical signed manifest.
    public var manifest: PatchPackage.Manifest
    /// Payload bytes keyed by safe relative path.
    public var payloads: [String: Data]
    /// Certificate and signature covering manifest and payload identities.
    public var signatureEnvelope: PatchPackage.SignatureEnvelope

    /// Creates an in-memory container. This does not verify or sign its fields.
    public init(
        manifest: PatchPackage.Manifest,
        payloads: [String: Data],
        signatureEnvelope: PatchPackage.SignatureEnvelope
    ) {
        self.manifest = manifest
        self.payloads = payloads
        self.signatureEnvelope = signatureEnvelope
    }

    /// Validates and signs a manifest and its exact payload bytes.
    ///
    /// ```swift
    /// let package = try PatchPackage.Container.signed(
    ///     manifest: manifest,
    ///     payloads: ["Patch.hlbc": bytecode],
    ///     signer: signer
    /// )
    /// let bytes = try package.encoded()
    /// ```
    public static func signed(
        manifest: PatchPackage.Manifest,
        payloads: [String: Data],
        signer: any PatchPackage.SignatureProviding
    ) throws -> Self {
        try manifest.validateStructure()
        try verifyPayloadDescriptors(manifest: manifest, payloads: payloads)
        let request = try PatchPackage.SigningRequest.make(manifest: manifest, payloads: payloads)
        let expectedCertificate = signer.certificate
        let envelope = try signer.sign(request)
        guard envelope.certificate == expectedCertificate,
              envelope.certificate.keyID == manifest.security.signerKeyID,
              envelope.schemaVersion == 1,
              envelope.algorithm == "ed25519"
        else {
            throw PatchPackage.Error.invalidSigningCertificate(
                "signature provider returned an unexpected certificate"
            )
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: envelope.certificate.publicKey)
        } catch {
            throw PatchPackage.Error.invalidSigningCertificate("invalid leaf public key")
        }
        guard publicKey.isValidSignature(
            envelope.signature,
            for: request.signatureMaterial
        ) else {
            throw PatchPackage.Error.invalidPackageSignature
        }
        return .init(manifest: manifest, payloads: payloads, signatureEnvelope: envelope)
    }

    /// Encodes this container using canonical manifest and envelope JSON.
    public func encoded() throws -> Data {
        try manifest.validateStructure()
        try verifyPayloadDescriptors()
        let manifestBytes = try Core.CanonicalJSON.encode(manifest)
        let signatureBytes = try Core.CanonicalJSON.encode(signatureEnvelope)
        guard manifestBytes.count <= Int(UInt32.max),
              signatureBytes.count <= Int(UInt32.max),
              payloads.count <= Int(UInt32.max)
        else {
            throw PatchPackage.Error.limitExceeded("container field does not fit its encoded width")
        }

        var writer = PatchPackage.BinaryWriter()
        writer.append(Self.magic)
        writer.append(Self.containerVersion)
        writer.append(UInt16(0))
        writer.append(UInt32(manifestBytes.count))
        writer.append(UInt32(payloads.count))
        writer.append(UInt32(signatureBytes.count))
        writer.append(UInt32(0))
        writer.append(manifestBytes)

        for path in payloads.keys.sorted() {
            guard let payload = payloads[path],
                  let pathBytes = path.data(using: .utf8),
                  pathBytes.count <= Int(UInt16.max)
            else {
                throw PatchPackage.Error.unsafePayloadPath(path)
            }
            writer.append(UInt16(pathBytes.count))
            writer.append(UInt16(0))
            writer.append(UInt64(payload.count))
            writer.append(Core.Digest.sha256(payload).data)
            writer.append(pathBytes)
            writer.append(payload)
        }
        writer.append(signatureBytes)
        return writer.data
    }

    /// Decodes an untrusted container under strict size and count limits.
    ///
    /// Decoding validates framing and canonical JSON but does not establish
    /// signing trust. Pass the original bytes to ``PatchPackage/Verifier``
    /// before activation.
    public static func decode(
        _ bytes: Data,
        limits: PatchPackage.DecodingLimits = .init()
    ) throws -> Self {
        guard bytes.count <= limits.maximumPackageBytes else {
            throw PatchPackage.Error.limitExceeded("package bytes")
        }
        var reader = PatchPackage.BinaryReader(bytes)
        guard try reader.read(Self.magic.count) == Self.magic else {
            throw PatchPackage.Error.malformedContainer("bad magic")
        }
        let version = try reader.readUInt16()
        guard version == Self.containerVersion else {
            throw PatchPackage.Error.malformedContainer("unsupported container version \(version)")
        }
        guard try reader.readUInt16() == 0 else {
            throw PatchPackage.Error.malformedContainer("nonzero header flags")
        }
        let manifestLength = Int(try reader.readUInt32())
        let payloadCount = Int(try reader.readUInt32())
        let signatureLength = Int(try reader.readUInt32())
        guard try reader.readUInt32() == 0 else {
            throw PatchPackage.Error.malformedContainer("nonzero reserved header field")
        }
        guard manifestLength <= limits.maximumManifestBytes else {
            throw PatchPackage.Error.limitExceeded("manifest bytes")
        }
        guard signatureLength <= limits.maximumSignatureBytes else {
            throw PatchPackage.Error.limitExceeded("signature bytes")
        }
        guard payloadCount <= limits.maximumPayloadCount else {
            throw PatchPackage.Error.limitExceeded("payload count")
        }

        let manifestBytes = try reader.read(manifestLength)
        try PatchPackage.ManifestSchema.rejectUnknownFields(in: manifestBytes)
        let manifest: PatchPackage.Manifest
        do {
            manifest = try JSONDecoder().decode(PatchPackage.Manifest.self, from: manifestBytes)
        } catch {
            throw PatchPackage.Error.malformedContainer("manifest decoding failed: \(error)")
        }
        try manifest.validateStructure()
        guard try Core.CanonicalJSON.encode(manifest) == manifestBytes else {
            throw PatchPackage.Error.nonCanonicalManifest
        }

        var payloads: [String: Data] = [:]
        var previousPath: String?
        for _ in 0..<payloadCount {
            let pathLength = Int(try reader.readUInt16())
            guard try reader.readUInt16() == 0 else {
                throw PatchPackage.Error.malformedContainer("nonzero payload flags")
            }
            let payloadLength64 = try reader.readUInt64()
            guard payloadLength64 <= UInt64(limits.maximumPayloadBytes),
                  payloadLength64 <= UInt64(Int.max)
            else {
                throw PatchPackage.Error.limitExceeded("payload bytes")
            }
            let expectedHash = try Core.Digest(bytes: reader.read(Core.Digest.byteCount))
            let pathData = try reader.read(pathLength)
            guard let path = String(data: pathData, encoding: .utf8),
                  PatchPackage.Manifest.isSafeRelativePath(path)
            else {
                throw PatchPackage.Error.unsafePayloadPath(String(decoding: pathData, as: UTF8.self))
            }
            guard previousPath.map({ $0 < path }) ?? true else {
                throw PatchPackage.Error.malformedContainer(
                    "payload table is not in canonical path order"
                )
            }
            previousPath = path
            let payload = try reader.read(Int(payloadLength64))
            guard expectedHash.constantTimeEquals(Core.Digest.sha256(payload)) else {
                throw PatchPackage.Error.payloadHashMismatch(path)
            }
            guard payloads.updateValue(payload, forKey: path) == nil else {
                throw PatchPackage.Error.duplicatePayload(path)
            }
        }

        let signatureBytes = try reader.read(signatureLength)
        guard reader.isAtEnd else {
            throw PatchPackage.Error.malformedContainer("trailing bytes")
        }
        try PatchPackage.SignatureSchema.rejectUnknownFields(in: signatureBytes)
        let envelope: PatchPackage.SignatureEnvelope
        do {
            envelope = try JSONDecoder().decode(PatchPackage.SignatureEnvelope.self, from: signatureBytes)
        } catch {
            throw PatchPackage.Error.malformedContainer("signature envelope decoding failed: \(error)")
        }
        guard try Core.CanonicalJSON.encode(envelope) == signatureBytes else {
            throw PatchPackage.Error.nonCanonicalSignatureEnvelope
        }

        let package = Self(manifest: manifest, payloads: payloads, signatureEnvelope: envelope)
        try package.verifyPayloadDescriptors()
        return package
    }

    /// Confirms every manifest payload descriptor matches the in-memory bytes.
    public func verifyPayloadDescriptors() throws {
        try Self.verifyPayloadDescriptors(manifest: manifest, payloads: payloads)
    }

    private static func verifyPayloadDescriptors(
        manifest: PatchPackage.Manifest,
        payloads: [String: Data]
    ) throws {
        let expectedPaths = Set(manifest.payloads.map(\.path))
        guard expectedPaths == Set(payloads.keys) else {
            if let missing = expectedPaths.subtracting(payloads.keys).sorted().first {
                throw PatchPackage.Error.missingPayload(missing)
            }
            throw PatchPackage.Error.invalidManifest("container has an undeclared payload")
        }
        for descriptor in manifest.payloads {
            guard let payload = payloads[descriptor.path] else {
                throw PatchPackage.Error.missingPayload(descriptor.path)
            }
            guard descriptor.byteLength == UInt64(payload.count) else {
                throw PatchPackage.Error.payloadLengthMismatch(descriptor.path)
            }
            guard descriptor.sha256.constantTimeEquals(.sha256(payload)) else {
                throw PatchPackage.Error.payloadHashMismatch(descriptor.path)
            }
        }
    }
}

private struct BinaryWriter {
    var data = Data()

    mutating func append(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}

private struct BinaryReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw PatchPackage.Error.malformedContainer("negative read")
        }
        let end = offset.addingReportingOverflow(count)
        guard !end.overflow, end.partialValue <= data.count else {
            throw PatchPackage.Error.malformedContainer("truncated data at offset \(offset)")
        }
        defer { offset = end.partialValue }
        return data.subdata(in: offset..<end.partialValue)
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try read(2)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try read(8)
        return bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }
}

private enum ManifestSchema {
    static func rejectUnknownFields(in data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw PatchPackage.Error.malformedContainer("manifest root is not an object")
        }
        try exactKeys(
            root,
            allowed: [
                "schemaVersion", "packageID", "campaignID", "revision", "createdAtUnixSeconds",
                "notBeforeUnixSeconds", "expiresAtUnixSeconds", "purpose", "incidentID",
                "ownerTeam", "distributionPolicy", "distributionPolicyApprovalID", "targets",
                "payloads", "rollout", "rollback", "security",
            ],
            context: "manifest"
        )
        for target in try arrayOfObjects(root["targets"], context: "targets") {
            try exactKeys(
                target,
                allowed: [
                    "bundleID", "marketingVersion", "buildNumber", "shellNamespaceID", "machOUUID",
                    "shellInterfaceHash", "nativeCapabilityManifestHash",
                    "architecture", "platform", "minimumOSVersion",
                    "maximumTestedOSVersion", "compatibility",
                ],
                context: "target"
            )
            try semanticVersion(target["minimumOSVersion"], context: "minimumOSVersion")
            try semanticVersion(target["maximumTestedOSVersion"], context: "maximumTestedOSVersion")
            guard let compatibility = target["compatibility"] as? [String: Any] else {
                throw PatchPackage.Error.malformedContainer("compatibility is not an object")
            }
            try exactKeys(
                compatibility,
                allowed: ["runtime", "bytecode", "interfaceArchive", "compilerFingerprint"],
                context: "compatibility"
            )
            try semanticVersion(compatibility["runtime"], context: "runtime")
            try semanticVersion(compatibility["bytecode"], context: "bytecode")
            try semanticVersion(compatibility["interfaceArchive"], context: "interfaceArchive")
        }
        for payload in try arrayOfObjects(root["payloads"], context: "payloads") {
            try exactKeys(
                payload,
                allowed: [
                    "backend", "targetIndex", "path", "byteLength", "sha256",
                    "changedFunctionKeys", "entryIndices", "capabilities", "quotas",
                ],
                context: "payload"
            )
            guard let quotas = payload["quotas"] as? [String: Any] else {
                throw PatchPackage.Error.malformedContainer("quotas is not an object")
            }
            try exactKeys(
                quotas,
                allowed: [
                    "instructionFuelPerEntry", "maxCallDepth", "maxFrameRegisters", "maxVMHeapBytes",
                    "maxNativeOwnedBytes", "maxNativeCallsPerEntry",
                    "maxWallTimeMainThreadMilliseconds", "maxWallTimeBackgroundMilliseconds",
                    "maxSuspendedFrames",
                ],
                context: "quotas"
            )
        }
        try nestedObject(
            root["rollout"],
            allowed: ["cohortSalt", "percentageBasisPoints", "installationAllowlist", "installationDenylist"],
            context: "rollout"
        )
        try nestedObject(
            root["rollback"],
            allowed: ["parentGenerationPackageHash", "mutuallyExclusivePackageIDs"],
            context: "rollback"
        )
        try nestedObject(
            root["security"],
            allowed: ["signerKeyID", "approvalPolicyID", "antiRollbackCounter", "emergencyPolicyEpoch"],
            context: "security"
        )
    }

    private static func semanticVersion(_ value: Any?, context: String) throws {
        try nestedObject(value, allowed: ["major", "minor", "patch"], context: context)
    }

    private static func nestedObject(_ value: Any?, allowed: Set<String>, context: String) throws {
        guard let object = value as? [String: Any] else {
            throw PatchPackage.Error.malformedContainer("\(context) is not an object")
        }
        try exactKeys(object, allowed: allowed, context: context)
    }

    private static func arrayOfObjects(_ value: Any?, context: String) throws -> [[String: Any]] {
        guard let objects = value as? [[String: Any]] else {
            throw PatchPackage.Error.malformedContainer("\(context) is not an object array")
        }
        return objects
    }

    private static func exactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw PatchPackage.Error.invalidManifest("unknown critical field \(context).\(unknown.sorted()[0])")
        }
    }
}

private enum SignatureSchema {
    static func rejectUnknownFields(in data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let certificate = root["certificate"] as? [String: Any]
        else {
            throw PatchPackage.Error.malformedContainer("signature envelope is not an object")
        }
        try exactKeys(
            root,
            allowed: ["schemaVersion", "algorithm", "certificate", "signature"],
            context: "signature"
        )
        try exactKeys(
            certificate,
            allowed: [
                "schemaVersion", "algorithm", "keyID", "issuerKeyID", "publicKey",
                "validFromUnixSeconds", "validUntilUnixSeconds", "allowedDistributionPolicies",
                "allowedBackends", "allowedBundleIDs", "maximumPayloadBytes", "issuerSignature",
            ],
            context: "certificate"
        )
    }

    private static func exactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw PatchPackage.Error.invalidManifest("unknown critical field \(context).\(unknown.sorted()[0])")
        }
    }
}
}
