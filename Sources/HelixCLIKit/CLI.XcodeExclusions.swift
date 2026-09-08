import Foundation
import HelixCore

extension CLI {
public struct XcodeExclusionReport: Codable, Sendable {
    public var schemaVersion: UInt16 = 1
    public var declarationCount: Int
    public var fileCount: Int
    public var unownedMappingCount: Int
    public var diagnostics: [Core.Diagnostic]
}
}

extension CLI.Application {
    func inspectXcodeExclusions(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: """
            Usage: helix xcode exclusions --diagnostics PATH [--file LOGICAL_PATH] [--json]

            Queries FrontendDiagnostics.json from the last successful Prepare.
            --file matches an exact source-root-relative file path. --json includes
            every matching failure and its evidence; text shows at most 20 entries.
            This is build-time indexing coverage, not runtime activation evidence.

            """)
        }
        let options = try CLI.Arguments(arguments, valueOptions: ["diagnostics", "file"], flagOptions: ["json"])
        guard options.positionals.isEmpty else { throw CLI.Error.usage("xcode exclusions accepts no positional arguments") }
        let url = files.resolve(try options.require("diagnostics"))
        let data = try readRegularFile(url, maximumBytes: 64 * 1_024 * 1_024, label: "frontend diagnostics")
        let file = try options.value("file")
        let values = try JSONDecoder().decode([Core.Diagnostic].self, from: data).filter {
            ["HLXIDX024", "HLXIDX025"].contains($0.code) && (file == nil || $0.location?.file == file)
        }
        let report = CLI.XcodeExclusionReport(
            declarationCount: values.filter { $0.code == "HLXIDX024" }.count,
            fileCount: Set(values.filter { $0.code == "HLXIDX025" }.compactMap { $0.location?.file }).count,
            unownedMappingCount: values.filter { $0.code == "HLXIDX025" }.count, diagnostics: values)
        if options.hasFlag("json") {
            return .init(exitCode: 0, standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
        }
        var text = "Indexing exclusions: \(report.declarationCount) declaration(s), \(report.fileCount) file(s), \(report.unownedMappingCount) unowned mapping failure(s)\n"
        for diagnostic in values.prefix(20) { text += "\(diagnostic)\n" }
        if values.count > 20 { text += "Showing 20 of \(values.count) entries. Use --file or --json for details.\n" }
        text += "Build-time report: \(url.path)\n"
        return .init(exitCode: 0, standardOutput: text)
    }
}
