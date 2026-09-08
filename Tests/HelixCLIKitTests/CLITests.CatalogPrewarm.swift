import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixCLIKit

extension CLITests {
@Suite("Resumable Catalog prewarm")
struct CatalogPrewarm {
    private final class LaunchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    @Test("Module budget resumes through cache hits and rejects changed build inputs")
    func resumesPrewarm() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-prewarm-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.standardizedFileURL
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity()
        let target = "arm64-apple-ios15.0-simulator"
        for module in ["WarmA", "WarmB"] {
            let source = directory.appendingPathComponent("\(module).swift")
            try Data("public func increment(_ value: Int) -> Int { value + 1 }\n".utf8).write(to: source)
            let output = try frontend.run(arguments: [
                "-emit-module", "-parse-as-library", "-module-name", module,
                "-target", target, "-sdk", sdk.path, source.path,
                "-o", directory.appendingPathComponent("\(module).swiftmodule").path,
            ])
            #expect(output.terminationStatus == 0, "\(output.standardError)")
        }
        let arguments = ["-I", "."]
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.prewarm-test", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.prewarm-test", buildNumber: "1", seed: "test"),
            machOUUIDs: [], targetTriple: target, minimumOS: .init(15), xcodeBuild: "test", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(moduleName: "WarmConsumer", targetTriple: target, sdkName: sdk.name,
                sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library"] + arguments),
            transformPipelineHash: ShellBuild.transformPipelineHash, sourceBaselineHash: .sha256("test")
        )
        let inputs = BuildCache.CompilerInputs.capture(arguments: arguments, currentModuleName: "WarmConsumer",
            workingDirectory: workingDirectory, importedModules: ["WarmA", "WarmB"])
        let planRequest = NativeAPICatalog.PlanRequest(metadata: metadata, importedModules: ["WarmA", "WarmB"],
            compilerArguments: arguments, compilerURL: frontend.compilerURL, workingDirectory: workingDirectory,
            toolchain: toolchain, sdk: sdk, compilerInputs: inputs)
        let plan = try NativeAPICatalog.Planner().plan(planRequest)
        #expect(plan.requests.count == 2)
        let cache = try BuildCache.Store(rootURL: directory.appendingPathComponent("Cache"))
        let job = NativeAPICatalog.PrewarmJob(cacheRootURL: cache.rootURL, workingDirectoryURL: workingDirectory,
            planRequest: planRequest, requests: plan.requests)
        let jobURL = directory.appendingPathComponent("job.json")
        try NativeAPICatalog.PrewarmJobCodec.encode(job).write(to: jobURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobURL.path)
        let application = CLI.Application()
        let command = ["--job", jobURL.path, "--max-modules", "1"]
        let first = try application.prewarmXcodeCatalogs(command)
        #expect(first.standardOutput.contains("paused: 1 generated"))
        #expect(FileManager.default.fileExists(atPath: jobURL.path))
        let builder = NativeAPICatalog.Builder(cache: cache)
        #expect(try builder.cached(plan.requests[0]) != nil)
        #expect(try builder.cached(plan.requests[1]) == nil)
        let moduleURL = directory.appendingPathComponent("WarmB.swiftmodule")
        let original = try Data(contentsOf: moduleURL)
        try (original + Data("changed".utf8)).write(to: moduleURL)
        #expect(throws: CLI.Error.self) { try application.prewarmXcodeCatalogs(command) }
        #expect(FileManager.default.fileExists(atPath: jobURL.path))
        try original.write(to: moduleURL)
        let second = try application.prewarmXcodeCatalogs(command)
        #expect(second.standardOutput.contains("Prewarmed 2"))
        #expect(!FileManager.default.fileExists(atPath: jobURL.path))
        #expect(try builder.cached(plan.requests[1]) != nil)
    }

    @Test("A failed compile capture can bootstrap Catalogs without Prepare or frontend success")
    func bootstrapsFromAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-catalog-bootstrap-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let dependency = directory.appendingPathComponent("WarmA.swift")
        try Data("public func increment(_ value: Int) -> Int { value + 1 }\n".utf8).write(to: dependency)
        let output = try frontend.run(arguments: ["-emit-module", "-parse-as-library", "-module-name", "WarmA",
            "-target", "arm64-apple-ios15.0-simulator", "-sdk", sdk.path, dependency.path,
            "-o", directory.appendingPathComponent("WarmA.swiftmodule").path])
        try #require(output.terminationStatus == 0, "\(output.standardError)")
        let source = directory.appendingPathComponent("Consumer.swift")
        try Data("import WarmA\npublic func broken( {\n".utf8).write(to: source)
        let plan = XcodeIntegration.HostPlan(projectPath: "Example.xcodeproj",
            features: [.init(id: "consumer", targetName: "Consumer", moduleName: "Consumer")],
            profiles: [.init(id: "live", workflow: .liveReload, schemeName: "Example", applicationTargetName: "Example",
                configurationName: "Debug", bundleIdentifier: "dev.helix.bootstrap", namespaceSeed: "fixture", featureID: "consumer")])
        let planURL = directory.appendingPathComponent(".helix/xcode/HostPlan.json")
        try FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XcodeIntegration.HostPlanCodec.encode(plan).write(to: planURL)
        let captureURL = directory.appendingPathComponent("DerivedData/Build/Intermediates.noindex/Example.build/Debug-iphonesimulator/Consumer.build/Helix/FrontendAttempt.hlxswiftc")
        try FileManager.default.createDirectory(at: captureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fields = [Core.CompilerCapture.recordMarker, frontend.compilerURL.path,
            "-module-name", "Consumer", "-target", "arm64-apple-ios15.0-simulator", "-sdk", sdk.path, "-Onone",
            "-Xfrontend", "-enable-private-imports", "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-dynamic-replacement-chaining", "-I", directory.path, source.path]
        try Data((fields.joined(separator: "\0") + "\0").utf8).write(to: captureURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: captureURL.path)
        let launches = LaunchCount()
        let application = CLI.Application(currentDirectoryURL: directory,
            environment: ProcessInfo.processInfo.environment.merging(["HELIX_BUILD_CACHE_DIR": directory.appendingPathComponent("Cache").path]) { _, new in new },
            catalogPrewarmLauncher: { _, _, _, _ in launches.record() })
        let command = ["xcode", "catalog-prewarm", "--plan", planURL.path, "--profile", "live", "--capture", captureURL.path]
        let planned = await application.runAsync(command + ["--plan-only", "--json"])
        try #require(planned.exitCode == 0, "\(planned.standardError)")
        let report = try JSONDecoder().decode(CLI.XcodeCatalogPlanReport.self, from: Data(planned.standardOutput.utf8))
        #expect(report.pendingModules == ["WarmA"])
        #expect(report.unresolvedModules.isEmpty && report.cachedModules.isEmpty)
        let jobURL = URL(fileURLWithPath: try #require(report.jobPath))
        let job = try NativeAPICatalog.PrewarmJobCodec.decode(Data(contentsOf: jobURL))
        #expect(job.workingDirectoryPath == directory.path)
        let invocationURL = captureURL.deletingLastPathComponent().appendingPathComponent("FrontendInvocation.hlxswiftc")
        try FileManager.default.copyItem(at: captureURL, to: invocationURL)
        let failedPrepare = await application.runAsync(["xcode", "post-compile", "--plan", planURL.path, "--profile", "live", "--capture", invocationURL.path])
        #expect(failedPrepare.exitCode != 0)
        #expect(launches.count == 1)
        #expect(failedPrepare.standardError.contains("Catalog prewarm: scheduled 1"))
        let prewarmed = try application.prewarmXcodeCatalogs(["--job", jobURL.path, "--max-modules", "1"])
        #expect(prewarmed.exitCode == 0 && !FileManager.default.fileExists(atPath: jobURL.path))
        let repeated = await application.runAsync(command + ["--plan-only", "--json"])
        try #require(repeated.exitCode == 0, "\(repeated.standardError)")
        let cached = try JSONDecoder().decode(CLI.XcodeCatalogPlanReport.self, from: Data(repeated.standardOutput.utf8))
        #expect(cached.cachedModules == ["WarmA"] && cached.pendingModules.isEmpty && cached.jobPath == nil)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.hasSuffix("PrepareState.json") || $0.hasSuffix("FrontendReceipt.json") || $0.hasSuffix("Shell.o") })
        for suffix in [["--json"], ["--max-modules", "0"], ["--max-modules", "257"]] {
            #expect(await application.runAsync(command + suffix).exitCode != 0)
        }
        try Data("import WarmA\n/* unfinished".utf8).write(to: source)
        let blocked = await application.runAsync(command + ["--plan-only", "--json"])
        #expect(blocked.exitCode == 1)
        let blockedReport = try JSONDecoder().decode(CLI.XcodeCatalogPlanReport.self, from: Data(blocked.standardOutput.utf8))
        #expect(blockedReport.unresolvedModules == ["WarmA"] && blockedReport.jobPath == nil)
        #expect(blockedReport.unresolvedReasons["WarmA"]?.contains { $0.contains("Consumer.swift") } == true)
    }

    @Test("Prewarm limits are bounded and documented")
    func prewarmLimits() throws {
        let application = CLI.Application()
        for value in ["0", "257", "-1", "unknown"] {
            #expect(throws: CLI.Error.self) {
                try application.prewarmXcodeCatalogs(["--job", "/missing.json", "--max-modules", value])
            }
        }
        #expect(try application.prewarmXcodeCatalogs(["--help"]).standardOutput.contains("--max-modules"))
    }
}
}
