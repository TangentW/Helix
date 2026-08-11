#if canImport(Network) && canImport(Security) && canImport(UIKit) && canImport(SwiftUI)
import Foundation
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier

extension DevRuntime {
/// Thin App-owned composition root for the generated Bridge, Runtime Engine,
/// authenticated Dev connection, UI reload coordinators, and debug overlay.
///
/// Keep one session alive for the App process while using a Helix-enabled Debug
/// scheme. The session is inert when no Helix launch configuration is present;
/// partial or malformed configuration fails initialization.
///
/// ```swift
/// @MainActor
/// final class DevelopmentRuntimeOwner {
///     let session: DevRuntime.ApplicationSession
///
///     init() throws {
///         session = try DevRuntime.ApplicationSession()
///     }
/// }
/// ```
@MainActor
public final class ApplicationSession {
    /// UI refresh, status, and debug-overlay environment owned by this session.
    public let environment: DevRuntime.LiveReloadEnvironment
    /// Runtime Engine that receives temporary development generations.
    public let runtime: Runtime.Engine
    /// Active authenticated connection graph, or `nil` when disabled or
    /// awaiting debugger handoff.
    public private(set) var bootstrap: DevRuntime.Bootstrap?

    private var debuggerHandoffTask: Task<Void, Never>?

    /// Creates a Dev session from the hidden Bridge linked by the Helix Xcode
    /// phase. The optional provider exists for tests and advanced composition;
    /// ordinary App code uses the linked provider automatically.
    ///
    /// - Parameters:
    ///   - environment: UI refresh and diagnostics environment to retain.
    ///   - options: Enabled backends, limits, reconnect policy, and cache path.
    ///   - debuggerHandoffEnabled: Whether to wait for late Xcode credential
    ///     injection when launch variables are initially absent.
    ///   - launchEnvironment: Process environment containing one-run credentials.
    ///   - bridgeProvider: Explicit provider for tests; production Debug builds
    ///     should use the linked provider.
    public convenience init(
        environment: DevRuntime.LiveReloadEnvironment = .init(),
        options: DevRuntime.Bootstrap.Options = .init(),
        debuggerHandoffEnabled: Bool = true,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bridgeProvider: Runtime.BridgeProvider? = nil
    ) throws {
        let provider: Runtime.BridgeProvider
        if let bridgeProvider {
            provider = bridgeProvider
        } else {
            provider = try Runtime.LinkedBridge.load()
        }
        let runtime = try provider.makeRuntime()
        try self.init(
            build: DevRuntime.BuildContract(bridge: provider.descriptor),
            runtime: runtime,
            shell: provider.makeShellInterface(),
            environment: environment,
            installBridge: provider.install(on:),
            options: options,
            debuggerHandoffEnabled: debuggerHandoffEnabled,
            launchEnvironment: launchEnvironment
        )
    }

    /// Creates a session from explicitly assembled Runtime components.
    ///
    /// This initializer is intended for tests and alternate build adapters.
    /// Applications using the generated Xcode integration should use the
    /// convenience initializer.
    public init(
        build: DevRuntime.BuildContract,
        runtime: Runtime.Engine,
        shell: Verification.ShellInterface,
        environment: DevRuntime.LiveReloadEnvironment = .init(),
        installBridge: (Runtime.Engine) throws -> Void,
        options: DevRuntime.Bootstrap.Options = .init(),
        debuggerHandoffEnabled: Bool = true,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try installBridge(runtime)
        bootstrap = try DevRuntime.Bootstrap.startIfConfigured(
            build: build,
            runtime: runtime,
            shell: shell,
            liveReloadEnvironment: environment,
            options: options,
            launchEnvironment: launchEnvironment
        )
        self.environment = environment
        self.runtime = runtime
        debuggerHandoffTask = nil

        if bootstrap == nil, options.isEnabled, debuggerHandoffEnabled {
            debuggerHandoffTask = Task { @MainActor [weak self, environment] in
                guard let launchEnvironment =
                    await DevRuntime.DebuggerHandoff.waitForEnvironment()
                else { return }
                guard let self, self.bootstrap == nil else { return }
                do {
                    self.bootstrap = try DevRuntime.Bootstrap.startIfConfigured(
                        build: build,
                        runtime: self.runtime,
                        shell: shell,
                        liveReloadEnvironment: environment,
                        options: options,
                        launchEnvironment: launchEnvironment
                    )
                } catch {
                    await environment.connectionEventHandler()(
                        .session(.closed("Debugger handoff failed: \(error)"))
                    )
                }
            }
        }
    }

    /// Stops the authenticated Dev connection and cancels pending debugger handoff.
    ///
    /// Scheme lifecycle scripts normally stop the daemon automatically. Call
    /// this method when an application explicitly tears down its runtime owner.
    public func stop() async {
        debuggerHandoffTask?.cancel()
        debuggerHandoffTask = nil
        await bootstrap?.stop()
    }

    deinit {
        debuggerHandoffTask?.cancel()
    }
}
}
#endif
