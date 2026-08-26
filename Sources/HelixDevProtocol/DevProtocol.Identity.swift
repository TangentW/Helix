import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixLiveReloadAPI
#endif

extension DevProtocol {
/// Stable identity of one linked development Shell.
public struct ShellID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Stable identity of one pairing invitation.
public struct InvitationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Stable identity of one authenticated reconnect lease.
public struct LeaseID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Random identity retained for the lifetime of one App process.
public struct PeerID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Build facts an App can measure before it is trusted by a Hub session.
public struct PeerBuildIdentity: Codable, Hashable, Sendable {
    /// Wire protocol version understood by the App.
    public var protocolVersion: UInt16
    /// Application bundle identifier.
    public var bundleID: String
    /// UUID of the running Mach-O image.
    public var executableUUID: UUID
    /// Apple platform for which the Shell was linked.
    public var platform: DevProtocol.ApplePlatform
    /// Architecture of the running App process.
    public var architecture: String
    /// Xcode build version used to produce the Shell.
    public var xcodeBuild: String
    /// SDK build version whose imported declarations were cataloged.
    public var sdkBuild: String
    /// Stable fingerprint of the Swift compiler invocation.
    public var swiftCompilerFingerprint: String
    /// Digest of the linked Live Reload entry-point index.
    public var liveReloadIndexHash: Core.Digest

    public init(
        protocolVersion: UInt16 = DevProtocol.Metadata.currentProtocolVersion,
        bundleID: String,
        executableUUID: UUID,
        platform: DevProtocol.ApplePlatform,
        architecture: String,
        xcodeBuild: String,
        sdkBuild: String,
        swiftCompilerFingerprint: String,
        liveReloadIndexHash: Core.Digest
    ) {
        self.protocolVersion = protocolVersion
        self.bundleID = bundleID
        self.executableUUID = executableUUID
        self.platform = platform
        self.architecture = architecture
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.liveReloadIndexHash = liveReloadIndexHash
    }

    /// Validates bounded fields and rejects protocol/build placeholders.
    public func validate() throws {
        guard protocolVersion == DevProtocol.Metadata.currentProtocolVersion,
              !Self.isZero(executableUUID),
              [bundleID, architecture, xcodeBuild, sdkBuild,
               swiftCompilerFingerprint].allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              })
        else {
            throw DevProtocol.Error.malformedMessage("peer build identity is invalid")
        }
    }

    private static func isZero(_ value: UUID) -> Bool {
        value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}

/// Immutable identity of one installed development Shell.
public struct ShellIdentity: Codable, Hashable, Sendable {
    /// Build-scoped Shell identifier.
    public var shellID: DevProtocol.ShellID
    /// Exact linked build facts expected from the App.
    public var build: DevProtocol.PeerBuildIdentity

    public init(shellID: DevProtocol.ShellID, build: DevProtocol.PeerBuildIdentity) {
        self.shellID = shellID
        self.build = build
    }

    /// Validates the Shell and its linked build facts.
    public func validate() throws {
        guard !Self.isZero(shellID.rawValue) else {
            throw DevProtocol.Error.malformedMessage("Shell ID is zero")
        }
        try build.validate()
    }

    /// Returns whether a peer is running this exact linked Shell.
    public func matches(_ peer: DevProtocol.PeerBuildIdentity) -> Bool {
        build == peer
    }

    private static func isZero(_ value: UUID) -> Bool {
        value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}

/// Process facts presented before an invitation is redeemed.
public struct PeerIdentity: Codable, Hashable, Sendable {
    /// Per-process random identity used by reconnect leases.
    public var peerID: DevProtocol.PeerID
    /// Build facts measured by the running App.
    public var build: DevProtocol.PeerBuildIdentity
    /// App process identifier, used for diagnostics only.
    public var processID: Int32
    /// Operating system build reported by the App.
    public var operatingSystemBuild: String
    /// Execution backends available in the running Shell.
    public var supportedBackends: [LiveReload.Backend]

    public init(
        peerID: DevProtocol.PeerID,
        build: DevProtocol.PeerBuildIdentity,
        processID: Int32,
        operatingSystemBuild: String,
        supportedBackends: [LiveReload.Backend]
    ) {
        self.peerID = peerID
        self.build = build
        self.processID = processID
        self.operatingSystemBuild = operatingSystemBuild
        self.supportedBackends = supportedBackends.sorted { $0.rawValue < $1.rawValue }
    }

    /// Validates bounded process fields and canonical backend ordering.
    public func validate() throws {
        guard !Self.isZero(peerID.rawValue), processID > 0,
              !operatingSystemBuild.isEmpty,
              operatingSystemBuild.utf8.count <= 4_096,
              !operatingSystemBuild.unicodeScalars.contains(where: { $0.value == 0 }),
              !supportedBackends.isEmpty,
              Set(supportedBackends).count == supportedBackends.count,
              supportedBackends == supportedBackends.sorted(by: { $0.rawValue < $1.rawValue })
        else {
            throw DevProtocol.Error.malformedMessage("peer identity is invalid")
        }
        try build.validate()
    }

    private static func isZero(_ value: UUID) -> Bool {
        value == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
}
