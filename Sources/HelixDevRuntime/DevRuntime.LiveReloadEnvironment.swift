#if canImport(UIKit) && canImport(SwiftUI)
import HelixDevProtocol
import HelixLiveReloadAPI
import SwiftUI
import UIKit

extension DevRuntime {
/// Owns the App-side UI reload surface. The transport and activation objects
/// remain explicit so applications can still choose their budgets and caches.
@MainActor
public final class LiveReloadEnvironment {
    public let status: DevStatus.Store
    public let reload: UIReload.Coordinator
    public let overlay: DebugOverlay.Controller

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

    public func startOverlay() {
        overlay.start()
    }

    public func stopOverlay() {
        overlay.stop()
    }

    public func activationReloadHandler() -> DevActivation.Controller.ReloadHandler {
        reload.activationReloadHandler()
    }

    public func manualReloadHandler() -> DevRuntimeSession.Controller.ManualReloadHandler {
        reload.manualReloadHandler()
    }

    #if canImport(Network) && canImport(Security)
    public func connectionEventHandler() -> DevConnection.Client.EventHandler {
        status.connectionEventHandler()
    }
    #endif
}
}
#endif
