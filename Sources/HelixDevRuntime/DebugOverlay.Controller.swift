#if canImport(UIKit)
import Foundation
import UIKit

/// On-device development UI for connection, compilation, and reload status.
public enum DebugOverlay {}

extension DebugOverlay {
/// Attaches a Helix status panel to every active foreground UIKit scene.
///
/// ``DevRuntime/ApplicationSession`` owns and starts this controller by
/// default. Custom integrations can use the same status store and supply a
/// manual reload action:
///
/// ```swift
/// let overlay = DebugOverlay.Controller(store: statusStore) {
///     await reloadCoordinator.manualReloadLatest()
/// }
/// overlay.start()
/// ```
@MainActor
public final class Controller {
    /// Async action invoked when the user taps the overlay's manual reload control.
    public typealias ManualReloadHandler = @MainActor () async -> Void

    /// Observable source rendered by every scene panel.
    public let store: DevStatus.Store
    /// Immutable layout and presentation options.
    public let configuration: DebugOverlay.Configuration

    private let manualReloadHandler: ManualReloadHandler
    private var hosts: [String: DebugOverlay.Host] = [:]
    private var observationToken: DevStatus.ObservationToken?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isRunning = false

    /// Creates an overlay controller without attaching it to any windows.
    ///
    /// Call ``start()`` after application scenes are available. The controller
    /// observes later scene activation and disconnection automatically.
    public init(
        store: DevStatus.Store,
        configuration: DebugOverlay.Configuration = .init(),
        manualReloadHandler: @escaping ManualReloadHandler = {}
    ) {
        self.store = store
        self.configuration = configuration
        self.manualReloadHandler = manualReloadHandler
    }

    /// Starts status observation and attaches panels to active foreground scenes.
    ///
    /// Calling this method more than once is safe and has no additional effect.
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

    /// Removes all panels and observers owned by the controller.
    ///
    /// Calling this method more than once is safe.
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

    /// Number of foreground scenes that currently host a Helix panel.
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
}
#endif
