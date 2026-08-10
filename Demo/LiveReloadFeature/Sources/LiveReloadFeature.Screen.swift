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

    /// Edit the presentation values below and save this file. Helix
    /// classifies this callback as an invalidation-safe UIKit root, activates
    /// its Native replacement, and asks UIKit to lay out this same instance.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.backgroundColor = UIColor(red: 0.96, green: 0.98, blue: 1, alpha: 1)
        badgeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        badgeLabel.text = "NATIVE DYNAMIC REPLACEMENT"
        badgeLabel.textColor = .systemBlue
        titleLabel.text = "SAVE TO RELOAD" // HELIX_LIVE_BASELINE
        detailLabel.text = "Edit this callback in Xcode. No rebuild. No reinstall."
        titleLabel.font = .systemFont(ofSize: 34, weight: .black)
        detailLabel.font = .systemFont(ofSize: 16)
        detailLabel.textColor = .secondaryLabel
        countLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
    }

    /// The host uses this only for the explicit Reloadable fallback. Normal
    /// edits to the layout callback take the inferred invalidation path.
    public func refreshAfterReload() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
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
