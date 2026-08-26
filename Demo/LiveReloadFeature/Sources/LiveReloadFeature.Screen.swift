import QuartzCore
import UIKit

public enum LiveReloadFeature {}

extension LiveReloadFeature {
@MainActor
public final class ScreenViewController: UIViewController {
    private let badgeLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let countLabel = UILabel()
    private let incrementButton = UIButton(type: .system)
    private var tapCount = 0

    public override func viewDidLoad() {
        super.viewDidLoad()
        installHierarchy()
        updateStateLabel()
    }

    /// Edit the presentation values below and save this file. Helix compiles
    /// this callback to HLBC, calls the unchanged presentation helper through
    /// its Shell Entry, then asks UIKit to lay out this same instance.
    public override func viewDidLayoutSubviews() {
        // Keep the real Demo exercising both non-Objective-C native paths.
        // These values are intentionally behavior-neutral smoke probes.
        _ = currentMediaTimeProbe()
        _ = Date(timeIntervalSince1970: 0).addingTimeInterval(1)

        applyPresentation(
            badge: "HLBC · SAME VM ON DEVICE AND SIMULATOR",
            title: "Hello World", // HELIX_LIVE_BASELINE
            detail: "Edit this callback in Xcode. No rebuild. No reinstall."
        )
    }

    /// UIKit interaction stays in the original signed App. A changed HLBC
    /// function reaches it through the generation-aware Shell Entry table.
    private func applyPresentation(badge: String, title: String, detail: String) {
        super.viewDidLayoutSubviews()

        var intrinsicContentChanged = false
        if badgeLabel.text != badge {
            badgeLabel.text = badge
            intrinsicContentChanged = true
        }
        if titleLabel.text != title {
            titleLabel.text = title
            intrinsicContentChanged = true
        }
        if detailLabel.text != detail {
            detailLabel.text = detail
            intrinsicContentChanged = true
        }

        let badgeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let titleFont = UIFont.systemFont(ofSize: 34, weight: .black)
        let detailFont = UIFont.systemFont(ofSize: 16)
        let countFont = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        if badgeLabel.font != badgeFont {
            badgeLabel.font = badgeFont
            intrinsicContentChanged = true
        }
        if titleLabel.font != titleFont {
            titleLabel.font = titleFont
            intrinsicContentChanged = true
        }
        if detailLabel.font != detailFont {
            detailLabel.font = detailFont
            intrinsicContentChanged = true
        }
        if countLabel.font != countFont {
            countLabel.font = countFont
            intrinsicContentChanged = true
        }

        view.backgroundColor = UIColor(red: 0.96, green: 0.98, blue: 1, alpha: 1)
        badgeLabel.textColor = .systemBlue
        detailLabel.textColor = .secondaryLabel

        if intrinsicContentChanged {
            // The callback runs after the current Auto Layout pass. Schedule a
            // fresh outer pass when text or fonts change so hit testing uses
            // the updated stack bounds as well as its visible subview frames.
            view.setNeedsUpdateConstraints()
            view.setNeedsLayout()
        }
    }

    private func installHierarchy() {
        badgeLabel.textAlignment = .center
        badgeLabel.accessibilityIdentifier = "helix.live.badge"

        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "helix.live.title"

        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        countLabel.textAlignment = .center
        countLabel.accessibilityIdentifier = "helix.live.count"

        incrementButton.configuration = .filled()
        incrementButton.configuration?.title = "Change in-memory state"
        incrementButton.accessibilityIdentifier = "helix.live.increment"
        incrementButton.addTarget(
            self,
            action: #selector(incrementCounter),
            for: .touchUpInside
        )

        let stack = UIStackView(arrangedSubviews: [
            badgeLabel, titleLabel, detailLabel, countLabel, incrementButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            incrementButton.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func currentMediaTimeProbe() -> Double {
        CACurrentMediaTime()
    }

    @objc
    private func incrementCounter() {
        tapCount += 1
        updateStateLabel()
    }

    private func updateStateLabel() {
        countLabel.text = "State retained: \(tapCount)"
    }
}
}
