import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension PatchRuntime {
/// Security-relevant facts measured from the running App process.
///
/// Helix combines this value with the installation ID and compares the result
/// with ``BuildContract`` and each package target, preventing a patch compiled
/// for a different installation, executable, architecture, or OS from activating.
public struct ProcessIdentity: Hashable, Sendable {
    /// Bundle identifier read from the running bundle.
    public var bundleID: String
    /// `CFBundleShortVersionString` read from the running bundle.
    public var marketingVersion: String
    /// `LC_UUID` measured from the current App executable.
    public var executableUUID: UUID
    /// Runtime architecture, currently `arm64` or `x86_64`.
    public var architecture: String
    /// Whether this is an iOS device or Simulator process.
    public var platform: PatchPackage.Platform
    /// Operating-system version reported by the process.
    public var operatingSystemVersion: Core.SemanticVersion

    /// Creates and validates an explicit process identity.
    ///
    /// This initializer is primarily useful in tests. Production code should
    /// use ``current(bundle:)``.
    public init(
        bundleID: String,
        marketingVersion: String,
        executableUUID: UUID,
        architecture: String,
        platform: PatchPackage.Platform,
        operatingSystemVersion: Core.SemanticVersion
    ) throws {
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.executableUUID = executableUUID
        self.architecture = architecture
        self.platform = platform
        self.operatingSystemVersion = operatingSystemVersion
        try validate()
    }

    /// Validates required values and supported architecture constraints.
    public func validate() throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 4_096,
              !marketingVersion.isEmpty, marketingVersion.utf8.count <= 256,
              !bundleID.unicodeScalars.contains(where: { $0.value == 0 }),
              !marketingVersion.unicodeScalars.contains(where: { $0.value == 0 }),
              (try? Core.SemanticVersion(parsing: marketingVersion)) != nil,
              executableUUID.uuidString != "00000000-0000-0000-0000-000000000000",
              ["arm64", "x86_64"].contains(architecture)
        else {
            throw PatchRuntime.Error.invalidProcessIdentity("required field is missing")
        }
    }

    /// Measures identity from an iOS App bundle and its Mach-O executable.
    ///
    /// ```swift
    /// let identity = try PatchRuntime.ProcessIdentity.current()
    /// ```
    ///
    /// - Parameter bundle: The application bundle to inspect. Defaults to main.
    /// - Throws: ``PatchRuntime/Error/invalidProcessIdentity(_:)`` when metadata
    ///   is missing, the platform is unsupported, or `LC_UUID` is malformed.
    public static func current(bundle: Bundle = .main) throws -> Self {
        #if os(iOS)
        #if targetEnvironment(macCatalyst)
        throw PatchRuntime.Error.invalidProcessIdentity("Mac Catalyst is unsupported")
        #else
        guard let bundleID = bundle.bundleIdentifier,
              let marketingVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let executableURL = bundle.executableURL
        else {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "bundle metadata or executable is unavailable"
            )
        }
        let uuid = try executableUUID(at: executableURL)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard let major = UInt16(exactly: version.majorVersion),
              let minor = UInt16(exactly: version.minorVersion),
              let patch = UInt16(exactly: version.patchVersion)
        else {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "operating-system version is outside the supported range"
            )
        }
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        throw PatchRuntime.Error.invalidProcessIdentity("unsupported architecture")
        #endif
        let platform: PatchPackage.Platform
        #if targetEnvironment(simulator)
        platform = .iOSSimulator
        #else
        platform = .iOS
        #endif
        return try .init(
            bundleID: bundleID,
            marketingVersion: marketingVersion,
            executableUUID: uuid,
            architecture: architecture,
            platform: platform,
            operatingSystemVersion: .init(major, minor, patch)
        )
        #endif
        #else
        throw PatchRuntime.Error.invalidProcessIdentity("unsupported platform")
        #endif
    }

    private static func executableUUID(at url: URL) throws -> UUID {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "cannot read the App executable"
            )
        }
        guard data.count >= 32, readUInt32(data, at: 0) == 0xfeedfacf else {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "App executable is not a supported 64-bit Mach-O"
            )
        }
        let commandCount = Int(readUInt32(data, at: 16))
        let commandBytes = Int(readUInt32(data, at: 20))
        let end = 32.addingReportingOverflow(commandBytes)
        guard commandCount <= 16_384, commandBytes <= 16 * 1_024 * 1_024,
              !end.overflow, end.partialValue <= data.count
        else {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "Mach-O load commands are malformed"
            )
        }
        var offset = 32
        var uuid: UUID?
        for _ in 0..<commandCount {
            guard offset <= end.partialValue - 8 else {
                throw PatchRuntime.Error.invalidProcessIdentity(
                    "Mach-O load commands are truncated"
                )
            }
            let command = readUInt32(data, at: offset)
            let size = Int(readUInt32(data, at: offset + 4))
            let next = offset.addingReportingOverflow(size)
            guard size >= 8, size.isMultiple(of: 8), !next.overflow,
                  next.partialValue <= end.partialValue
            else {
                throw PatchRuntime.Error.invalidProcessIdentity(
                    "Mach-O load command size is invalid"
                )
            }
            if command == 0x1b {
                guard size >= 24, uuid == nil else {
                    throw PatchRuntime.Error.invalidProcessIdentity(
                        "Mach-O UUID command is invalid"
                    )
                }
                let bytes = Array(data[(offset + 8)..<(offset + 24)])
                uuid = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            }
            offset = next.partialValue
        }
        guard offset == end.partialValue, let uuid else {
            throw PatchRuntime.Error.invalidProcessIdentity(
                "App executable has no unique LC_UUID"
            )
        }
        return uuid
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
}
