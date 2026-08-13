import Foundation

extension Hub {
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case noCapabilitiesSelected
    case invalidProject(String)
    case unsupportedProject(String)
    case projectInspectionFailed(String)
    case invalidOnboarding(String)
    case integrationConflict(String)
    case storageFailure(String)
    case transactionFailed(String)

    public var description: String {
        switch self {
        case .noCapabilitiesSelected:
            "select Hot Patch, Live Reload, or both"
        case let .invalidProject(detail):
            "invalid Xcode project: \(detail)"
        case let .unsupportedProject(detail):
            "unsupported Xcode project: \(detail)"
        case let .projectInspectionFailed(detail):
            "Xcode project inspection failed: \(detail)"
        case let .invalidOnboarding(detail):
            "invalid Helix onboarding configuration: \(detail)"
        case let .integrationConflict(detail):
            "Helix integration conflicts with the project: \(detail)"
        case let .storageFailure(detail):
            "Helix Hub storage failed: \(detail)"
        case let .transactionFailed(detail):
            "Helix project transaction failed: \(detail)"
        }
    }
}
}
