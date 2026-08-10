import Foundation
import Darwin
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
import HelixPatch
import HelixReleaseTools

extension CLI {
public struct XcodeValidationProfile: Codable, Hashable, Sendable {
    public var id: String
    public var workflow: XcodeIntegration.Workflow
    public var schemeName: String
    public var runtimePackageProduct: String
    public var patchActionSchemeName: String?
}

public struct XcodeValidationReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var projectPath: String
    public var featureCount: UInt32
    public var sourceFileCount: UInt32
    public var profiles: [CLI.XcodeValidationProfile]
}

public enum XcodeDoctorSeverity: String, Codable, Hashable, Sendable {
    case information
    case warning
    case error

    var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .information: 2
        }
    }
}

public struct XcodeDoctorCheck: Codable, Hashable, Sendable {
    public var code: String
    public var severity: CLI.XcodeDoctorSeverity
    public var summary: String
    public var detail: String
}

public struct XcodeDoctorReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var profileID: String
    public var workflow: XcodeIntegration.Workflow
    public var passed: Bool
    public var checks: [CLI.XcodeDoctorCheck]
}
}

extension CLI.Application {
func executeXcode(_ arguments: [String]) throws -> CLI.Result {
    if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.xcodeHelp)
    }
    let command = arguments[0]
    let tail = Array(arguments.dropFirst())
    switch command {
    case "generate": return try generateXcodeIntegration(tail)
    case "validate": return try validateXcodeIntegration(tail)
    case "phase": return try executeXcodePhase(tail)
    case "doctor": return try doctorXcodeIntegration(tail)
    default:
        throw CLI.Error.usage("unknown xcode command \(command)")
    }
}

private func doctorXcodeIntegration(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.xcodeDoctorHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["plan", "profile"],
        flagOptions: ["json", "static"]
    )
    try requireNoXcodePositionals(options, command: "xcode doctor")
    let planURL = files.resolve(try options.require("plan"))
    let planBytes = try readRegularFile(
        planURL,
        maximumBytes: XcodeIntegration.HostPlanCodec.maximumDocumentBytes,
        label: "Xcode Host Plan"
    )
    let plan = try loadHostPlan(at: planURL)
    let profile = try plan.profile(id: options.require("profile"))
    _ = try validateHostInputs(plan: plan, planURL: planURL)
    var checks: [CLI.XcodeDoctorCheck] = []
    checks.append(
        .init(
            code: "HLXXC001",
            severity: .information,
            summary: "Host Plan and referenced inputs are valid",
            detail: "\(plan.features.count) feature(s), \(plan.profiles.count) profile(s)"
        )
    )
    checks.append(contentsOf: inspectGeneratedKit(
        plan: plan,
        planBytes: planBytes,
        planURL: planURL,
        profile: profile
    ))
    checks.append(contentsOf: inspectXcodeProject(
        plan: plan,
        planURL: planURL,
        profile: profile
    ))
    if options.hasFlag("static") {
        checks.append(
            .init(
                code: "HLXXC009",
                severity: .information,
                summary: "Volatile Xcode environment check was skipped",
                detail: "Run Doctor from the generated Xcode phase to validate build settings."
            )
        )
    } else {
        do {
            let context = try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: profile.id,
                variables: environment,
                requireFeatureCompilerSettings: false
            )
            let executable = context.environment.compilerURL
            checks.append(
                .init(
                    code: "HLXXC010",
                    severity: FileManager.default.isExecutableFile(atPath: executable.path)
                        ? .information : .error,
                    summary: "Active Xcode build identity was resolved",
                    detail: "\(context.environment.targetTriple), SDK "
                        + "\(context.environment.sdkBuild), compiler \(executable.path)"
                )
            )
        } catch {
            checks.append(
                .init(
                    code: "HLXXC011",
                    severity: .error,
                    summary: "Active Xcode build environment is incompatible",
                    detail: String(describing: error)
                )
            )
        }
    }
    let conventionalConfiguration = profile.workflow == .hotPatch ? "Release" : "Debug"
    if profile.configurationName != conventionalConfiguration {
        checks.append(
            .init(
                code: "HLXXC012",
                severity: .warning,
                summary: "Profile uses a custom build configuration",
                detail: "Expected the conventional \(conventionalConfiguration) name, got "
                    + profile.configurationName
            )
        )
    }
    checks.sort { ($0.severity.sortOrder, $0.code) < ($1.severity.sortOrder, $1.code) }
    let passed = !checks.contains { $0.severity == .error }
    let report = CLI.XcodeDoctorReport(
        schemaVersion: CLI.XcodeDoctorReport.currentSchemaVersion,
        profileID: profile.id,
        workflow: profile.workflow,
        passed: passed,
        checks: checks
    )
    if options.hasFlag("json") {
        return .init(
            exitCode: passed ? 0 : 1,
            standardOutput: String(
                decoding: try Core.CanonicalJSON.encode(report),
                as: UTF8.self
            ) + "\n"
        )
    }
    let output = checks.map {
        "[\($0.severity.rawValue)] \($0.code): \($0.summary) — \($0.detail)"
    }.joined(separator: "\n") + "\n"
    return .init(exitCode: passed ? 0 : 1, standardOutput: output)
}

private func inspectGeneratedKit(
    plan: XcodeIntegration.HostPlan,
    planBytes: Data,
    planURL: URL,
    profile: XcodeIntegration.Profile
) -> [CLI.XcodeDoctorCheck] {
    let root = planURL.deletingLastPathComponent()
        .appendingPathComponent(plan.integrationRoot, isDirectory: true)
        .standardizedFileURL
    let manifestURL = root.appendingPathComponent("IntegrationManifest.json")
    do {
        let bytes = try readRegularFile(
            manifestURL,
            maximumBytes: 4 * 1_024 * 1_024,
            label: "Xcode Integration Manifest"
        )
        let manifest = try JSONDecoder().decode(
            XcodeIntegration.KitManifest.self,
            from: bytes
        )
        guard try Core.CanonicalJSON.encode(manifest) == bytes,
              manifest.schemaVersion == XcodeIntegration.KitManifest.currentSchemaVersion,
              manifest.hostPlanSHA256 == .sha256(planBytes),
              manifest.profiles.contains(where: { $0.profileID == profile.id })
        else {
            throw CLI.Error.input("integration manifest identity is stale")
        }
        for artifact in manifest.artifacts {
            let url = root.appendingPathComponent(artifact.path).standardizedFileURL
            guard Self.contains(url, in: root) else {
                throw CLI.Error.input("unsafe integration artifact \(artifact.path)")
            }
            let data = try readRegularFile(
                url,
                maximumBytes: 16 * 1_024 * 1_024,
                label: "generated Xcode artifact"
            )
            guard UInt64(data.count) == artifact.byteCount,
                  Core.Digest.sha256(data) == artifact.sha256,
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: url.path
                  ),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.uint16Value & 0o777 == artifact.permissions
            else {
                throw CLI.Error.input("generated artifact drift: \(artifact.path)")
            }
        }
        return [
            .init(
                code: "HLXXC002",
                severity: .information,
                summary: "Generated Xcode kit matches the Host Plan",
                detail: "Verified \(manifest.artifacts.count) generated artifacts."
            ),
        ]
    } catch {
        return [
            .init(
                code: "HLXXC003",
                severity: .error,
                summary: "Generated Xcode kit is missing or stale",
                detail: String(describing: error)
            ),
        ]
    }
}

