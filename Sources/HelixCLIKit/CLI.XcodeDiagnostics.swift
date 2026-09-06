#if os(macOS)
import Foundation
import HelixBuildTools
import HelixCore

extension CLI.Application {
    func formatXcodeDiagnosis(_ report: FrontendReceipt.DiagnosticReport, json: Bool) throws -> CLI.Result {
        if json {
            return .init(exitCode: report.passed ? 0 : 1,
                standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
        }
        var text = "Frontend diagnosis: \(report.passed ? "passed" : "failed")\n"
        for check in report.checks {
            text += "[\(check.status.rawValue)] \(check.stage)\n"
            if !check.detail.isEmpty { text += "  " + check.detail.replacingOccurrences(of: "\n", with: "\n  ") + "\n" }
        }
        if !report.diagnostics.isEmpty {
            text += "Frontend eligibility diagnostics:\n"
            for diagnostic in report.diagnostics {
                text += "  \(diagnostic)\n"
                for note in diagnostic.notes { text += "    \(note)\n" }
            }
        }
        text += "Scope: frontend receipt analysis. Shell/Bridge generation, linking and runtime activation require normal Build/Run.\n"
        return .init(exitCode: report.passed ? 0 : 1, standardOutput: text)
    }
}
#endif
