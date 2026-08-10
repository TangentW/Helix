import HelixDevRuntime
import HelixLiveReloadAPI
import HelixRuntime
import LiveReloadE2E
import LiveReloadE2EHelixBridge
import UIKit

extension LiveReloadE2E.HostViewController: @retroactive LiveReload.Reloadable {
    public func applyLiveReload(_ context: LiveReload.Context) throws {
        viewDidAppear(false)
    }
}

enum LiveReloadE2EHost {}

extension LiveReloadE2EHost {
@MainActor
final class RuntimeOwner {
    let environment = DevRuntime.LiveReloadEnvironment(
        overlayConfiguration: .init(startsExpanded: false)
    )
    private(set) var runtime: Runtime.Engine?
    private(set) var bootstrap: DevRuntime.Bootstrap?

    func start() throws {
        let nominalTypeID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadE2E",
            canonicalName: "LiveReloadE2E.HostViewController"
        )
        environment.reload.uiKit.typeRegistry.register(
            LiveReloadE2E.HostViewController.self,
            for: nominalTypeID
        )
        let runtime = try LiveReloadE2EBridge.makeRuntime()
        try LiveReloadE2EBridge.bootstrap(using: runtime)
        bootstrap = try DevRuntime.Bootstrap.startIfConfigured(
            build: LiveReloadE2EBridge.makeDevBuildContract(),
            runtime: runtime,
            shell: LiveReloadE2EBridge.makeShellInterface(),
            liveReloadEnvironment: environment,
            options: .init(
                supportedBackends: [.nativeDynamicReplacement, .hlbc],
                nativeChainingProbePassed: true
            )
        )
        self.runtime = runtime
    }
}
}

@main
@MainActor
final class LiveReloadE2EHostApplication: UIResponder, UIApplicationDelegate {
    private let runtimeOwner = LiveReloadE2EHost.RuntimeOwner()
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try runtimeOwner.start()
        } catch {
            fatalError("Helix E2E bootstrap failed: \(error)")
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LiveReloadE2E.HostViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
