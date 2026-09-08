import Foundation
import HelixCore

extension XcodeIntegration {
/// Explicit remote package selection. It does not certify tool/runtime compatibility
/// or resolve the selected revision; Xcode performs package resolution.
public struct RuntimePackageRequirement: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case revision, exactVersion, branch }
    /// Published runtime baseline used only when creating a new remote reference.
    /// Advance this deliberately after runtime compatibility and package tests.
    public static let defaultRuntime = Self(kind: .revision, value: "df420536312358631c1278d6b3b274e2fda64ddd")
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public func validate() throws {
        let valid: Bool
        switch kind {
        case .revision:
            valid = value.utf8.count == 40 && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
        case .exactVersion:
            valid = (try? Core.SemanticVersion(parsing: value).description) == value
        case .branch:
            let components = value.split(separator: "/", omittingEmptySubsequences: false)
            valid = !value.isEmpty && value.utf8.count <= 255 && !value.hasPrefix("-")
                && !value.contains("..") && components.allSatisfy {
                    !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock")
                } && value.utf8.allSatisfy {
                    (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                        || [0x2d, 0x2e, 0x2f, 0x5f].contains($0)
                }
        }
        guard valid else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "runtimePackageRequirement \(kind.rawValue)=\(String(reflecting: value)) requires a full lowercase 40-hex revision, canonical major.minor.patch version, or an explicit safe ASCII branch name")
        }
    }
}
}
