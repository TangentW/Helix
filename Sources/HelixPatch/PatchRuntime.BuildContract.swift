import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixRuntime
#endif

/// App-side assembly helpers for the production-safe HLBC runtime graph.
public enum PatchRuntime {}

extension PatchRuntime {
/// Frozen build facts that bind a production Runtime to one audited Shell.
///
/// The Xcode integration constructs this value from the hidden Bridge. Normal
/// applications do not create it manually; the public initializer exists for
/// tests and alternate build-system adapters.
public struct BuildContract: Hashable, Sendable {
    /// Bundle identifier accepted by this Shell.
    public var bundleID: String
    /// `CFBundleVersion` captured during the audited build.
    public var buildNumber: String
    /// Namespace used to derive stable Shell identities.
    public var shellNamespaceID: Core.ShellNamespaceID
    /// Hash of the exact callable Shell interface.
    public var shellInterfaceHash: Core.Digest
    /// Minimum operating-system version used to build the Shell.
    public var minimumOSVersion: Core.SemanticVersion
    /// Runtime, bytecode, archive, and compiler compatibility facts.
    public var compatibility: Core.Compatibility
    /// HLBC capabilities accepted by the audited Shell.
    public var capabilities: Set<Core.Capability>
    /// Native imports compiled and allowlisted in the Shell.
    public var nativeImportIDs: Set<Core.NativeImportID>
    /// Runtime image ABI identity expected by this framework build.
    public var runtimeImageIdentity: Core.RuntimeImageIdentity

    /// Creates and validates an explicit build contract.
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

    /// Creates a production contract from the linked Bridge descriptor.
    public init(bridge descriptor: Runtime.BridgeDescriptor) throws {
        try descriptor.validate()
        try self.init(
            bundleID: descriptor.bundleID,
            buildNumber: descriptor.buildNumber,
            shellNamespaceID: descriptor.shellNamespaceID,
            shellInterfaceHash: descriptor.shellInterfaceHash,
            minimumOSVersion: descriptor.minimumOSVersion,
            compatibility: descriptor.compatibility,
            capabilities: descriptor.capabilities,
            nativeImportIDs: descriptor.nativeImportIDs,
            runtimeImageIdentity: descriptor.runtimeImageIdentity
        )
    }

    /// Validates required identities before a Runtime graph is assembled.
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

    /// Builds the production VM policy enforced for every activated generation.
    ///
    /// - Parameter resourceCeiling: Application-wide limits that no package may
    ///   exceed even when its own manifest requests more.
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

/// Errors raised while assembling the production hot-patch Runtime.
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// The embedded build contract is malformed or incompatible.
    case invalidBuildContract
    /// A measured process identity is absent or malformed.
    case invalidProcessIdentity(String)
    /// A measured process field differs from the audited Shell.
    case buildMismatch(String)
    /// Runtime Engine and Shell Interface belong to different builds.
    case runtimeShellMismatch
    /// The generated Bridge did not install its exact ABI registrations.
    case bridgeNotInstalled
    /// No additional monotonically increasing generation ID can be allocated.
    case generationIdentifierExhausted

    /// A diagnostic suitable for logs and incident telemetry.
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
