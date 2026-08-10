import Foundation

extension Core {
/// A process-local token shared by every Helix module in one linked runtime
/// image. Different copies indicate an invalid overlapping-product link graph.
public struct RuntimeImageIdentity: Hashable, Sendable {
    private let token: UUID

    public init() {
        token = UUID()
    }

    public static let current = Core.RuntimeImageIdentity()
}
}
