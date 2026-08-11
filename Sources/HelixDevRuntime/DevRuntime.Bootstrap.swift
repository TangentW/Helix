import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier

#if canImport(Darwin)
import Darwin
#endif

extension DevRuntime {
/// Frozen values that are known before the final application executable is
/// linked. The executable UUID and process-local fields are measured at launch.
public struct BuildContract: Hashable, Sendable {
    /// Bundle identifier expected by the development Shell.
    public var bundleID: String
    /// Apple platform for which the Feature and Bridge were built.
    public var platform: DevProtocol.ApplePlatform
    /// Target architecture.
    public var architecture: String
    /// Xcode build identifier used for compilation.
    public var xcodeBuild: String
    /// Canonical Swift compiler fingerprint.
    public var swiftCompilerFingerprint: String
    /// Hash of the Reload Index installed in the App.
    public var liveReloadIndexHash: Core.Digest
    /// Runtime image ABI identity expected by this framework build.
    public var runtimeImageIdentity: Core.RuntimeImageIdentity

    /// Creates and validates an explicit development build contract.
    public init(
        bundleID: String,
        platform: DevProtocol.ApplePlatform,
        architecture: String,
        xcodeBuild: String,
        swiftCompilerFingerprint: String,
        liveReloadIndexHash: Core.Digest,
        runtimeImageIdentity: Core.RuntimeImageIdentity = .current
    ) throws {
        self.bundleID = bundleID
        self.platform = platform
        self.architecture = architecture
        self.xcodeBuild = xcodeBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.liveReloadIndexHash = liveReloadIndexHash
        self.runtimeImageIdentity = runtimeImageIdentity
        try validate()
    }

    /// Creates a contract from the hidden Bridge linked into the App.
    public init(bridge descriptor: Runtime.BridgeDescriptor) throws {
        try descriptor.validate()
        let platform: DevProtocol.ApplePlatform
        switch descriptor.platform {
        case .iOS: platform = .iOS
        case .iOSSimulator: platform = .iOSSimulator
        case .macOS: platform = .macOS
        }
        try self.init(
            bundleID: descriptor.bundleID,
            platform: platform,
            architecture: descriptor.architecture,
            xcodeBuild: descriptor.xcodeBuild,
            swiftCompilerFingerprint: descriptor.compatibility.compilerFingerprint,
            liveReloadIndexHash: descriptor.liveReloadIndexHash,
            runtimeImageIdentity: descriptor.runtimeImageIdentity
        )
    }

    /// Validates required build identities before opening a Dev connection.
    public func validate() throws {
        guard [bundleID, architecture, xcodeBuild, swiftCompilerFingerprint].allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              })
        else {
            throw DevRuntime.BootstrapError.invalidBuildContract
        }
    }
}

/// Process facts measured by the App rather than accepted from launch
/// variables. Keeping these separate makes stale-install checks testable.
public struct ProcessIdentity: Hashable, Sendable {
    /// Bundle identifier measured from the running App.
    public var bundleID: String
    /// Mach-O UUID measured from the running executable.
    public var executableUUID: UUID
    /// Current process identifier.
    public var processID: Int32
    /// Running Apple platform.
    public var platform: DevProtocol.ApplePlatform
    /// Running process architecture.
    public var architecture: String
    /// Operating-system build string reported by the process.
    public var operatingSystemBuild: String

    /// Creates and validates an explicit process identity.
    public init(
        bundleID: String,
        executableUUID: UUID,
        processID: Int32,
        platform: DevProtocol.ApplePlatform,
        architecture: String,
        operatingSystemBuild: String
    ) throws {
        self.bundleID = bundleID
        self.executableUUID = executableUUID
        self.processID = processID
        self.platform = platform
        self.architecture = architecture
        self.operatingSystemBuild = operatingSystemBuild
        try validate()
    }

