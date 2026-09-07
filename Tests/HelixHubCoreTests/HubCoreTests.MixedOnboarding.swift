#if os(macOS)
import Foundation
import Testing
import HelixBuildTools
import HelixCLIKit
import HelixCore
import HelixDevTools
@testable import HelixHubCore

extension HubCoreTests {
@Suite("Real Xcode mixed-project onboarding", .serialized)
struct MixedOnboarding {
    private struct Observation: Codable {
        var operation: String
        var status: Int32
        var milliseconds: UInt64
        var captureSourceCount: Int?
        var captureFileCount: Int?
    }

    @Test("Mixed Xcode build, transactional installation, diagnosis and driver capture",
          .enabled(if: ProcessInfo.processInfo.environment["HELIX_RUN_MIXED_XCODE"] == "1"))
    func validatesMixedProject() async throws {
        let manager = FileManager.default
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = manager.temporaryDirectory.appendingPathComponent("helix-mixed-xcode-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Mixed Project")
        try manager.copyItem(at: repository.appendingPathComponent("Tests/Fixtures/MixedOnboarding"), to: sourceRoot)
        let project = sourceRoot.appendingPathComponent("MixedOnboarding.xcodeproj")
        let pbx = project.appendingPathComponent("project.pbxproj")
        let original = try String(contentsOf: pbx, encoding: .utf8).replacingOccurrences(of: "\"../../..\"", with: "\"\(repository.path)\"")
        try Data(original.utf8).write(to: pbx)
        let reportPath = ProcessInfo.processInfo.environment["HELIX_MIXED_XCODE_REPORT_DIR"]
        try #require(reportPath == nil || reportPath?.hasPrefix("/") == true, "Report directory must be absolute")
        let reportRoot = reportPath.map { URL(fileURLWithPath: $0) }
        if let reportRoot { try manager.createDirectory(at: reportRoot, withIntermediateDirectories: true) }
        var observations: [Observation] = []
        func save(_ name: String, _ data: Data) throws {
            if let reportRoot { try data.write(to: reportRoot.appendingPathComponent(name), options: .atomic) }
        }
        func run(_ name: String, executable: String = "/usr/bin/xcodebuild", arguments: [String]) throws -> ProcessExecution.Result {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try ProcessExecution.Runner().run(executable: URL(fileURLWithPath: executable),
                arguments: arguments, environment: [:], workingDirectory: sourceRoot)
            observations.append(.init(operation: name, status: result.status,
                milliseconds: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
            try save(name + ".log", Data((result.standardOutput + "\n" + result.standardError).utf8))
            try save("observations.json", Core.CanonicalJSON.encode(observations))
            return result
        }
        let proxy = root.appendingPathComponent("Compiler/swiftc")
        try manager.createDirectory(at: proxy.deletingLastPathComponent(), withIntermediateDirectories: false)
        try XcodeIntegration.CompilerCapture.proxyScript().write(to: proxy)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        func arguments(driver: String, derived: URL) -> [String] {
            ["-project", project.path, "-scheme", "MixedApp", "-configuration", "Debug", "-sdk", "iphonesimulator",
             "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived.path,
             "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO",
             "SWIFT_EXEC=\(proxy.path)", "SWIFT_USE_INTEGRATED_DRIVER=\(driver)", "SWIFT_ENABLE_COMPILE_CACHE=YES"]
                + (driver == "NO" ? ["SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO"] : []) + ["build"]
        }
        func captures(in derived: URL) -> [URL] {
            (manager.subpaths(atPath: derived.path) ?? []).filter { $0.hasSuffix("/" + XcodeIntegration.CompilerCapture.invocationFileName) }
                .map { derived.appendingPathComponent($0) }
        }
        _ = try run("legacy-default-linker-options", arguments: arguments(driver: "NO", derived: root.appendingPathComponent("LegacyDefaultDerivedData"))
            .filter { $0 != "SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO" })
        let legacy = root.appendingPathComponent("LegacyDerivedData")
        let compiled = try run("legacy-build", arguments: arguments(driver: "NO", derived: legacy))
        try #require(compiled.status == 0, "\(compiled.standardError)\n\(compiled.standardOutput.suffix(12_000))")
        let capture = try #require(captures(in: legacy).first)
        let job = try BuildCapture.FrontendJobNormalizer().normalize(
            BuildCapture.SwiftInvocationRecord.decode(Data(contentsOf: capture)), workingDirectory: sourceRoot)
        #expect(job.moduleName == "MixedOnboarding")
        #expect(job.sourcePaths.count == 5)
        #expect(job.arguments.contains("-g"))
        observations[observations.count - 1].captureSourceCount = job.sourcePaths.count
        observations[observations.count - 1].captureFileCount = captures(in: legacy).count
        try save("captured-arguments.json", Core.CanonicalJSON.encode(job.arguments))

        // Probe the integrated mode as evidence, without treating discovery-only
        // proxy calls as proof of a complete target capture or post-compile hook.
        let integrated = root.appendingPathComponent("IntegratedDerivedData")
        _ = try run("integrated-build", arguments: arguments(driver: "YES", derived: integrated))
        if let file = captures(in: integrated).first,
           let record = try? BuildCapture.SwiftInvocationRecord.decode(Data(contentsOf: file)),
           let captured = try? BuildCapture.FrontendJobNormalizer().normalize(record, workingDirectory: sourceRoot) {
            observations[observations.count - 1].captureSourceCount = captured.sourcePaths.count
        }
        observations[observations.count - 1].captureFileCount = captures(in: integrated).count
        try save("observations.json", Core.CanonicalJSON.encode(observations))
        // A sibling real driver can satisfy XCBuild's tool lookup, but successful
        // compilation alone still does not establish Helix capture/hook support.
        let swift = try run("resolve-swift", executable: "/usr/bin/xcrun", arguments: ["--find", "swift"])
        try #require(swift.status == 0)
        try manager.createSymbolicLink(atPath: proxy.deletingLastPathComponent().appendingPathComponent("swift").path,
            withDestinationPath: swift.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        let sibling = root.appendingPathComponent("IntegratedSiblingDerivedData")
        _ = try run("integrated-with-sibling", arguments: arguments(driver: "YES", derived: sibling))
        observations[observations.count - 1].captureFileCount = captures(in: sibling).count
        try save("observations.json", Core.CanonicalJSON.encode(observations))

        let parsed = try Hub.ProjectFileParser().parse(projectURL: project)
        let planned = try Hub.OnboardingPlanner().plan(.init(project: parsed, capabilities: .init([.liveReload]),
            profiles: [.init(id: "live", capability: .liveReload, applicationTargetName: "MixedApp", featureTargetName: "MixedApp",
                featureModuleName: "MixedOnboarding", schemeName: "MixedApp", configurationName: "Debug",
                bundleIdentifier: "dev.helix.mixed-onboarding", namespaceSeed: "fixture")]))
        let inputPlan = sourceRoot.appendingPathComponent("InputPlan.json")
        try XcodeIntegration.HostPlanCodec.encode(planned.hostPlan).write(to: inputPlan)
        var environment = ProcessInfo.processInfo.environment
        environment["HELIX_BUILD_CACHE_DIR"] = root.appendingPathComponent("BuildFacts").path
        let app = CLI.Application(currentDirectoryURL: sourceRoot, environment: environment)
        let installed = app.run(["xcode", "install", "--project", project.path, "--plan", inputPlan.path, "--json"])
        try #require(installed.exitCode == 0, "\(installed.standardError)")
        let featureSettings = try String(contentsOf: sourceRoot.appendingPathComponent(".helix/xcode/Profiles/live/Feature.xcconfig"), encoding: .utf8)
        #expect(featureSettings.contains("SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS = NO"))
        let installedData = try Data(contentsOf: pbx)
        let installedText = String(decoding: installedData, as: UTF8.self)
        #expect(installedText.contains("\"libc++\""))
        #expect(installedText.contains("\"@executable_path/Frameworks\""))
        #expect(installedText.contains("\"*.xcassets\""))
        #expect(app.run(["xcode", "install", "--project", project.path, "--plan", inputPlan.path]).exitCode == 0)
        #expect(try Data(contentsOf: pbx) == installedData)
        let lint = try run("installed-plutil", executable: "/usr/bin/plutil", arguments: ["-lint", pbx.path])
        #expect(lint.status == 0)
        let listing = try run("installed-xcode-list", arguments: ["-list", "-project", project.path, "-json"])
        #expect(listing.status == 0, "\(listing.standardError)")
        try save("project-before.pbxproj", Data(original.utf8))
        try save("project-after.pbxproj", installedData)
        let partialStart = DispatchTime.now().uptimeNanoseconds
        let partial = await app.runAsync(["xcode", "post-compile", "--plan", sourceRoot.appendingPathComponent(".helix/xcode/HostPlan.json").path,
            "--profile", "live", "--capture", capture.path, "--diagnose", "--stages", "source-nominals,imported-types", "--json"])
        try save("selected-diagnosis.json", Data(partial.standardOutput.utf8))
        observations.append(.init(operation: "selected-frontend-diagnosis", status: partial.exitCode,
            milliseconds: (DispatchTime.now().uptimeNanoseconds - partialStart) / 1_000_000))
        try save("observations.json", Core.CanonicalJSON.encode(observations))
        try #require(partial.exitCode == 0, "\(partial.standardOutput)\n\(partial.standardError)")
        let selectedReport = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(partial.standardOutput.utf8))
        #expect(selectedReport.requestedStages == [.importedTypes, .sourceNominals])
        #expect(selectedReport.checks.allSatisfy { $0.status == .passed })
        #expect(selectedReport.performance?.subprocesses.contains { $0.kind == .canonicalSIL } == false)
        #expect(selectedReport.checks.contains { $0.stage == "xcode.catalog_availability" } == false)
        #expect(selectedReport.checks.contains { $0.stage == "frontend.receipt" } == false)
        let start = DispatchTime.now().uptimeNanoseconds
        let diagnosed = await app.runAsync(["xcode", "post-compile", "--plan", sourceRoot.appendingPathComponent(".helix/xcode/HostPlan.json").path,
            "--profile", "live", "--capture", capture.path, "--diagnose", "--json"])
        try save("diagnosis.json", Data(diagnosed.standardOutput.utf8))
        try save("diagnosis-stderr.log", Data(diagnosed.standardError.utf8))
        observations.append(.init(operation: "frontend-diagnosis", status: diagnosed.exitCode,
            milliseconds: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        try save("observations.json", Core.CanonicalJSON.encode(observations))
        try #require(diagnosed.exitCode == 0, "\(diagnosed.standardOutput)\n\(diagnosed.standardError)")
        let report = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(diagnosed.standardOutput.utf8))
        #expect(report.passed)
        #expect(report.checks.contains { $0.stage == "frontend.receipt" && $0.status == .passed })
        for prefix in ["frontend.identity_sil", "frontend.semantic_sil"] {
            for component in ["conformances", "nominal_declarations", "function_locations", "ast_mapping"] {
                #expect(report.checks.contains { $0.stage == prefix + "." + component && $0.status == .passed })
            }
        }
        #expect(report.performance?.stages.contains { $0.name == "prepare.validate_environment" } == true)
        // Replay exact Xcode arguments through the real compiler proxy with a
        // deliberate compiler error. Dependencies already exist; no successful
        // Helix Prepare or Shell is needed to diagnose this attempt.
        let swiftSource = sourceRoot.appendingPathComponent("Sources/MixedFixture.swift")
        let originalSwift = try Data(contentsOf: swiftSource)
        try (originalSwift + Data("\n#if HELIX_PREFLIGHT_FAILURE\n#error(\"preflight fixture failure\")\n#endif\n".utf8)).write(to: swiftSource)
        let successBytes = try Data(contentsOf: capture)
        let rawJob = try BuildCapture.SwiftInvocationRecord.decode(successBytes)
        let failure = try ProcessExecution.Runner().run(executable: proxy,
            arguments: rawJob.arguments + ["-D", "HELIX_PREFLIGHT_FAILURE"],
            environment: ["HELIX_REAL_SWIFT_EXEC": rawJob.executable], workingDirectory: sourceRoot)
        try save("compiler-attempt-failure.log", Data((failure.standardOutput + failure.standardError).utf8))
        try #require(failure.status != 0)
        #expect(try Data(contentsOf: capture) == successBytes)
        let attempt = capture.deletingLastPathComponent().appendingPathComponent(XcodeIntegration.CompilerCapture.attemptFileName)
        let preflightArguments = ["xcode", "preflight", "--plan", sourceRoot.appendingPathComponent(".helix/xcode/HostPlan.json").path,
            "--profile", "live", "--capture", attempt.path, "--json"]
        let inputOnly = await app.runAsync(preflightArguments + ["--stages", "inputs"])
        try save("attempt-input-preflight.json", Data(inputOnly.standardOutput.utf8))
        #expect(inputOnly.exitCode == 0, "\(inputOnly.standardOutput)\n\(inputOnly.standardError)")
        let inputReport = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(inputOnly.standardOutput.utf8))
        #expect(inputReport.performance?.stages.contains { $0.name.contains("compiler_inputs") } == false)
        #expect(inputReport.performance?.subprocesses.allSatisfy { $0.kind != .typedAST && $0.kind != .canonicalSIL } == true)
        let typedFailure = await app.runAsync(preflightArguments)
        try save("attempt-typed-preflight.json", Data(typedFailure.standardOutput.utf8))
        #expect(typedFailure.exitCode != 0)
        let typedReport = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(typedFailure.standardOutput.utf8))
        #expect(typedReport.checks.contains { $0.stage == "frontend.typed_ast" && $0.status == .failed })
        let forbidden = await app.runAsync(["xcode", "post-compile", "--plan", sourceRoot.appendingPathComponent(".helix/xcode/HostPlan.json").path,
            "--profile", "live", "--capture", attempt.path])
        #expect(forbidden.exitCode != 0 && forbidden.standardError.contains("capture path"))
        #expect(!(manager.subpaths(atPath: root.path) ?? []).contains { $0.hasSuffix("/ShellBuildReceipt.json") })
        let removed = app.run(["xcode", "uninstall", "--project", project.path, "--plan", inputPlan.path, "--json"])
        try save("uninstall.json", Data(removed.standardOutput.utf8))
        try #require(removed.exitCode == 0, "\(removed.standardError)")
        let removal = try JSONDecoder().decode(CLI.XcodeUninstallationReport.self, from: Data(removed.standardOutput.utf8))
        #expect(removal.projectPath == project.path)
        #expect(!manager.fileExists(atPath: removal.hostPlanPath))
        let afterRemoval = try Data(contentsOf: pbx)
        try save("project-uninstalled.pbxproj", afterRemoval)
        let uninstalledText = String(decoding: afterRemoval, as: UTF8.self)
        #expect(!uninstalledText.contains("Helix Prepare (Generated)") && !uninstalledText.contains("HelixBuildTrigger_"))
        let uninstalledProject = try Hub.ProjectFileParser().parse(projectURL: project)
        for target in parsed.targets {
            #expect(uninstalledProject.target(named: target.name)?.packageProducts == target.packageProducts)
        }
        #expect(uninstalledText.contains("XCLocalSwiftPackageReference"))
        let uninstalledLint = try run("uninstalled-plutil", executable: "/usr/bin/plutil", arguments: ["-lint", pbx.path])
        #expect(uninstalledLint.status == 0)
        let uninstalledList = try run("uninstalled-xcode-list", arguments: ["-list", "-project", project.path, "-json"])
        #expect(uninstalledList.status == 0)
        try originalSwift.write(to: swiftSource)
        let uninstalledBuild = try run("uninstalled-build", arguments: arguments(driver: "NO", derived: legacy))
        #expect(uninstalledBuild.status == 0, "\(uninstalledBuild.standardError)\n\(uninstalledBuild.standardOutput.suffix(12_000))")

    }
}
}
#endif
