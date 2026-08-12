import Foundation

public enum Pairing {}

extension Pairing {
/// A short, human-readable invitation code used only inside pinned TLS.
public struct Code: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Number of characters presented to the developer.
    public static let characterCount = 4
    /// Case-insensitive alphabet with visually ambiguous characters removed.
    public static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    /// Canonical uppercase code.
    public let rawValue: String

    /// Normalizes and validates a developer-entered code.
    public init(_ value: String) throws {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.count == Self.characterCount,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && Self.alphabet.unicodeScalars.contains(scalar)
              })
        else {
            throw DevProtocol.Error.invalidPairingCode
        }
        rawValue = normalized
    }

    /// Generates an unbiased code using the operating system random source.
    public static func random() throws -> Self {
        let alphabet = Array(Self.alphabet.utf8)
        precondition(alphabet.count == 31)
        let unbiasedUpperBound = UInt8.max - (UInt8.max % UInt8(alphabet.count))
        var result = [UInt8]()
        result.reserveCapacity(Self.characterCount)
        while result.count < Self.characterCount {
            for byte in try DevProtocol.SecureRandom.bytes(count: Self.characterCount * 2) {
                guard byte < unbiasedUpperBound else { continue }
                result.append(alphabet[Int(byte) % alphabet.count])
                if result.count == Self.characterCount { break }
            }
        }
        return try .init(String(decoding: result, as: UTF8.self))
    }

    /// Canonical user-facing representation.
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
}
