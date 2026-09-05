import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Large dependency planning")
struct DependencyPlanning {
    private struct Measurement: Codable {
        var moduleCount: Int
        var inputFiles: UInt64
        var inputBytes: UInt64
        var wallMicroseconds: UInt64
        var moduleContentHashes: [Core.Digest]
    }

    @Test("Module planning preserves independent input identities across many frameworks")
    func measuresDependencyPlanning() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = try #require(Int(environment["HELIX_DEPENDENCY_MODULE_COUNT"] ?? "8"))
        try #require((1...256).contains(count))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-dependency-planning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = (0..<count).map { "Framework\($0)" }
        for module in modules {
            let framework = root.appendingPathComponent("\(module).framework")
            let headers = framework.appendingPathComponent("Headers")
            let maps = framework.appendingPathComponent("Modules")
            try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
            for index in 0..<20 {
                try Data("// \(module) \(index)\n\(String(repeating: " ", count: 2_048))".utf8)
                    .write(to: headers.appendingPathComponent("Header\(index).h"))
            }
            try Data("framework module \(module) { umbrella \"../Headers\" export * }\n".utf8)
                .write(to: maps.appendingPathComponent("module.modulemap"))
        }
        let arguments = ["-F", root.path]
        let inputs = BuildCache.CompilerInputs.capture(
            arguments: arguments, currentModuleName: "App", workingDirectory: root,
            importedModules: Set(modules)
        )
        try #require(inputs.isComplete)
        let sdk = SwiftFrontend.Driver.SDKIdentity(name: "iphonesimulator", path: "/Fixture/SDK", buildVersion: "test-sdk")
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.dependency-planning", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.dependency-planning", buildNumber: "1", seed: "fixture"),
            machOUUIDs: [], targetTriple: "arm64-apple-ios15.0-simulator", minimumOS: .init(15),
            xcodeBuild: "fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: "App", targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: sdk.name, sdkBuild: sdk.buildVersion, optimization: "-Onone",
                semanticArguments: arguments
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("fixture")
        )
        let request = NativeAPICatalog.PlanRequest(
            metadata: metadata, importedModules: modules, compilerArguments: arguments,
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), workingDirectory: root,
            toolchain: .init(fingerprint: "fixture", versionOutput: "fixture", targetInfo: "{}", compilerBinaryHash: .sha256("fixture")),
            sdk: sdk, compilerInputs: inputs
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let plan = try NativeAPICatalog.Planner().plan(request)
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000
        #expect(plan.unresolvedModules.isEmpty)
        #expect(plan.requests.count == count)
        for planned in plan.requests {
            let independent = BuildCache.CompilerInputs.capture(
                arguments: arguments, currentModuleName: "App", workingDirectory: root,
                importedModules: [planned.identity.moduleName]
            )
            #expect(independent.isComplete)
            #expect(independent.fileCount == 21)
            #expect(planned.identity.moduleContentHash == independent.contentHash)
            #expect(planned.identity.dependencyGraphHash == inputs.contentHash)
            #expect(planned.identity.provenance == .thirdPartyModule)
        }
        if let path = environment["HELIX_DEPENDENCY_PLANNING_REPORT"] {
            try #require(path.hasPrefix("/"))
            try Core.CanonicalJSON.encode(Measurement(
                moduleCount: count, inputFiles: inputs.fileCount, inputBytes: inputs.byteCount,
                wallMicroseconds: elapsed, moduleContentHashes: plan.requests.map(\.identity.moduleContentHash)
            )).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
}
