import Foundation

extension Hub {
/// Product capabilities a project may integrate independently.
public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
    case hotPatch
    case liveReload

    public var displayName: String {
        switch self {
        case .hotPatch: "Hot Patch"
        case .liveReload: "Live Reload"
        }
    }
}

/// Canonical, nonempty capability selection used by onboarding and storage.
public struct CapabilitySelection: Codable, Hashable, Sendable {
    public var values: [Hub.Capability]

    public init(_ values: some Sequence<Hub.Capability> = Hub.Capability.allCases) throws {
        let canonical = Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
        guard !canonical.isEmpty else { throw Hub.Error.noCapabilitiesSelected }
        self.values = canonical
    }

    public func contains(_ capability: Hub.Capability) -> Bool {
        values.contains(capability)
    }
}
}
