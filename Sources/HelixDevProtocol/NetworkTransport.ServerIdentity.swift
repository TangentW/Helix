#if canImport(Security)
import CryptoKit
import Foundation
import Security
import HelixCore

extension NetworkTransport {
/// TLS identity whose public-key pin can remain stable across certificates.
public final class ServerIdentity: @unchecked Sendable {
    /// Security identity supplied to Network.framework's TLS listener.
    public let identity: SecIdentity
    /// Self-signed certificate associated with ``identity``.
    public let certificate: SecCertificate
    /// SHA-256 digest of the certificate's SubjectPublicKeyInfo.
    public let spkiHash: Core.Digest
    /// Certificate expiry. The host key and SPKI pin may outlive this value.
    public let validUntil: Date

    fileprivate init(
        identity: SecIdentity,
        certificate: SecCertificate,
        spkiHash: Core.Digest,
        validUntil: Date
    ) {
        self.identity = identity
        self.certificate = certificate
        self.spkiHash = spkiHash
        self.validUntil = validUntil
    }
}

public enum IdentityFactory {
    /// Creates a TLS identity from a new or previously persisted P-256 key.
    public static func makeServerIdentity(
        privateKeyRawRepresentation: Data? = nil,
        now: Date = Date(),
        lifetime: TimeInterval = 30 * 24 * 60 * 60
    ) throws -> NetworkTransport.ServerIdentity {
        guard lifetime.isFinite, (60...366 * 24 * 60 * 60).contains(lifetime) else {
            throw NetworkTransport.Error.identityGenerationFailed(
                "certificate lifetime must be between one minute and 366 days"
            )
        }
        // CryptoKit keeps generation in-process. Importing its X9.63 representation
        // also avoids SecKeyCreateRandomKey attempting unsupported token-backed paths
        // on some macOS hosts.
        let signingKey: P256.Signing.PrivateKey
        do {
            if let privateKeyRawRepresentation {
                signingKey = try .init(rawRepresentation: privateKeyRawRepresentation)
            } else {
                signingKey = .init()
            }
        } catch {
            throw NetworkTransport.Error.identityGenerationFailed(
                "stored P-256 private key is invalid"
            )
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            signingKey.x963Representation as CFData,
            attributes as CFDictionary,
            &keyError
        ),
              let publicKey = SecKeyCopyPublicKey(privateKey)
        else {
            throw failure(keyError?.takeRetainedValue())
        }
        var representationError: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(
            publicKey,
            &representationError
        ) as Data? else {
            throw failure(representationError?.takeRetainedValue())
        }
        guard publicBytes.count == 65, publicBytes.first == 0x04 else {
            throw NetworkTransport.Error.identityGenerationFailed(
                "P-256 public key is not an uncompressed X9.63 point"
            )
        }

        let validFrom = now.addingTimeInterval(-60)
        let validUntil = now.addingTimeInterval(lifetime)
        let serial = try DevProtocol.SecureRandom.bytes(count: 16)
        let commonName = "Helix"
        let tbs = CertificateDER.tbsCertificate(
            serial: serial,
            commonName: commonName,
            publicKey: publicBytes,
            validFrom: validFrom,
            validUntil: validUntil
        )
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &signingError
        ) as Data? else {
            throw failure(signingError?.takeRetainedValue())
        }
        let certificateBytes = CertificateDER.sequence(
            tbs
                + CertificateDER.ecdsaSHA256Algorithm
                + CertificateDER.bitString(signature)
        )
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateBytes as CFData
        ), let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw NetworkTransport.Error.identityGenerationFailed(
                "Security rejected the generated X.509 certificate"
            )
        }
        return try .init(
            identity: identity,
            certificate: certificate,
            spkiHash: NetworkTransport.SPKIPin.hash(certificate: certificate),
            validUntil: validUntil
        )
    }

    private static func failure(_ error: CFError?) -> NetworkTransport.Error {
        .identityGenerationFailed(error.map(String.init(describing:)) ?? "Security failed")
    }
}
}

private enum CertificateDER {
    static let ecdsaSHA256Algorithm = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))

    static func tbsCertificate(
        serial: Data,
        commonName: String,
        publicKey: Data,
        validFrom: Date,
        validUntil: Date
    ) -> Data {
        let name = sequence(
            set(sequence(oid([2, 5, 4, 3]) + value(tag: 0x0c, Data(commonName.utf8))))
        )
        let validity = sequence(time(validFrom) + time(validUntil))
        let publicKeyInfo = sequence(
            sequence(
                oid([1, 2, 840, 10045, 2, 1])
                    + oid([1, 2, 840, 10045, 3, 1, 7])
            ) + bitString(publicKey)
        )
        let extensions = value(
            tag: 0xa3,
            sequence(
                extensionValue(
                    oid: [2, 5, 29, 19],
                    critical: true,
                    contents: sequence(Data())
                )
                + extensionValue(
                    oid: [2, 5, 29, 15],
                    critical: true,
                    contents: value(tag: 0x03, Data([0x07, 0x80]))
                )
                + extensionValue(
                    oid: [2, 5, 29, 37],
                    critical: false,
                    contents: sequence(oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))
                )
                + extensionValue(
                    oid: [2, 5, 29, 17],
                    critical: false,
                    contents: sequence(
                        value(tag: 0x82, Data("localhost".utf8))
                            + value(tag: 0x87, Data([127, 0, 0, 1]))
                            + value(
                                tag: 0x87,
                                Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
                            )
                    )
                )
            )
        )
        return sequence(
            value(tag: 0xa0, integer(Data([2])))
                + integer(positiveInteger(serial))
                + ecdsaSHA256Algorithm
                + name
                + validity
                + name
                + publicKeyInfo
                + extensions
        )
    }

    static func sequence(_ contents: Data) -> Data { value(tag: 0x30, contents) }
    static func set(_ contents: Data) -> Data { value(tag: 0x31, contents) }
    static func integer(_ contents: Data) -> Data { value(tag: 0x02, contents) }

    static func bitString(_ contents: Data) -> Data {
        value(tag: 0x03, Data([0]) + contents)
    }

    static func value(tag: UInt8, _ contents: Data) -> Data {
        Data([tag]) + length(contents.count) + contents
    }

    static func extensionValue(
        oid arcs: [UInt64],
        critical: Bool,
        contents: Data
    ) -> Data {
        sequence(
            oid(arcs)
                + (critical ? value(tag: 0x01, Data([0xff])) : Data())
                + value(tag: 0x04, contents)
        )
    }

    static func oid(_ arcs: [UInt64]) -> Data {
        precondition(arcs.count >= 2 && arcs[0] <= 2 && arcs[1] <= 39)
        var bytes = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var encoded = [UInt8(arc & 0x7f)]
            var value = arc >> 7
            while value > 0 {
                encoded.append(UInt8(value & 0x7f) | 0x80)
                value >>= 7
            }
            bytes.append(contentsOf: encoded.reversed())
        }
        return value(tag: 0x06, bytes)
    }

    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return value(tag: 0x18, Data(formatter.string(from: date).utf8))
    }

    static func positiveInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([1]) }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: 0) }
        return value
    }

    static func length(_ count: Int) -> Data {
        precondition(count >= 0)
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes.reversed())
    }
}
#endif
