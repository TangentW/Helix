import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Independent frontend diagnosis", .serialized)
struct FrontendDiagnostics {
    @Test("One malformed source reports all independent compiler failures and blocks consumers")
    func independentCompilerFailures() throws {
        let fixture = try makeFixture(source: "public func broken( {\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: fixture.root.appendingPathComponent("Cache")))
        let report = try adapter.diagnose(fixture.request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(!report.passed)
        let failed = Set(report.checks.filter { $0.status == .failed }.map(\.stage))
        #expect(failed == ["frontend.typed_ast", "frontend.identity_sil", "frontend.semantic_sil"])
        for stage in ["frontend.demangle_types", "frontend.discover_source_nominals", "frontend.discover_imported_types", "frontend.discover_imported_operations", "frontend.receipt"] {
            #expect(report.checks.contains { $0.stage == stage && $0.status == .blocked })
        }
        for check in report.checks where check.status == .failed { #expect(check.detail.contains("Feature.swift")) }
        let paths = FileManager.default.subpaths(atPath: adapter.cache.rootURL.path) ?? []
        #expect(!paths.contains { $0.hasSuffix("Payload.bin") })
        let combined = try adapter.diagnose(fixture.request, compilerCapture: Data("capture".utf8),
            workingDirectory: fixture.root, catalogFailure: "FixtureCatalog at /tmp/catalog.json could not be validated")
        #expect(combined.checks.filter { $0.status == .failed }.count == 4)
        #expect(combined.checks.contains { $0.stage == "frontend.resolve_native_api_catalogs" && $0.status == .failed && $0.detail.contains("FixtureCatalog") })
        #expect(combined.checks.contains { $0.stage == "frontend.receipt" && $0.status == .blocked })
        let decoded = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Core.CanonicalJSON.encode(report))
        #expect(decoded.checks == report.checks)
        #expect(!decoded.passed)
    }

    @Test("All independent request and source-file problems are visible before compiler work")
    func reportsInputFacts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var request = fixture.request
        request.sources.append(request.sources[0])
        request.metadata.transformPipelineHash = .sha256("wrong-transform")
        request.metadata.machOUUIDs = [UUID()]
        let report = try FrontendReceipt.Adapter().diagnose(request)
        let failure = try #require(report.checks.first { $0.stage == "frontend.validate_request" })
        #expect(failure.status == .failed)
        for fact in ["duplicate logical", "duplicate physical", "transform identity mismatch", "Mach-O UUIDs", "Feature.swift"] {
            #expect(failure.detail.contains(fact))
        }
        #expect(report.performance?.subprocesses.isEmpty == true)
        request = fixture.request
        request.sources = ["A.swift", "B.swift"].map { .init(logicalPath: "Sources/\($0)", url: fixture.root.appendingPathComponent($0)) }
        let missing = try FrontendReceipt.Adapter().diagnose(request)
        let files = try #require(missing.checks.first { $0.stage == "frontend.load_sources" })
        #expect(files.status == .failed)
        #expect(files.detail.contains("A.swift") && files.detail.contains("B.swift"))
        #expect(missing.checks.filter { ["frontend.typed_ast", "frontend.identity_sil", "frontend.semantic_sil"].contains($0.stage) }.allSatisfy { $0.status == .blocked })
    }

    @Test("Late diagnosis failure and corrected diagnosis reuse checkpoints without publishing receipts")
    func diagnosisCheckpoints() throws {
        let fixture = try makeFixture(source: "public struct Value { public var value: Int }\npublic func increment(_ value: Int) -> Int { value + 1 }\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var request = fixture.request
        request.nativeImportCatalog = .init(nativeTypes: [.init(canonicalName: "DiagnosticFixture.Value", kind: .value,
            layoutFingerprint: .sha256("fixture"), isCopyable: true, estimatedSize: 8,
            factoryType: "FixtureFactories.ValueOps", importedModules: ["FixtureFactories"])], candidates: [])
        let adapter = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: fixture.root.appendingPathComponent("Cache")))
        let failed = try adapter.diagnose(request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(!failed.passed)
        #expect(failed.checks.contains { $0.stage == "frontend.receipt" && $0.status == .failed && $0.detail.contains("indexed structural codec") })
        request.nativeImportCatalog = .empty
        let corrected = try adapter.diagnose(request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(corrected.passed, "\(corrected.checks)")
        for stage in ["typed_ast", "identity_sil", "semantic_sil"] {
            #expect(corrected.performance?.counters.first { $0.name == "frontend_checkpoint.\(stage)_hit_count" }?.value == 1)
            #expect(corrected.performance?.stages.contains { $0.name == "frontend.emit_\(stage)" } == false)
        }
        let moduleRoot = adapter.cache.rootURL.appendingPathComponent("v1/module_frontend")
        #expect(!(FileManager.default.subpaths(atPath: moduleRoot.path) ?? []).contains { $0.hasSuffix("Payload.bin") })
        let built = try adapter.generate(request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        try built.receipt.validate()
        #expect(built.performance.counters.first { $0.name == "frontend_checkpoint.retired_count" }?.value == 3)
    }

    @Test("Production diagnosis reports missing Catalog coverage without cold Catalog generation")
    func productionCatalogCoverage() throws {
        let fixture = try makeFixture(source: "import Foundation\npublic func value(_ progress: Progress) -> Int64 { progress.completedUnitCount }\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var request = fixture.request
        request.callingSurfacePolicy = .managedProductionModule
        let report = try FrontendReceipt.Adapter().diagnose(request)
        #expect(!report.passed)
        #expect(report.checks.contains { $0.stage == "frontend.identity_sil" && $0.status == .passed })
        #expect(report.checks.contains { $0.stage == "frontend.resolve_native_api_catalogs" && $0.status == .failed && $0.detail.contains("Foundation") })
        #expect(report.checks.contains { $0.stage == "frontend.receipt" && $0.status == .blocked })
    }

    @Test("Missing required captured compiler options are reported together")
    func missingCaptureFlags() {
        do {
            _ = try XcodeIntegration.CompilerArguments.semanticArguments(from: [])
            Issue.record("Expected missing compiler options")
        } catch {
            let text = String(describing: error)
            for flag in ["-enable-private-imports", "-enable-implicit-dynamic", "-enable-dynamic-replacement-chaining"] { #expect(text.contains(flag)) }
        }
    }

    private func makeFixture(source: String = "public func value(_ value: Int) -> Int { value }\n") throws -> (root: URL, request: FrontendReceipt.Request) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("Feature.swift")
        try Data(source.utf8).write(to: url)
        let sdk = try SwiftFrontend.Driver().sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(bundleID: "dev.helix.diagnostics", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.diagnostics", buildNumber: "1", seed: "fixture"), machOUUIDs: [],
            targetTriple: target, minimumOS: .init(15), xcodeBuild: "fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(moduleName: "DiagnosticFixture", targetTriple: target, sdkName: sdk.name,
                sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library"]),
            transformPipelineHash: ShellBuild.transformPipelineHash, sourceBaselineHash: .sha256("computed"))
        return (root, .init(metadata: metadata, configuration: .automaticProjectPolicy(moduleName: "DiagnosticFixture"),
            sources: [.init(logicalPath: "Sources/Feature.swift", url: url)]))
    }
}
}
