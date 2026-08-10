import CryptoKit
import Foundation
import HelixCore

extension DevProtocol {
public struct FrameCodec: Sendable {
    public var maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = 2 * 1_024 * 1_024) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    public func encode(
        _ message: DevProtocol.Message,
        sessionSecret: Data
    ) throws -> Data {
        try Self.validateSecret(sessionSecret)
        guard maximumMessageBytes > 0 else { throw DevProtocol.Error.frameTooLarge }
        try message.validate()
        let messageBytes = try Core.CanonicalJSON.encode(message)
        guard messageBytes.count <= maximumMessageBytes,
              messageBytes.count <= Int(UInt32.max)
        else {
            throw DevProtocol.Error.frameTooLarge
        }
        let tag = Self.authenticationTag(
            domain: "HLX.DevFrame.v1",
            body: messageBytes,
            secret: sessionSecret
        )
        var bytes = Data()
        Self.append(UInt32(messageBytes.count), to: &bytes)
        bytes.append(messageBytes)
        bytes.append(tag)
        return bytes
    }

    public func decode(
        _ frame: Data,
        sessionSecret: Data
    ) throws -> DevProtocol.Message {
        try Self.validateSecret(sessionSecret)
        guard maximumMessageBytes > 0 else { throw DevProtocol.Error.frameTooLarge }
        guard frame.count >= 4 + 32 else { throw DevProtocol.Error.truncatedFrame }
        let length = Int(Self.readUInt32(frame.prefix(4)))
        guard length <= maximumMessageBytes else { throw DevProtocol.Error.frameTooLarge }
        guard frame.count == 4 + length + 32 else {
            throw DevProtocol.Error.truncatedFrame
        }
        let body = frame.subdata(in: 4..<(4 + length))
        let receivedTag = frame.suffix(32)
        let expectedTag = Self.authenticationTag(
            domain: "HLX.DevFrame.v1",
            body: body,
            secret: sessionSecret
        )
        guard Self.constantTimeEqual(receivedTag, expectedTag) else {
            throw DevProtocol.Error.invalidAuthentication
        }
        let message: DevProtocol.Message
        do {
            message = try JSONDecoder().decode(DevProtocol.Message.self, from: body)
        } catch {
            throw DevProtocol.Error.malformedMessage(String(describing: error))
        }
        guard try Core.CanonicalJSON.encode(message) == body else {
            throw DevProtocol.Error.nonCanonicalMessage
        }
        try message.validate()
        return message
    }

    static func authenticationTag(domain: String, body: Data, secret: Data) -> Data {
        var hasher = Core.StableHasher(domain: domain)
        hasher.append(body)
        let digest = hasher.finalize().data
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(for: digest, using: key))
    }

    public static func validateSecret(_ secret: Data) throws {
        guard (32...4_096).contains(secret.count) else {
            throw DevProtocol.Error.invalidSecretLength
        }
    }

    static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    static func readUInt32(_ data: Data.SubSequence) -> UInt32 {
        data.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    static func readUInt64(_ data: Data.SubSequence) -> UInt64 {
        data.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    static func constantTimeEqual<C1: Collection, C2: Collection>(
        _ lhs: C1,
        _ rhs: C2
    ) -> Bool where C1.Element == UInt8, C2.Element == UInt8 {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum Handshake {
    public static func proof(
        sessionSecret: Data,
        clientNonce: Data,
        serverNonce: Data,
        identity: DevProtocol.SessionIdentity,
        tlsTranscriptHash: Core.Digest
    ) throws -> Data {
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        guard (16...64).contains(clientNonce.count),
              (16...64).contains(serverNonce.count)
        else {
            throw DevProtocol.Error.invalidNonceLength
        }
        var hasher = Core.StableHasher(domain: "HLX.DevHandshake.v1")
        hasher.append(clientNonce)
        hasher.append(serverNonce)
        hasher.append(try Core.CanonicalJSON.encode(identity))
        hasher.append(tlsTranscriptHash)
        return DevProtocol.FrameCodec.authenticationTag(
            domain: "HLX.DevHandshakeProof.v1",
            body: hasher.finalize().data,
            secret: sessionSecret
        )
    }

    public static func verify(
        proof: Data,
        sessionSecret: Data,
        clientNonce: Data,
        serverNonce: Data,
        identity: DevProtocol.SessionIdentity,
        tlsTranscriptHash: Core.Digest
    ) throws -> Bool {
        let expected = try self.proof(
            sessionSecret: sessionSecret,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            identity: identity,
            tlsTranscriptHash: tlsTranscriptHash
        )
        return DevProtocol.FrameCodec.constantTimeEqual(proof, expected)
    }
}
}
