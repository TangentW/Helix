import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension InterfaceArchive {
public struct DecodingLimits: Hashable, Sendable {
    public var maximumFileBytes: Int
    public var maximumPayloadBytes: Int

    public init(
        maximumFileBytes: Int = 64 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 63 * 1_024 * 1_024
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

public struct DecodedArchive: Sendable {
    public var archive: InterfaceArchive.Archive
    public var archiveHash: Core.Digest
    public var payloadHash: Core.Digest
}

public enum Codec {
    public static let magic: [UInt8] = [0x48, 0x4c, 0x58, 0x49, 0x00, 0x0d, 0x0a, 0x1a]
    private static let headerSize = 8 + 2 + 2 + 8 + 32 + 32

    public static func encode(_ archive: InterfaceArchive.Archive) throws -> Data {
        var normalized = archive.normalized()
        normalized.shellInterfaceHash = try normalized.computeShellInterfaceHash()
        try normalized.validate()
        let payload = try Core.CanonicalJSON.encode(normalized)
        let payloadHash = Core.Digest.sha256(payload)
        var domainHasher = Core.StableHasher(domain: "HLXI.Container.v1")
        domainHasher.append(payload)
        let archiveHash = domainHasher.finalize()

        var output = Data(magic)
        output.appendLittleEndian(normalized.schemaVersion)
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt64(payload.count))
        output.append(payloadHash.data)
        output.append(archiveHash.data)
        output.append(payload)
        return output
    }

    public static func decode(
        _ data: Data,
        limits: InterfaceArchive.DecodingLimits = .init()
    ) throws -> InterfaceArchive.DecodedArchive {
        guard data.count <= limits.maximumFileBytes else {
            throw InterfaceArchive.Error.fileTooLarge(actual: data.count, maximum: limits.maximumFileBytes)
        }
        guard data.count >= headerSize else { throw InterfaceArchive.Error.truncated }
        guard Array(data.prefix(magic.count)) == magic else { throw InterfaceArchive.Error.invalidMagic }
        var cursor = magic.count
        let schema: UInt16 = try data.readLittleEndian(at: &cursor)
        guard schema == InterfaceArchive.Archive.currentSchemaVersion else {
            throw InterfaceArchive.Error.unsupportedSchema(schema)
        }
        let flags: UInt16 = try data.readLittleEndian(at: &cursor)
        guard flags == 0 else { throw InterfaceArchive.Error.unsupportedFlags(flags) }
        let payloadLength: UInt64 = try data.readLittleEndian(at: &cursor)
        guard payloadLength <= UInt64(limits.maximumPayloadBytes),
              payloadLength <= UInt64(Int.max)
        else {
            throw InterfaceArchive.Error.fileTooLarge(
                actual: payloadLength > UInt64(Int.max) ? Int.max : Int(payloadLength),
                maximum: limits.maximumPayloadBytes
            )
        }
        let payloadHash = try Core.Digest(bytes: try data.read(count: 32, at: &cursor))
        let archiveHash = try Core.Digest(bytes: try data.read(count: 32, at: &cursor))
        guard data.count == headerSize + Int(payloadLength) else {
            if data.count < headerSize + Int(payloadLength) { throw InterfaceArchive.Error.truncated }
            throw InterfaceArchive.Error.trailingBytes
        }
        let payload = data.subdata(in: cursor..<data.count)
        guard payloadHash.constantTimeEquals(.sha256(payload)) else {
            throw InterfaceArchive.Error.payloadHashMismatch
        }
        var domainHasher = Core.StableHasher(domain: "HLXI.Container.v1")
        domainHasher.append(payload)
        guard archiveHash.constantTimeEquals(domainHasher.finalize()) else {
            throw InterfaceArchive.Error.archiveHashMismatch
        }
        let archive: InterfaceArchive.Archive
        do {
            archive = try JSONDecoder().decode(InterfaceArchive.Archive.self, from: payload)
        } catch {
            throw InterfaceArchive.Error.malformedPayload(String(describing: error))
        }
        guard try Core.CanonicalJSON.encode(archive) == payload else {
            throw InterfaceArchive.Error.nonCanonicalPayload
        }
        guard archive.schemaVersion == schema else {
            throw InterfaceArchive.Error.invalidArchive(
                "container and payload schema versions differ"
            )
        }
        try archive.validate()
        return .init(archive: archive, archiveHash: archiveHash, payloadHash: payloadHash)
    }
}
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func read(count: Int, at cursor: inout Int) throws -> Data {
        guard count >= 0, cursor >= 0, cursor <= self.count,
              count <= self.count - cursor
        else { throw InterfaceArchive.Error.truncated }
        defer { cursor += count }
        return subdata(in: cursor..<(cursor + count))
    }

    func readLittleEndian<T: FixedWidthInteger>(at cursor: inout Int) throws -> T {
        let bytes = try read(count: MemoryLayout<T>.size, at: &cursor)
        var value: T = 0
        for (offset, byte) in bytes.enumerated() {
            value |= T(byte) << T(offset * 8)
        }
        return value
    }
}
