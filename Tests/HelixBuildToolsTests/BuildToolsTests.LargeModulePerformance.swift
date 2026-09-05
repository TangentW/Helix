import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Large module receipt performance")
struct LargeModulePerformance {
    private struct Sample: Codable {
        var scenario: String
        var wallMicroseconds: UInt64
        var receiptBytes: Int
        var trace: BuildPerformance.Trace
    }

    private struct Measurement: Codable {
        var sourceCount: Int
        var sourceBytes: Int
        var targetTriple: String
        var sdkBuild: String
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var samples: [Sample]
    }

    @Test("Large source sets reuse unchanged receipts and invalidate on a body edit")
    func measuresLargeModuleCache() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = try #require(Int(environment["HELIX_LARGE_MODULE_SOURCE_COUNT"] ?? "32"))
        try #require((2...5_000).contains(count))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-large-module-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sourceBytes = 0
        let sources = try (0..<count).map { index in
            let name = "Feature\(index).swift"
            let url = directory.appendingPathComponent(name)
            let bytes = Data("public func value\(index)(_ input: Int) -> Int { input + \(index) }\n".utf8)
            try bytes.write(to: url)
            sourceBytes += bytes.count
            return FrontendReceipt.Source(logicalPath: "Sources/\(name)", url: url)
        }
        let compiler = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compiler)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(compilerURL: compiler)
        let target = "arm64-apple-ios15.0-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.large-module", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.large-module", buildNumber: "1", seed: "fixture"),
            machOUUIDs: [], targetTriple: target, minimumOS: .init(15),
            xcodeBuild: "performance-fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: "LargeModuleFixture", targetTriple: target,
                sdkName: sdk.name, sdkBuild: sdk.buildVersion, optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by the indexer")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          LargeModuleFixture:
            include:
              - Sources/**
        """)
        let request = FrontendReceipt.Request(
            metadata: metadata, configuration: configuration, sources: sources, compilerURL: compiler
        )
        let adapter = FrontendReceipt.CachedAdapter(
            cache: try BuildCache.Store(rootURL: directory.appendingPathComponent("Cache"))
        )
        var samples: [Sample] = []
        func run(_ scenario: String) throws -> FrontendReceipt.Output {
            let start = DispatchTime.now().uptimeNanoseconds
            let output = try adapter.generate(
                request, compilerCapture: Data("large-module-fixture".utf8),
                workingDirectory: directory, precomputedToolchain: toolchain
            )
            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000
            try output.receipt.validate()
            try output.performance.validate()
            #expect(output.receipt.sources.count == count)
            #expect(output.receipt.declarations.count == count)
            samples.append(.init(
                scenario: scenario, wallMicroseconds: elapsed,
                receiptBytes: try ShellBuildReceipt.Codec.encode(output.receipt).count,
                trace: output.performance
            ))
            return output
        }
        let cold = try run("cold_receipt")
        let warm = try run("unchanged_receipt")
        #expect(warm.receipt == cold.receipt)
        #expect(warm.performance.subprocesses.isEmpty)
        #expect(warm.performance.counters.first { $0.name == "frontend_cache.module_hit_count" }?.value == 1)
        try Data("public func value0(_ input: Int) -> Int { input + 42 }\n".utf8)
            .write(to: sources[0].url)
        let edited = try run("one_body_edit_receipt")
        #expect(edited.performance.counters.first { $0.name == "frontend_cache.module_miss_count" }?.value == 1)
        #expect(!edited.performance.subprocesses.isEmpty)
        #expect(edited.receipt.sources[0].contentHash != cold.receipt.sources[0].contentHash)
        #expect(edited.receipt.roots.map(\.declarationMangledName) == cold.receipt.roots.map(\.declarationMangledName))
        if let path = environment["HELIX_LARGE_MODULE_REPORT"] {
            try #require(path.hasPrefix("/"))
            let report = Measurement(
                sourceCount: count, sourceBytes: sourceBytes,
                targetTriple: target, sdkBuild: sdk.buildVersion,
                toolchain: toolchain, samples: samples
            )
            try Core.CanonicalJSON.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
}
