import HelixCore

/// High-level entry points and metadata for Helix's App-side development runtime.
public enum DevRuntime {}

extension DevRuntime {
/// Version metadata for the development runtime module.
public enum Metadata {
    /// Semantic version of the development runtime API.
    public static let version = Core.SemanticVersion(1, 0, 0)
}
}
