#if canImport(UIKit)
import Foundation
import UIKit

public enum DebugOverlay {}

extension DebugOverlay {
public struct Configuration: Hashable, Sendable {
    public var startsExpanded: Bool
    public var horizontalMargin: CGFloat
    public var verticalMargin: CGFloat

    public init(
        startsExpanded: Bool = false,
        horizontalMargin: CGFloat = 12,
        verticalMargin: CGFloat = 12
    ) {
        self.startsExpanded = startsExpanded
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
    }
}

@MainActor
public final class Controller {
    public typealias ManualReloadHandler = @MainActor () async -> Void

    public let store: DevStatus.Store
    public let configuration: DebugOverlay.Configuration

    private let manualReloadHandler: ManualReloadHandler
    private var hosts: [String: DebugOverlay.Host] = [:]
    private var observationToken: DevStatus.ObservationToken?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isRunning = false

    public init(
        store: DevStatus.Store,
        configuration: DebugOverlay.Configuration = .init(),
        manualReloadHandler: @escaping ManualReloadHandler = {}
    ) {
        self.store = store
        self.configuration = configuration
        self.manualReloadHandler = manualReloadHandler
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observationToken = store.observe { [weak self] snapshot in
            self?.hosts.values.forEach { $0.panel.update(snapshot) }
        }
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.synchronizeScenes() }
            },
            center.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.synchronizeScenes() }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.synchronizeScenes() }
            },
            center.addObserver(
                forName: UIWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.synchronizeScenes() }
            },
        ]
        synchronizeScenes()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observationToken {
            store.removeObserver(observationToken)
            self.observationToken = nil
        }
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
        hosts.values.forEach { $0.detach() }
        hosts.removeAll()
    }

    public var visibleSceneCount: Int { hosts.count }

    private func synchronizeScenes() {
        guard isRunning else { return }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
        }
        let activeIDs = Set(scenes.map { $0.session.persistentIdentifier })
        for id in hosts.keys where !activeIDs.contains(id) {
            hosts[id]?.detach()
            hosts.removeValue(forKey: id)
        }
        for scene in scenes {
            let id = scene.session.persistentIdentifier
            guard let contentWindow = scene.windows.first(where: {
                $0.isKeyWindow && !$0.isHidden
            }) ?? scene.windows.first(where: { !$0.isHidden }) else {
                hosts[id]?.detach()
                hosts.removeValue(forKey: id)
                continue
            }
            if let host = hosts[id], host.window === contentWindow {
                host.updateLayout()
                continue
            }
            hosts[id]?.detach()
            hosts[id] = DebugOverlay.Host(
                window: contentWindow,
                snapshot: store.snapshot,
                configuration: configuration,
                manualReloadHandler: manualReloadHandler
            )
        }
    }
}

@MainActor
private final class Host {
    private(set) weak var window: UIWindow?
    let panel: DebugOverlay.PanelView
    private let overlayConfiguration: DebugOverlay.Configuration
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    init(
        window: UIWindow,
        snapshot: DevStatus.Snapshot,
        configuration: DebugOverlay.Configuration,
        manualReloadHandler: @escaping DebugOverlay.Controller.ManualReloadHandler
    ) {
        self.window = window
        overlayConfiguration = configuration
        panel = .init(
            snapshot: snapshot,
            configuration: configuration,
            manualReloadHandler: manualReloadHandler
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = "helix.debug-overlay.host"
        window.addSubview(panel)
        let widthConstraint = panel.widthAnchor.constraint(equalToConstant: 1)
        let heightConstraint = panel.heightAnchor.constraint(equalToConstant: 1)
        self.widthConstraint = widthConstraint
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(
                equalTo: window.safeAreaLayoutGuide.topAnchor,
                constant: configuration.verticalMargin
            ),
            panel.trailingAnchor.constraint(
                equalTo: window.safeAreaLayoutGuide.trailingAnchor,
                constant: -configuration.horizontalMargin
            ),
            panel.leadingAnchor.constraint(
                greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor,
                constant: configuration.horizontalMargin
            ),
            widthConstraint,
            heightConstraint,
        ])
        panel.layoutDidChange = { [weak self] in
            self?.updateLayout()
        }
        updateLayout()
    }

    func detach() {
        panel.removeFromSuperview()
        window = nil
    }

    func updateLayout() {
        guard let window else { return }
        window.bringSubviewToFront(panel)
        let safeAreaWidth = window.bounds.width
            - window.safeAreaInsets.left
            - window.safeAreaInsets.right
        let maximumWidth = max(
            1,
            safeAreaWidth - 2 * overlayConfiguration.horizontalMargin
        )
        let size = panel.preferredOverlaySize(maximumWidth: maximumWidth)
        widthConstraint?.constant = size.width
        heightConstraint?.constant = size.height
        window.layoutIfNeeded()
    }
}

@MainActor
class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

@MainActor
private final class PanelView: DebugOverlay.PassThroughView {
    private let manualReloadHandler: DebugOverlay.Controller.ManualReloadHandler

    private let pillButton = UIButton(type: .system)
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let headlineLabel = UILabel()
    private let metadataLabel = UILabel()
    private let detailLabel = UILabel()
    private let manualButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private var canManuallyReload = false
    var layoutDidChange: (() -> Void)?

