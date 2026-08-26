import Foundation
import HelixCompiler
import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Native Adapter Pack")
struct NativeAdapterPackTests {
    @Test("Pack identity is project-independent and invalidates semantic inputs")
    func identity() {
        let key = Core.NativeCall.Key(rawValue: .sha256("adapter"))
        let baseline = makeIdentity(keys: [key])
        #expect(baseline == makeIdentity(keys: [key]))
        #expect(baseline.cacheKey == makeIdentity(keys: [key]).cacheKey)

        var changedTarget = baseline
        changedTarget.targetTriple = "x86_64-apple-ios15.0-simulator"
        #expect(changedTarget.cacheKey != baseline.cacheKey)

        var changedCompiler = baseline
        changedCompiler.compilerFingerprint = "swift-other"
        #expect(changedCompiler.cacheKey != baseline.cacheKey)

        var changedKey = baseline
        changedKey.keys = [
            .init(rawValue: .sha256("another adapter")),
        ]
        #expect(changedKey.cacheKey != baseline.cacheKey)

        var changedImports = baseline
        changedImports.importedModules.append("GeometryKit")
        changedImports.importedModules.sort()
        #expect(changedImports.cacheKey != baseline.cacheKey)
    }

    @Test("Canonical Pack cache validates source integrity and reuses a hit")
    func cacheRoundTrip() throws {
        let identity = makeIdentity(keys: [
            .init(rawValue: .sha256("adapter")),
        ])
        let path = BridgeGeneration.Generator.adapterPackSourcePath(
            moduleName: identity.moduleName
        )
        let source = """
        // Generated Helix Adapter Pack v1. Do not edit.
        import Foundation
        """
        let artifact = NativeAdapterPack.CachedArtifact(
            document: .init(
                identity: identity,
                sourcePath: path,
                source: source
            ),
            source: source
        )
        let bytes = try NativeAdapterPack.Codec.encode(artifact)
        #expect(try NativeAdapterPack.Codec.decode(bytes).document == artifact.document)

        var drifted = artifact
        drifted.source += "\n// drift"
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try NativeAdapterPack.Codec.encode(drifted)
        }
        let staleSource = source + "\n// stale but internally valid"
        let stale = NativeAdapterPack.CachedArtifact(
            document: .init(
                identity: identity,
                sourcePath: path,
                source: staleSource
            ),
            source: staleSource
        )
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try stale.validated(
                against: artifact.document,
                source: artifact.source
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-adapter-pack-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BuildCache.Store(rootURL: root)
        let first = try store.value(
            namespace: .adapterPack,
            key: identity.cacheKey,
            maximumBytes: NativeAdapterPack.Codec.maximumBytes,
            validate: { _ = try NativeAdapterPack.Codec.decode($0) },
            produce: { bytes }
        )
        #expect(first.source == .generated)
        let second = try store.value(
            namespace: .adapterPack,
            key: identity.cacheKey,
            maximumBytes: NativeAdapterPack.Codec.maximumBytes,
            validate: { _ = try NativeAdapterPack.Codec.decode($0) },
            produce: {
                Issue.record("a valid Pack cache hit regenerated payload")
                return bytes
            }
        )
        #expect(second.source == .hit)
        #expect(second.data == bytes)
    }

    @Test("Compiled Pack identity ignores transient paths and invalidates ABI inputs")
    func objectIdentity() throws {
        let pack = makeIdentity(keys: [
            .init(rawValue: .sha256("adapter")),
        ])
        let firstPlan = try makeCompilationPlan(
            pack: pack,
            source: "/tmp/First/Pack.swift",
            output: "/tmp/First/Pack.o"
        )
        let secondPlan = try makeCompilationPlan(
            pack: pack,
            source: "/tmp/Second/Pack.swift",
            output: "/tmp/Second/Pack.o"
        )
        #expect(firstPlan.compilerModuleName == secondPlan.compilerModuleName)
        #expect(firstPlan.identityArguments == secondPlan.identityArguments)
        #expect(!firstPlan.identityArguments.contains("/tmp/First/Pack.swift"))
        #expect(!firstPlan.identityArguments.contains("/tmp/First/Pack.o"))

        let baseline = makeObjectIdentity(pack: pack, plan: firstPlan)
        let equivalent = makeObjectIdentity(pack: pack, plan: secondPlan)
        #expect(try baseline.cacheKey() == equivalent.cacheKey())

        var changedSource = baseline
        changedSource.sourceHash = .sha256("changed source")
        #expect(try changedSource.cacheKey() != baseline.cacheKey())

        var changedInterfaces = baseline
        changedInterfaces.compilerInputs.contentHash = .sha256("changed interfaces")
        #expect(try changedInterfaces.cacheKey() != baseline.cacheKey())

        var incomplete = baseline
        incomplete.compilerInputs.isComplete = false
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try incomplete.cacheKey()
        }

