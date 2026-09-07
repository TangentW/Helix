import Foundation
import HelixCore

extension XcodeIntegration {
/// Explicit remote package selection. It does not certify tool/runtime compatibility
/// or resolve the selected revision; Xcode performs package resolution.
public struct RuntimePackageRequirement: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case revision, exactVersion }
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
        }
        guard valid else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "runtimePackageRequirement \(kind.rawValue)=\(String(reflecting: value)) requires a full lowercase 40-hex revision or canonical major.minor.patch version")
        }
    }
}
}