private func inspectXcodeProject(
    plan: XcodeIntegration.HostPlan,
    planURL: URL,
    profile: XcodeIntegration.Profile
) -> [CLI.XcodeDoctorCheck] {
    let projectURL = planURL.deletingLastPathComponent()
        .appendingPathComponent(plan.projectPath).standardizedFileURL
    let schemeURL = projectURL.appendingPathComponent(
        "xcshareddata/xcschemes/\(profile.schemeName).xcscheme"
    )
    var checks: [CLI.XcodeDoctorCheck] = []
    checks.append(
        .init(
            code: "HLXXC004",
            severity: FileManager.default.fileExists(atPath: schemeURL.path)
                ? .information : .error,
            summary: "Shared scheme \(profile.schemeName)",
            detail: schemeURL.path
        )
    )
    if let patch = profile.patch {
        let patchSchemeURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes/\(patch.actionSchemeName).xcscheme"
        )
        checks.append(
            .init(
                code: "HLXXC013",
                severity: FileManager.default.fileExists(atPath: patchSchemeURL.path)
                    ? .information : .error,
                summary: "Shared patch action scheme \(patch.actionSchemeName)",
                detail: patchSchemeURL.path
            )
        )
    }
    guard projectURL.pathExtension == "xcodeproj" else {
        checks.append(
            .init(
                code: "HLXXC005",
                severity: .information,
                summary: "Workspace target graph inspection is deferred to Xcode",
                detail: projectURL.path
            )
        )
        return checks
    }
    let projectFile = projectURL.appendingPathComponent("project.pbxproj")
    guard let text = try? String(contentsOf: projectFile, encoding: .utf8) else {
        checks.append(
            .init(
                code: "HLXXC006",
                severity: .error,
                summary: "Xcode project file is unreadable",
                detail: projectFile.path
            )
        )
        return checks
    }
    checks.append(
        .init(
            code: "HLXXC007",
            severity: text.contains(profile.applicationTargetName) ? .information : .error,
            summary: "Application target \(profile.applicationTargetName)",
            detail: text.contains(profile.applicationTargetName)
                ? "Target name is present in project.pbxproj."
                : "Target name was not found in project.pbxproj."
        )
    )
    checks.append(
        .init(
            code: "HLXXC008",
            severity: text.contains(profile.runtimePackageProduct) ? .information : .error,
            summary: "Runtime product \(profile.runtimePackageProduct)",
            detail: text.contains(profile.runtimePackageProduct)
                ? "Required package product is present in the project graph."
                : "Required package product was not found in project.pbxproj."
        )
    )
    if let patch = profile.patch {
        checks.append(
            .init(
                code: "HLXXC014",
                severity: text.contains(patch.actionTargetName) ? .information : .error,
                summary: "Patch action target \(patch.actionTargetName)",
                detail: text.contains(patch.actionTargetName)
                    ? "Target name is present in project.pbxproj."
                    : "Target name was not found in project.pbxproj."
            )
        )
    }
    return checks
}

private func executeXcodePhase(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.xcodePhaseHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["plan", "profile", "phase"],
        flagOptions: []
    )
    try requireNoXcodePositionals(options, command: "xcode phase")
    let planURL = files.resolve(try options.require("plan"))
    let plan = try loadHostPlan(at: planURL)
    let profileID = try options.require("profile")
    guard let phase = XcodeIntegration.Phase(rawValue: try options.require("phase")) else {
        throw CLI.Error.usage(
            "--phase must be \(XcodeIntegration.Phase.allCases.map(\.rawValue).joined(separator: ", "))"
        )
    }
    let profile = try plan.profile(id: profileID)
    guard phase.isAvailable(for: profile.workflow) else {
        throw CLI.Error.usage(
            "phase \(phase.rawValue) is unavailable for \(profile.workflow.rawValue)"
        )
    }
    let context: XcodeIntegration.BuildContext
    do {
        context = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: profileID,
            variables: environment,
            requireFeatureCompilerSettings: phase == .prepare
        )
    } catch let error as XcodeIntegration.EnvironmentError {
        throw CLI.Error.input(error.description)
    }
    let phaseLock = try XcodePhaseLock(
        directoryURL: context.environment.profileOutputURL
    )
    defer { phaseLock.unlock() }
    switch phase {
    case .prepare:
        return try prepareXcodeShell(context)
    case .bridge:
        return try compileXcodeBridge(context)
    case .finalize:
        let product = try resolveXcodeProduct(context)
        let archive = try finalizeXcodeShell(context, product: product)
        return .init(
            exitCode: 0,
            standardOutput: "Finalized \(context.environment.finalArchiveURL.path)\n"
                + "Mach-O UUIDs: \(archive.metadata.machOUUIDs.map(\.uuidString).joined(separator: ", "))\n"
        )
    case .liveStart:
        return try startXcodeLiveSession(context)
    case .liveStop:
        try DevProcess.Supervisor().stop(
            stateURL: context.environment.profileOutputURL
                .appendingPathComponent("Session.json"),
            allowMissing: true
        )
        return .init(exitCode: 0, standardOutput: "Stopped Helix Xcode Live Session.\n")
    case .audit:
        let product = try resolveXcodeProduct(context)
        _ = try finalizeXcodeShell(context, product: product)
        let report = try auditXcodeProduct(context, product: product)
        return .init(
            exitCode: report.passed ? 0 : 1,
            standardOutput: describeXcodeAudit(report)
        )
    case .patch:
        return try buildXcodePatch(context)
    }
}

