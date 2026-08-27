import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixVerifier
#endif

#if canImport(Darwin)
import Darwin
#endif

extension Runtime {
/// Build facts and compatibility values emitted from the same Shell archive as
/// the linked Bridge. Runtime products convert this neutral descriptor into
/// their workflow-specific contracts.
public struct BridgeDescriptor: Hashable, Sendable {
    /// Apple platform encoded into the generated Bridge archive.
    public enum Platform: String, Hashable, Sendable {
        /// Physical iOS devices.
        case iOS
        /// iOS Simulator processes.
        case iOSSimulator
        /// macOS processes.
        case macOS
    }

    /// Bundle identifier for which the Bridge was generated.
    public var bundleID: String
    /// Application build number frozen into the generated artifacts.
    public var buildNumber: String
    /// Namespace separating native imports belonging to this Shell interface.
    public var shellNamespaceID: Core.ShellNamespaceID
    /// Canonical hash shared by the Bridge, verifier interface, and runtime.
    public var shellInterfaceHash: Core.Digest
    /// Minimum operating-system version assumed by generated native bindings.
    public var minimumOSVersion: Core.SemanticVersion
    /// Swift compiler, ABI, bytecode, and VM compatibility identity.
    public var compatibility: Core.Compatibility
    /// Capabilities compiled into the generated Shell interface.
    public var capabilities: Set<Core.Capability>
    /// Exact native-call authority embedded in this code-signed Bridge.
    public var nativeCapabilityManifest: Core.NativeCapability.Manifest
    /// Platform for which the Bridge archive was linked.
    public var platform: Platform
    /// Architecture for which the Bridge archive was linked.
    public var architecture: String
    /// Xcode build identifier used to produce the generated artifacts.
    public var xcodeBuild: String
    /// SDK build identifier whose imported API and ABI surface was cataloged.
    public var sdkBuild: String
    /// Hash of the generated Live Reload index installed in the App.
    public var liveReloadIndexHash: Core.Digest
    /// Identity used to reject duplicate or incompatible Runtime images.
    public var runtimeImageIdentity: Core.RuntimeImageIdentity

    /// Creates a descriptor emitted by generated Bridge code.
    ///
    /// Applications should load this value through ``LinkedBridge/load()``
    /// rather than recreating generated metadata manually.
    public init(
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        shellInterfaceHash: Core.Digest,
        minimumOSVersion: Core.SemanticVersion,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability>,
        nativeCapabilityManifest: Core.NativeCapability.Manifest,
        platform: Platform,
        architecture: String,
        xcodeBuild: String,
        sdkBuild: String,
        liveReloadIndexHash: Core.Digest,
        runtimeImageIdentity: Core.RuntimeImageIdentity = .current
    ) {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.shellInterfaceHash = shellInterfaceHash
        self.minimumOSVersion = minimumOSVersion
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.nativeCapabilityManifest = nativeCapabilityManifest
        self.platform = platform
        self.architecture = architecture
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.liveReloadIndexHash = liveReloadIndexHash
        self.runtimeImageIdentity = runtimeImageIdentity
    }

