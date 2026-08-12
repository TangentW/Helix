extension XcodeIntegration {
public enum Phase: String, Codable, CaseIterable, Hashable, Sendable {
    case prepare
    case bridge
    case finalize
    case audit
    case patch
    case liveRegister = "live-register"

    public func isAvailable(for workflow: XcodeIntegration.Workflow) -> Bool {
        switch (workflow, self) {
        case (_, .prepare), (_, .bridge), (_, .finalize): true
        case (.hotPatch, .audit), (.hotPatch, .patch): true
        case (.liveReload, .liveRegister): true
        default: false
        }
    }
}
}
