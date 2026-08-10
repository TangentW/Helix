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

    /// This lifecycle body is the save-to-reload acceptance root. Avoid adding
    /// setup work here: the LiveReload hook intentionally invokes it again.
    public override func viewDidAppear(_ animated: Bool) {
        titleLabel.text = "HELIX BASELINE"
    }
}
}