    init(
        snapshot: DevStatus.Snapshot,
        configuration: DebugOverlay.Configuration,
        manualReloadHandler: @escaping DebugOverlay.Controller.ManualReloadHandler
    ) {
        self.manualReloadHandler = manualReloadHandler
        super.init(frame: .zero)
        backgroundColor = .clear
        configurePill()
        configurePanel()
        panel.isHidden = !configuration.startsExpanded
        update(snapshot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DebugOverlay.PanelView does not support NSCoder")
    }

    func update(_ snapshot: DevStatus.Snapshot) {
        let prefix: String
        switch snapshot.tone {
        case .neutral: prefix = "●"
        case .progress: prefix = "◌"
        case .success: prefix = "✓"
        case .warning: prefix = "!"
        case .error: prefix = "×"
        }
        var pillConfiguration = pillButton.configuration
        pillConfiguration?.title = "\(prefix) \(snapshot.headline)"
        pillConfiguration?.baseBackgroundColor = color(for: snapshot.tone)
        pillButton.configuration = pillConfiguration
        headlineLabel.text = snapshot.headline
        let identities = [
            snapshot.sourceRevision.map(String.init(describing:)),
            snapshot.generationID.map(String.init(describing:)),
        ].compactMap { $0 }
        let operation = identities.isEmpty
            ? snapshot.phase.rawValue
            : identities.joined(separator: " · ")
        if let active = snapshot.activeGenerationID, active != snapshot.generationID {
            metadataLabel.text = "\(operation) · active \(active)"
        } else {
            metadataLabel.text = operation
        }
        detailLabel.text = snapshot.detail
        detailLabel.isHidden = snapshot.detail == nil
        canManuallyReload = snapshot.activeGenerationID != nil
            && snapshot.phase != .restartRequired
        manualButton.isEnabled = canManuallyReload
        manualButton.alpha = manualButton.isEnabled ? 1 : 0.45
        pillButton.accessibilityLabel = "Helix Live Reload: \(snapshot.headline)"
        layoutDidChange?()
    }

    private func configurePill() {
        pillButton.translatesAutoresizingMaskIntoConstraints = false
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.baseForegroundColor = .white
        buttonConfiguration.cornerStyle = .capsule
        buttonConfiguration.contentInsets = .init(
            top: 8,
            leading: 11,
            bottom: 8,
            trailing: 11
        )
        buttonConfiguration.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            return attributes
        }
        pillButton.configuration = buttonConfiguration
        pillButton.layer.shadowColor = UIColor.black.cgColor
        pillButton.layer.shadowOpacity = 0.2
        pillButton.layer.shadowRadius = 5
        pillButton.layer.shadowOffset = .init(width: 0, height: 2)
        pillButton.accessibilityIdentifier = "helix.debug-overlay.pill"
        pillButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        addSubview(pillButton)

        NSLayoutConstraint.activate([
            pillButton.topAnchor.constraint(equalTo: topAnchor),
            pillButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    private func configurePanel() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 14
        panel.clipsToBounds = true
        panel.accessibilityIdentifier = "helix.debug-overlay.panel"
        addSubview(panel)

        headlineLabel.font = .preferredFont(forTextStyle: .headline)
        headlineLabel.numberOfLines = 0
        metadataLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.textColor = .secondaryLabel
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 4

        manualButton.setTitle("Reload UI", for: .normal)
        manualButton.accessibilityIdentifier = "helix.debug-overlay.reload"
        manualButton.addTarget(self, action: #selector(manualReload), for: .touchUpInside)
        collapseButton.setTitle("Collapse", for: .normal)
        collapseButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [manualButton, collapseButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually

        [headlineLabel, metadataLabel, detailLabel, actions].forEach(
            contentStack.addArrangedSubview
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 8
        panel.contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: pillButton.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(
                equalTo: panel.contentView.topAnchor,
                constant: 14
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: panel.contentView.leadingAnchor,
                constant: 14
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: panel.contentView.trailingAnchor,
                constant: -14
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: panel.contentView.bottomAnchor,
                constant: -10
            ),
        ])
    }

    @objc private func togglePanel() {
        panel.isHidden.toggle()
        layoutDidChange?()
    }

    @objc private func manualReload() {
        manualButton.isEnabled = false
        Task { @MainActor [weak self, manualReloadHandler] in
            await manualReloadHandler()
            self?.manualButton.isEnabled = self?.canManuallyReload == true
        }
    }

    private func color(for tone: DevStatus.Tone) -> UIColor {
        switch tone {
        case .neutral: .systemGray
        case .progress: .systemBlue
        case .success: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        }
    }

    func preferredOverlaySize(maximumWidth: CGFloat) -> CGSize {
        let pillSize = pillButton.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        guard !panel.isHidden else {
            return CGSize(
                width: ceil(min(maximumWidth, max(1, pillSize.width))),
                height: ceil(max(1, pillSize.height))
            )
        }
        let panelWidth = min(maximumWidth, max(340, pillSize.width))
        let contentWidth = max(1, panelWidth - 28)
        let contentSize = contentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: ceil(panelWidth),
            height: ceil(pillSize.height + 8 + contentSize.height + 24)
        )
    }
}
}
#endif
