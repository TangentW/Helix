import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension DevProtocol {
public struct LiveArtifact: Sendable {
    public static let magic = Data([0x48, 0x4c, 0x58, 0x4c, 0x49, 0x56, 0x45, 0x1a])
    public static let version: UInt16 = 1

    public var offer: DevProtocol.PatchOffer
    public var payload: Data

    public init(offer: DevProtocol.PatchOffer, payload: Data) {
        self.offer = offer
        self.payload = payload
    }

    public func encoded(
        sessionSecret: Data,
        maximumManifestBytes: Int = 2 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024
    ) throws -> Data {
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard maximumManifestBytes > 0, maximumPayloadBytes > 0 else {
            throw DevProtocol.Error.frameTooLarge
        }
        try offer.validate()
        guard offer.payloadByteLength == UInt64(payload.count),
              offer.payloadSHA256.constantTimeEquals(.sha256(payload)),
              payload.count <= maximumPayloadBytes
        else {
            throw DevProtocol.Error.invalidArtifact("payload descriptor mismatch")
        }
        let manifest = try Core.CanonicalJSON.encode(offer)
        guard manifest.count <= maximumManifestBytes,
              manifest.count <= Int(UInt32.max)
        else {
            throw DevProtocol.Error.frameTooLarge
        }
        let authenticated = Self.authenticationMaterial(
            manifest: manifest,
            payload: payload
        )
        let tag = DevProtocol.FrameCodec.authenticationTag(
            domain: "HLX.LiveArtifact.v1",
            body: authenticated,
            secret: sessionSecret
        )

        var bytes = Data()
        bytes.append(Self.magic)
        bytes.append(UInt8(truncatingIfNeeded: Self.version))
        bytes.append(UInt8(truncatingIfNeeded: Self.version >> 8))
        DevProtocol.FrameCodec.append(UInt32(manifest.count), to: &bytes)
        DevProtocol.FrameCodec.append(UInt64(payload.count), to: &bytes)
        bytes.append(tag)
        bytes.append(manifest)
        bytes.append(payload)
        return bytes
    }

    public static func decode(
        _ bytes: Data,
        sessionSecret: Data,
        maximumManifestBytes: Int = 2 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024
    ) throws -> Self {
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard maximumManifestBytes > 0, maximumPayloadBytes > 0 else {
            throw DevProtocol.Error.frameTooLarge
        }
        let headerLength = 8 + 2 + 4 + 8 + 32
        guard bytes.count >= headerLength else {
            throw DevProtocol.Error.invalidArtifact("truncated header")
        }
        guard bytes.prefix(8) == Self.magic else {
            throw DevProtocol.Error.invalidArtifact("bad magic")
        }
        let version = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
        guard version == Self.version else {
            throw DevProtocol.Error.invalidArtifact("unsupported version \(version)")
        }
        let manifestLength = Int(DevProtocol.FrameCodec.readUInt32(bytes[10..<14]))
        let payloadLength64 = DevProtocol.FrameCodec.readUInt64(bytes[14..<22])
        guard manifestLength <= maximumManifestBytes,
              payloadLength64 <= UInt64(maximumPayloadBytes),
              payloadLength64 <= UInt64(Int.max)
        else {
            throw DevProtocol.Error.frameTooLarge
        }
        let payloadLength = Int(payloadLength64)
        let total = headerLength.addingReportingOverflow(manifestLength)
        guard !total.overflow else { throw DevProtocol.Error.frameTooLarge }
        let final = total.partialValue.addingReportingOverflow(payloadLength)
        guard !final.overflow, final.partialValue == bytes.count else {
            throw DevProtocol.Error.invalidArtifact("length mismatch")
        }
        let tag = bytes[22..<54]
        let manifestStart = headerLength
        let manifestEnd = manifestStart + manifestLength
        let manifest = bytes.subdata(in: manifestStart..<manifestEnd)
        let payload = bytes.subdata(in: manifestEnd..<bytes.count)
        let authenticated = Self.authenticationMaterial(
            manifest: manifest,
            payload: payload
        )
        let expectedTag = DevProtocol.FrameCodec.authenticationTag(
            domain: "HLX.LiveArtifact.v1",
            body: authenticated,
            secret: sessionSecret
        )
        guard DevProtocol.FrameCodec.constantTimeEqual(tag, expectedTag) else {
            throw DevProtocol.Error.invalidAuthentication
        }
        let offer: DevProtocol.PatchOffer
        do {
            offer = try JSONDecoder().decode(DevProtocol.PatchOffer.self, from: manifest)
        } catch {
            throw DevProtocol.Error.invalidArtifact("manifest decoding failed")
        }
        guard try Core.CanonicalJSON.encode(offer) == manifest else {
            throw DevProtocol.Error.nonCanonicalMessage
        }
        try offer.validate()
        guard offer.payloadByteLength == UInt64(payload.count),
              offer.payloadSHA256.constantTimeEquals(.sha256(payload))
        else {
            throw DevProtocol.Error.invalidArtifact("payload hash mismatch")
        }
        return .init(offer: offer, payload: payload)
    }

    private static func authenticationMaterial(manifest: Data, payload: Data) -> Data {
        var bytes = Data()
        bytes.append(Self.magic)
        bytes.append(UInt8(truncatingIfNeeded: Self.version))
        bytes.append(UInt8(truncatingIfNeeded: Self.version >> 8))
        DevProtocol.FrameCodec.append(UInt32(manifest.count), to: &bytes)
        DevProtocol.FrameCodec.append(UInt64(payload.count), to: &bytes)
        bytes.append(manifest)
        bytes.append(payload)
        return bytes
    }
}
}