    /// Validates required strings, supported architecture, and runtime identity.
    public func validate() throws {
        let values = [
            bundleID, buildNumber, architecture, xcodeBuild, sdkBuild,
            compatibility.compilerFingerprint,
        ]
        let manifest = nativeCapabilityManifest
        do {
            try manifest.validate()
        } catch {
            throw Runtime.BridgeProviderError.invalidDescriptor
        }
        let nativeCallKeys = manifest.nativeCallKeys
        let manifestIdentity = manifest.identity
        let normalizedTriple = manifestIdentity.targetTriple.lowercased()
        guard values.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }), ["arm64", "x86_64"].contains(architecture),
              nativeCallKeys.isEmpty
                || capabilities.contains(.nativeImportsV1),
              Set(manifest.capabilities) == capabilities,
              manifestIdentity.bundleID == bundleID,
              manifestIdentity.buildNumber == buildNumber,
              manifestIdentity.shellNamespaceID == shellNamespaceID,
              manifestIdentity.shellInterfaceHash == shellInterfaceHash,
              manifestIdentity.minimumOSVersion == minimumOSVersion,
              manifestIdentity.compatibility == compatibility,
              manifestIdentity.xcodeBuild == xcodeBuild,
              manifestIdentity.sdkBuild == sdkBuild,
              normalizedTriple.hasPrefix(architecture.lowercased() + "-"),
              Self.matches(platform: platform, targetTriple: normalizedTriple),
              runtimeImageIdentity == .current
        else {
            throw Runtime.BridgeProviderError.invalidDescriptor
        }
    }

    /// Native-call keys derived from the manifest rather than duplicated state.
    public var nativeCallKeys: Set<Core.NativeCall.Key> {
        nativeCapabilityManifest.nativeCallKeys
    }

    /// Canonical digest signed into a patch target for this released App.
    public func nativeCapabilityManifestHash() throws -> Core.Digest {
        try nativeCapabilityManifest.contentHash()
    }

    private static func matches(
        platform: Runtime.BridgeDescriptor.Platform,
        targetTriple: String
    ) -> Bool {
        switch platform {
        case .iOS:
            targetTriple.contains("-apple-ios")
                && !targetTriple.contains("simulator")
        case .iOSSimulator:
            targetTriple.contains("-apple-ios")
                && targetTriple.contains("simulator")
        case .macOS:
            targetTriple.contains("-apple-macos")
        }
    }
}

/// Type-erased entry point to generated Bridge code. The App links one hidden
/// Bridge object and interacts only with this stable Runtime API.
public final class BridgeProvider: @unchecked Sendable {
    /// Generated closure that constructs a runtime around a shared registry.
    public typealias RuntimeFactory = @Sendable (
        Runtime.GenerationRegistry,
        any Runtime.Observing
    ) throws -> Runtime.Engine
    /// Generated closure that exposes the frozen verifier Shell interface.
    public typealias ShellFactory = @Sendable () throws -> Verification.ShellInterface
    /// Generated closure that registers native import thunks on a runtime.
    public typealias Installer = @Sendable (Runtime.Engine) throws -> Void

    /// Build and compatibility metadata associated with all provider closures.
    public let descriptor: Runtime.BridgeDescriptor
    private let runtimeFactory: RuntimeFactory
    private let shellFactory: ShellFactory
    private let installer: Installer
    private let shellCache = Runtime.BridgeProvider.ShellCache()

    /// Creates a type-erased provider around generated Bridge closures.
    ///
    /// This initializer is intended for generated code and tests. App code loads
    /// the single linked instance through ``LinkedBridge/load()``.
    public init(
        descriptor: Runtime.BridgeDescriptor,
        makeRuntime: @escaping RuntimeFactory,
        makeShellInterface: @escaping ShellFactory,
        install: @escaping Installer
    ) {
        self.descriptor = descriptor
        runtimeFactory = makeRuntime
        shellFactory = makeShellInterface
        installer = install
    }

    /// Creates a runtime and verifies its Shell interface identity.
    ///
    /// The registry supplied here must also be used by patch activation so
    /// instrumented dispatch observes newly activated generations.
    public func makeRuntime(
        registry: Runtime.GenerationRegistry = .init(),
        observer: any Runtime.Observing = Runtime.NoopObserver()
    ) throws -> Runtime.Engine {
        try descriptor.validate()
        let runtime = try runtimeFactory(registry, observer)
        guard runtime.shellInterfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        let shell = try resolvedShell()
        try validate(shell: shell)
        try runtime.validateNativeCapabilities(
            against: descriptor.nativeCapabilityManifest,
            shell: shell
        )
        return runtime
    }

    /// Creates the frozen verifier interface and checks it against the descriptor.
    public func makeShellInterface() throws -> Verification.ShellInterface {
        try descriptor.validate()
        let shell = try resolvedShell()
        guard shell.interfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        try validate(shell: shell)
        return shell
    }

