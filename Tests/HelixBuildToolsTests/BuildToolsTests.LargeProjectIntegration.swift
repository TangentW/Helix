import Foundation
import HelixCore
import HelixDevTools
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Large-project integration controls")
struct LargeProjectIntegration {
    @Test("Device Native qualification is explicit, round-trips, and excludes Hot Patch")
    func deviceNativeProfile() throws {
        var profile = XcodeIntegration.Profile(
            id: "live", workflow: .liveReload, schemeName: "App", applicationTargetName: "App",
            configurationName: "Debug", bundleIdentifier: "dev.helix.large", namespaceSeed: "test", featureID: "app"
        )
        let legacy = try Core.CanonicalJSON.encode(profile)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("deviceNativeMatrixQualified"))
        #expect(try JSONDecoder().decode(XcodeIntegration.Profile.self, from: legacy) == profile)
        #expect(profile.runtimeAutostartSymbol == "hlx_dev_runtime_autostart_v1")
        profile.deviceNativeMatrixQualified = true
        var plan = XcodeIntegration.HostPlan(
            projectPath: "App.xcodeproj", features: [.init(id: "app", targetName: "App", moduleName: "App")], profiles: [profile]
        )
        let encoded = try XcodeIntegration.HostPlanCodec.encode(plan)
        #expect(try XcodeIntegration.HostPlanCodec.decode(encoded) == plan)
        #expect(profile.runtimeAutostartSymbol == "hlx_dev_runtime_autostart_device_native_qualified_v1")
        #expect(try XcodeIntegration.KitGenerator().generate(plan: plan).artifacts["HostPlan.json"] == encoded)
        plan.profiles[0].workflow = .hotPatch
        #expect(throws: XcodeIntegration.Error.self) { try plan.validate() }
    }

    @Test("Misplaced dyld search paths are diagnosed without becoming response files")
    func runtimeSearchPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = BuildCapture.CapturedFrontendJob(
            executable: "/usr/bin/swiftc", arguments: [
                "-module-name", "Fixture", "-target", "arm64-apple-ios15.0-simulator",
                "-sdk", "/SDK", "Source.swift", "-F", "@executable_path/Frameworks",
            ], sourceLine: "test"
        )
        let result = try BuildCapture.FrontendJobNormalizer().normalize(job, workingDirectory: directory)
        #expect(result.arguments.contains("-F@executable_path/Frameworks"))
        let warnings = BuildCapture.SearchPaths.warnings(arguments: result.arguments, workingDirectory: directory)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("FRAMEWORK_SEARCH_PATHS"))
        #expect(warnings[0].contains("LD_RUNPATH_SEARCH_PATHS"))
        #expect(warnings[0].contains("@executable_path/Frameworks"))
        for forwarding in ["-Xcc", "-Xfrontend"] {
            var forwarded = job
            forwarded.arguments.removeLast(2)
            forwarded.arguments += [forwarding, "-F", forwarding, "@loader_path/Frameworks"]
            let normalized = try BuildCapture.FrontendJobNormalizer().normalize(forwarded, workingDirectory: directory)
            #expect(normalized.arguments.suffix(2) == [forwarding, "-F@loader_path/Frameworks"])
            #expect(BuildCapture.SearchPaths.warnings(arguments: normalized.arguments, workingDirectory: directory).count == 1)
        }
        var missingResponse = job
        missingResponse.arguments = ["@missing.rsp"]
        #expect(throws: (any Error).self) {
            try BuildCapture.FrontendJobNormalizer().normalize(missingResponse, workingDirectory: directory)
        }
    }

    @Test("Nested response files use compiler working-directory semantics")
    func nestedResponseWorkingDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lists = directory.appendingPathComponent("Lists")
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: false)
        try Data("@inner.rsp".utf8).write(to: lists.appendingPathComponent("outer.rsp"))
        try Data("-module-name Fixture -target arm64-apple-ios15.0-simulator -sdk /SDK Source.swift".utf8)
            .write(to: directory.appendingPathComponent("inner.rsp"))
        let result = try BuildCapture.FrontendJobNormalizer().normalize(.init(
            executable: "/usr/bin/swiftc", arguments: ["@Lists/outer.rsp"], sourceLine: "test"
        ), workingDirectory: directory)
        #expect(result.sourcePaths == [directory.appendingPathComponent("Source.swift").path])
    }

    @Test("Missing search roots warn and remain part of cache invalidation")
    func advisorySearchRoots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("Missing")
        let arguments = ["-I", missing.path, "-Fsystem" + directory.path]
        let before = BuildCache.CompilerInputs.capture(arguments: arguments, currentModuleName: "App", workingDirectory: directory)
        #expect(before.isComplete)
        #expect(BuildCapture.SearchPaths.warnings(arguments: arguments, workingDirectory: directory).count == 1)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        try Data("module bytes".utf8).write(to: missing.appendingPathComponent("External.swiftmodule"))
        let after = BuildCache.CompilerInputs.capture(arguments: arguments, currentModuleName: "App", workingDirectory: directory)
        #expect(after.contentHash != before.contentHash)
        #expect(BuildCapture.SearchPaths.warnings(arguments: arguments, workingDirectory: directory).isEmpty)
        #expect(BuildCapture.SearchPaths.warnings(arguments: ["-Xcc", "-I", "-Xcc", directory.path], workingDirectory: directory).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: missing.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: missing.path) }
        #expect(BuildCapture.SearchPaths.warnings(arguments: arguments, workingDirectory: directory).count == 1)
        let unreadable = BuildCache.CompilerInputs.capture(arguments: arguments, currentModuleName: "App", workingDirectory: directory)
        #expect(!unreadable.isComplete)
    }

    @Test("Catalog closure bounds apply to the accumulated module set")
    func catalogClosureBounds() throws {
        let modules = (0..<256).map { "Module\($0)" }
        #expect(try NativeAPICatalog.Planner.catalogModules(modules + ["Swift", "App", "Module0.Submodule"], excluding: "App").count == 256)
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Planner.catalogModules(modules + ["OneTooMany"], excluding: "App")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-large-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
}