private func auditXcodeProduct(
    _ context: XcodeIntegration.BuildContext,
    product: XcodeIntegration.ProductEnvironment
) throws -> ReleaseLeakage.Report {
    let report = try ReleaseLeakage.AppBundleAuditor().audit(
        appURL: product.applicationBundleURL
    )
    let reportBytes = try Core.CanonicalJSON.encode(report)
    try files.write(
        reportBytes,
        to: context.environment.profileOutputURL.appendingPathComponent("ReleaseAudit.json")
    )
    if report.passed {
        let archiveBytes = try readRegularFile(
            context.environment.finalArchiveURL,
            maximumBytes: 64 * 1_024 * 1_024,
            label: "finalized HLXI"
        )
        let archive = try InterfaceArchive.Codec.decode(archiveBytes).archive
        try validateXcodeArchive(archive, context: context)
        let executableBytes = try readRegularFile(
            product.executableURL,
            maximumBytes: 2 * 1_024 * 1_024 * 1_024,
            label: "audited application executable"
        )
        let now = Date().timeIntervalSince1970
        guard now > 0, now <= Double(Int64.max) else {
            throw CLI.Error.input("system clock cannot timestamp a Release baseline")
        }
        let baseline = XcodeIntegration.ReleaseBaseline(
            profileID: context.profile.id,
            bundleID: context.profile.bundleIdentifier,
            marketingVersion: product.marketingVersion,
            buildNumber: context.environment.buildNumber,
            configurationName: context.environment.configurationName,
            moduleName: context.feature.moduleName,
            targetTriple: context.environment.targetTriple,
            minimumOS: try Core.SemanticVersion(
                parsing: context.environment.minimumOS
            ),
            xcodeBuild: context.environment.xcodeBuild,
            sdkBuild: context.environment.sdkBuild,
            swiftCompilerFingerprint: archive.compatibility.compilerFingerprint,
            machOUUIDs: archive.metadata.machOUUIDs,
            shellInterfaceHash: archive.shellInterfaceHash,
            interfaceArchiveSHA256: .sha256(archiveBytes),
            executableSHA256: .sha256(executableBytes),
            releaseAuditSHA256: .sha256(reportBytes),
            createdAtUnixSeconds: Int64(now)
        )
        try files.write(
            try XcodeIntegration.ReleaseBaselineCodec.encode(baseline),
            to: context.environment.profileOutputURL.appendingPathComponent(
                "ReleaseBaseline.json"
            )
        )
    }
    return report
}

private func describeXcodeAudit(_ report: ReleaseLeakage.Report) -> String {
    guard !report.findings.isEmpty else {
        return "Release leakage audit passed with no findings.\n"
    }
    return report.findings.map {
        "[\($0.severity.rawValue)] \($0.code): \($0.detail)"
    }.joined(separator: "\n") + "\n"
}

private func buildXcodePatch(
    _ context: XcodeIntegration.BuildContext
) throws -> CLI.Result {
    guard context.profile.patch != nil else {
        throw CLI.Error.input(
            "Hot Patch profile \(context.profile.id) has no patch settings"
        )
    }
    let patch: XcodeIntegration.PatchEnvironment
    do {
        patch = try XcodeIntegration.EnvironmentResolver().resolvePatch(
            context: context,
            variables: environment
        )
    } catch let error as XcodeIntegration.EnvironmentError {
        throw CLI.Error.input(error.description)
    }
    let (baseline, archive, audit) = try loadXcodeReleaseBaseline(
        context,
        marketingVersion: patch.marketingVersion
    )
    let recipe: ReleasePipeline.QuickPatchRecipe = try CLI.JSONDocument.decode(
        ReleasePipeline.QuickPatchRecipe.self,
        from: readRegularFile(
            patch.recipeURL,
            maximumBytes: 1 * 1_024 * 1_024,
            label: "quick-patch recipe"
        ),
        kind: .quickPatchRecipe
    )
    let certificate: PatchPackage.SigningCertificate = try CLI.JSONDocument.decode(
        PatchPackage.SigningCertificate.self,
        from: readRegularFile(
            patch.signingCertificateURL,
            maximumBytes: 1 * 1_024 * 1_024,
            label: "signing certificate"
        ),
        kind: .signingCertificate
    )
    let trustedRoot: PatchPackage.TrustedRoot = try CLI.JSONDocument.decode(
        PatchPackage.TrustedRoot.self,
        from: readRegularFile(
            patch.trustedRootURL,
            maximumBytes: 1 * 1_024 * 1_024,
            label: "trusted root"
        ),
        kind: .trustedRoot
    )
    let signingKey: ReleasePipeline.SigningKeyDocument = try CLI.JSONDocument.decode(
        ReleasePipeline.SigningKeyDocument.self,
        from: files.readPrivateKeyDocument(patch.privateKeyURL.path),
        kind: .signingKey
    )
    let now = Date().timeIntervalSince1970
    guard now > 0, now <= Double(Int64.max) else {
        throw CLI.Error.input("system clock cannot timestamp a patch")
    }
    let platform: PatchPackage.Platform = context.environment.sdkName == "iphoneos"
        ? .iOS : .iOSSimulator
    let configuration = try recipe.resolve(
        archive: archive,
        certificate: certificate,
        marketingVersion: patch.marketingVersion,
        architecture: context.environment.architecture,
        platform: platform,
        nowUnixSeconds: Int64(now)
    )
    let artifact = try ReleasePipeline.Builder().build(
        .init(
            configuration: configuration,
            archive: archive,
            sourceFiles: context.sourceURLs,
            compilerURL: context.environment.compilerURL,
            certificate: certificate,
            signingKey: signingKey,
            trustedRoot: trustedRoot
        )
    )
    guard !artifact.report.changedFunctions.isEmpty else {
        throw CLI.Error.input(
            "no eligible Swift function body changed from the finalized Shell"
        )
    }
    let profileRoot = patch.outputRootURL.appendingPathComponent(
        context.profile.id,
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: profileRoot,
            withIntermediateDirectories: true
        )
    } catch {
        throw CLI.Error.input(
            "cannot create patch output root: \(error.localizedDescription)"
        )
    }
    var profileInformation = Darwin.stat()
    let resolvedPatchRoot = patch.outputRootURL.resolvingSymlinksInPath()
    let resolvedProfileRoot = profileRoot.resolvingSymlinksInPath()
    guard lstat(profileRoot.path, &profileInformation) == 0,
          profileInformation.st_mode & S_IFMT == S_IFDIR,
          Self.contains(resolvedProfileRoot, in: resolvedPatchRoot)
    else {
        throw CLI.Error.input("patch profile output is not a contained directory")
    }
    let output = profileRoot.appendingPathComponent("Current", isDirectory: true)
    try files.writeDirectory(
        [
            "Patch.hlxp": artifact.packageBytes,
            "Patch.hlbc": artifact.compilation.bytecode,
            "Patch.disassembly": Data((artifact.compilation.disassembly + "\n").utf8),
            "PatchReport.json": try Core.CanonicalJSON.encode(artifact.report),
            "ResolvedReleaseConfiguration.json": try Core.CanonicalJSON.encode(configuration),
            "ReleaseAudit.json": try Core.CanonicalJSON.encode(audit),
            "ReleaseBaseline.json": try XcodeIntegration.ReleaseBaselineCodec.encode(
                baseline
            ),
        ],
        to: output,
        force: true
    )
    let staged: URL?
    if context.environment.sdkName == "iphonesimulator",
       let inbox = patch.simulatorInboxPath {
        staged = try PatchDelivery.SimulatorStager().stage(
            packageURL: output.appendingPathComponent("Patch.hlxp"),
            bundleID: context.profile.bundleIdentifier,
            relativeInboxPath: inbox
        )
    } else {
        staged = nil
    }
    return .init(
        exitCode: 0,
        standardOutput: "Built signed Helix patch at \(output.path)/Patch.hlxp\n"
            + "Changed functions: \(artifact.report.changedFunctions.count)\n"
            + "SHA-256: \(artifact.report.packageSHA256.hex)\n"
            + (staged.map { "Staged in Simulator: \($0.path)\n" } ?? "")
    )
}

