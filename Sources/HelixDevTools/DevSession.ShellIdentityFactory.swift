import Foundation
import HelixCore
import HelixDevProtocol

extension DevSession {
/// Derives the stable Shell identifier used by the persistent Hub service.
///
/// A normal Xcode Run may reproduce the exact same App build. Giving that
/// build a fresh random identifier would make the long-lived exact-build index
/// ambiguous. The identifier is therefore deterministic over the workspace
/// and every peer-visible build fact; process and invitation identities remain
/// random and short-lived.
public struct ShellIdentityFactory: Sendable {
    public init() {}

    /// Creates one RFC 4122 variant, version-5-shaped identifier from the
    /// complete exact-build key. SHA-256 remains the underlying domain hash.
    public func make(
        workspacePathHash: Core.Digest,
        build: DevProtocol.PeerBuildIdentity
    ) throws -> DevProtocol.ShellIdentity {
        try build.validate()
        var hasher = Core.StableHasher(domain: "dev.helix.shell-identity.v1")
        hasher.append(workspacePathHash)
        hasher.append(build.protocolVersion)
        hasher.append(build.bundleID)
        hasher.append(build.executableUUID.uuidString.lowercased())
        hasher.append(build.platform.rawValue)
        hasher.append(build.architecture)
        hasher.append(build.xcodeBuild)
        hasher.append(build.swiftCompilerFingerprint)
        hasher.append(build.liveReloadIndexHash)
        var bytes = Array(hasher.finalize().bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let identifier = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        let identity = DevProtocol.ShellIdentity(
            shellID: .init(rawValue: identifier),
            build: build
        )
        try identity.validate()
        return identity
    }

    /// Derives the exact build key from a validated development manifest.
    public func make(
        manifest: DevBuildManifest.Document
    ) throws -> DevProtocol.ShellIdentity {
        try manifest.validate()
        return try make(
            workspacePathHash: manifest.workspacePathHash,
            build: .init(
                bundleID: manifest.bundleID,
                executableUUID: manifest.executableUUID,
                platform: manifest.platform,
                architecture: manifest.architecture,
                xcodeBuild: manifest.xcodeBuild,
                swiftCompilerFingerprint: manifest.swiftCompilerFingerprint,
                liveReloadIndexHash: manifest.liveReloadIndexHash
            )
        )
    }
}
}
