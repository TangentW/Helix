import LiveReloadFeature
import UIKit

@main
@MainActor
final class LiveReloadDemoApplication: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let screen = LiveReloadFeature.ScreenViewController()
        screen.navigationItem.title = "Live Reload"
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
