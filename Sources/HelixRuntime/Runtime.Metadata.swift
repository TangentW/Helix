#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
#endif

/// Execution, generation routing, and generated Bridge support for Helix code.
public enum Runtime {}

extension Runtime {
/// Version metadata for the runtime module.
public enum Metadata {
    /// Runtime semantic version embedded in compatibility checks.
    public static let version = Core.Versions.runtime
}
}
