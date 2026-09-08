#if os(macOS)
import Foundation
import HelixBuildTools
import HelixCore

extension CLI.Application {
    func xcodeExclusionSummary(count: Int, files: Int = 0, unowned: Int = 0, context: XcodeIntegration.BuildContext) -> String {
        guard count > 0 || files > 0 || unowned > 0 else { return "" }
        return "Indexing exclusions: \(count) declaration(s), \(files) source file(s), \(unowned) unowned mapping failure(s). Changes in excluded code require a normal rebuild. Details: \(context.environment.shellOutputURL.appendingPathComponent("FrontendDiagnostics.json").path)\n"
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
            if !check.detail.isEmpty {
                let detail = String(decoding: check.detail.utf8.prefix(4 * 1_024), as: UTF8.self)
                text += "  " + detail.replacingOccurrences(of: "\n", with: "\n  ") + "\n"
                if check.detail.utf8.count > 4 * 1_024 { text += "  Detail truncated; use --json for complete evidence.\n" }
            }
        }
        if !report.diagnostics.isEmpty {
            text += "Frontend eligibility diagnostics:\n"
            for diagnostic in report.diagnostics.prefix(20) {
                text += "  \(diagnostic)\n"
                for note in diagnostic.notes { text += "    \(note)\n" }
            }
            if report.diagnostics.count > 20 {
                text += "  Showing 20 of \(report.diagnostics.count) diagnostics; use --json for the complete list.\n"
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