private func loadXcodeReleaseBaseline(
    _ context: XcodeIntegration.BuildContext,
    marketingVersion: String
) throws -> (
    XcodeIntegration.ReleaseBaseline,
    InterfaceArchive.Archive,
    ReleaseLeakage.Report
) {
    let archiveBytes = try readRegularFile(
        context.environment.finalArchiveURL,
        maximumBytes: 64 * 1_024 * 1_024,
        label: "frozen finalized HLXI"
    )
    let archive = try InterfaceArchive.Codec.decode(archiveBytes).archive
    try validateXcodeArchive(archive, context: context)
    let auditBytes = try readRegularFile(
        context.environment.profileOutputURL.appendingPathComponent("ReleaseAudit.json"),
        maximumBytes: 4 * 1_024 * 1_024,
        label: "Release audit report"
    )
    let audit: ReleaseLeakage.Report
    do {
        audit = try JSONDecoder().decode(ReleaseLeakage.Report.self, from: auditBytes)
    } catch {
        throw CLI.Error.input("cannot decode the frozen Release audit report")
    }
    guard try Core.CanonicalJSON.encode(audit) == auditBytes, audit.passed else {
        throw CLI.Error.input("frozen Release audit is noncanonical or failed")
    }
    let baseline = try XcodeIntegration.ReleaseBaselineCodec.decode(
        readRegularFile(
            context.environment.profileOutputURL.appendingPathComponent(
                "ReleaseBaseline.json"
            ),
            maximumBytes: XcodeIntegration.ReleaseBaselineCodec.maximumDocumentBytes,
            label: "Release baseline receipt"
        )
    )
    guard baseline.profileID == context.profile.id,
          baseline.bundleID == context.profile.bundleIdentifier,
          baseline.marketingVersion == marketingVersion,
          baseline.buildNumber == context.environment.buildNumber,
          baseline.configurationName == context.environment.configurationName,
          baseline.moduleName == context.feature.moduleName,
          baseline.targetTriple == context.environment.targetTriple,
          baseline.minimumOS == archive.metadata.minimumOS,
          baseline.xcodeBuild == context.environment.xcodeBuild,
          baseline.sdkBuild == context.environment.sdkBuild,
          baseline.swiftCompilerFingerprint == archive.compatibility.compilerFingerprint,
          baseline.machOUUIDs == archive.metadata.machOUUIDs,
          baseline.shellInterfaceHash == archive.shellInterfaceHash,
          baseline.interfaceArchiveSHA256 == .sha256(archiveBytes),
          baseline.releaseAuditSHA256 == .sha256(auditBytes)
    else {
        throw CLI.Error.input(
            "current Xcode patch action does not match the frozen audited Release baseline"
        )
    }
    return (baseline, archive, audit)
}

private func validateXcodeArchive(
    _ archive: InterfaceArchive.Archive,
    context: XcodeIntegration.BuildContext
) throws {
    let minimumOS: Core.SemanticVersion
    do {
        minimumOS = try Core.SemanticVersion(parsing: context.environment.minimumOS)
    } catch {
        throw CLI.Error.input("current Xcode deployment target is invalid")
    }
    let invocation = archive.metadata.frontendInvocation
    guard archive.metadata.bundleID == context.profile.bundleIdentifier,
          archive.metadata.buildNumber == context.environment.buildNumber,
          archive.metadata.targetTriple == context.environment.targetTriple,
          archive.metadata.minimumOS == minimumOS,
          archive.metadata.xcodeBuild == context.environment.xcodeBuild,
          archive.metadata.sdkBuild == context.environment.sdkBuild,
          invocation.moduleName == context.feature.moduleName,
          invocation.targetTriple == context.environment.targetTriple,
          invocation.sdkName == context.environment.sdkName,
          invocation.sdkBuild == context.environment.sdkBuild,
          Set(archive.sources.map(\.logicalPath)) == Set(context.feature.sourceFiles)
    else {
        throw CLI.Error.input(
            "finalized HLXI does not match the active Xcode profile and source contract"
        )
    }
}

private func resolveXcodeProduct(
    _ context: XcodeIntegration.BuildContext
) throws -> XcodeIntegration.ProductEnvironment {
    do {
        return try XcodeIntegration.EnvironmentResolver().resolveProduct(
            context: context,
            variables: environment
        )
    } catch let error as XcodeIntegration.EnvironmentError {
        throw CLI.Error.input(error.description)
    }
}

@discardableResult
private func finalizeXcodeShell(
    _ context: XcodeIntegration.BuildContext,
    product: XcodeIntegration.ProductEnvironment
) throws -> InterfaceArchive.Archive {
    let executable = try readRegularFile(
        product.executableURL,
        maximumBytes: 2 * 1_024 * 1_024 * 1_024,
        label: "linked application executable"
    )
    let provisional = try InterfaceArchive.Codec.decode(
        readRegularFile(
            context.environment.shellOutputURL.appendingPathComponent(
                "Shell.provisional.hlxi"
            ),
            maximumBytes: 64 * 1_024 * 1_024,
            label: "provisional HLXI"
        )
    ).archive
    let finalized = try ShellBuild.Finalizer().finalize(
        provisionalArchive: provisional,
        linkedExecutable: executable
    )
    try files.write(
        try InterfaceArchive.Codec.encode(finalized),
        to: context.environment.finalArchiveURL
    )
    return finalized
}

