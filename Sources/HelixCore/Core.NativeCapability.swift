import Foundation

extension Core {
/// Immutable native-call authority carried by one released application.
public enum NativeCapability {}
}

extension Core.NativeCapability {
/// Release and Shell identity covered by a capability manifest.
public struct Identity: Codable, Hashable, Sendable {
    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var shellInterfaceHash: Core.Digest
    public var targetTriple: String
    public var minimumOSVersion: Core.SemanticVersion
    public var xcodeBuild: String
    public var sdkBuild: String
    public var compatibility: Core.Compatibility

    public init(
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        shellInterfaceHash: Core.Digest,
        targetTriple: String,
        minimumOSVersion: Core.SemanticVersion,
        xcodeBuild: String,
        sdkBuild: String,
        compatibility: Core.Compatibility
    ) {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.shellInterfaceHash = shellInterfaceHash
        self.targetTriple = targetTriple
        self.minimumOSVersion = minimumOSVersion
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.compatibility = compatibility
    }
}

/// One exact native call linked into a released application.
public struct Entry: Codable, Hashable, Sendable {
    public var id: Core.NativeImportID
    public var key: Core.NativeCall.Key
    public var descriptor: Core.NativeCall.Descriptor
    public var contract: Core.NativeImportContract
    public var requiredCapability: Core.Capability

    public init(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        contract: Core.NativeImportContract,
        requiredCapability: Core.Capability = .nativeImportsV1
    ) {
        self.id = id
        self.key = key
        self.descriptor = descriptor
        self.contract = contract
        self.requiredCapability = requiredCapability
    }

    public func validate() throws {
        do {
            try descriptor.validate(contract: contract)
            guard try descriptor.canonicalized() == descriptor,
                  try Core.NativeCall.Key.derive(descriptor: descriptor) == key,
                  requiredCapability == .nativeImportsV1
            else {
                throw Core.NativeCapability.Error.invalidEntry(key)
            }
        } catch let error as Core.NativeCapability.Error {
            throw error
        } catch {
            throw Core.NativeCapability.Error.invalidEntry(key)
        }
    }
}

/// Canonical production capability table embedded in the code-signed Bridge.
///
/// The same bytes are emitted beside the Shell for release audit and their
/// digest is included in every signed patch target. Production registries are
/// immutable and must match this complete table before any package activates.
public struct Manifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var identity: Core.NativeCapability.Identity
    public var capabilities: [Core.Capability]
    public var entries: [Core.NativeCapability.Entry]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identity: Core.NativeCapability.Identity,
        capabilities: Set<Core.Capability>,
        entries: [Core.NativeCapability.Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.capabilities = capabilities.sorted()
        self.entries = entries.sorted { $0.id < $1.id }
    }

    public var nativeCallKeys: Set<Core.NativeCall.Key> {
        Set(entries.map(\.key))
    }

    public func entry(
        for key: Core.NativeCall.Key
    ) -> Core.NativeCapability.Entry? {
        entries.first { $0.key == key }
    }

    public func contentHash() throws -> Core.Digest {
        try validate()
        return .sha256(try Core.CanonicalJSON.encode(self))
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw Core.NativeCapability.Error.unsupportedSchema(schemaVersion)
        }
        let strings = [
            identity.bundleID, identity.buildNumber, identity.targetTriple,
            identity.xcodeBuild, identity.sdkBuild,
            identity.compatibility.compilerFingerprint,
        ]
        guard strings.allSatisfy(Self.isBoundText),
              capabilities == Array(Set(capabilities)).sorted(),
              capabilities.contains(.baselineV1),
              entries.count <= 250_000,
              entries == entries.sorted(by: { $0.id < $1.id }),
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.key)).count == entries.count,
              entries.enumerated().allSatisfy({ offset, entry in
                  UInt32(exactly: offset) == entry.id.rawValue
              }),
              entries.isEmpty || capabilities.contains(.nativeImportsV1)
        else {
            throw Core.NativeCapability.Error.invalidManifest
        }
        try entries.forEach { try $0.validate() }
    }

    private static func isBoundText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt16)
    case invalidManifest
    case invalidEntry(Core.NativeCall.Key)

    public var description: String {
        switch self {
        case let .unsupportedSchema(version):
            "unsupported native capability manifest schema \(version)"
        case .invalidManifest:
            "native capability manifest identity or ordering is invalid"
        case let .invalidEntry(key):
            "native capability manifest entry \(key) is invalid"
        }
    }
}
}
