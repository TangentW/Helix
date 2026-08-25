import UIKit

enum LiveReloadE2EHost {}

@main
@MainActor
final class LiveReloadE2EHostApplication: UIResponder, UIApplicationDelegate {
    private weak var scenarioController: LiveReloadE2E.HostViewController?
    private var scenarioTimer: Timer?
    private var nextScenarioRevision = 3
    private var scenarioDirectory: URL?
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = LiveReloadE2E.HostViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        startScenarioChannel(controller: controller)
        return true
    }

    private func startScenarioChannel(
        controller: LiveReloadE2E.HostViewController
    ) {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        scenarioController = controller
        scenarioDirectory = directory
        for revision in 3...8 {
            try? FileManager.default.removeItem(
                at: scenarioCommandURL(revision, in: directory)
            )
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("HelixE2EEvidence.txt")
        )
        scenarioTimer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(pollScenarioChannel),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func pollScenarioChannel() {
        guard let directory = scenarioDirectory,
              let controller = scenarioController
        else { return }
        let command = scenarioCommandURL(
            nextScenarioRevision,
            in: directory
        )
        if FileManager.default.fileExists(atPath: command.path) {
            try? FileManager.default.removeItem(at: command)
            nextScenarioRevision += 1
            controller.triggerScenario()
        }
        try? controller.scenarioEvidence().write(
            to: directory.appendingPathComponent("HelixE2EEvidence.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func scenarioCommandURL(
        _ revision: Int,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent("HelixE2ERun-\(revision)")
    }
}
