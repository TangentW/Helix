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
    @Test("Module budget resumes through cache hits and rejects changed build inputs")
    func resumesPrewarm() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-prewarm-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
        let arguments = ["-I", directory.path]
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
