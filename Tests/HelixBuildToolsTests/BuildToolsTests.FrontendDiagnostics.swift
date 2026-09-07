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

    @Test("Selected AST checks skip SIL and Catalog work, and later full checks reuse their checkpoint")
    func selectedChecks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: fixture.root.appendingPathComponent("Cache")))
        let stages: [FrontendReceipt.DiagnosticStage] = [.sourceNominals, .importedTypes, .sourceNominals]
        let selected = try adapter.diagnose(fixture.request, compilerCapture: Data("capture".utf8),
            workingDirectory: fixture.root, catalogFailure: "An unselected Catalog must not be read", stages: stages)
        #expect(selected.passed, "\(selected.checks)")
        #expect(selected.schemaVersion == 2)
        #expect(selected.requestedStages == [.importedTypes, .sourceNominals])
        #expect(Set(selected.checks.map(\.stage)) == ["frontend.validate_request", "frontend.load_sources",
            "frontend.toolchain_identity", "frontend.typed_ast", "frontend.demangle_types",
            "frontend.discover_source_nominals", "frontend.discover_imported_types"])
        #expect(selected.performance?.subprocesses.contains { $0.kind == .canonicalSIL } == false)
        #expect(selected.performance?.counters.first { $0.name == "frontend_checkpoint.typed_ast_generated_count" }?.value == 1)
        let partial = try adapter.diagnose(fixture.request, compilerCapture: Data("capture".utf8),
            workingDirectory: fixture.root, stages: stages)
        #expect(partial.passed)
        #expect(partial.performance?.counters.first { $0.name == "frontend_checkpoint.typed_ast_hit_count" }?.value == 1)
        #expect(partial.performance?.stages.contains { $0.name == "frontend.emit_typed_ast" } == false)
        let full = try adapter.diagnose(fixture.request, compilerCapture: Data("capture".utf8),
            workingDirectory: fixture.root, stages: [.receipt])
        #expect(full.passed, "\(full.checks)")
        #expect(full.checks.contains { $0.stage == "frontend.receipt" && $0.status == .passed })
        #expect(full.performance?.counters.first { $0.name == "frontend_checkpoint.typed_ast_hit_count" }?.value == 1)
        let moduleRoot = adapter.cache.rootURL.appendingPathComponent("v1/module_frontend")
        #expect(!(FileManager.default.subpaths(atPath: moduleRoot.path) ?? []).contains { $0.hasSuffix("Payload.bin") })
        let built = try adapter.generate(fixture.request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(built.performance.counters.first { $0.name == "frontend_checkpoint.retired_count" }?.value == 3)
        #expect(throws: FrontendReceipt.Error.self) { try adapter.diagnose(fixture.request, compilerCapture: Data(), stages: []) }
        #expect(throws: FrontendReceipt.Error.self) { try FrontendReceipt.Adapter().diagnose(fixture.request, stages: []) }
    }

    @Test("SIL component failures preserve independent source mappings without caching invalid output")
    func independentSILFailures() throws {
        let fixture = try makeFixture(source: "public func fallback(_ value: Int?) -> Int { value ?? { 7 }() }\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var request = fixture.request
        request.metadata.frontendInvocation.semanticArguments.append("-g")
        request.compilerURL = fixture.root.appendingPathComponent("swiftc")
        // Inject malformed summaries after a real compiler emission. The marker
        // models a transient failed emission; it never changes valid AST facts.
        let script = #"""
        #!/bin/sh
        emit_sil=no
        previous=''
        sil_output=''
        for argument in "$@"; do
          if [ "$argument" = '-emit-sil' ]; then emit_sil=yes; fi
          if [ "$previous" = '-o' ]; then sil_output="$argument"; fi
          previous="$argument"
        done
        /usr/bin/swiftc "$@" || exit $?
        if [ "$emit_sil" = yes ] && [ -f "${0%/*}/malformed" ]; then
          cat >> "$sil_output" <<'SIL'
        struct Duplicate {
        }
        struct Duplicate {
        }
        sil_witness_table Value: Feature module DiagnosticFixture {
          associated_type Item: Int
          associated_type Item: String
        }
        SIL
        fi
        """#
        try Data((script + "\n").utf8).write(to: request.compilerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: request.compilerURL.path)
        let marker = fixture.root.appendingPathComponent("malformed")
        try Data().write(to: marker)
        let adapter = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: fixture.root.appendingPathComponent("Cache")))
        let failed = try adapter.diagnose(request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(!failed.passed)
        for prefix in ["frontend.identity_sil", "frontend.semantic_sil"] {
            for component in ["conformances", "nominal_declarations"] {
                #expect(failed.checks.contains { $0.stage == prefix + "." + component && $0.status == .failed })
            }
            for component in ["function_definitions", "debug_scopes", "function_locations", "ast_mapping"] {
                #expect(failed.checks.contains { $0.stage == prefix + "." + component && $0.status == .passed })
                #expect(failed.performance?.stages.contains { $0.name == prefix + "." + component } == true)
            }
        }
        #expect(failed.checks.contains { $0.stage == "frontend.discover_source_nominals" && $0.status == .passed })
        #expect(failed.checks.contains { $0.stage == "frontend.discover_imported_operations" && $0.status == .blocked })
        #expect(failed.checks.contains { $0.stage == "frontend.receipt" && $0.status == .blocked })
        let checkpoints = adapter.cache.rootURL.appendingPathComponent("v1/compiler_checkpoint")
        #expect((FileManager.default.subpaths(atPath: checkpoints.path) ?? []).filter { $0.hasSuffix("Payload.bin") }.count == 1)
        try FileManager.default.removeItem(at: marker)
        let corrected = try adapter.diagnose(request, compilerCapture: Data("capture".utf8), workingDirectory: fixture.root)
        #expect(corrected.passed, "\(corrected.checks)")
        #expect(corrected.performance?.counters.first { $0.name == "frontend_checkpoint.typed_ast_hit_count" }?.value == 1)
        for stage in ["identity_sil", "semantic_sil"] {
            #expect(corrected.performance?.counters.first { $0.name == "frontend_checkpoint.\(stage)_generated_count" }?.value == 1)
        }
    }

    @Test("Diagnostic schema 1 retains full scope and schema 2 preserves selected scope")
    func diagnosticSchemaMigration() throws {
        let legacy = Data(#"{"schemaVersion":1,"passed":true,"checks":[{"stage":"frontend.receipt","status":"passed","detail":""}],"diagnostics":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: legacy)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.requestedStages == nil)
        var current = FrontendReceipt.DiagnosticReport.failure(stage: "fixture", reason: "unavailable")
        current.requestedStages = [.typedAST]
        let roundtrip = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Core.CanonicalJSON.encode(current))
        #expect(roundtrip.schemaVersion == 2)
        #expect(roundtrip.requestedStages == [.typedAST])
    }

    @Test("Every diagnostic root includes its prerequisites and skips full receipt publication", arguments:
        [FrontendReceipt.DiagnosticStage.typedAST, .identitySIL, .semanticSIL, .sourceMappings, .importedOperations, .catalogs])
    func individualRoots(stage: FrontendReceipt.DiagnosticStage) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = try FrontendReceipt.Adapter().diagnose(fixture.request, stages: [stage])
        #expect(report.passed, "\(report.checks)")
        #expect(report.requestedStages == [stage])
        #expect(report.checks.contains { $0.stage == "frontend.receipt" } == false)
        for root in stage.roots { #expect(report.checks.contains { $0.stage == root && $0.status == .passed }) }
        if [.typedAST, .catalogs].contains(stage) {
            #expect(report.performance?.subprocesses.contains { $0.kind == .canonicalSIL } == false)
        }
        if [.identitySIL, .semanticSIL].contains(stage) {
            #expect(report.performance?.subprocesses.contains { $0.kind == .typedAST } == false)
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