private func startXcodeLiveSession(
    _ context: XcodeIntegration.BuildContext
) throws -> CLI.Result {
    let product = try resolveXcodeProduct(context)
    _ = try finalizeXcodeShell(context, product: product)
    let capturedFrontendJobs: [BuildCapture.CapturedFrontendJob]?
    let activityLog: URL?
    if FileManager.default.fileExists(
        atPath: context.environment.frontendInvocationURL.path
    ) {
        capturedFrontendJobs = [
            try BuildCapture.SwiftInvocationReader().readFrontendJob(
                at: context.environment.frontendInvocationURL
            ),
        ]
        activityLog = nil
    } else {
        capturedFrontendJobs = nil
        do {
            activityLog = try BuildCapture.XcodeActivityReader().latestActivityLog(
                in: product.activityLogDirectoryURL
            )
        } catch {
            throw CLI.Error.input(
                "cannot find a captured Swift invocation or Xcode activity log: "
                    + String(describing: error)
            )
        }
    }
    let prepared = try DevSession.Preparer(
        probe: BuildCapture.DefaultFrontendReplayProbe(runner: .init())
    ).prepare(
        .init(
            activityLogURL: activityLog,
            capturedFrontendJobs: capturedFrontendJobs,
            workingDirectory: context.environment.sourceRootURL,
            workspaceURL: product.projectURL,
            scheme: context.profile.schemeName,
            configuration: context.profile.configurationName,
            bundleID: context.profile.bundleIdentifier,
            moduleName: context.feature.moduleName,
            executableURL: product.executableURL,
            reloadIndexURL: context.environment.shellOutputURL
                .appendingPathComponent("ReloadIndex.json"),
            interfaceArchiveURL: context.environment.finalArchiveURL,
            compilerURL: context.environment.compilerURL,
            sourceMappings: Dictionary(
                uniqueKeysWithValues: zip(
                    context.feature.sourceFiles,
                    context.sourceURLs
                ).map { ($0.0, $0.1) }
            ),
            compiledSourceMappings: Dictionary(
                uniqueKeysWithValues: zip(
                    context.feature.sourceFiles,
                    context.sourceURLs
                ).map { ($0.0, $0.1) }
            ),
            expandedCodeSignIdentity: product.expandedCodeSignIdentity,
            teamIdentifier: product.teamIdentifier,
            entitlementsURL: product.entitlementsURL
        )
    )
    let manifestURL = context.environment.profileOutputURL.appendingPathComponent(
        "DevBuildManifest.json"
    )
    let nativeOutput = context.environment.profileOutputURL.appendingPathComponent(
        "Native",
        isDirectory: true
    )
    let configuration = DevSession.Configuration(
        manifestPath: manifestURL.lastPathComponent,
        reloadIndexPath: context.environment.shellOutputURL
            .appendingPathComponent("ReloadIndex.json").path,
        interfaceArchivePath: context.environment.finalArchiveURL.path,
        compilerPath: prepared.compilerURL.path,
        nativeOutputDirectory: nativeOutput.path,
        backendPreference: .automatic,
        deviceNativeMatrixQualified: false,
        listenPort: 0,
        advertiseBonjour: context.environment.sdkName == "iphoneos",
        debounceMilliseconds: 120,
        maximumSourceBytes: 8 * 1_024 * 1_024,
        nativeImageSoftLimit: 50
    )
    try configuration.validate()
    try files.write(
        try Core.CanonicalJSON.encode(prepared.manifest),
        to: manifestURL
    )
    try files.write(
        try Core.CanonicalJSON.encode(configuration),
        to: context.environment.devConfigurationURL
    )
    _ = try DevSession.PreparedConfiguration.load(
        configurationURL: context.environment.devConfigurationURL
    )

    let state = try DevProcess.Supervisor().start(
        .init(
            executableURL: executableURL,
            configurationURL: context.environment.devConfigurationURL,
            stateURL: context.environment.profileOutputURL
                .appendingPathComponent("Session.json"),
            logURL: context.environment.profileOutputURL
                .appendingPathComponent("Daemon.log"),
            lldbInitURL: context.environment.profileOutputURL
                .appendingPathComponent("Helix.lldbinit"),
            target: context.environment.sdkName == "iphonesimulator"
                ? .simulator : .device
        )
    )
    return .init(
        exitCode: 0,
        standardOutput: "Started Helix Xcode Live Session \(state.sessionID.uuidString).\n"
            + "LLDB init: \(state.lldbInitPath)\n"
            + "Daemon log: \(state.logPath)\n"
    )
}

private final class XcodePhaseLock {
    private var descriptor: Int32

    init(directoryURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw CLI.Error.input(
                "cannot create Helix phase directory: \(error.localizedDescription)"
            )
        }
        let lockURL = directoryURL.appendingPathComponent(".phase.lock")
        descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input("cannot open Xcode phase lock at \(lockURL.path)")
        }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            Darwin.close(descriptor)
            descriptor = -1
            throw CLI.Error.input("Xcode phase lock is not a private regular file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw CLI.Error.input(
                "another Helix Xcode phase is already running for this profile"
            )
        }
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}

