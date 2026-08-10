import Foundation

public enum MachO {}

extension MachO {
public enum Architecture: String, Codable, Hashable, Sendable {
    case arm64
    case x86_64
}

public enum Platform: UInt32, Codable, Hashable, Sendable {
    case macOS = 1
    case iOS = 2
    case iOSSimulator = 7
}

public struct Descriptor: Codable, Hashable, Sendable {
    public var architecture: MachO.Architecture
    public var fileType: UInt32
    public var uuid: UUID?
    public var installName: String?
    public var dependencies: [String]
    public var platform: MachO.Platform?
    public var hasWritableExecutableSegment: Bool
    public var codeSignature: MachO.CodeSignature?

    public var isDynamicLibrary: Bool { fileType == 6 }
    public var isCodeSigned: Bool { codeSignature != nil }
}

public struct CodeSignature: Codable, Hashable, Sendable {
    public var dataOffset: UInt32
    public var dataSize: UInt32

    public init(dataOffset: UInt32, dataSize: UInt32) {
        self.dataOffset = dataOffset
        self.dataSize = dataSize
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case truncated
    case unsupportedMagic(UInt32)
    case unsupportedArchitecture(Int32)
    case invalidLoadCommands
    case unsafeSegment
    case notDynamicLibrary
    case architectureMismatch(expected: MachO.Architecture, actual: MachO.Architecture)
    case platformMismatch(expected: MachO.Platform, actual: MachO.Platform?)
    case dependencyDenied(String)
    case installNameMismatch

    public var description: String {
        switch self {
        case .truncated: "truncated Mach-O"
        case let .unsupportedMagic(magic): "unsupported Mach-O magic \(String(magic, radix: 16))"
        case let .unsupportedArchitecture(cpu): "unsupported Mach-O CPU type \(cpu)"
        case .invalidLoadCommands: "invalid Mach-O load commands"
        case .unsafeSegment: "Mach-O contains a writable and executable segment"
        case .notDynamicLibrary: "Mach-O is not a dynamic library"
        case let .architectureMismatch(expected, actual):
            "Mach-O architecture mismatch; expected \(expected.rawValue), got \(actual.rawValue)"
        case let .platformMismatch(expected, actual):
            "Mach-O platform mismatch; expected \(expected), got \(String(describing: actual))"
        case let .dependencyDenied(name): "Mach-O dependency is not allowlisted: \(name)"
        case .installNameMismatch: "Mach-O install name does not match the generation manifest"
        }
    }
}

public struct Inspector: Sendable {
    public init() {}

    public func inspect(_ data: Data) throws -> MachO.Descriptor {
        guard data.count >= 32 else { throw MachO.Error.truncated }
        let magic = readUInt32(data, 0)
        guard magic == 0xfeedfacf else { throw MachO.Error.unsupportedMagic(magic) }
        let cpu = Int32(bitPattern: readUInt32(data, 4))
        let architecture: MachO.Architecture
        switch UInt32(bitPattern: cpu) {
        case 0x0100000c: architecture = .arm64
        case 0x01000007: architecture = .x86_64
        default: throw MachO.Error.unsupportedArchitecture(cpu)
        }
        let fileType = readUInt32(data, 12)
        let commandCount = Int(readUInt32(data, 16))
        let commandBytes = Int(readUInt32(data, 20))
        let commandEnd = 32.addingReportingOverflow(commandBytes)
        guard commandCount <= 16_384,
              !commandEnd.overflow,
              commandEnd.partialValue <= data.count
        else {
            throw MachO.Error.invalidLoadCommands
        }

        var offset = 32
        var uuid: UUID?
        var installName: String?
        var dependencies: [String] = []
        var platform: MachO.Platform?
        var writableExecutable = false
        var codeSignature: MachO.CodeSignature?
        for _ in 0..<commandCount {
            guard offset <= commandEnd.partialValue - 8 else {
                throw MachO.Error.invalidLoadCommands
            }
            let command = readUInt32(data, offset)
            let size = Int(readUInt32(data, offset + 4))
            let next = offset.addingReportingOverflow(size)
            guard size >= 8, size.isMultiple(of: 8),
                  !next.overflow, next.partialValue <= commandEnd.partialValue
            else {
                throw MachO.Error.invalidLoadCommands
            }
            switch command {
            case 0x1b:
                guard size >= 24 else { throw MachO.Error.invalidLoadCommands }
                let bytes = Array(data[(offset + 8)..<(offset + 24)])
                uuid = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            case 0x0d:
                installName = try loadCommandString(data, commandOffset: offset, commandSize: size)
            case 0x0c, 0x80000018, 0x8000001f, 0x80000023:
                dependencies.append(
                    try loadCommandString(data, commandOffset: offset, commandSize: size)
                )
            case 0x32:
                guard size >= 24 else { throw MachO.Error.invalidLoadCommands }
                guard platform == nil,
                      let parsed = MachO.Platform(rawValue: readUInt32(data, offset + 8))
                else {
                    throw MachO.Error.invalidLoadCommands
                }
                platform = parsed
            case 0x24:
                guard size >= 16, platform == nil else {
                    throw MachO.Error.invalidLoadCommands
                }
                platform = .macOS
            case 0x25:
                guard size >= 16, platform == nil else {
                    throw MachO.Error.invalidLoadCommands
                }
                platform = .iOS
            case 0x19:
                guard size >= 72 else { throw MachO.Error.invalidLoadCommands }
                let maximumProtection = readUInt32(data, offset + 56)
                let initialProtection = readUInt32(data, offset + 60)
                if (maximumProtection & 0x2 != 0 && maximumProtection & 0x4 != 0)
                    || (initialProtection & 0x2 != 0 && initialProtection & 0x4 != 0)
                {
                    writableExecutable = true
                }
            case 0x1d:
                guard size >= 16, codeSignature == nil else {
                    throw MachO.Error.invalidLoadCommands
                }
                let dataOffset = readUInt32(data, offset + 8)
                let dataSize = readUInt32(data, offset + 12)
                let signatureEnd = UInt64(dataOffset).addingReportingOverflow(UInt64(dataSize))
                guard dataSize >= 12,
                      UInt64(dataOffset) >= UInt64(commandEnd.partialValue),
                      !signatureEnd.overflow,
                      signatureEnd.partialValue <= UInt64(data.count),
                      readBigEndianUInt32(data, Int(dataOffset)) == 0xfade0cc0
                else {
                    throw MachO.Error.invalidLoadCommands
                }
                let encodedSize = readBigEndianUInt32(data, Int(dataOffset) + 4)
                guard encodedSize >= 12, encodedSize <= dataSize else {
                    throw MachO.Error.invalidLoadCommands
                }
                codeSignature = .init(dataOffset: dataOffset, dataSize: dataSize)
            default:
                break
            }
            offset = next.partialValue
        }
        guard offset == commandEnd.partialValue else { throw MachO.Error.invalidLoadCommands }
        return .init(
            architecture: architecture,
            fileType: fileType,
            uuid: uuid,
            installName: installName,
            dependencies: dependencies.sorted(),
            platform: platform,
            hasWritableExecutableSegment: writableExecutable,
            codeSignature: codeSignature
        )
    }

