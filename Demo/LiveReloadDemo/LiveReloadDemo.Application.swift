import HelixDevRuntime
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier
import LiveReloadFeature
import LiveReloadFeatureHelixBridge
import UIKit

extension LiveReloadFeature.ScreenViewController: @retroactive LiveReload.Reloadable {
    public func applyLiveReload(_ context: LiveReload.Context) throws {
        refreshAfterReload()
    }
}

enum LiveReloadDemo {}

extension LiveReloadDemo {
@MainActor
final class RuntimeOwner {
    let session: DevRuntime.ApplicationSession
    private let environment: DevRuntime.LiveReloadEnvironment

    init() throws {
        let environment = DevRuntime.LiveReloadEnvironment(
            overlayConfiguration: .init(startsExpanded: false)
        )
        self.environment = environment
        let typeID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadFeature",
            canonicalName: "LiveReloadFeature.ScreenViewController"
        )
        environment.reload.uiKit.typeRegistry.register(
            LiveReloadFeature.ScreenViewController.self,
            for: typeID
        )
        let runtime = try LiveReloadFeatureBridge.makeRuntime()
        session = try DevRuntime.ApplicationSession(
            build: LiveReloadFeatureBridge.makeDevBuildContract(),
            runtime: runtime,
            shell: LiveReloadFeatureBridge.makeShellInterface(),
            environment: environment,
            installBridge: LiveReloadFeatureBridge.bootstrap,
            options: .init(
                supportedBackends: [.nativeDynamicReplacement, .hlbc],
                nativeChainingProbePassed: true
            )
        )
    }

    func startOverlay() {
        environment.startOverlay()
    }
}
}

@main
@MainActor
final class LiveReloadDemoApplication: UIResponder, UIApplicationDelegate {
    private var runtimeOwner: LiveReloadDemo.RuntimeOwner?
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            let owner = try LiveReloadDemo.RuntimeOwner()
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = LiveReloadFeature.ScreenViewController()
            window.makeKeyAndVisible()
            runtimeOwner = owner
            self.window = window
            owner.startOverlay()
            return true
        } catch {
            fatalError("Helix Live Reload Demo bootstrap failed: \(error)")
        }
    }
}