    /// Validates required process facts.
    public func validate() throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 4_096,
              !executableUUID.isHelixZero,
              processID > 0,
              !architecture.isEmpty, architecture.utf8.count <= 128,
              !operatingSystemBuild.isEmpty, operatingSystemBuild.utf8.count <= 4_096
        else {
            throw DevRuntime.BootstrapError.invalidProcessIdentity
        }
    }

    /// Measures identity from the running App bundle and executable.
    ///
    /// This method is used automatically by ``Bootstrap``.
    public static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let bundleID = bundle.bundleIdentifier,
              let executableURL = bundle.executableURL,
              executableURL.isFileURL,
              fileManager.isReadableFile(atPath: executableURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            throw DevRuntime.BootstrapError.executableUnavailable
        }
        let executable: Data
        let descriptor: MachO.Descriptor
        do {
            executable = try Data(contentsOf: executableURL, options: .mappedIfSafe)
            descriptor = try MachO.Inspector().inspect(executable)
        } catch {
            throw DevRuntime.BootstrapError.executableInspectionFailed(
                String(describing: error)
            )
        }
        guard let executableUUID = descriptor.uuid else {
            throw DevRuntime.BootstrapError.executableUUIDMissing
        }
        return try .init(
            bundleID: bundleID,
            executableUUID: executableUUID,
            processID: ProcessInfo.processInfo.processIdentifier,
            platform: currentPlatform,
            architecture: currentArchitecture,
            operatingSystemBuild: currentOperatingSystemBuild
        )
    }

    private static var currentPlatform: DevProtocol.ApplePlatform {
        #if os(iOS) && targetEnvironment(simulator)
        .iOSSimulator
        #elseif os(iOS)
        .iOS
        #elseif os(macOS)
        .macOS
        #else
        preconditionFailure("Helix Dev Runtime supports Apple platforms only")
        #endif
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        preconditionFailure("Helix Dev Runtime supports arm64 and x86_64 only")
        #endif
    }

    private static var currentOperatingSystemBuild: String {
        #if canImport(Darwin)
        if let build = kernelString("kern.osversion"), !build.isEmpty {
            return build
        }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    #if canImport(Darwin)
    private static func kernelString(_ name: String) -> String? {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0,
              byteCount > 1,
              byteCount <= 64 * 1_024
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname(name, buffer.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0 else { return nil }
        if let terminator = bytes.firstIndex(of: 0) {
            bytes.removeSubrange(terminator..<bytes.endIndex)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
    #endif
}

/// Combines trusted build metadata with measured process facts for authentication.
public struct IdentityFactory: Sendable {
    /// Creates a stateless identity factory.
    public init() {}

    /// Validates all inputs and creates the session identity advertised to the daemon.
    ///
    /// Build and process bundle, platform, and architecture values must match.
    /// The runtime image identity must also prove that exactly one compatible
    /// Helix aggregate product is linked into this configuration.
    public func make(
        connection: DevConnection.Configuration,
        build: DevRuntime.BuildContract,
        process: DevRuntime.ProcessIdentity,
        supportedBackends: [LiveReload.Backend],
        nativeChainingProbePassed: Bool
    ) throws -> DevProtocol.SessionIdentity {
        try connection.validate()
        try build.validate()
        try process.validate()
        guard build.runtimeImageIdentity == .current else {
            throw DevRuntime.BootstrapError.duplicateRuntimeImages
        }
        guard process.bundleID == build.bundleID else {
            throw DevRuntime.BootstrapError.buildMismatch("bundle ID")
        }
        guard process.platform == build.platform else {
            throw DevRuntime.BootstrapError.buildMismatch("platform")
        }
        guard process.architecture == build.architecture else {
            throw DevRuntime.BootstrapError.buildMismatch("architecture")
        }
        let identity = DevProtocol.SessionIdentity(
            protocolVersion: connection.protocolVersion,
            sessionID: connection.sessionID,
            bundleID: process.bundleID,
            executableUUID: process.executableUUID,
            processID: process.processID,
            platform: process.platform,
            architecture: process.architecture,
            operatingSystemBuild: process.operatingSystemBuild,
            xcodeBuild: build.xcodeBuild,
            swiftCompilerFingerprint: build.swiftCompilerFingerprint,
            liveReloadIndexHash: build.liveReloadIndexHash,
            supportedBackends: supportedBackends,
            nativeChainingProbePassed: nativeChainingProbePassed
        )
        try identity.validate()
        return identity
    }
}

/// Fail-closed setup errors raised before a development connection starts.
public enum BootstrapError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// Required generated or frozen build metadata is malformed.
    case invalidBuildContract
    /// Measured process facts are missing or malformed.
    case invalidProcessIdentity
    /// The running executable cannot be located or read.
    case executableUnavailable
    /// Mach-O inspection of the running executable failed.
    case executableInspectionFailed(String)
    /// The running executable has no `LC_UUID` identity.
    case executableUUIDMissing
    /// A named frozen build field does not match the running process.
    case buildMismatch(String)
    /// Runtime and generated Shell compatibility identities differ.
    case runtimeShellMismatch
    /// No generated Bridge provider is linked and installed.
    case bridgeNotInstalled
    /// A generation was already active before a fresh Dev Runtime bootstrap.
    case runtimeAlreadyActive
    /// A private local cache directory could not be established.
    case cacheDirectoryUnavailable
    /// More than one incompatible Helix runtime image is linked into the process.
    case duplicateRuntimeImages

    /// Human-readable bootstrap failure detail.
    public var description: String {
        switch self {
        case .invalidBuildContract:
            "Helix Dev build contract is incomplete or malformed"
        case .invalidProcessIdentity:
            "Helix could not establish a valid App process identity"
        case .executableUnavailable:
            "the App executable is unavailable for identity inspection"
        case let .executableInspectionFailed(reason):
            "the App executable could not be inspected: \(reason)"
        case .executableUUIDMissing:
            "the App executable has no LC_UUID"
        case let .buildMismatch(field):
            "the running App does not match the frozen Helix \(field)"
        case .runtimeShellMismatch:
            "Runtime.Engine and the generated Shell interface do not match"
        case .bridgeNotInstalled:
            "the generated Helix Bridge must be bootstrapped before Dev Runtime"
        case .runtimeAlreadyActive:
            "Dev Runtime bootstrap requires a fresh generation registry"
        case .cacheDirectoryUnavailable:
            "the App cache directory is unavailable"
        case .duplicateRuntimeImages:
            "multiple Helix runtime images are loaded; link exactly one Helix aggregate package product for this configuration"
        }
    }
}
}

#if canImport(Network) && canImport(Security)
extension DevRuntime {
/// Owns one authenticated development connection and activation pipeline.
///
/// Applications normally retain `DevRuntime.ApplicationSession` rather than
/// constructing a bootstrap directly.
public final class Bootstrap: @unchecked Sendable {
    /// Product and safety options for a development session.
    public struct Options: Hashable, Sendable {
        /// Whether Dev Runtime startup is allowed at all.
        public var isEnabled: Bool
        /// Backends this App build is prepared to activate.
        public var supportedBackends: [LiveReload.Backend]
        /// Whether Dynamic Replacement chaining passed this product's device matrix.
        public var nativeChainingProbePassed: Bool
        /// Optional override for the HLBC Runtime policy.
        public var runtimePolicy: Core.RuntimePolicy?
        /// Limits on temporary native images, generations, and cached artifacts.
        public var activationLimits: DevActivation.Limits
        /// Retry and backoff behavior for transient Dev connection failures.
        public var reconnectPolicy: DevConnection.ReconnectPolicy
        /// Ping, timeout, and clock-skew rules for the authenticated session.
        public var liveness: DevProtocol.LivenessConfiguration
        /// Optional private cache root. The default is scoped by session ID.
        public var cacheDirectory: URL?

        /// Creates development-session options.
        ///
        /// ```swift
        /// let options = DevRuntime.Bootstrap.Options()
        /// ```
        ///
        /// The default enables only the unified HLBC product backend. Internal
        /// Native experiments must opt in and pass their chaining probe.
        public init(
            isEnabled: Bool = _isDebugAssertConfiguration(),
            supportedBackends: [LiveReload.Backend] = [.hlbc],
            nativeChainingProbePassed: Bool = false,
            runtimePolicy: Core.RuntimePolicy? = nil,
            activationLimits: DevActivation.Limits = .init(),
            reconnectPolicy: DevConnection.ReconnectPolicy = .init(),
            liveness: DevProtocol.LivenessConfiguration = .init(),
            cacheDirectory: URL? = nil
        ) {
            self.isEnabled = isEnabled
            self.supportedBackends = supportedBackends.sorted { $0.rawValue < $1.rawValue }
            self.nativeChainingProbePassed = nativeChainingProbePassed
            self.runtimePolicy = runtimePolicy
            self.activationLimits = activationLimits
            self.reconnectPolicy = reconnectPolicy
            self.liveness = liveness
            self.cacheDirectory = cacheDirectory
        }
    }

    /// Callbacks that connect activation to product diagnostics and UI refresh.
    public struct Handlers: Sendable {
        /// Receives authenticated connection lifecycle events.
        public var connectionEvent: DevConnection.Client.EventHandler
        /// Refreshes UI after a generation is active.
        public var activationReload: DevActivation.Controller.ReloadHandler
        /// Handles a developer-initiated refresh request.
        public var manualReload: DevRuntimeSession.Controller.ManualReloadHandler
        /// Runs once after the bootstrap has fully stopped.
        public var stopped: @Sendable () async -> Void

        /// Creates handler callbacks. Defaults keep the transport functional but
        /// do not claim that UI was refreshed.
        public init(
            connectionEvent: @escaping DevConnection.Client.EventHandler = { _ in },
            activationReload: @escaping DevActivation.Controller.ReloadHandler = {
                _, _ in .notRequested
            },
            manualReload: @escaping DevRuntimeSession.Controller.ManualReloadHandler = { _ in
                (.manualRefreshRequired, "no manual UI reload handler is installed")
            },
            stopped: @escaping @Sendable () async -> Void = {}
        ) {
            self.connectionEvent = connectionEvent
            self.activationReload = activationReload
            self.manualReload = manualReload
            self.stopped = stopped
        }
    }

    /// Immutable identity advertised to the paired Mac daemon.
    public let identity: DevProtocol.SessionIdentity
    /// Controller that verifies and activates temporary generations.
    public let activation: DevActivation.Controller
    /// Private directory used for native images and session artifacts.
    public let cacheDirectory: URL

    private let client: DevConnection.Client
    private let runTask: Task<Void, Never>
    private let stoppedHandler: @Sendable () async -> Void
    private let stopLock = NSLock()
    private var hasStopped = false

    private init(
        identity: DevProtocol.SessionIdentity,
        activation: DevActivation.Controller,
        cacheDirectory: URL,
        client: DevConnection.Client,
        runTask: Task<Void, Never>,
        stoppedHandler: @escaping @Sendable () async -> Void
    ) {
        self.identity = identity
        self.activation = activation
        self.cacheDirectory = cacheDirectory
        self.client = client
        self.runTask = runTask
        self.stoppedHandler = stoppedHandler
    }

    deinit {
        runTask.cancel()
        let client = client
        Task { await client.stop() }
    }

    /// Starts only when explicitly enabled and a complete launch environment
    /// is present. Optimized builds are disabled by default.
    ///
    /// - Returns: A running bootstrap, or `nil` when disabled or when no Helix
    ///   launch variables are present.
    public static func startIfConfigured(
        build: DevRuntime.BuildContract,
        runtime: Runtime.Engine,
        shell: Verification.ShellInterface,
        options: Options = .init(),
        handlers: Handlers = .init(),
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DevRuntime.Bootstrap? {
        guard options.isEnabled else { return nil }
        guard let connection = try DevConnection.Configuration.load(
            environment: launchEnvironment
        ) else { return nil }
        let process = try DevRuntime.ProcessIdentity.current()
        return try start(
            connection: connection,
            build: build,
            process: process,
            runtime: runtime,
            shell: shell,
            options: options,
            handlers: handlers
        )
    }

    /// Idempotently stops transport, activation work, and the stopped callback.
    public func stop() async {
        let shouldStop = stopLock.withLock {
            guard !hasStopped else { return false }
            hasStopped = true
            return true
        }
        guard shouldStop else { return }
        runTask.cancel()
        await client.stop()
        _ = await runTask.result
        await stoppedHandler()
    }

    private static func start(
        connection: DevConnection.Configuration,
        build: DevRuntime.BuildContract,
        process: DevRuntime.ProcessIdentity,
        runtime: Runtime.Engine,
        shell: Verification.ShellInterface,
        options: Options,
        handlers: Handlers
    ) throws -> DevRuntime.Bootstrap {
        guard runtime.shellInterfaceHash == shell.interfaceHash else {
            throw DevRuntime.BootstrapError.runtimeShellMismatch
        }
        guard Runtime.Bridge.shared.installedInterfaceHash == shell.interfaceHash else {
            throw DevRuntime.BootstrapError.bridgeNotInstalled
        }
        let registrySnapshot = runtime.registry.snapshot()
        guard registrySnapshot.activeGenerationID == nil,
              registrySnapshot.loadedGenerationIDs.isEmpty
        else {
            throw DevRuntime.BootstrapError.runtimeAlreadyActive
        }
        let identity = try DevRuntime.IdentityFactory().make(
            connection: connection,
            build: build,
            process: process,
            supportedBackends: options.supportedBackends,
            nativeChainingProbePassed: options.nativeChainingProbePassed
        )
        let cacheDirectory = try options.cacheDirectory
            ?? defaultCacheDirectory(sessionID: identity.sessionID)
        let policy = options.runtimePolicy ?? Core.RuntimePolicy(
            acceptedCapabilities: shell.capabilities,
            allowedNativeImports: Set(shell.imports.keys),
            allowMainActorSynchronousEntries: true,
            productionChannelEnabled: false
        )
        let activation = try DevActivation.Controller(
            identity: identity,
            shell: shell,
            runtimePolicy: policy,
            registry: runtime.registry,
            cacheDirectory: cacheDirectory,
            limits: options.activationLimits,
            reloadHandler: handlers.activationReload
        )
        let client = try DevConnection.Client(
            configuration: connection,
            identity: identity,
            activation: activation,
            reconnectPolicy: options.reconnectPolicy,
            liveness: options.liveness,
            eventHandler: handlers.connectionEvent,
            manualReloadHandler: handlers.manualReload
        )
        let eventHandler = handlers.connectionEvent
        let runTask = Task {
            do {
                try await client.run()
            } catch is CancellationError {
                // Explicit stop owns the final status transition.
            } catch {
                await eventHandler(
                    .session(.closed("Dev connection stopped: \(error)"))
                )
            }
        }
        return .init(
            identity: identity,
            activation: activation,
            cacheDirectory: cacheDirectory,
            client: client,
            runTask: runTask,
            stoppedHandler: handlers.stopped
        )
    }

    private static func defaultCacheDirectory(sessionID: UUID) throws -> URL {
        guard let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw DevRuntime.BootstrapError.cacheDirectoryUnavailable
        }
        return base
            .appendingPathComponent("HelixDev", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
}
}

#if canImport(UIKit) && canImport(SwiftUI)
extension DevRuntime.Bootstrap {
/// Starts a configured development session and wires the standard UI environment.
///
/// The environment supplies status reduction, automatic UIKit/SwiftUI refresh,
/// and the optional debug overlay. The overlay starts only when launch variables
/// produce a real bootstrap and is stopped with the session.
///
/// Applications normally use `DevRuntime.ApplicationSession`; this overload is
/// available for custom ownership while retaining the standard UI integration.
///
/// - Returns: A running bootstrap, or `nil` when development runtime is disabled
///   or no Helix launch variables are present.
@MainActor
public static func startIfConfigured(
    build: DevRuntime.BuildContract,
    runtime: Runtime.Engine,
    shell: Verification.ShellInterface,
    liveReloadEnvironment: DevRuntime.LiveReloadEnvironment,
    options: Options = .init(),
    launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
) throws -> DevRuntime.Bootstrap? {
    let bootstrap = try startIfConfigured(
        build: build,
        runtime: runtime,
        shell: shell,
        options: options,
        handlers: .init(
            connectionEvent: liveReloadEnvironment.connectionEventHandler(),
            activationReload: liveReloadEnvironment.activationReloadHandler(),
            manualReload: liveReloadEnvironment.manualReloadHandler(),
            stopped: { @MainActor [weak liveReloadEnvironment] in
                liveReloadEnvironment?.stopOverlay()
            }
        ),
        launchEnvironment: launchEnvironment
    )
    if bootstrap != nil { liveReloadEnvironment.startOverlay() }
    return bootstrap
}
}
#endif
#endif

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension UUID {
    var isHelixZero: Bool {
        uuidString == "00000000-0000-0000-0000-000000000000"
    }
}