private func prepareXcodeShell(
    _ context: XcodeIntegration.BuildContext
) throws -> CLI.Result {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: context.environment.compilerURL.path) else {
        throw CLI.Error.input(
            "Swift compiler is not executable: \(context.environment.compilerURL.path)"
        )
    }
    let configurationData = try readRegularFile(
        context.patchConfigurationURL,
        maximumBytes: 4 * 1_024 * 1_024,
        label: "patchability configuration"
    )
    guard let configurationText = String(data: configurationData, encoding: .utf8) else {
        throw CLI.Error.input("patchability configuration is not UTF-8")
    }
    let configuration = try PatchConfiguration.Document.parse(yaml: configurationText)
    let catalog: NativeImportCatalog.Document
    if let catalogURL = context.nativeImportCatalogURL {
        catalog = try NativeImportCatalog.Codec.decode(
            readRegularFile(
                catalogURL,
                maximumBytes: NativeImportCatalog.Codec.maximumDocumentBytes,
                label: "NativeImport catalog"
            )
        )
    } else {
        catalog = .empty
    }
    let minimumOS: Core.SemanticVersion
    do {
        minimumOS = try Core.SemanticVersion(
            parsing: context.environment.minimumOS
        )
    } catch {
        throw CLI.Error.input(
            "invalid deployment target \(context.environment.minimumOS)"
        )
    }
    let invocation = InterfaceArchive.FrontendInvocation(
        moduleName: context.feature.moduleName,
        targetTriple: context.environment.targetTriple,
        sdkName: context.environment.sdkName,
        sdkBuild: context.environment.sdkBuild,
        optimization: context.environment.optimization,
        semanticArguments: context.environment.semanticArguments
    )
    let metadata = try ShellBuild.MetadataFactory().make(
        .init(
            bundleID: context.profile.bundleIdentifier,
            buildNumber: context.environment.buildNumber,
            namespaceSeed: context.profile.namespaceSeed,
            minimumOS: minimumOS,
            xcodeBuild: context.environment.xcodeBuild,
            frontendInvocation: invocation
        )
    )
    let indexed = try FrontendReceipt.Adapter().generate(
        .init(
            metadata: metadata,
            configuration: configuration,
            sources: zip(context.feature.sourceFiles, context.sourceURLs).map {
                .init(logicalPath: $0.0, url: $0.1)
            },
            compilerURL: context.environment.compilerURL,
            nativeImportCatalog: catalog
        )
    )
    let materialized = try ShellBuild.Materializer().materialize(
        receipt: indexed.receipt,
        sourceRoot: context.sourceRootURL
    )
    var artifacts = try materialized.artifacts()
    artifacts["ReleaseMetadata.json"] = try Core.CanonicalJSON.encode(metadata)
    artifacts["ShellBuildReceipt.json"] = try ShellBuildReceipt.Codec.encode(
        indexed.receipt
    )
    artifacts["FrontendDiagnostics.json"] = try Core.CanonicalJSON.encode(
        indexed.diagnostics
    )
    do {
        try manager.createDirectory(
            at: context.environment.profileOutputURL,
            withIntermediateDirectories: true
        )
    } catch {
        throw CLI.Error.input(
            "cannot create Helix profile output: \(error.localizedDescription)"
        )
    }
    try files.writeDirectory(
        artifacts,
        to: context.environment.shellOutputURL,
        force: true
    )
    try prepareXcodeCompilerProxy(context)
    return .init(
        exitCode: 0,
        standardOutput: "Prepared \(context.profile.id) Helix Shell at "
            + "\(context.environment.shellOutputURL.path)\n"
            + "Functions: \(materialized.report.eligibleFunctionCount) eligible, "
            + "\(materialized.report.rejectedFunctionCount) rejected\n"
    )
}

private func prepareXcodeCompilerProxy(
    _ context: XcodeIntegration.BuildContext
) throws {
    let manager = FileManager.default
    let proxy = try XcodeIntegration.CompilerCapture.proxyScript(
        realCompilerURL: context.environment.compilerURL
    )
    do {
        let proxyURL = context.environment.compilerProxyURL
        try manager.createDirectory(
            at: proxyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Keep the last successful capture for incremental builds where Xcode
        // does not need to recompile the Feature target. Bridge compilation
        // validates it against the active compiler, SDK, and target triple.
        try files.write(proxy, to: proxyURL)
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o755))],
            ofItemAtPath: proxyURL.path
        )
    } catch {
        throw CLI.Error.input(
            "cannot prepare the Helix Swift compiler proxy: "
                + error.localizedDescription
        )
    }
}

