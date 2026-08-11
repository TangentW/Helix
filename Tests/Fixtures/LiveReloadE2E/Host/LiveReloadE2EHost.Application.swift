import HelixDevRuntime
import LiveReloadE2E
import UIKit

enum LiveReloadE2EHost {}

extension LiveReloadE2EHost {
@MainActor
final class RuntimeOwner {
    let session: DevRuntime.ApplicationSession

    init() throws {
        session = try DevRuntime.ApplicationSession(
            environment: .init(overlayConfiguration: .init(startsExpanded: false))
        )
    }
}
}

@main
@MainActor
final class LiveReloadE2EHostApplication: UIResponder, UIApplicationDelegate {
    private var runtimeOwner: LiveReloadE2EHost.RuntimeOwner?
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            runtimeOwner = try LiveReloadE2EHost.RuntimeOwner()
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
