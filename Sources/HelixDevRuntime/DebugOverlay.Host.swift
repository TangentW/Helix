#if canImport(UIKit)
import UIKit

extension DebugOverlay {
enum DragEvent {
    case began
    case changed(translation: CGPoint)
    case ended(translation: CGPoint)
}

/// Safe-area geometry used by the host and exercised independently in tests.
struct Placement {
    static func defaultAnchor(
        size: CGSize,
        safeAreaSize: CGSize,
        configuration: DebugOverlay.Configuration
    ) -> CGPoint {
        clampedAnchor(
            CGPoint(
                x: safeAreaSize.width - horizontalMargin(configuration),
                y: verticalMargin(configuration)
            ),
            size: size,
            safeAreaSize: safeAreaSize,
            configuration: configuration
        )
    }

    static func clampedAnchor(
        _ anchor: CGPoint,
        size: CGSize,
        safeAreaSize: CGSize,
        configuration: DebugOverlay.Configuration
    ) -> CGPoint {
        let horizontal = horizontalMargin(configuration)
        let vertical = verticalMargin(configuration)
        let maximumX = max(horizontal, safeAreaSize.width - horizontal)
        let minimumX = min(maximumX, horizontal + size.width)
        let maximumY = max(vertical, safeAreaSize.height - vertical - size.height)
        return CGPoint(
            x: min(max(anchor.x, minimumX), maximumX),
            y: min(max(anchor.y, vertical), maximumY)
        )
    }

    static func origin(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x - size.width, y: anchor.y)
    }

    private static func horizontalMargin(
        _ configuration: DebugOverlay.Configuration
    ) -> CGFloat {
        normalized(configuration.horizontalMargin)
    }

    private static func verticalMargin(
        _ configuration: DebugOverlay.Configuration
    ) -> CGFloat {
        normalized(configuration.verticalMargin)
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}

@MainActor
final class Host {
    private(set) weak var window: UIWindow?
    let panel: DebugOverlay.PanelView

    private let configuration: DebugOverlay.Configuration
    private var leadingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var userAnchor: CGPoint?
    private var dragStartAnchor: CGPoint?
    private var deferredLayoutTask: Task<Void, Never>?

    init(
        window: UIWindow,
        snapshot: DevStatus.Snapshot,
        configuration: DebugOverlay.Configuration,
        manualReloadHandler: @escaping DebugOverlay.Controller.ManualReloadHandler
    ) {
        self.window = window
        self.configuration = configuration
        panel = .init(
            snapshot: snapshot,
            configuration: configuration,
            manualReloadHandler: manualReloadHandler
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = "helix.debug-overlay.host"
        window.addSubview(panel)

        let leadingConstraint = panel.leadingAnchor.constraint(
            equalTo: window.safeAreaLayoutGuide.leadingAnchor
        )
        let topConstraint = panel.topAnchor.constraint(
            equalTo: window.safeAreaLayoutGuide.topAnchor
        )
        let widthConstraint = panel.widthAnchor.constraint(equalToConstant: 1)
        let heightConstraint = panel.heightAnchor.constraint(equalToConstant: 1)
        self.leadingConstraint = leadingConstraint
        self.topConstraint = topConstraint
        self.widthConstraint = widthConstraint
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            leadingConstraint,
            topConstraint,
            widthConstraint,
            heightConstraint,
        ])

        panel.layoutDidChange = { [weak self] in
            self?.updateLayout()
        }
        panel.dragDidChange = { [weak self] event in
            self?.handleDrag(event)
        }
        updateLayout()
    }

    func detach() {
        deferredLayoutTask?.cancel()
        deferredLayoutTask = nil
        panel.prepareForRemoval()
        panel.removeFromSuperview()
        window = nil
    }

    func updateLayout() {
        updateLayout(allowsDeferredRetry: true)
    }

    private func updateLayout(allowsDeferredRetry: Bool) {
        guard let window else { return }
        window.layoutIfNeeded()
        guard let safeAreaSize = resolvedSafeAreaSize(in: window) else {
            guard allowsDeferredRetry, deferredLayoutTask == nil else { return }
            deferredLayoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard !Task.isCancelled else { return }
                self?.deferredLayoutTask = nil
                self?.updateLayout(allowsDeferredRetry: false)
            }
            return
        }
        deferredLayoutTask?.cancel()
        deferredLayoutTask = nil

        window.bringSubviewToFront(panel)
        let maximumWidth = max(
            1,
            safeAreaSize.width - 2 * normalized(configuration.horizontalMargin)
        )
        let size = panel.preferredOverlaySize(maximumWidth: maximumWidth)
        let proposedAnchor = userAnchor ?? DebugOverlay.Placement.defaultAnchor(
            size: size,
            safeAreaSize: safeAreaSize,
            configuration: configuration
        )
        let anchor = DebugOverlay.Placement.clampedAnchor(
            proposedAnchor,
            size: size,
            safeAreaSize: safeAreaSize,
            configuration: configuration
        )
        if userAnchor != nil { userAnchor = anchor }
        apply(anchor: anchor, size: size, in: window)
    }

    private func handleDrag(_ event: DebugOverlay.DragEvent) {
        guard let window,
              let safeAreaSize = resolvedSafeAreaSize(in: window)
        else { return }
        let size = CGSize(
            width: widthConstraint?.constant ?? panel.bounds.width,
            height: heightConstraint?.constant ?? panel.bounds.height
        )
        switch event {
        case .began:
            let current = CGPoint(
                x: (leadingConstraint?.constant ?? 0) + size.width,
                y: topConstraint?.constant ?? 0
            )
            dragStartAnchor = current
            userAnchor = current
        case let .changed(translation), let .ended(translation):
            guard let dragStartAnchor else { return }
            let anchor = DebugOverlay.Placement.clampedAnchor(
                CGPoint(
                    x: dragStartAnchor.x + translation.x,
                    y: dragStartAnchor.y + translation.y
                ),
                size: size,
                safeAreaSize: safeAreaSize,
                configuration: configuration
            )
            userAnchor = anchor
            apply(anchor: anchor, size: size, in: window)
            if case .ended = event { self.dragStartAnchor = nil }
        }
    }

    private func apply(
        anchor: CGPoint,
        size: CGSize,
        in window: UIWindow
    ) {
        let origin = DebugOverlay.Placement.origin(anchor: anchor, size: size)
        leadingConstraint?.constant = origin.x
        topConstraint?.constant = origin.y
        widthConstraint?.constant = size.width
        heightConstraint?.constant = size.height
        window.layoutIfNeeded()
    }

    private func resolvedSafeAreaSize(in window: UIWindow) -> CGSize? {
        let layoutSize = window.safeAreaLayoutGuide.layoutFrame.size
        if layoutSize.width > 0, layoutSize.height > 0 {
            return layoutSize
        }
        let boundsSize = window.bounds.inset(by: window.safeAreaInsets).size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return nil }
        return boundsSize
    }

    private func normalized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
}
#endif
