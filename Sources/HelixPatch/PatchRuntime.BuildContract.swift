import Foundation
import HelixCore

/// App-side assembly helpers for the production-safe HLBC runtime graph.
public enum PatchRuntime {}

extension PatchRuntime {
public struct BuildContract: Hashable, Sendable {
    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var shellInterfaceHash: Core.Digest
    public var minimumOSVersion: Core.SemanticVersion
    public var compatibility: Core.Compatibility
    public var capabilities: Set<Core.Capability>
    public var nativeImportIDs: Set<Core.NativeImportID>
    public var runtimeImageIdentity: Core.RuntimeImageIdentity

    public init(
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        shellInterfaceHash: Core.Digest,
        minimumOSVersion: Core.SemanticVersion,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability>,
        nativeImportIDs: Set<Core.NativeImportID>,
        runtimeImageIdentity: Core.RuntimeImageIdentity = .current
    ) throws {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.shellInterfaceHash = shellInterfaceHash
        self.minimumOSVersion = minimumOSVersion
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.nativeImportIDs = nativeImportIDs
        self.runtimeImageIdentity = runtimeImageIdentity
        try validate()
    }

    public func validate() throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 4_096,
              !buildNumber.isEmpty, buildNumber.utf8.count <= 256,
              !bundleID.unicodeScalars.contains(where: { $0.value == 0 }),
              !buildNumber.unicodeScalars.contains(where: { $0.value == 0 }),
              runtimeImageIdentity == .current
        else {
            throw PatchRuntime.Error.invalidBuildContract
        }
    }

    public func runtimePolicy(
        resourceCeiling: Core.ResourceLimits = .init()
    ) -> Core.RuntimePolicy {
        .init(
            acceptedCapabilities: capabilities,
            resourceCeiling: resourceCeiling,
            allowedNativeImports: nativeImportIDs,
            allowMainActorSynchronousEntries: capabilities.contains(.mainActorSyncV1),
            productionChannelEnabled: true
        )
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidBuildContract
    case invalidProcessIdentity(String)
    case buildMismatch(String)
    case runtimeShellMismatch
    case bridgeNotInstalled
    case generationIdentifierExhausted

    public var description: String {
        switch self {
        case .invalidBuildContract: "invalid Patch Runtime build contract"
        case let .invalidProcessIdentity(reason):
            "invalid Patch Runtime process identity: \(reason)"
        case let .buildMismatch(field):
            "running App does not match Patch Runtime \(field)"
        case .runtimeShellMismatch:
            "Runtime.Engine and generated Shell interface do not match"
        case .bridgeNotInstalled:
            "generated Helix Bridge must be installed before Patch Runtime"
        case .generationIdentifierExhausted:
            "Patch Runtime generation identifier is exhausted"
        }
    }
}
}
