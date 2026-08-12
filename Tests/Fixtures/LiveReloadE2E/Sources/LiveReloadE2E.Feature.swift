import QuartzCore
import UIKit

public enum LiveReloadE2E {}

extension LiveReloadE2E {
@MainActor
public final class HostViewController: UIViewController {
    private let titleLabel = UILabel()

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
        view.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// Saving this body exercises HLBC activation, an imported UIKit enum
    /// setter, a QuartzCore C global, interpolated print, an unchanged Shell
    /// Entry, and inferred UI invalidation. The App neither registers this type
    /// nor owns a reload hook.
    public override func viewDidLayoutSubviews() {
        let title = "HELIX BASELINE"
        titleLabel.textAlignment = .center
        let timestamp = CACurrentMediaTime()
        print("Helix Live Reload title: \(title) at \(timestamp)")
        applyTitle(title)
    }

    private func applyTitle(_ title: String) {
        super.viewDidLayoutSubviews()
        titleLabel.text = title
    }
}
}
