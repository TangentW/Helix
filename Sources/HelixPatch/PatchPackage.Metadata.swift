import HelixBytecode
import HelixCore
import HelixRuntime
import HelixVerifier

/// Signed patch-package models, trust policy, verification, and container I/O.
///
/// Shipping applications normally create ``TrustStore`` and
/// ``AcceptancePolicy`` values, then pass package bytes to
/// ``PatchRuntime/ApplicationSession``. Manifest construction and signing APIs
/// belong on trusted build infrastructure.
public enum PatchPackage {}

extension PatchPackage {
/// Package-format metadata exposed for diagnostics and compatibility checks.
public enum Metadata {
    /// Current semantic package format version.
    public static let version = Core.Versions.package
}
}
