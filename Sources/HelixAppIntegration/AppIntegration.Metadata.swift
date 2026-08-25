/// Namespace for the application-side integration installed by Helix Hub.
///
/// Applications do not need to import or initialize this module directly.
public enum AppIntegration {}

extension AppIntegration {
    /// The application integration contract remains unified at version 1
    /// while the product is under development.
    public static let contractVersion: UInt16 = 1
}
