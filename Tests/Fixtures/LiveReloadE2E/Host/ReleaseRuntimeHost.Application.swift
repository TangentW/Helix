import HelixCore
import HelixPatch
import UIKit

enum ReleaseRuntimeHost {}

extension ReleaseRuntimeHost {
struct RuntimeSentinel {
    let imageIdentity = Core.RuntimeImageIdentity.current
    let sourceDigest = Core.Digest.sha256("ReleaseRuntimeHost.Application.swift")
    let packageVersion = PatchPackage.Metadata.version

    var summary: String {
        let identityIsShared = imageIdentity == Core.RuntimeImageIdentity.current
        return "Helix \(packageVersion) · \(sourceDigest.hex.prefix(8)) · \(identityIsShared)"
    }
}
}

@main
@MainActor
final class ReleaseRuntimeHostApplication: UIResponder, UIApplicationDelegate {
    private let sentinel = ReleaseRuntimeHost.RuntimeSentinel()
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let label = UILabel()
        label.text = sentinel.summary
        label.textAlignment = .center
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
