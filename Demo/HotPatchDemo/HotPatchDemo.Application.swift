import HelixCore
import HelixPatch
import HotPatchFeature
import UIKit

enum HotPatchDemo {}

extension HotPatchDemo {
@MainActor
final class RuntimeOwner {
    let session: PatchRuntime.ApplicationSession

    init() throws {
        let rootURL = try Self.requiredResource(
            name: "HelixTrustedRoot",
            extension: "json"
        )
        let root = try JSONDecoder().decode(
            PatchPackage.TrustedRoot.self,
            from: Data(contentsOf: rootURL)
        )
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        session = try PatchRuntime.ApplicationSession(
            installationID: Self.installationID(),
            storeRootURL: applicationSupport.appendingPathComponent(
                "HelixPatchStore",
                isDirectory: true
            ),
            trustStore: PatchPackage.TrustStore(roots: [root]),
            acceptancePolicy: .init(
                acceptedDistributionPolicies: [.internalHLBC],
                approvedDistributionPolicyIDs: ["helix-demo-only"]
            ),
            nowUnixSeconds: Self.currentUnixTime()
        )
    }

    func markHealthy() throws {
        try session.markHealthy(nowUnixSeconds: Self.currentUnixTime())
    }

    private static func requiredResource(
        name: String,
        extension pathExtension: String
    ) throws -> URL {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: pathExtension
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func installationID() -> String {
        let key = "HelixDemoInstallationID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func currentUnixTime() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}

@MainActor
final class ScreenViewController: UIViewController {
    private let session: PatchRuntime.ApplicationSession
    private let feeLabel = UILabel()
    private let totalLabel = UILabel()
    private let statusLabel = UILabel()
    private let applyButton = UIButton(type: .system)
    private let rollbackButton = UIButton(type: .system)
    private let subtotalCents: Int64 = 12_900

    init(session: PatchRuntime.ApplicationSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installHierarchy()
        renderPricing()
        renderRuntimeStatus("Audited Release Shell is active")
    }

    private func installHierarchy() {
        let badge = UILabel()
        badge.text = "SIGNED HLBC PATCH"
        badge.textColor = .systemOrange
        badge.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        badge.textAlignment = .center

        let title = UILabel()
        title.text = "Production incident simulation"
        title.font = .systemFont(ofSize: 30, weight: .black)
        title.numberOfLines = 0
        title.textAlignment = .center

        let explanation = UILabel()
        explanation.text = "This ¥129 order should have free delivery, but the shipped body charges ¥19.99."
        explanation.textColor = .secondaryLabel
        explanation.font = .systemFont(ofSize: 16)
        explanation.numberOfLines = 0
        explanation.textAlignment = .center

        [feeLabel, totalLabel, statusLabel].forEach {
            $0.numberOfLines = 0
            $0.textAlignment = .center
        }
        feeLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        feeLabel.accessibilityIdentifier = "helix.patch.fee"
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "helix.patch.status"

        applyButton.configuration = .filled()
        applyButton.configuration?.title = "Mock download and apply"
        applyButton.accessibilityIdentifier = "helix.patch.apply"
        applyButton.addTarget(self, action: #selector(applyPatch), for: .touchUpInside)

        rollbackButton.configuration = .bordered()
        rollbackButton.configuration?.title = "Rollback active patch"
        rollbackButton.accessibilityIdentifier = "helix.patch.rollback"
        rollbackButton.addTarget(self, action: #selector(rollbackPatch), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            badge, title, explanation, feeLabel, totalLabel,
            applyButton, rollbackButton, statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -26),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            applyButton.heightAnchor.constraint(equalToConstant: 48),
            rollbackButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func renderPricing() {
        let fee = deliveryFeeCents(subtotalCents: subtotalCents)
        feeLabel.text = "Delivery: \(currency(fee))"
        feeLabel.textColor = fee == 0 ? .systemGreen : .systemRed
        totalLabel.text = "Order total: \(currency(subtotalCents + fee))"
    }

    private func renderRuntimeStatus(_ message: String) {
        let generation = session.runtime.registry.snapshot().activeGenerationID
        let suffix = generation.map { " · generation \($0.rawValue)" } ?? " · original"
        statusLabel.text = message + suffix
    }

    private func currency(_ cents: Int64) -> String {
        String(format: "¥%.2f", Double(cents) / 100)
    }

    private func inboxURL() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("HelixDemo/Current.hlxp")
    }

    private func currentUnixTime() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    @objc
    private func applyPatch() {
        do {
            let previousGeneration = session.runtime.registry.snapshot().activeGenerationID
            let result = try session.install(
                localPackageURL: inboxURL(),
                nowUnixSeconds: currentUnixTime()
            )
            renderPricing()
            if result.generationLease.generation.id == previousGeneration {
                renderRuntimeStatus("Verified; identical package was already active")
            } else {
                renderRuntimeStatus(
                    "Verified and activated \(result.activatedEntryIndices.count) entry"
                )
            }
        } catch {
            renderRuntimeStatus("Apply failed: \(error)")
        }
    }

    @objc
    private func rollbackPatch() {
        do {
            guard try session.rollback(nowUnixSeconds: currentUnixTime()) != nil else {
                renderRuntimeStatus("No active patch to roll back")
                return
            }
            renderPricing()
            renderRuntimeStatus("Rolled back to the audited original")
        } catch {
            renderRuntimeStatus("Rollback failed: \(error)")
        }
    }
}
}

@main
@MainActor
final class HotPatchDemoApplication: UIResponder, UIApplicationDelegate {
    private var runtimeOwner: HotPatchDemo.RuntimeOwner?
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            let owner = try HotPatchDemo.RuntimeOwner()
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = HotPatchDemo.ScreenViewController(
                session: owner.session
            )
            window.makeKeyAndVisible()
            try owner.markHealthy()
            runtimeOwner = owner
            self.window = window
            return true
        } catch {
            fatalError("Helix Hot Patch Demo bootstrap failed: \(error)")
        }
    }
}
