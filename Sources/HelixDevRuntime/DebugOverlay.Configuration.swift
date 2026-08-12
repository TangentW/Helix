#if canImport(UIKit)
import UIKit

extension DebugOverlay {
/// Visual placement and presentation options for the debug overlay.
public struct Configuration: Hashable, Sendable {
    /// Whether each scene's status panel starts in its expanded form.
    public var startsExpanded: Bool
    /// Whether the overlay hides after five seconds without a new status event.
    ///
    /// A later status event presents it again with an animation. Disable this
    /// option when a persistent development indicator is preferable.
    public var automaticallyHides: Bool
    /// Distance from the host window's horizontal safe-area edges.
    public var horizontalMargin: CGFloat
    /// Distance from the host window's vertical safe-area edges.
    public var verticalMargin: CGFloat

    /// Creates overlay layout and presentation options.
    ///
    /// Margins are expressed in UIKit points. For example, a persistent panel
    /// with the standard placement can be configured as follows:
    ///
    /// ```swift
    /// let configuration = DebugOverlay.Configuration(
    ///     startsExpanded: true,
    ///     automaticallyHides: false
    /// )
    /// ```
    public init(
        startsExpanded: Bool = false,
        automaticallyHides: Bool = true,
        horizontalMargin: CGFloat = 12,
        verticalMargin: CGFloat = 12
    ) {
        self.startsExpanded = startsExpanded
        self.automaticallyHides = automaticallyHides
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
    }
}
}
#endif
