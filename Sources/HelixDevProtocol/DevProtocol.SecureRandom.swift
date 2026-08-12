import Foundation
import Security

extension DevProtocol {
/// Bounded cryptographic random-byte source shared by Dev Protocol peers.
public enum SecureRandom {
    /// Returns bytes from Swift's operating-system-backed random generator.
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