    /// Installs all generated native import thunks on a compatible runtime.
    public func install(on runtime: Runtime.Engine) throws {
        try descriptor.validate()
        guard runtime.shellInterfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        let shell = try resolvedShell()
        try validate(shell: shell)
        try runtime.validateNativeCapabilities(
            against: descriptor.nativeCapabilityManifest,
            shell: shell
        )
        try installer(runtime)
    }

    private func validate(shell: Verification.ShellInterface) throws {
        let manifest = descriptor.nativeCapabilityManifest
        guard shell.interfaceHash == manifest.identity.shellInterfaceHash,
              shell.compatibility == manifest.identity.compatibility,
              shell.capabilities == Set(manifest.capabilities),
              shell.imports.count == manifest.entries.count,
              manifest.entries.allSatisfy({ entry in
                  guard let resolved = shell.imports[entry.id] else {
                      return false
                  }
                  return resolved.key == entry.key
                      && resolved.descriptor == entry.descriptor
                      && resolved.contract == entry.contract
                      && resolved.capability == entry.requiredCapability
              })
        else {
            throw Runtime.NativeCapabilityError.shellMismatch
        }
    }

    private func resolvedShell() throws -> Verification.ShellInterface {
        try shellCache.resolve(shellFactory)
    }

    fileprivate final class ShellCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Verification.ShellInterface?

        func resolve(
            _ factory: Runtime.BridgeProvider.ShellFactory
        ) throws -> Verification.ShellInterface {
            try lock.withLock {
                if let value { return value }
                let resolved = try factory()
                value = resolved
                return resolved
            }
        }
    }
}

/// Resolves the single Bridge provider linked into the application executable.
/// The stable C symbol avoids importing a generated Swift module in App code.
public enum LinkedBridge {
    /// Stable C symbol exported once by the generated Bridge object.
    public static let providerSymbol = "hlx_bridge_provider_v1"

    /// Resolves and validates the Bridge provider linked into the current process.
    ///
    /// ```swift
    /// let bridge = try Runtime.LinkedBridge.load()
    /// let runtime = try bridge.makeRuntime()
    /// try bridge.install(on: runtime)
    /// ```
    ///
    /// This opens only the already loaded process image; it does not download or
    /// map executable code.
    public static func load() throws -> Runtime.BridgeProvider {
        #if canImport(Darwin)
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            throw Runtime.BridgeProviderError.imageUnavailable
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, providerSymbol) else {
            throw Runtime.BridgeProviderError.providerMissing
        }
        typealias ProviderFactory = @convention(c) () -> UnsafeMutableRawPointer?
        let factory = unsafeBitCast(symbol, to: ProviderFactory.self)
        guard let pointer = factory() else {
            throw Runtime.BridgeProviderError.providerMissing
        }
        let provider = Unmanaged<Runtime.BridgeProvider>
            .fromOpaque(pointer).takeUnretainedValue()
        try provider.descriptor.validate()
        return provider
        #else
        throw Runtime.BridgeProviderError.imageUnavailable
        #endif
    }
}

/// Failures while resolving or validating the generated linked Bridge.
public enum BridgeProviderError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// The current platform cannot inspect its own process image.
    case imageUnavailable
    /// The generated provider symbol is absent or returned no provider.
    case providerMissing
    /// Generated build metadata is incomplete, malformed, or incompatible.
    case invalidDescriptor
    /// Provider components do not share one Shell interface hash.
    case interfaceMismatch

    /// Human-readable linked Bridge failure detail.
    public var description: String {
        switch self {
        case .imageUnavailable:
            "the current process image cannot be inspected for a Helix Bridge"
        case .providerMissing:
            "the App does not contain a linked Helix Bridge provider"
        case .invalidDescriptor:
            "the linked Helix Bridge descriptor is invalid"
        case .interfaceMismatch:
            "the linked Helix Bridge components have different interface identities"
        }
    }
}
}
