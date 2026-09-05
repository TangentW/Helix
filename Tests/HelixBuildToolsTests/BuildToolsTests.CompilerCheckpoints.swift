import Darwin
import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Validated compiler checkpoints")
struct CompilerCheckpointsTests {
    @Test("A late receipt failure preserves validated compilation for a corrected retry")
    func recoversAfterReceiptFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Feature.swift")
        try Data("public struct Value { public var value: Int }\npublic func increment(_ value: Int) -> Int { value + 1 }\n".utf8).write(to: source)
        let compiler = URL(fileURLWithPath: "/usr/bin/swiftc")
        let sdk = try SwiftFrontend.Driver(compilerURL: compiler).sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(compilerURL: compiler)
        let target = "arm64-apple-ios15.0-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.checkpoint", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.checkpoint", buildNumber: "1", seed: "fixture"),
            machOUUIDs: [], targetTriple: target, minimumOS: .init(15), xcodeBuild: "fixture",
            sdkBuild: sdk.buildVersion, frontendInvocation: .init(moduleName: "CheckpointFixture",
                targetTriple: target, sdkName: sdk.name, sdkBuild: sdk.buildVersion,
                optimization: "-Onone", semanticArguments: ["-parse-as-library"]),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          CheckpointFixture:
            include:
              - Sources/**
        """)
        var request = FrontendReceipt.Request(metadata: metadata, configuration: configuration,
            sources: [.init(logicalPath: "Sources/Feature.swift", url: source)], compilerURL: compiler)
        // A valid catalog cannot replace a source value's structural codec.
        // This conflict is discovered only after all three compiler stages.
        request.nativeImportCatalog = .init(nativeTypes: [.init(
            canonicalName: "CheckpointFixture.Value", kind: .value, layoutFingerprint: .sha256("fixture"),
            isCopyable: true, estimatedSize: 8, factoryType: "FixtureFactories.ValueOps",
            importedModules: ["FixtureFactories"]
        )], candidates: [])
        let cached = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: root.appendingPathComponent("Cache")))
        do {
            _ = try cached.generate(request, compilerCapture: Data("capture".utf8), workingDirectory: root,
                                    precomputedToolchain: toolchain)
            Issue.record("Expected a source/native codec conflict")
        } catch {
            #expect(String(describing: error).contains("indexed structural codec"))
        }
        request.nativeImportCatalog = .empty
        let recovered = try cached.generate(request, compilerCapture: Data("capture".utf8), workingDirectory: root,
                                            precomputedToolchain: toolchain)
        try recovered.receipt.validate()
        #expect(recovered.performance.counters.first { $0.name == "frontend_checkpoint.retired_count" }?.value == 3)
        let checkpointRoot = cached.cache.rootURL.appendingPathComponent("v1/compiler_checkpoint")
        #expect(try #require(FileManager.default.subpaths(atPath: checkpointRoot.path))
            .allSatisfy { !$0.hasSuffix("Payload.bin") })
        for stage in ["typed_ast", "identity_sil", "semantic_sil"] {
            #expect(recovered.performance.counters.first { $0.name == "frontend_checkpoint.\(stage)_hit_count" }?.value == 1)
            #expect(!recovered.performance.stages.contains { $0.name == "frontend.emit_\(stage)" })
        }
        let authoritative = try FrontendReceipt.Adapter().generate(request)
        #expect(recovered.receipt == authoritative.receipt)
        #expect(recovered.diagnostics == authoritative.diagnostics)
        try Data("public struct Value { public var value: Int }\npublic func increment(_ value: Int) -> Int { value + 2 }\n".utf8).write(to: source)
        let changed = try cached.generate(request, compilerCapture: Data("capture".utf8), workingDirectory: root,
                                         precomputedToolchain: toolchain)
        #expect(changed.receipt.sources != recovered.receipt.sources)
        for stage in ["typed_ast", "identity_sil", "semantic_sil"] {
            #expect(changed.performance.counters.first { $0.name == "frontend_checkpoint.\(stage)_generated_count" }?.value == 1)
        }
    }

    @Test("Stage identity, corruption, and parser validation control reuse")
    func validatesEveryStage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try BuildCache.Store(rootURL: root.appendingPathComponent("Cache"))
        let context = FrontendReceipt.CompilerCheckpoints.Context(cache: cache, identity: .sha256("one"), confirmInputs: {})
        var produced = 0
        func read(_ stage: FrontendReceipt.CompilerCheckpoints.Stage, context: FrontendReceipt.CompilerCheckpoints.Context) throws -> Int {
            try FrontendReceipt.CompilerCheckpoints.read(stage, context: context, performance: .init(),
                produce: { produced += 1; return "42" }, parse: { try #require(Int($0)) })
        }
        #expect(try read(.typedAST, context: context) == 42)
        #expect(try read(.typedAST, context: context) == 42)
        #expect(produced == 1)
        #expect(try read(.identitySIL, context: context) == 42)
        #expect(produced == 2)
        var changed = context
        changed.identity = .sha256("two")
        #expect(try read(.typedAST, context: changed) == 42)
        #expect(produced == 3)
        let namespace = cache.rootURL.appendingPathComponent("v1/compiler_checkpoint")
        for path in try #require(FileManager.default.subpaths(atPath: namespace.path)) where path.hasSuffix("Payload.bin") {
            try Data("corrupt".utf8).write(to: namespace.appendingPathComponent(path))
        }
        #expect(try read(.typedAST, context: context) == 42)
        #expect(produced == 4)
    }

    @Test("Checkpoint retirement does not follow links outside the cache")
    func retainsExternalFilesDuringRetirement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try BuildCache.Store(rootURL: root.appendingPathComponent("Cache"))
        let key = Core.Digest.sha256("entry")
        _ = try cache.value(namespace: .compilerCheckpoint, key: key, maximumBytes: 16) { Data("payload".utf8) }
        let entry = cache.rootURL.appendingPathComponent("v1/compiler_checkpoint/\(key.hex)")
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let file = external.appendingPathComponent("Keep.txt")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: external)
        #expect(!cache.discard(namespace: .compilerCheckpoint, key: key))
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }

    @Test("Parser failures are never retained as successful compiler stages")
    func rejectsMalformedCompilerOutput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = FrontendReceipt.CompilerCheckpoints.Context(
            cache: try .init(rootURL: root.appendingPathComponent("Cache")),
            identity: .sha256("parser"), confirmInputs: {}
        )
        var produced = 0
        func read(_ output: String) throws -> Int {
            try FrontendReceipt.CompilerCheckpoints.read(.typedAST, context: context, performance: .init(),
                produce: { produced += 1; return output }, parse: {
                    guard let number = Int($0) else { throw FrontendReceipt.Error.malformedAST("not a number") }
                    return number
                })
        }
        #expect(throws: FrontendReceipt.Error.self) { try read("malformed") }
        #expect(try read("42") == 42)
        #expect(produced == 2)
    }

    @Test("Retirement skips an intermediate owned by another active lock")
    func skipsBusyRetirement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try BuildCache.Store(rootURL: root.appendingPathComponent("Cache"))
        let key = Core.Digest.sha256("busy")
        _ = try cache.value(namespace: .compilerCheckpoint, key: key, maximumBytes: 16) { Data("payload".utf8) }
        let lock = cache.rootURL.appendingPathComponent("v1/compiler_checkpoint/.\(key.hex).lock")
        let descriptor = Darwin.open(lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(!cache.discard(namespace: .compilerCheckpoint, key: key))
        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(cache.discard(namespace: .compilerCheckpoint, key: key))
    }

    @Test("Input drift preserves prior entries and prevents new checkpoint publication")
    func rejectsInputDrift() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try BuildCache.Store(rootURL: root.appendingPathComponent("Cache"))
        let context = FrontendReceipt.CompilerCheckpoints.Context(cache: cache, identity: .sha256("stable"), confirmInputs: {})
        var drifted = context
        drifted.confirmInputs = { throw FrontendReceipt.SourceImports.ValidationError.sourceChanged }
        var produced = 0
        func read(_ stage: FrontendReceipt.CompilerCheckpoints.Stage, _ context: FrontendReceipt.CompilerCheckpoints.Context) throws -> String {
            try FrontendReceipt.CompilerCheckpoints.read(stage, context: context, performance: .init(),
                produce: { produced += 1; return "valid" }, parse: { $0 })
        }
        _ = try read(.typedAST, context)
        #expect(throws: FrontendReceipt.SourceImports.ValidationError.self) { try read(.typedAST, drifted) }
        _ = try read(.typedAST, context)
        #expect(produced == 1)
        #expect(throws: FrontendReceipt.SourceImports.ValidationError.self) { try read(.semanticSIL, drifted) }
        _ = try read(.semanticSIL, context)
        #expect(produced == 3)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-checkpoints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
}
