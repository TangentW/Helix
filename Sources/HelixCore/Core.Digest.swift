import CryptoKit
import Foundation

public enum Core {}

extension Core {
/// A stable SHA-256 digest used by every persisted Helix identity.
public struct Digest: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let byteCount = 32

    private let storage: Data

    private init(sha256Digest: SHA256.Digest) {
        storage = Data(sha256Digest)
    }

    public init(bytes: some Sequence<UInt8>) throws {
        let data = Data(bytes)
        guard data.count == Self.byteCount else {
            throw Core.Error.invalidDigestLength(actual: data.count)
        }
        storage = data
    }

    public init(hex: String) throws {
        guard hex.utf8.count == Self.byteCount * 2 else {
            throw Core.Error.invalidDigestHex(hex)
        }
        var output = Data(capacity: Self.byteCount)
        var index = hex.startIndex
        for _ in 0..<Self.byteCount {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw Core.Error.invalidDigestHex(hex)
            }
            output.append(byte)
            index = next
        }
        storage = output
    }

    public static func sha256(_ data: Data) -> Self {
        Self(sha256Digest: SHA256.hash(data: data))
    }

    public static func sha256(_ text: String) -> Self {
        sha256(Data(text.utf8))
    }

    public var bytes: [UInt8] { Array(storage) }
    public var data: Data { storage }
    public var hex: String { storage.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.storage.lexicographicallyPrecedes(rhs.storage)
    }

    public func constantTimeEquals(_ other: Self) -> Bool {
        zip(storage, other.storage).reduce(UInt8(0)) { result, pair in
            result | (pair.0 ^ pair.1)
        } == 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(hex: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Length-prefixes every component so concatenation can never be ambiguous.
public struct StableHasher: Sendable {
    private var data = Data()

    public init(domain: String) {
        appendRaw(Data(domain.utf8))
    }

    public mutating func append(_ value: String) {
        appendRaw(Data(value.utf8))
    }

    public mutating func append(_ value: Data) {
        appendRaw(value)
    }

    public mutating func append(_ value: Core.Digest) {
        appendRaw(value.data)
    }

    public mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { appendRaw(Data($0)) }
    }

    public func finalize() -> Core.Digest {
        .sha256(data)
    }

    private mutating func appendRaw(_ component: Data) {
        precondition(component.count <= Int(UInt32.max), "identity component is too large")
        var length = UInt32(component.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(component)
    }
}
}
