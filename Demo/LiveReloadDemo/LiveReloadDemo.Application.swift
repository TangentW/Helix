import HelixDevRuntime
import LiveReloadFeature
import SwiftUI
import UIKit

enum LiveReloadDemo {}

extension LiveReloadDemo {
@MainActor
final class RuntimeOwner {
    let session: DevRuntime.ApplicationSession

    init() throws {
        let environment = DevRuntime.LiveReloadEnvironment(
            overlayConfiguration: .init(startsExpanded: false)
        )
        session = try DevRuntime.ApplicationSession(environment: environment)
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
            let screen = LiveReloadFeature.ScreenViewController()
            screen.navigationItem.title = "Live Reload"
            screen.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Helix",
                style: .plain,
                target: self,
                action: #selector(showHelixDebugPage)
            )
            window.rootViewController = UINavigationController(rootViewController: screen)
            window.makeKeyAndVisible()
            runtimeOwner = owner
            self.window = window
            return true
        } catch {
            fatalError("Helix Live Reload Demo bootstrap failed: \(error)")
        }
    }

    @objc private func showHelixDebugPage() {
        guard let runtimeOwner,
              let navigation = window?.rootViewController as? UINavigationController
        else { return }
        let controller = UIHostingController(
            rootView: DevRuntime.PairingView(session: runtimeOwner.session)
        )
        navigation.pushViewController(controller, animated: true)
    }
}