    public func preflight(
        _ descriptor: MachO.Descriptor,
        expectedArchitecture: MachO.Architecture,
        expectedInstallName: String,
        expectedPlatform: MachO.Platform? = nil,
        allowedDependencyPrefixes: [String]
    ) throws {
        guard descriptor.isDynamicLibrary else {
            throw MachO.Error.notDynamicLibrary
        }
        guard descriptor.architecture == expectedArchitecture else {
            throw MachO.Error.architectureMismatch(
                expected: expectedArchitecture,
                actual: descriptor.architecture
            )
        }
        guard !descriptor.hasWritableExecutableSegment else {
            throw MachO.Error.unsafeSegment
        }
        guard descriptor.installName == expectedInstallName else {
            throw MachO.Error.installNameMismatch
        }
        if let expectedPlatform, descriptor.platform != expectedPlatform {
            throw MachO.Error.platformMismatch(
                expected: expectedPlatform,
                actual: descriptor.platform
            )
        }
        for dependency in descriptor.dependencies {
            guard allowedDependencyPrefixes.contains(where: dependency.hasPrefix) else {
                throw MachO.Error.dependencyDenied(dependency)
            }
        }
    }

    /// Returns true only when a linked dSYM contains non-empty DWARF info and
    /// line tables. LC_UUID alone is not sufficient because dsymutil can emit
    /// an empty bundle after its temporary object files disappear.
    public func hasLinkedDebugInformation(_ data: Data) throws -> Bool {
        _ = try inspect(data)
        let commandCount = Int(readUInt32(data, 16))
        let commandBytes = Int(readUInt32(data, 20))
        var offset = 32
        let commandEnd = 32 + commandBytes
        var hasInfo = false
        var hasLineTable = false

        for _ in 0..<commandCount {
            let command = readUInt32(data, offset)
            let commandSize = Int(readUInt32(data, offset + 4))
            if command == 0x19 {
                guard commandSize >= 72 else { throw MachO.Error.invalidLoadCommands }
                let sectionCount = Int(readUInt32(data, offset + 64))
                let sectionBytes = sectionCount.multipliedReportingOverflow(by: 80)
                guard !sectionBytes.overflow,
                      72 + sectionBytes.partialValue <= commandSize
                else {
                    throw MachO.Error.invalidLoadCommands
                }
                for index in 0..<sectionCount {
                    let sectionOffset = offset + 72 + index * 80
                    let sectionName = fixedString(data, at: sectionOffset, length: 16)
                    let segmentName = fixedString(data, at: sectionOffset + 16, length: 16)
                    let byteCount = readUInt64(data, sectionOffset + 40)
                    guard segmentName == "__DWARF", byteCount > 0 else { continue }
                    if sectionName == "__debug_info" { hasInfo = true }
                    if sectionName == "__debug_line" { hasLineTable = true }
                }
            }
            offset += commandSize
        }
        guard offset == commandEnd else { throw MachO.Error.invalidLoadCommands }
        return hasInfo && hasLineTable
    }

    private func loadCommandString(
        _ data: Data,
        commandOffset: Int,
        commandSize: Int
    ) throws -> String {
        guard commandSize >= 12 else { throw MachO.Error.invalidLoadCommands }
        let stringOffset = Int(readUInt32(data, commandOffset + 8))
        guard stringOffset >= 8, stringOffset < commandSize else {
            throw MachO.Error.invalidLoadCommands
        }
        let start = commandOffset + stringOffset
        let end = commandOffset + commandSize
        let storage = data[start..<end]
        guard let terminator = storage.firstIndex(of: 0) else {
            throw MachO.Error.invalidLoadCommands
        }
        let bytes = storage[..<terminator]
        guard !bytes.isEmpty, let value = String(data: bytes, encoding: .utf8) else {
            throw MachO.Error.invalidLoadCommands
        }
        return value
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    private func fixedString(_ data: Data, at offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readBigEndianUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}
}
