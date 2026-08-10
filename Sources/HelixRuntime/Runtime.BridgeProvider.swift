import Foundation
import HelixCore
import HelixVerifier

#if canImport(Darwin)
import Darwin
#endif

extension Runtime {
/// Build facts and compatibility values emitted from the same Shell archive as
/// the linked Bridge. Runtime products convert this neutral descriptor into
/// their workflow-specific contracts.
public struct BridgeDescriptor: Hashable, Sendable {
    public enum Platform: String, Hashable, Sendable {
        case iOS
        case iOSSimulator
        case macOS
    }

    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var shellInterfaceHash: Core.Digest
    public var minimumOSVersion: Core.SemanticVersion
    public var compatibility: Core.Compatibility
    public var capabilities: Set<Core.Capability>
    public var nativeImportIDs: Set<Core.NativeImportID>
    public var platform: Platform
    public var architecture: String
    public var xcodeBuild: String
    public var liveReloadIndexHash: Core.Digest
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
        platform: Platform,
        architecture: String,
        xcodeBuild: String,
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
        self.nativeImportIDs = nativeImportIDs
        self.platform = platform
        self.architecture = architecture
        self.xcodeBuild = xcodeBuild
        self.liveReloadIndexHash = liveReloadIndexHash
        self.runtimeImageIdentity = runtimeImageIdentity
    }

    public func validate() throws {
        let values = [
            bundleID, buildNumber, architecture, xcodeBuild,
            compatibility.compilerFingerprint,
        ]
        guard values.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }), ["arm64", "x86_64"].contains(architecture),
              runtimeImageIdentity == .current
        else {
            throw Runtime.BridgeProviderError.invalidDescriptor
        }
    }
}

/// Type-erased entry point to generated Bridge code. The App links one hidden
/// Bridge object and interacts only with this stable Runtime API.
public final class BridgeProvider: @unchecked Sendable {
    public typealias RuntimeFactory = @Sendable (
        Runtime.GenerationRegistry,
        any Runtime.Observing
    ) throws -> Runtime.Engine
    public typealias ShellFactory = @Sendable () throws -> Verification.ShellInterface
    public typealias Installer = @Sendable (Runtime.Engine) throws -> Void

    public let descriptor: Runtime.BridgeDescriptor
    private let runtimeFactory: RuntimeFactory
    private let shellFactory: ShellFactory
    private let installer: Installer

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

    public func makeRuntime(
        registry: Runtime.GenerationRegistry = .init(),
        observer: any Runtime.Observing = Runtime.NoopObserver()
    ) throws -> Runtime.Engine {
        try descriptor.validate()
        let runtime = try runtimeFactory(registry, observer)
        guard runtime.shellInterfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        return runtime
    }

    public func makeShellInterface() throws -> Verification.ShellInterface {
        try descriptor.validate()
        let shell = try shellFactory()
        guard shell.interfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        return shell
    }

    public func install(on runtime: Runtime.Engine) throws {
        try descriptor.validate()
        guard runtime.shellInterfaceHash == descriptor.shellInterfaceHash else {
            throw Runtime.BridgeProviderError.interfaceMismatch
        }
        try installer(runtime)
    }
}

/// Resolves the single Bridge provider linked into the application executable.
/// The stable C symbol avoids importing a generated Swift module in App code.
public enum LinkedBridge {
    public static let providerSymbol = "hlx_bridge_provider_v1"

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

public enum BridgeProviderError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case imageUnavailable
    case providerMissing
    case invalidDescriptor
    case interfaceMismatch

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