        var malformedPack = baseline
        malformedPack.pack.moduleName = "Foundation;Injected"
        malformedPack.compilerModuleName = XcodeIntegration
            .AdapterPackCompilationPlanner.compilerModuleName(
                for: malformedPack.pack
            )
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try malformedPack.cacheKey()
        }

        var duplicateKeys = baseline
        duplicateKeys.pack.keys.append(duplicateKeys.pack.keys[0])
        duplicateKeys.compilerModuleName = XcodeIntegration
            .AdapterPackCompilationPlanner.compilerModuleName(
                for: duplicateKeys.pack
            )
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try duplicateKeys.cacheKey()
        }

        var missingPrimaryImport = baseline
        missingPrimaryImport.pack.importedModules = []
        missingPrimaryImport.compilerModuleName = XcodeIntegration
            .AdapterPackCompilationPlanner.compilerModuleName(
                for: missingPrimaryImport.pack
            )
        #expect(throws: NativeAdapterPack.Error.invalid) {
            _ = try missingPrimaryImport.cacheKey()
        }
    }

    private func makeIdentity(
        keys: [Core.NativeCall.Key]
    ) -> NativeAdapterPack.Identity {
        .init(
            compilerFingerprint: "swift-fixture",
            sdkBuild: "23A1",
            targetTriple: "arm64-apple-ios15.0-simulator",
            minimumDeployment: .init(15),
            transformPipelineHash: .sha256("adapter-pack-pipeline"),
            moduleName: "Foundation",
            importedModules: ["Foundation"],
            keys: keys
        )
    }

    private func makeCompilationPlan(
        pack: NativeAdapterPack.Identity,
        source: String,
        output: String
    ) throws -> XcodeIntegration.AdapterPackCompilationPlan {
        try XcodeIntegration.AdapterPackCompilationPlanner().plan(
            compilerPath: "/Toolchain/usr/bin/swiftc",
            capturedArguments: [
                "-module-name", "DemoApp",
                "-target", "arm64-apple-ios15.0-simulator",
                "-sdk", "/SDK/iPhoneSimulator.sdk",
                "-I", "/Build/Products/Debug-iphonesimulator",
                "-Xfrontend", "-enable-private-imports",
                "-Xfrontend", "-enable-implicit-dynamic",
                "-Xfrontend", "-enable-dynamic-replacement-chaining",
                "-Onone",
            ],
            expectedCompilerPath: "/Toolchain/usr/bin/swiftc",
            expectedCapturedModuleName: "DemoApp",
            expectedTargetTriple: "arm64-apple-ios15.0-simulator",
            expectedSDKPath: "/SDK/iPhoneSimulator.sdk",
            expectedOptimization: "-Onone",
            clangModuleMapURLs: [
                URL(fileURLWithPath: "/Modules/Runtime.modulemap"),
            ],
            generatedSourceURL: URL(fileURLWithPath: source),
            outputURL: URL(fileURLWithPath: output),
            identity: pack
        )
    }

    private func makeObjectIdentity(
        pack: NativeAdapterPack.Identity,
        plan: XcodeIntegration.AdapterPackCompilationPlan
    ) -> NativeAdapterPack.ObjectIdentity {
        .init(
            pack: pack,
            sourceHash: .sha256("pack source"),
            compilerModuleName: plan.compilerModuleName,
            toolchain: .init(
                fingerprint: "swift-fixture",
                versionOutput: "Apple Swift fixture",
                targetInfo: "arm64-apple-macosx",
                compilerBinaryHash: .sha256("swiftc")
            ),
            xcodeBuild: "16A1",
            compilerArguments: plan.identityArguments,
            compilerInputs: .init(
                importedModules: ["Foundation", "HelixRuntime"],
                searchRoots: ["/Build/Products/Debug-iphonesimulator"],
                explicitPaths: ["/Modules/Runtime.modulemap"],
                fileCount: 2,
                byteCount: 1_024,
                contentHash: .sha256("compiler interfaces"),
                isComplete: true
            ),
            moduleMaps: [
                .init(
                    path: "/Modules/Runtime.modulemap",
                    contentHash: .sha256("module map")
                ),
            ]
        )
    }
}
}
