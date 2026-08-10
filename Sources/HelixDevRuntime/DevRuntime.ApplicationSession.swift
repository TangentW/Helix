#if canImport(Network) && canImport(Security) && canImport(UIKit) && canImport(SwiftUI)
import Foundation
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier

extension DevRuntime {
/// Thin App-owned composition root for the generated Bridge, Runtime Engine,
/// authenticated Dev connection, UI reload coordinators, and debug overlay.
@MainActor
public final class ApplicationSession {
    public let environment: DevRuntime.LiveReloadEnvironment
    public let runtime: Runtime.Engine
    public private(set) var bootstrap: DevRuntime.Bootstrap?

    private var debuggerHandoffTask: Task<Void, Never>?

    /// Creates a Dev session from the hidden Bridge linked by the Helix Xcode
    /// phase. The optional provider exists for tests and advanced composition;
    /// ordinary App code uses the linked provider automatically.
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
