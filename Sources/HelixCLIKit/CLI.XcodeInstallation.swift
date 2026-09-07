import Foundation
import HelixBuildTools
import HelixCore
import HelixHubCore

extension CLI {
public struct XcodeProjectInspection: Codable, Sendable {
    public struct Target: Codable, Sendable {
        public var name: String
        public var productType: String?
        public var supportsSourceCompilation: Bool
        public var configurations: [String]
    }
    public var schemaVersion: UInt16 = 1
    public var projectPath: String
    public var targets: [Target]
    public var schemes: [String]
}

public struct XcodeInstallationReport: Codable, Sendable {
    public var schemaVersion: UInt16 = 1
    public var projectPath: String
    public var hostPlanPath: String
    public var writtenRelativePaths: [String]
}

public struct XcodeUninstallationReport: Codable, Sendable {
    public var schemaVersion: UInt16 = 1
    public var projectPath: String
    public var hostPlanPath: String
}
}

extension CLI.Application {
func uninstallXcodeProject(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: """
        Usage: helix xcode uninstall --project PATH --plan PATH [--json]

        Removes Helix-owned integration through Hub's transactional installer.
        Use the installed Host Plan or a matching backup; keep a backup for recovery
        or repeated removal after generated files are gone. Application source,
        developer files, user package references and signing material are preserved.
        \n
        """)
    }
    let options = try CLI.Arguments(arguments, valueOptions: ["project", "plan"], flagOptions: ["json"])
    guard options.positionals.isEmpty else { throw CLI.Error.usage("xcode uninstall accepts no positional arguments") }
    let inputURL = files.resolve(try options.require("plan"))
    let plan = try XcodeIntegration.HostPlanCodec.decode(readRegularFile(inputURL,
        maximumBytes: XcodeIntegration.HostPlanCodec.maximumDocumentBytes, label: "Xcode removal Host Plan"))
    let project = try Hub.ProjectFileParser().parse(projectURL: files.resolve(try options.require("project")))
    let installedURL = project.sourceRootURL.appendingPathComponent(plan.integrationRoot)
        .appendingPathComponent(XcodeIntegration.HostPlan.defaultFileName)
    // The installer validates the applied plan under its project lock. Removal
    // does not require recipes, signing inputs or compiler outputs.
    try Hub.ProjectInstaller().uninstall(project: project, plan: plan)
    let report = CLI.XcodeUninstallationReport(projectPath: project.projectURL.path, hostPlanPath: installedURL.path)
    if options.hasFlag("json") {
        return .init(exitCode: 0, standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
    }
    return .init(exitCode: 0, standardOutput: "Removed Helix integration from \(report.projectPath)\n")
}

func inspectXcodeProjectTargets(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: "Usage: helix xcode inspect --project PATH [--json]\n")
    }
    let options = try CLI.Arguments(arguments, valueOptions: ["project"], flagOptions: ["json"])
    guard options.positionals.isEmpty else { throw CLI.Error.usage("xcode inspect accepts no positional arguments") }
    let project = try Hub.ProjectFileParser().parse(projectURL: files.resolve(try options.require("project")))
    let report = CLI.XcodeProjectInspection(projectPath: project.projectURL.path,
        targets: project.targets.sorted { $0.name < $1.name }.map {
            .init(name: $0.name, productType: $0.productType,
                  supportsSourceCompilation: $0.supportsSourceCompilation,
                  configurations: $0.configurationNames.sorted())
        }, schemes: project.sharedSchemes.map(\.name).sorted())
    if options.hasFlag("json") {
        return .init(exitCode: 0, standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
    }
    let targets = report.targets.map { "\($0.name): \($0.configurations.joined(separator: ", "))" }
    return .init(exitCode: 0, standardOutput: (targets + ["Schemes: \(report.schemes.joined(separator: ", "))"]).joined(separator: "\n") + "\n")
}

func installXcodeProject(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: """
        Usage: helix xcode install --project PATH --plan PATH [--json]

        Applies the supplied Host Plan through the same transactional installer as Hub.
        Updates PBX settings, phases, package products, shared schemes, and generated files.
        Hot Patch recipes and public trust material must already exist at their plan paths.
        \n
        """)
    }
    let options = try CLI.Arguments(arguments, valueOptions: ["project", "plan"], flagOptions: ["json"])
    guard options.positionals.isEmpty else { throw CLI.Error.usage("xcode install accepts no positional arguments") }
    let planURL = files.resolve(try options.require("plan"))
    let plan = try XcodeIntegration.HostPlanCodec.decode(readRegularFile(
        planURL, maximumBytes: XcodeIntegration.HostPlanCodec.maximumDocumentBytes, label: "Xcode Host Plan"
    ))
    let project = try Hub.ProjectFileParser().parse(projectURL: files.resolve(try options.require("project")))
    _ = try validateHostInputs(plan: plan, planURL: project.sourceRootURL
        .appendingPathComponent(plan.integrationRoot).appendingPathComponent(XcodeIntegration.HostPlan.defaultFileName))
    let installed = try Hub.ProjectInstaller().install(.init(
        project: project, hostPlan: plan, artifacts: [:], requirements: [], developmentIdentityProfiles: []
    ))
    let report = CLI.XcodeInstallationReport(projectPath: installed.projectURL.path,
        hostPlanPath: installed.hostPlanURL.path, writtenRelativePaths: installed.writtenRelativePaths.sorted())
    if options.hasFlag("json") {
        return .init(exitCode: 0, standardOutput: String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n")
    }
    return .init(exitCode: 0, standardOutput: "Installed \(report.hostPlanPath)\n"
        + report.writtenRelativePaths.map { "  \($0)" }.joined(separator: "\n") + "\n")
}
}
