import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("System-framework mixed configuration integration", .serialized)
struct SystemFrameworkIntegrationTests {
    private struct Measurement: Codable {
        var sdk: SwiftFrontend.Driver.SDKIdentity
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var target: String
        var sourceCount: Int
        var sourceBytes: Int
        var importedModules: [String]
        var explicitBuildMicroseconds: UInt64
        var coldReceiptMicroseconds: UInt64
        var warmReceiptMicroseconds: UInt64
        var trace: BuildPerformance.Trace
    }

    @Test("Explicit-module compilation replays framework overlays, Objective-C, C++ and macros together")
    func integratesMixedSystemFrameworks() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = try #require(Int(environment["HELIX_SYSTEM_FRAMEWORK_SOURCE_COUNT"] ?? "8"))
        try #require((2...2_500).contains(count))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-system-frameworks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep source headers apart from generated module/PCH/cache outputs,
        // as an Xcode source tree and DerivedData are in normal integration.
        let headers = root.appendingPathComponent("Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: false)
        let header = headers.appendingPathComponent("Bridging Header.h")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface BridgedValue : NSObject
        @end
        struct ImportedCounter { int value; };
        """.utf8).write(to: header)
        var sourceBytes = 0
        let sources = try (0..<count).map { index in
            let url = root.appendingPathComponent("Feature\(index).swift")
            let progressType = index.isMultiple(of: 2) ? "Progress" : "Foundation.Progress"
            var contents = "import Foundation\npublic func completed\(index)(_ progress: \(progressType)) -> Int64 { progress.completedUnitCount }\n"
            if index == 0 {
                contents += """
                import UIKit
                import AVFoundation
                import Photos
                enum RequestContext { @TaskLocal static var value: Int = 1 }
                @MainActor public func frameworkValues(_ image: UIImage, _ player: AVPlayer, _ asset: PHAsset) -> Int {
                    _ = image
                    _ = player
                    return asset.pixelWidth + RequestContext.value
                }
                public func bridged(_ value: BridgedValue) -> BridgedValue { value }
                public func counter(_ value: ImportedCounter) -> Int32 { value.value }
                public func scalar(_ value: Int) -> Int { value + 1 }

                """
            }
            let bytes = Data(contents.utf8)
            sourceBytes += bytes.count
            try bytes.write(to: url)
            return FrontendReceipt.Source(logicalPath: "Sources/Feature\(index).swift", url: url)
        }
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let captured = [
            "-Xfrontend", "-enable-private-imports", "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-dynamic-replacement-chaining", "-explicit-module-build",
            "-cxx-interoperability-mode=default", "-Xcc", "-std=gnu++20",
            "-import-objc-header", header.path, "-pch-output-dir", root.path,
        ]
        let initialStarted = DispatchTime.now().uptimeNanoseconds
        let initial = try frontend.run(arguments: ["-emit-module", "-module-name", "SystemFrameworkFixture",
            "-target", target, "-sdk", sdk.path, "-parse-as-library", "-module-cache-path", root.appendingPathComponent("ModuleCache").path]
            + captured + sources.map { $0.url.path }
            + ["-emit-module-path", root.appendingPathComponent("SystemFrameworkFixture.swiftmodule").path])
        try #require(initial.terminationStatus == 0, "\(initial.standardError)")
        let explicitMicroseconds = (DispatchTime.now().uptimeNanoseconds - initialStarted) / 1_000
        let semantic = try XcodeIntegration.CompilerArguments.semanticArguments(from: captured)
        let metadata = InterfaceArchive.ReleaseMetadata(bundleID: "dev.helix.system-frameworks", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.system-frameworks", buildNumber: "1", seed: "fixture"),
            machOUUIDs: [], targetTriple: target, minimumOS: .init(15), xcodeBuild: "fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(moduleName: "SystemFrameworkFixture", targetTriple: target, sdkName: sdk.name,
                sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: semantic),
            transformPipelineHash: ShellBuild.transformPipelineHash, sourceBaselineHash: .sha256("computed"))
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          SystemFrameworkFixture:
            include:
              - Sources/**
        """)
        let request = FrontendReceipt.Request(metadata: metadata, configuration: configuration, sources: sources)
        let adapter = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: root.appendingPathComponent("Cache")))
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(compilerURL: request.compilerURL)
        let started = DispatchTime.now().uptimeNanoseconds
        let cold = try adapter.generate(request, compilerCapture: Data(captured.joined(separator: "\0").utf8),
            compilerArguments: semantic, workingDirectory: root, precomputedToolchain: toolchain)
        let coldMicroseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        let warm = try adapter.generate(request, compilerCapture: Data(captured.joined(separator: "\0").utf8),
            compilerArguments: semantic, workingDirectory: root, precomputedToolchain: toolchain)
        let warmMicroseconds = (DispatchTime.now().uptimeNanoseconds - warmStarted) / 1_000
        try cold.receipt.validate()
        #expect(cold.receipt.sources.count == count)
        #expect(Set(cold.importedModules).isSuperset(of: ["Foundation", "UIKit", "AVFoundation", "Photos"]))
        #expect(warm.receipt == cold.receipt)
        #expect(warm.performance.subprocesses.isEmpty)
        #expect(cold.receipt.declarations.contains { $0.canonicalDeclaration.contains("completed0") })
        #expect(cold.receipt.nativeTypes.filter { $0.objectiveCRuntimeName == "NSProgress" }.count == 1)
        if let path = environment["HELIX_SYSTEM_FRAMEWORK_REPORT"] {
            try #require(path.hasPrefix("/"))
            try Core.CanonicalJSON.encode(Measurement(sdk: sdk, toolchain: toolchain, target: target,
                sourceCount: count, sourceBytes: sourceBytes,
                importedModules: cold.importedModules, explicitBuildMicroseconds: explicitMicroseconds,
                coldReceiptMicroseconds: coldMicroseconds, warmReceiptMicroseconds: warmMicroseconds,
                trace: cold.performance)).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
}
