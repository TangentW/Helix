import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode {
public enum SectionKind: UInt32, Codable, Hashable, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case strings = 0x5354_5253 // STRS
    case types = 0x5459_5045 // TYPE
    case imports = 0x494d_5054 // IMPT
    case constants = 0x434e_5354 // CNST
    case functions = 0x4655_4e43 // FUNC
    case code = 0x434f_4445 // CODE
    case cleanup = 0x434c_4e50 // CLNP
    case debug = 0x4442_5547 // DBUG
    case metadata = 0x4d45_5441 // META

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        let bytes: [UInt8] = [
            UInt8((rawValue >> 24) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8(rawValue & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct Header: Hashable, Sendable {
    public static let byteCount = 92
    public static let imageHashRange = 48..<80

    public var formatMajor: UInt16
    public var formatMinor: UInt16
    public var minimumRuntimeMajor: UInt16
    public var flags: UInt16
    public var shellInterfaceHash: Core.Digest
    public var imageHash: Core.Digest
    public var sectionCount: UInt32
    public var sectionTableOffset: UInt64
}

public struct SectionEntry: Hashable, Sendable {
    public static let byteCount = 64

    public var kind: Bytecode.SectionKind
    public var flags: UInt32
    public var offset: UInt64
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var sha256: Core.Digest
}

public struct DecodedContainer: Sendable {
    public var header: Bytecode.Header
    public var sections: [Bytecode.SectionKind: Data]
    public var module: Bytecode.Module
}

public struct DecodingLimits: Sendable, Hashable {
    public var maximumFileBytes: Int
    public var maximumSectionCount: Int
    public var maximumSectionBytes: Int

    public init(
        maximumFileBytes: Int = 64 * 1_024 * 1_024,
        maximumSectionCount: Int = 32,
        maximumSectionBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumSectionCount = maximumSectionCount
        self.maximumSectionBytes = maximumSectionBytes
    }
}

public enum CodecError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileTooLarge(actual: Int, maximum: Int)
    case truncated(offset: Int, requested: Int, available: Int)
    case invalidMagic
    case unsupportedFormat(major: UInt16, minor: UInt16)
    case invalidHeader(String)
    case tooManySections(actual: Int, maximum: Int)
    case unknownSection(UInt32)
    case duplicateSection(Bytecode.SectionKind)
    case unsupportedSectionFlags(kind: Bytecode.SectionKind, flags: UInt32)
    case invalidSectionRange(Bytecode.SectionKind)
    case overlappingSections(Bytecode.SectionKind, Bytecode.SectionKind)
    case sectionTooLarge(kind: Bytecode.SectionKind, actual: Int, maximum: Int)
    case sectionHashMismatch(Bytecode.SectionKind)
    case imageHashMismatch
    case missingSection(Bytecode.SectionKind)
    case malformedSection(kind: Bytecode.SectionKind, reason: String)
    case malformedFunctionLayout(String)

    public var description: String {
        switch self {
        case let .fileTooLarge(actual, maximum): "HLBC file is \(actual) bytes; maximum is \(maximum)"
        case let .truncated(offset, requested, available):
            "HLBC truncated at \(offset): requested \(requested) bytes, \(available) available"
        case .invalidMagic: "invalid HLBC magic"
        case let .unsupportedFormat(major, minor): "unsupported HLBC format \(major).\(minor)"
        case let .invalidHeader(reason): "invalid HLBC header: \(reason)"
        case let .tooManySections(actual, maximum): "HLBC has \(actual) sections; maximum is \(maximum)"
        case let .unknownSection(raw): "unknown HLBC section FourCC 0x\(String(raw, radix: 16))"
        case let .duplicateSection(kind): "duplicate HLBC \(kind) section"
        case let .unsupportedSectionFlags(kind, flags): "unsupported flags 0x\(String(flags, radix: 16)) for \(kind)"
        case let .invalidSectionRange(kind): "invalid byte range for HLBC \(kind) section"
        case let .overlappingSections(lhs, rhs): "HLBC sections \(lhs) and \(rhs) overlap"
        case let .sectionTooLarge(kind, actual, maximum):
            "HLBC \(kind) section is \(actual) bytes; maximum is \(maximum)"
        case let .sectionHashMismatch(kind): "HLBC \(kind) section hash mismatch"
        case .imageHashMismatch: "HLBC image hash mismatch"
        case let .missingSection(kind): "required HLBC \(kind) section is missing"
        case let .malformedSection(kind, reason): "malformed HLBC \(kind) section: \(reason)"
        case let .malformedFunctionLayout(reason): "malformed HLBC function layout: \(reason)"
        }
    }
}

struct BinaryWriter {
    var data = Data()

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }
}

struct BinaryReader {
    let data: Data
    var offset: Int = 0

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        let bytes = try readData(count: size)
        return bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: T.self).littleEndian
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw Bytecode.CodecError.truncated(
                offset: offset,
                requested: count,
                available: max(0, data.count - offset)
            )
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
}
