import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface

extension DevSession {
public struct Configuration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var manifestPath: String
    public var reloadIndexPath: String
    public var interfaceArchivePath: String
    public var compilerPath: String
    public var nativeOutputDirectory: String
    public var backendPreference: DevBackendSelection.Preference
    public var deviceNativeMatrixQualified: Bool
    public var debounceMilliseconds: UInt32
    public var maximumSourceBytes: Int
    public var nativeImageSoftLimit: UInt32

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        manifestPath: String,
        reloadIndexPath: String,
        interfaceArchivePath: String,
        compilerPath: String = "/usr/bin/swiftc",
        nativeOutputDirectory: String = ".helix/dev-native",
        backendPreference: DevBackendSelection.Preference = .automatic,
        deviceNativeMatrixQualified: Bool = false,
        debounceMilliseconds: UInt32 = 120,
        maximumSourceBytes: Int = 8 * 1_024 * 1_024,
        nativeImageSoftLimit: UInt32 = 50
    ) {
        self.schemaVersion = schemaVersion
        self.manifestPath = manifestPath
        self.reloadIndexPath = reloadIndexPath
        self.interfaceArchivePath = interfaceArchivePath
        self.compilerPath = compilerPath
        self.nativeOutputDirectory = nativeOutputDirectory
        self.backendPreference = backendPreference
        self.deviceNativeMatrixQualified = deviceNativeMatrixQualified
        self.debounceMilliseconds = debounceMilliseconds
        self.maximumSourceBytes = maximumSourceBytes
        self.nativeImageSoftLimit = nativeImageSoftLimit
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DevSession.ConfigurationError.unsupportedSchema(schemaVersion)
        }
        let paths = [
            manifestPath, reloadIndexPath, interfaceArchivePath,
            compilerPath, nativeOutputDirectory,
        ]
        guard paths.allSatisfy(Self.isSafePath),
              (20...5_000).contains(debounceMilliseconds),
              (1_024...64 * 1_024 * 1_024).contains(maximumSourceBytes),
              (1...80).contains(nativeImageSoftLimit)
        else {
            throw DevSession.ConfigurationError.invalidValue
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1_024 else {
            throw DevSession.ConfigurationError.documentTooLarge
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw DevSession.ConfigurationError.invalidJSON("root must be an object")
            }
            let expected: Set<String> = [
                "schemaVersion", "manifestPath", "reloadIndexPath",
                "interfaceArchivePath", "compilerPath", "nativeOutputDirectory",
                "backendPreference", "deviceNativeMatrixQualified",
                "debounceMilliseconds", "maximumSourceBytes",
                "nativeImageSoftLimit",
            ]
            if let unknown = Set(root.keys).subtracting(expected).sorted().first {
                throw DevSession.ConfigurationError.invalidJSON(
                    "unknown field \(unknown)"
                )
            }
            let configuration = try JSONDecoder().decode(Self.self, from: data)
            try configuration.validate()
            return configuration
        } catch let error as DevSession.ConfigurationError {
            throw error
        } catch {
            throw DevSession.ConfigurationError.invalidJSON(
                String(describing: error)
            )
        }
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty
            && path.utf8.count <= 4_096
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct ResolvedConfiguration: Sendable {
    public var document: DevSession.Configuration
    public var manifestURL: URL
    public var reloadIndexURL: URL
    public var interfaceArchiveURL: URL
    public var compilerURL: URL
    public var nativeOutputDirectoryURL: URL

    public init(
        document: DevSession.Configuration,
        relativeTo baseDirectory: URL
    ) throws {
        try document.validate()
        guard baseDirectory.isFileURL else {
            throw DevSession.ConfigurationError.invalidBaseDirectory
        }
        self.document = document
        manifestURL = Self.resolve(document.manifestPath, relativeTo: baseDirectory)
        reloadIndexURL = Self.resolve(document.reloadIndexPath, relativeTo: baseDirectory)
        interfaceArchiveURL = Self.resolve(
            document.interfaceArchivePath,
            relativeTo: baseDirectory
        )
        compilerURL = Self.resolve(document.compilerPath, relativeTo: baseDirectory)
        nativeOutputDirectoryURL = Self.resolve(
            document.nativeOutputDirectory,
            relativeTo: baseDirectory
        )
    }

    private static func resolve(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return base.appendingPathComponent(path).standardizedFileURL
    }
}

public struct PreparedConfiguration: Sendable {
    public var resolved: DevSession.ResolvedConfiguration
    public var manifest: DevBuildManifest.Document
    public var reloadIndex: ReloadIndex.Document
    public var archive: InterfaceArchive.Archive

