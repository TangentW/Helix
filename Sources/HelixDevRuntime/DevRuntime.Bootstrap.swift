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
    public var bundleID: String
    public var platform: DevProtocol.ApplePlatform
    public var architecture: String
    public var xcodeBuild: String
    public var swiftCompilerFingerprint: String
    public var liveReloadIndexHash: Core.Digest
    public var runtimeImageIdentity: Core.RuntimeImageIdentity

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
    public var bundleID: String
    public var executableUUID: UUID
    public var processID: Int32
    public var platform: DevProtocol.ApplePlatform
    public var architecture: String
    public var operatingSystemBuild: String

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

public struct IdentityFactory: Sendable {
    public init() {}

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

public enum BootstrapError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidBuildContract
    case invalidProcessIdentity
    case executableUnavailable
    case executableInspectionFailed(String)
    case executableUUIDMissing
    case buildMismatch(String)
    case runtimeShellMismatch
    case bridgeNotInstalled
    case runtimeAlreadyActive
    case cacheDirectoryUnavailable
    case duplicateRuntimeImages

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
public final class Bootstrap: @unchecked Sendable {
    public struct Options: Hashable, Sendable {
        public var isEnabled: Bool
        public var supportedBackends: [LiveReload.Backend]
        public var nativeChainingProbePassed: Bool
        public var runtimePolicy: Core.RuntimePolicy?
        public var activationLimits: DevActivation.Limits
        public var reconnectPolicy: DevConnection.ReconnectPolicy
        public var liveness: DevProtocol.LivenessConfiguration
        public var cacheDirectory: URL?

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

    public struct Handlers: Sendable {
        public var connectionEvent: DevConnection.Client.EventHandler
        public var activationReload: DevActivation.Controller.ReloadHandler
        public var manualReload: DevRuntimeSession.Controller.ManualReloadHandler
        public var stopped: @Sendable () async -> Void

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

    public let identity: DevProtocol.SessionIdentity
    public let activation: DevActivation.Controller
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
