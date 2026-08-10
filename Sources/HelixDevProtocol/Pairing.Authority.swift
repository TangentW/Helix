import CryptoKit
import Foundation
import Security
import HelixCore

public enum Pairing {}

extension DevProtocol {
public enum SecureRandom {
    public static func bytes(count: Int) throws -> Data {
        guard count > 0, count <= 4_096 else {
            throw DevProtocol.Error.secureRandomFailed
        }
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard status == errSecSuccess else {
            throw DevProtocol.Error.secureRandomFailed
        }
        return bytes
    }
}
}

extension Pairing {
public struct Token: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16
    private let bytes: Data

    public init(code: String) throws {
        let normalized = code
            .lowercased()
            .filter { $0 != "-" && !$0.isWhitespace }
        guard normalized.utf8.count == Self.byteCount * 2 else {
            throw DevProtocol.Error.invalidPairingCode
        }
        var value = Data(capacity: Self.byteCount)
        var index = normalized.startIndex
        for _ in 0..<Self.byteCount {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw DevProtocol.Error.invalidPairingCode
            }
            value.append(byte)
            index = next
        }
        bytes = value
    }

    fileprivate init(randomBytes: Data) {
        precondition(randomBytes.count == Self.byteCount)
        bytes = randomBytes
    }

    public var code: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(4, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: "-")
    }

    public var description: String { code }

    public func deriveSessionSecret(
        clientNonce: Data,
        serverNonce: Data,
        tlsTranscriptHash: Core.Digest
    ) throws -> Data {
        guard (16...64).contains(clientNonce.count),
              (16...64).contains(serverNonce.count)
        else {
            throw DevProtocol.Error.invalidNonceLength
        }
        var infoHasher = Core.StableHasher(domain: "HLX.PairingSession.v1")
        infoHasher.append(clientNonce)
        infoHasher.append(serverNonce)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: tlsTranscriptHash.data,
            info: infoHasher.finalize().data,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    fileprivate var digest: Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.PairingToken.v1")
        hasher.append(bytes)
        return hasher.finalize()
    }
}

public actor Authority {
    private struct ActiveToken {
        var digest: Core.Digest
        var expiresAt: Date
        var failedAttempts: Int
    }

    public var tokenLifetime: TimeInterval
    public var maximumFailedAttempts: Int
    private var active: ActiveToken?

    public init(
        tokenLifetime: TimeInterval = 120,
        maximumFailedAttempts: Int = 5
    ) {
        self.tokenLifetime = tokenLifetime
        self.maximumFailedAttempts = maximumFailedAttempts
    }

    public func issue(now: Date = Date()) throws -> Pairing.Token {
        guard tokenLifetime.isFinite, tokenLifetime > 0,
              maximumFailedAttempts > 0
        else {
            throw DevProtocol.Error.pairingRejected
        }
        let bytes = try DevProtocol.SecureRandom.bytes(count: Pairing.Token.byteCount)
        let token = Pairing.Token(randomBytes: bytes)
        active = .init(
            digest: token.digest,
            expiresAt: now.addingTimeInterval(tokenLifetime),
            failedAttempts: 0
        )
        return token
    }

    public func redeem(
        code: String,
        clientNonce: Data,
        serverNonce: Data,
        tlsTranscriptHash: Core.Digest,
        now: Date = Date()
    ) throws -> Data {
        guard var active else { throw DevProtocol.Error.pairingRejected }
        guard now <= active.expiresAt else {
            self.active = nil
            throw DevProtocol.Error.pairingExpired
        }
        let submitted: Pairing.Token
        do {
            submitted = try .init(code: code)
        } catch {
            active.failedAttempts += 1
            self.active = active.failedAttempts >= maximumFailedAttempts ? nil : active
            throw DevProtocol.Error.pairingRejected
        }
        guard submitted.digest.constantTimeEquals(active.digest) else {
            active.failedAttempts += 1
            self.active = active.failedAttempts >= maximumFailedAttempts ? nil : active
            throw DevProtocol.Error.pairingRejected
        }
        // Consume before deriving so no concurrent caller can redeem twice.
        self.active = nil
        return try submitted.deriveSessionSecret(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            tlsTranscriptHash: tlsTranscriptHash
        )
    }

    public func invalidate() {
        active = nil
    }
}
}