private func compileXcodeBridge(
    _ context: XcodeIntegration.BuildContext
) throws -> CLI.Result {
    let reportURL = context.environment.shellOutputURL.appendingPathComponent(
        "ShellBuildReport.json"
    )
    let reportBytes = try readRegularFile(
        reportURL,
        maximumBytes: 16 * 1_024 * 1_024,
        label: "Shell build report"
    )
    let report: ShellBuild.Report
    do {
        report = try JSONDecoder().decode(ShellBuild.Report.self, from: reportBytes)
        guard try Core.CanonicalJSON.encode(report) == reportBytes else {
            throw CLI.Error.input("Shell build report is noncanonical")
        }
    } catch let error as CLI.Error {
        throw error
    } catch {
        throw CLI.Error.input(
            "cannot decode the Shell build report: \(error.localizedDescription)"
        )
    }
    let sourceArtifacts = report.generatedSources.filter {
        $0.path.hasPrefix("Generated/") && $0.path.hasSuffix(".swift")
    }.sorted { $0.path < $1.path }
    guard !sourceArtifacts.isEmpty,
          Set(sourceArtifacts.map(\.path)).count == sourceArtifacts.count
    else {
        throw CLI.Error.input("Shell build report contains no unique Bridge sources")
    }
    let shellRoot = context.environment.shellOutputURL.standardizedFileURL
        .resolvingSymlinksInPath()
    let sourceURLs = try sourceArtifacts.map { artifact -> URL in
        let source = context.environment.shellOutputURL
            .appendingPathComponent(artifact.path).standardizedFileURL
        let resolved = source.resolvingSymlinksInPath()
        guard Self.contains(resolved, in: shellRoot) else {
            throw CLI.Error.input("Bridge source escapes the Shell output: \(artifact.path)")
        }
        let bytes = try readRegularFile(
            resolved,
            maximumBytes: 64 * 1_024 * 1_024,
            label: "generated Bridge source"
        )
        guard UInt64(bytes.count) == artifact.byteCount,
              Core.Digest.sha256(bytes) == artifact.contentHash
        else {
            throw CLI.Error.input("generated Bridge source drifted: \(artifact.path)")
        }
        return resolved
    }
    let captured = try BuildCapture.SwiftInvocationReader().readFrontendJob(
        at: context.environment.frontendInvocationURL
    )
    var moduleMapNames = ["HelixRuntimeSupport"]
    if context.profile.workflow == .liveReload {
        moduleMapNames.append("HelixDevRuntimeProbe")
    }
    let runtimeModuleMaps = try moduleMapNames.map { name -> URL in
        let url = context.environment.generatedModuleMapDirectoryURL
            .appendingPathComponent("\(name).modulemap")
        _ = try readRegularFile(
            url,
            maximumBytes: 1 * 1_024 * 1_024,
            label: "\(name) module map"
        )
        return url
    }
    let manager = FileManager.default
    do {
        try manager.createDirectory(
            at: context.environment.bridgeOutputURL,
            withIntermediateDirectories: true
        )
    } catch {
        throw CLI.Error.input(
            "cannot create hidden Bridge output: \(error.localizedDescription)"
        )
    }
    let resolvedProfileOutput = context.environment.profileOutputURL
        .resolvingSymlinksInPath()
    let resolvedBridgeOutput = context.environment.bridgeOutputURL
        .resolvingSymlinksInPath()
    guard Self.contains(resolvedBridgeOutput, in: resolvedProfileOutput),
          let bridgeAttributes = try? manager.attributesOfItem(
              atPath: context.environment.bridgeOutputURL.path
          ),
          (bridgeAttributes[.type] as? FileAttributeType) == .typeDirectory
    else {
        throw CLI.Error.input("hidden Bridge output is not a safe directory")
    }
    let temporary = context.environment.bridgeOutputURL.appendingPathComponent(
        ".HelixBridge.\(UUID().uuidString).o"
    )
    defer { try? manager.removeItem(at: temporary) }
    let moduleSuffix = Core.Digest.sha256(context.profile.id).hex.prefix(16)
    let plan: XcodeIntegration.BridgeCompilationPlan
    do {
        plan = try XcodeIntegration.BridgeCompilationPlanner().plan(
            compilerPath: captured.executable,
            capturedArguments: captured.arguments,
            expectedCompilerPath: context.environment.compilerURL.path,
            expectedCapturedModuleName: context.feature.moduleName,
            expectedTargetTriple: context.environment.targetTriple,
            expectedSDKPath: context.environment.sdkRootURL.path,
            expectedOptimization: context.environment.optimization,
            clangModuleMapURLs: runtimeModuleMaps,
            generatedSourceURLs: sourceURLs,
            outputURL: temporary,
            moduleName: "HelixBridge_\(moduleSuffix)"
        )
    } catch let error as XcodeIntegration.BridgeCompilationError {
        throw CLI.Error.input(error.description)
    }
    let compilation = try ProcessExecution.Runner().run(
        executable: plan.compilerURL,
        arguments: plan.arguments,
        environment: environment,
        workingDirectory: context.environment.bridgeOutputURL
    )
    guard compilation.status == 0 else {
        let diagnostics = String(compilation.standardError.prefix(512 * 1_024))
        throw CLI.Error.input(
            diagnostics.isEmpty
                ? "hidden Bridge compiler exited with status \(compilation.status)"
                : diagnostics
        )
    }
    guard let attributes = try? manager.attributesOfItem(atPath: temporary.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular,
          let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
          byteCount > 0,
          byteCount <= 512 * 1_024 * 1_024
    else {
        throw CLI.Error.input("hidden Bridge compiler produced an invalid object file")
    }
    let objectBytes = try readRegularFile(
        temporary,
        maximumBytes: 512 * 1_024 * 1_024,
        label: "hidden Bridge object"
    )
    let descriptor: MachO.Descriptor
    do {
        descriptor = try MachO.Inspector().inspect(objectBytes)
    } catch {
        throw CLI.Error.input("hidden Bridge compiler produced malformed Mach-O: \(error)")
    }
    let expectedArchitecture = MachO.Architecture(rawValue: context.environment.architecture)
    let expectedPlatform: MachO.Platform = context.environment.platformName == "iphonesimulator"
        ? .iOSSimulator
        : .iOS
    guard descriptor.fileType == 1,
          descriptor.architecture == expectedArchitecture,
          descriptor.platform == expectedPlatform
    else {
        throw CLI.Error.input(
            "hidden Bridge compiler produced an incompatible Mach-O object"
        )
    }
    guard Darwin.rename(temporary.path, context.environment.bridgeObjectURL.path) == 0 else {
        throw CLI.Error.input(
            "cannot atomically publish the hidden Bridge object: "
                + String(cString: strerror(errno))
        )
    }
    return .init(
        exitCode: 0,
        standardOutput: "Compiled hidden Helix Bridge at "
            + "\(context.environment.bridgeObjectURL.path)\n"
            + (compilation.standardError.isEmpty ? "" : compilation.standardError)
    )
}

private func readRegularFile(
    _ url: URL,
    maximumBytes: Int,
    label: String
) throws -> Data {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular,
          let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
          byteCount <= UInt64(maximumBytes)
    else {
        throw CLI.Error.input("\(label) is missing, unsafe, or too large: \(url.path)")
    }
    do {
        return try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
        throw CLI.Error.input("cannot read \(label): \(error.localizedDescription)")
    }
}

private func generateXcodeIntegration(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.xcodeGenerateHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["plan", "output"],
        flagOptions: ["force"]
    )
    try requireNoXcodePositionals(options, command: "xcode generate")
    let planURL = files.resolve(try options.require("plan"))
    let plan = try loadHostPlan(at: planURL)
    _ = try validateHostInputs(plan: plan, planURL: planURL)

    let expectedOutput = planURL.deletingLastPathComponent()
        .appendingPathComponent(plan.integrationRoot, isDirectory: true)
        .standardizedFileURL
    let outputURL = try options.value("output").map(files.resolve) ?? expectedOutput
    guard outputURL.standardizedFileURL == expectedOutput else {
        throw CLI.Error.input(
            "--output must match integrationRoot at \(expectedOutput.path)"
        )
    }
    let inputPath = planURL.standardizedFileURL.path
    let outputPrefix = outputURL.path.hasSuffix("/") ? outputURL.path : outputURL.path + "/"
    guard inputPath != outputURL.path, !inputPath.hasPrefix(outputPrefix) else {
        throw CLI.Error.input("Host Plan input must be outside the generated integration root")
    }
    let base = planURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let parent = outputURL.deletingLastPathComponent()
    let resolvedParent = parent.resolvingSymlinksInPath()
    guard Self.contains(resolvedParent, in: base),
          resolvedParent.path != base.path
    else {
        throw CLI.Error.input("integrationRoot must be nested under the Host Plan directory")
    }
    do {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    } catch {
        throw CLI.Error.input(
            "cannot create Xcode integration parent directory: \(error.localizedDescription)"
        )
    }

    let output = try XcodeIntegration.KitGenerator().generate(plan: plan)
    try files.writeDirectory(
        output.artifacts,
        to: outputURL,
        force: options.hasFlag("force"),
        executablePaths: output.executablePaths
    )
    return .init(
        exitCode: 0,
        standardOutput: "Generated Helix Xcode integration at \(outputURL.path)\n"
            + "Profiles: \(output.manifest.profiles.count), "
            + "artifacts: \(output.artifacts.count)\n"
    )
}

private func validateXcodeIntegration(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.xcodeValidateHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["plan"],
        flagOptions: ["json"]
    )
    try requireNoXcodePositionals(options, command: "xcode validate")
    let planURL = files.resolve(try options.require("plan"))
    let plan = try loadHostPlan(at: planURL)
    let report = try validateHostInputs(plan: plan, planURL: planURL)
    if options.hasFlag("json") {
        return .init(
            exitCode: 0,
            standardOutput: String(
                decoding: try Core.CanonicalJSON.encode(report),
                as: UTF8.self
            ) + "\n"
        )
    }
    return .init(
        exitCode: 0,
        standardOutput: "Helix Xcode Host Plan is valid.\n"
            + "Project: \(report.projectPath)\n"
            + "Features: \(report.featureCount), sources: \(report.sourceFileCount), "
            + "profiles: \(report.profiles.count)\n"
    )
}

