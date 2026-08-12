#if canImport(UIKit)
import UIKit

extension DebugOverlay {
/// Overlay root that leaves transparent space available to the application.
@MainActor
class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
}
#endif
