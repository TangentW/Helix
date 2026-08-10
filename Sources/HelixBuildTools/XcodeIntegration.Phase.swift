extension XcodeIntegration {
public enum Phase: String, Codable, CaseIterable, Hashable, Sendable {
    case prepare
    case finalize
    case audit
    case patch
    case liveStart = "live-start"
    case liveStop = "live-stop"

    public func isAvailable(for workflow: XcodeIntegration.Workflow) -> Bool {
        switch (workflow, self) {
        case (_, .prepare), (_, .finalize): true
        case (.hotPatch, .audit), (.hotPatch, .patch): true
        case (.liveReload, .liveStart), (.liveReload, .liveStop): true
        default: false
        }
    }
}
}
