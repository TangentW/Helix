#if canImport(UIKit)
import UIKit

extension DebugOverlay {
@MainActor
final class PanelView: DebugOverlay.PassThroughView {
    static let defaultAutoHideDelayNanoseconds: UInt64 = 5_000_000_000

    typealias AutoHideCancellation = @MainActor () -> Void
    typealias AutoHideScheduler = @MainActor (
        _ action: @escaping @MainActor () -> Void
    ) -> AutoHideCancellation

    private let manualReloadHandler: DebugOverlay.Controller.ManualReloadHandler
    private let automaticallyHides: Bool
    private let autoHideScheduler: AutoHideScheduler

    private let pillButton = UIButton(type: .system)
    private let expandedPanel = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemMaterial)
    )
    private let headlineLabel = UILabel()
    private let metadataLabel = UILabel()
    private let detailLabel = UILabel()
    private let manualButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private var canManuallyReload = false
    private var lastSequence: UInt64?
    private var cancelAutoHide: AutoHideCancellation?

    private(set) var isExpanded: Bool
    private(set) var isPresented = true
    var layoutDidChange: (() -> Void)?
    var dragDidChange: ((DebugOverlay.DragEvent) -> Void)?

    init(
        snapshot: DevStatus.Snapshot,
        configuration: DebugOverlay.Configuration,
        autoHideScheduler: AutoHideScheduler? = nil,
        manualReloadHandler: @escaping DebugOverlay.Controller.ManualReloadHandler
    ) {
        self.manualReloadHandler = manualReloadHandler
        automaticallyHides = configuration.automaticallyHides
        self.autoHideScheduler = autoHideScheduler
            ?? DebugOverlay.PanelView.productionAutoHideScheduler()
        isExpanded = configuration.startsExpanded
        super.init(frame: .zero)
        backgroundColor = .clear
        configurePill()
        configureExpandedPanel()
        expandedPanel.isHidden = !isExpanded
        update(snapshot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DebugOverlay.PanelView does not support NSCoder")
    }

    func update(_ snapshot: DevStatus.Snapshot) {
        let hadPriorEvent = lastSequence != nil
        let isNewEvent = lastSequence != snapshot.sequence
        lastSequence = snapshot.sequence

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
        pillButton.invalidateIntrinsicContentSize()

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

        if isNewEvent, snapshot.tone == .error {
            setExpanded(true)
        }
        if isNewEvent {
            setPresented(true, animated: hadPriorEvent)
            scheduleAutoHide()
        }
        layoutDidChange?()
    }

    func preferredOverlaySize(maximumWidth: CGFloat) -> CGSize {
        let availableWidth = maximumWidth.isFinite ? max(1, maximumWidth) : 1
        let pillSize = pillButton.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        guard isExpanded else {
            return CGSize(
                width: ceil(min(availableWidth, max(1, pillSize.width))),
                height: ceil(max(1, pillSize.height))
            )
        }

        let panelWidth = min(availableWidth, max(340, pillSize.width))
        let contentWidth = max(1, panelWidth - 28)
        let contentSize = contentStack.systemLayoutSizeFitting(
            CGSize(
                width: contentWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: ceil(panelWidth),
            height: ceil(pillSize.height + 8 + contentSize.height + 24)
        )
    }

    func prepareForRemoval() {
        cancelAutoHide?()
        cancelAutoHide = nil
        layer.removeAllAnimations()
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
        buttonConfiguration.titleLineBreakMode = .byTruncatingTail
        buttonConfiguration.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            return attributes
        }
        pillButton.configuration = buttonConfiguration
        pillButton.titleLabel?.numberOfLines = 1
        pillButton.setContentCompressionResistancePriority(.required, for: .vertical)
        pillButton.layer.shadowColor = UIColor.black.cgColor
        pillButton.layer.shadowOpacity = 0.2
        pillButton.layer.shadowRadius = 5
        pillButton.layer.shadowOffset = .init(width: 0, height: 2)
        pillButton.accessibilityIdentifier = "helix.debug-overlay.pill"
        pillButton.accessibilityHint = "Tap to expand. Drag to reposition."
        pillButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        pillButton.addGestureRecognizer(pan)
        addSubview(pillButton)

        NSLayoutConstraint.activate([
            pillButton.topAnchor.constraint(equalTo: topAnchor),
            pillButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    private func configureExpandedPanel() {
        expandedPanel.translatesAutoresizingMaskIntoConstraints = false
        expandedPanel.layer.cornerRadius = 14
        expandedPanel.clipsToBounds = true
        expandedPanel.accessibilityIdentifier = "helix.debug-overlay.panel"
        addSubview(expandedPanel)

        headlineLabel.font = .preferredFont(forTextStyle: .headline)
        headlineLabel.numberOfLines = 0
        metadataLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.textColor = .secondaryLabel
        metadataLabel.lineBreakMode = .byTruncatingMiddle
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
        expandedPanel.contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            expandedPanel.topAnchor.constraint(
                equalTo: pillButton.bottomAnchor,
                constant: 8
            ),
            expandedPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            expandedPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(
                equalTo: expandedPanel.contentView.topAnchor,
                constant: 14
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: expandedPanel.contentView.leadingAnchor,
                constant: 14
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: expandedPanel.contentView.trailingAnchor,
                constant: -14
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: expandedPanel.contentView.bottomAnchor,
                constant: -10
            ),
        ])
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        expandedPanel.isHidden = !expanded
        pillButton.accessibilityHint = expanded
            ? "Tap to collapse. Drag to reposition."
            : "Tap to expand. Drag to reposition."
        layoutDidChange?()
    }

    private func setPresented(_ presented: Bool, animated: Bool) {
        guard isPresented != presented || isHidden != !presented else { return }
        isPresented = presented
        if presented { isHidden = false }
        let changes = {
            self.alpha = presented ? 1 : 0
            self.transform = presented
                ? .identity
                : CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.97, y: 0.97)
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, !self.isPresented else { return }
            self.isHidden = true
        }
        guard animated else {
            changes()
            if !presented { isHidden = true }
            return
        }
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes,
            completion: completion
        )
    }

    private func scheduleAutoHide() {
        cancelAutoHide?()
        cancelAutoHide = nil
        guard automaticallyHides else { return }
        cancelAutoHide = autoHideScheduler { [weak self] in
            self?.setPresented(false, animated: true)
        }
    }

    private static func productionAutoHideScheduler() -> AutoHideScheduler {
        { action in
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: DebugOverlay.PanelView
                            .defaultAutoHideDelayNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
    }

    private func registerInteraction() {
        setPresented(true, animated: true)
        scheduleAutoHide()
    }

    @objc private func togglePanel() {
        registerInteraction()
        setExpanded(!isExpanded)
    }

    @objc private func manualReload() {
        registerInteraction()
        manualButton.isEnabled = false
        Task { @MainActor [weak self, manualReloadHandler] in
            await manualReloadHandler()
            self?.manualButton.isEnabled = self?.canManuallyReload == true
        }
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            registerInteraction()
            dragDidChange?(.began)
        case .changed:
            dragDidChange?(.changed(translation: translation))
        case .ended, .cancelled, .failed:
            dragDidChange?(.ended(translation: translation))
            registerInteraction()
        case .possible:
            break
        @unknown default:
            dragDidChange?(.ended(translation: translation))
            registerInteraction()
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
}
}
#endif