    public static func load(
        configurationURL: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard configurationURL.isFileURL else {
            throw DevSession.ConfigurationError.invalidBaseDirectory
        }
        let configurationData = try Self.read(
            configurationURL,
            maximumBytes: 256 * 1_024,
            fileManager: fileManager
        )
        let document = try DevSession.Configuration.decode(configurationData)
        let resolved = try DevSession.ResolvedConfiguration(
            document: document,
            relativeTo: configurationURL.deletingLastPathComponent()
        )
        let manifest: DevBuildManifest.Document = try Self.decodeJSON(
            at: resolved.manifestURL,
            maximumBytes: 16 * 1_024 * 1_024,
            fileManager: fileManager
        )
        try manifest.validate()
        let index: ReloadIndex.Document = try Self.decodeJSON(
            at: resolved.reloadIndexURL,
            maximumBytes: 32 * 1_024 * 1_024,
            fileManager: fileManager
        )
        try index.validate()
        let archive = try InterfaceArchive.Codec.decode(
            Self.read(
                resolved.interfaceArchiveURL,
                maximumBytes: 64 * 1_024 * 1_024,
                fileManager: fileManager
            )
        ).archive
        try validateIdentity(manifest: manifest, index: index, archive: archive)

        var isDirectory: ObjCBool = false
        guard fileManager.isExecutableFile(atPath: resolved.compilerURL.path),
              (!fileManager.fileExists(
                  atPath: resolved.nativeOutputDirectoryURL.path,
                  isDirectory: &isDirectory
              ) || isDirectory.boolValue)
        else {
            throw DevSession.ConfigurationError.invalidFilesystemEntry
        }
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: resolved.compilerURL
        )
        guard toolchain.fingerprint == manifest.swiftCompilerFingerprint else {
            throw DevSession.ConfigurationError.compilerIdentityMismatch
        }
        return .init(
            resolved: resolved,
            manifest: manifest,
            reloadIndex: index,
            archive: archive
        )
    }

    public var buildIdentity: DevProtocol.BuildIdentity {
        .init(
            sessionID: manifest.sessionBuildID,
            bundleID: manifest.bundleID,
            executableUUID: manifest.executableUUID,
            platform: manifest.platform,
            architecture: manifest.architecture,
            xcodeBuild: manifest.xcodeBuild,
            swiftCompilerFingerprint: manifest.swiftCompilerFingerprint,
            liveReloadIndexHash: manifest.liveReloadIndexHash
        )
    }

    /// Exact build facts presented before the App is allowed to pair.
    public var peerBuildIdentity: DevProtocol.PeerBuildIdentity {
        .init(
            bundleID: manifest.bundleID,
            executableUUID: manifest.executableUUID,
            platform: manifest.platform,
            architecture: manifest.architecture,
            xcodeBuild: manifest.xcodeBuild,
            swiftCompilerFingerprint: manifest.swiftCompilerFingerprint,
            liveReloadIndexHash: manifest.liveReloadIndexHash
        )
    }

    /// Stable identity of the fully linked Dev Shell represented by this context.
    public var shellIdentity: DevProtocol.ShellIdentity {
        .init(
            shellID: .init(rawValue: manifest.sessionBuildID),
            build: peerBuildIdentity
        )
    }

    private static func validateIdentity(
        manifest: DevBuildManifest.Document,
        index: ReloadIndex.Document,
        archive: InterfaceArchive.Archive
    ) throws {
        let archivedSources = Dictionary(
            uniqueKeysWithValues: archive.sources.map { ($0.logicalPath, $0.contentHash) }
        )
        let manifestSources = Dictionary(
            uniqueKeysWithValues: manifest.sourceFiles.map { ($0.logicalPath, $0.contentHash) }
        )
        let archivedFunctions = Set(archive.functions.map(\.key))
        let indexedFunctions = Set(index.roots.map(\.functionKey))
        guard try index.contentHash() == manifest.liveReloadIndexHash,
              archive.metadata.bundleID == manifest.bundleID,
              archive.metadata.machOUUIDs.contains(manifest.executableUUID),
              archive.metadata.targetTriple == manifest.targetTriple,
              archive.metadata.minimumOS == manifest.minimumOS,
              archive.metadata.xcodeBuild == manifest.xcodeBuild,
              archive.metadata.sdkBuild == manifest.sdkBuild,
              archive.compatibility.compilerFingerprint == manifest.swiftCompilerFingerprint,
              archive.metadata.frontendInvocation.moduleName == manifest.moduleName,
              archivedSources == manifestSources,
              indexedFunctions.isSubset(of: archivedFunctions)
        else {
            throw DevSession.ConfigurationError.identityMismatch
        }
    }

    private static func decodeJSON<T: Decodable>(
        at url: URL,
        maximumBytes: Int,
        fileManager: FileManager
    ) throws -> T {
        let data = try read(url, maximumBytes: maximumBytes, fileManager: fileManager)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DevSession.ConfigurationError.invalidJSON(String(describing: error))
        }
    }

    private static func read(
        _ url: URL,
        maximumBytes: Int,
        fileManager: FileManager
    ) throws -> Data {
        guard url.isFileURL,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
              byteCount <= UInt64(maximumBytes),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            throw DevSession.ConfigurationError.invalidFilesystemEntry
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else {
            throw DevSession.ConfigurationError.documentTooLarge
        }
        return data
    }
}

public enum ConfigurationError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt16)
    case documentTooLarge
    case invalidJSON(String)
    case invalidValue
    case invalidBaseDirectory
    case invalidFilesystemEntry
    case identityMismatch
    case compilerIdentityMismatch

    public var description: String {
        switch self {
        case let .unsupportedSchema(version):
            "unsupported Dev Session configuration schema \(version)"
        case .documentTooLarge:
            "Dev Session configuration or input exceeds its size limit"
        case let .invalidJSON(reason):
            "invalid Dev Session JSON: \(reason)"
        case .invalidValue:
            "Dev Session configuration contains an invalid path, debounce, or budget"
        case .invalidBaseDirectory:
            "Dev Session configuration must be resolved from a local file directory"
        case .invalidFilesystemEntry:
            "a configured Dev Session input is missing, unsafe, or has the wrong file type"
        case .identityMismatch:
            "Dev Manifest, Reload Index, and HLXI do not share one frozen build identity"
        case .compilerIdentityMismatch:
            "configured swiftc does not match the compiler frozen in the Dev Manifest"
        }
    }
}
}
