import HelixDevRuntime
import LiveReloadFeature
import UIKit

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
        session = try DevRuntime.ApplicationSession(environment: environment)
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
