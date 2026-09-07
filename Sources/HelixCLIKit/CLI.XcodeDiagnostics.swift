#if os(macOS)
import Foundation
import HelixBuildTools
import HelixCore

extension CLI.Application {
    func xcodeExclusionSummary(count: Int, context: XcodeIntegration.BuildContext) -> String {
        guard count > 0 else { return "" }
        return "Declarations: \(count) excluded; details: \(context.environment.shellOutputURL.appendingPathComponent("FrontendDiagnostics.json").path)\n"
    }

    func formatXcodeDiagnosis(_ report: FrontendReceipt.DiagnosticReport, json: Bool) throws -> CLI.Result {
        if json {
            return .init(exitCode: report.passed ? 0 : 1,
                standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
        }
        var text = "Frontend diagnosis: \(report.passed ? "passed" : "failed")\n"
        for check in report.checks {
            let elapsed = report.performance?.stages.first { $0.name == check.stage }
                .map { String(format: " (%.3fs)", Double($0.durationMicroseconds) / 1_000_000) } ?? ""
            text += "[\(check.status.rawValue)] \(check.stage)\(elapsed)\n"
            if !check.detail.isEmpty { text += "  " + check.detail.replacingOccurrences(of: "\n", with: "\n  ") + "\n" }
        }
        if !report.diagnostics.isEmpty {
            text += "Frontend eligibility diagnostics:\n"
            for diagnostic in report.diagnostics {
                text += "  \(diagnostic)\n"
                for note in diagnostic.notes { text += "    \(note)\n" }
            }
        }
        if let stages = report.requestedStages, !stages.contains(.receipt) {
            text += "Scope: selected checks (" + stages.map(\.rawValue).joined(separator: ", ") + "); full receipt validation was not requested.\n"
        } else {
            text += "Scope: frontend receipt analysis. Shell/Bridge generation, linking and runtime activation require normal Build/Run.\n"
        }
        return .init(exitCode: report.passed ? 0 : 1, standardOutput: text)
    }
}
#endif
