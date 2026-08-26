import QuartzCore
import Foundation
import UIKit

public enum LiveReloadE2E {}

extension LiveReloadE2E {
@MainActor
public final class HostViewController: UIViewController {
    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var actionCount = 0
    private var scenarioState = "baseline"

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "helix.live-title"

        actionButton.configuration = .filled()
        actionButton.configuration?.title = "Run Live Reload scenario"
        actionButton.accessibilityIdentifier = "helix.live-action"
        actionButton.addTarget(
            self,
            action: #selector(runScenario),
            for: .touchUpInside
        )
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        view.addSubview(actionButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -48),
            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            actionButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    /// Saving this body exercises HLBC activation, an imported UIKit enum
    /// setter, a QuartzCore C global, interpolated print, an unchanged Shell
    /// Entry, and inferred UI invalidation. The App neither registers this type
    /// nor owns a reload hook.
    public override func viewDidLayoutSubviews() {
        let title = "HELIX BASELINE"
        titleLabel.textAlignment = .center
        let epoch = Date(timeIntervalSince1970: 0)
        _ = epoch // HELIX_E2E_DORMANT_SWIFT_ADAPTER
        let timestamp = CACurrentMediaTime()
        print("Helix Live Reload title: \(title) at \(timestamp)")
        applyTitle(title)
    }

    private func applyTitle(_ title: String) {
        super.viewDidLayoutSubviews()
        titleLabel.text = title
    }

    /// The host-side test channel calls the same UIControl event path as a real
    /// tap, so it invokes a patched private action without a test-only
    /// registration path in Helix.
    public func triggerScenario() {
        actionButton.sendActions(for: .touchUpInside)
    }

    /// Exposes only observable UIKit state to the host-side test driver. It is
    /// ordinary App code and does not bypass the target-action route into the
    /// patched method.
    public func scenarioEvidence() -> String {
        let hasTransientView = view.subviews.contains {
            $0.accessibilityIdentifier == "helix.live-transient"
        }
        return [
            "title=\(titleLabel.text ?? "<none>")",
            "button=\(actionButton.configuration?.title ?? "<none>")",
            "state=\(scenarioState)",
            "presented=\(presentedViewController?.title ?? "<none>")",
            "transient=\(hasTransientView)",
        ].joined(separator: "\n")
    }

    @objc
    private func runScenario() {
        // HELIX_E2E_SCENARIO_BEGIN
        actionCount += 1
        scenarioState = "baseline-action-\(actionCount)"
        titleLabel.text = "HELIX ACTION BASELINE \(actionCount)"
        print("HELIX E2E BASELINE ACTION \(actionCount)")
        // HELIX_E2E_SCENARIO_END
    }
}
}
