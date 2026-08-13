#if canImport(UIKit) && canImport(SwiftUI)
#if canImport(HelixCore)
import HelixDevProtocol
import HelixLiveReloadAPI
#endif
import SwiftUI
import UIKit

extension DevRuntime {
/// Owns the App-side UI reload, status, and overlay surface.
///
/// ``DevRuntime/ApplicationSession`` wires its handlers to transport and
/// activation automatically. Pass a custom environment only when changing UI
/// behavior or presentation.
///
/// UIKit invalidation, SwiftUI pulses, and the on-device debug overlay can all
/// be customized through this single composition point.
@MainActor
public final class LiveReloadEnvironment {
    /// Observable connection, compilation, activation, and UI status.
    public let status: DevStatus.Store
    /// Unified UIKit and SwiftUI refresh coordinator.
    public let reload: UIReload.Coordinator
    /// In-App development status overlay controller.
    public let overlay: DebugOverlay.Controller

    /// Creates a UI reload environment.
    ///
    /// ```swift
    /// let environment = DevRuntime.LiveReloadEnvironment(
    ///     uiKit: .init(resolutionScope: .visibleOnly),
    ///     overlayConfiguration: .init(
    ///         startsExpanded: false,
    ///         automaticallyHides: true
    ///     )
    /// )
    /// let session = try DevRuntime.ApplicationSession(environment: environment)
    /// ```
    ///
    /// - Parameters:
    ///   - uiKit: UIKit discovery and invalidation behavior.
    ///   - pulse: Pulse used by SwiftUI reload boundaries.
    ///   - overlayConfiguration: Layout, initial state, and automatic hiding
    ///     behavior of the debug overlay.
    public init(
        uiKit: UIKitReload.Coordinator = .init(),
        pulse: LiveReload.Pulse = .shared,
        overlayConfiguration: DebugOverlay.Configuration = .init()
    ) {
        let status = DevStatus.Store()
        let reload = UIReload.Coordinator(
            uiKit: uiKit,
            swiftUI: .init(pulse: pulse)
        )
        reload.reportHandler = { [weak status] context, report in
            status?.recordUIResult(
                context: context,
                report.status,
                warnings: report.warnings,
                errors: report.errors
            )
        }
        let overlay = DebugOverlay.Controller(
            store: status,
            configuration: overlayConfiguration
        ) { [weak reload] in
            _ = await reload?.manualReloadLatest()
        }
        self.status = status
        self.reload = reload
        self.overlay = overlay
    }

    /// Attaches the debug overlay to eligible foreground scenes.
    public func startOverlay() {
        overlay.start()
    }

    /// Removes every debug overlay host from the App's scenes.
    public func stopOverlay() {
        overlay.stop()
    }

    /// Returns the handler used after a code generation becomes active.
    public func activationReloadHandler() -> DevActivation.Controller.ReloadHandler {
        reload.activationReloadHandler()
    }

    /// Returns the handler used by manual refresh requests from tooling or overlay.
    public func manualReloadHandler() -> DevRuntimeSession.Controller.ManualReloadHandler {
        reload.manualReloadHandler()
    }

    #if canImport(Network) && canImport(Security)
    /// Returns a connection-event handler that updates ``status``.
    public func connectionEventHandler() -> DevConnection.Client.EventHandler {
        status.connectionEventHandler()
    }
    #endif
}
}
#endif