private func loadHostPlan(at url: URL) throws -> XcodeIntegration.HostPlan {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLI.Error.input("file does not exist: \(url.path)")
    }
    do {
        return try XcodeIntegration.HostPlanCodec.decode(
            Data(contentsOf: url, options: .mappedIfSafe)
        )
    } catch let error as XcodeIntegration.Error {
        throw CLI.Error.input(error.description)
    } catch {
        throw CLI.Error.input("cannot read Host Plan: \(error.localizedDescription)")
    }
}

private func validateHostInputs(
    plan: XcodeIntegration.HostPlan,
    planURL: URL
) throws -> CLI.XcodeValidationReport {
    let manager = FileManager.default
    let base = planURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let project = base.appendingPathComponent(plan.projectPath).standardizedFileURL
    guard Self.contains(project.resolvingSymlinksInPath(), in: base) else {
        throw CLI.Error.input("Xcode project or workspace escapes the Host Plan root")
    }
    try requireDirectory(project, label: "Xcode project or workspace")

    var sourceCount = 0
    for feature in plan.features {
        let sourceRoot = base.appendingPathComponent(
            feature.sourceRoot,
            isDirectory: true
        ).standardizedFileURL
        try requireDirectory(sourceRoot, label: "feature \(feature.id) source root")
        let resolvedRoot = sourceRoot.resolvingSymlinksInPath()
        guard Self.contains(resolvedRoot, in: base) else {
            throw CLI.Error.input(
                "feature \(feature.id) source root escapes the Host Plan root"
            )
        }
        for logicalPath in feature.sourceFiles {
            let source = sourceRoot.appendingPathComponent(logicalPath).standardizedFileURL
            let resolved = source.resolvingSymlinksInPath()
            guard Self.contains(resolved, in: resolvedRoot) else {
                throw CLI.Error.input(
                    "feature \(feature.id) source escapes its source root: \(logicalPath)"
                )
            }
            try requireRegularFile(source, label: "Swift source")
            sourceCount += 1
        }
        let configurationURL = base.appendingPathComponent(
            feature.patchConfigurationPath
        ).standardizedFileURL
        guard Self.contains(configurationURL.resolvingSymlinksInPath(), in: base) else {
            throw CLI.Error.input(
                "feature \(feature.id) patchability configuration escapes the Host Plan root"
            )
        }
        try requireRegularFile(
            configurationURL,
            label: "patchability configuration"
        )
        if let path = feature.nativeImportCatalogPath {
            let catalogURL = base.appendingPathComponent(path).standardizedFileURL
            guard Self.contains(catalogURL.resolvingSymlinksInPath(), in: base) else {
                throw CLI.Error.input(
                    "feature \(feature.id) NativeImport catalog escapes the Host Plan root"
                )
            }
            try requireRegularFile(
                catalogURL,
                label: "NativeImport catalog"
            )
        }
    }
    guard sourceCount <= 65_536 else {
        throw CLI.Error.input("Xcode Host Plan exceeds 65,536 Swift sources")
    }
    for profile in plan.profiles {
        guard let patch = profile.patch else { continue }
        let inputs: [(String, String)] = [
            (patch.recipePath, "quick-patch recipe"),
            (patch.signingCertificatePath, "signing certificate"),
            (patch.trustedRootPath, "trusted root"),
        ]
        for (path, label) in inputs {
            let url = base.appendingPathComponent(path).standardizedFileURL
            guard Self.contains(url.resolvingSymlinksInPath(), in: base) else {
                throw CLI.Error.input("\(label) escapes the Host Plan root")
            }
            try requireRegularFile(url, label: label)
        }
        let recipeURL = base.appendingPathComponent(patch.recipePath)
        let recipe: ReleasePipeline.QuickPatchRecipe = try CLI.JSONDocument.decode(
            ReleasePipeline.QuickPatchRecipe.self,
            from: try Data(contentsOf: recipeURL, options: .mappedIfSafe),
            kind: .quickPatchRecipe
        )
        try recipe.validate()
    }
    let profiles = plan.profiles.map {
        CLI.XcodeValidationProfile(
            id: $0.id,
            workflow: $0.workflow,
            schemeName: $0.schemeName,
            runtimePackageProduct: $0.runtimePackageProduct,
            patchActionSchemeName: $0.patch?.actionSchemeName
        )
    }
    guard let featureCount = UInt32(exactly: plan.features.count),
          let encodedSourceCount = UInt32(exactly: sourceCount)
    else {
        throw CLI.Error.input("Xcode Host Plan count exceeds its schema")
    }
    return .init(
        schemaVersion: CLI.XcodeValidationReport.currentSchemaVersion,
        projectPath: project.path,
        featureCount: featureCount,
        sourceFileCount: encodedSourceCount,
        profiles: profiles
    )

    func requireDirectory(_ url: URL, label: String) throws {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CLI.Error.input("\(label) does not exist: \(url.path)")
        }
    }

    func requireRegularFile(_ url: URL, label: String) throws {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            throw CLI.Error.input("\(label) is not a regular file: \(url.path)")
        }
    }
}

private func requireNoXcodePositionals(
    _ options: CLI.Arguments,
    command: String
) throws {
    guard options.positionals.isEmpty else {
        throw CLI.Error.usage("\(command) accepts no positional arguments")
    }
}

private static func contains(_ candidate: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
}

static let xcodeGenerateHelp = """
Usage: helix xcode generate --plan HelixXcode.json [--output .helix/xcode] [--force]

The output must match the plan's integrationRoot. Helix writes the entire kit
atomically so Xcode never observes a partially regenerated source contract.
""" + "\n"

static let xcodeValidateHelp = """
Usage: helix xcode validate --plan HelixXcode.json [--json]

Validation checks canonical schema, workflow/runtime separation, project and
configuration inputs, source containment, and every declared Swift file.
""" + "\n"

static let xcodePhaseHelp = """
Usage: helix xcode phase --plan HelixXcode.json --profile ID --phase PHASE

Phases: prepare, bridge, finalize, audit, patch, live-start, live-stop. This command is
designed for generated Xcode scripts and reads volatile build facts only from
the active Xcode environment.
""" + "\n"

static let xcodeDoctorHelp = """
Usage: helix xcode doctor --plan HelixXcode.json --profile ID [--static] [--json]

Doctor verifies the generated kit, shared scheme, application target, runtime
product, and—unless --static is used—the active Xcode compiler environment.
""" + "\n"
}
