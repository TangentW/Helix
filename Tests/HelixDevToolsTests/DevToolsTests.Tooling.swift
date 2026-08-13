import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Build capture, snapshots, and release isolation")
struct Tooling {
    @Test("Activity commands and nested response files are expanded without guessing flags")
    func capturesFrontendJob() throws {
        let directory = try temporaryDirectory("helix-build-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source With Space.swift")
        try Data("func value() -> Int { 1 }\n".utf8).write(to: source)
        let response = directory.appendingPathComponent("job.rsp")
        let responseText = """
        -module-name Fixture -target arm64-apple-ios18.0-simulator \
        -sdk /SDK/iPhoneSimulator.sdk -Onone -enable-implicit-dynamic \
        -primary-file "\(source.path)" -I "\(directory.path)"
        """
        try Data(responseText.utf8).write(to: response)
        let jobs = try BuildCapture.XcodeActivityReader().readFrontendJobs(
            fromText: "/usr/bin/swiftc @\(response.path)\n"
        )
        let normalized = try BuildCapture.FrontendJobNormalizer().normalize(
            try #require(jobs.first),
            workingDirectory: directory
        )
        #expect(normalized.moduleName == "Fixture")
        #expect(normalized.targetTriple == "arm64-apple-ios18.0-simulator")
        #expect(normalized.primaryFilePaths == [source.path])
        #expect(normalized.arguments.contains("-enable-implicit-dynamic"))
    }

    @Test("Activity serialization bytes do not hide embedded frontend commands")
    func extractsCommandFromBinaryActivity() throws {
        let directory = try temporaryDirectory("helix-binary-activity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("Build.xcactivitylog")
        var bytes = Data([0x01, 0xff, 0x02])
        bytes.append(
            contentsOf: Data(
                "/usr/bin/swiftc -module-name Fixture -target arm64-apple-ios18.0-simulator "
                    .utf8
            )
        )
        bytes.append(contentsOf: Data("-sdk /SDK -Onone Source.swift\n".utf8))
        bytes.append(contentsOf: [0x00, 0x03])
        try bytes.write(to: log)

        let jobs = try BuildCapture.XcodeActivityReader().readFrontendJobs(
            fromActivityLog: log
        )

        #expect(jobs.count == 1)
        #expect(jobs[0].executable == "/usr/bin/swiftc")
        #expect(jobs[0].arguments.contains("-module-name"))
    }

    @Test("The Xcode compiler proxy record preserves every argument exactly")
    func decodesSwiftCompilerProxyRecord() throws {
        let directory = try temporaryDirectory("helix-swift-invocation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("FrontendInvocation.hlxswiftc")
        let fields = [
            Core.CompilerCapture.recordMarker,
            "/Toolchain/usr/bin/swiftc",
            "-module-name", "Live Feature", "", "Sources/Screen With Space.swift",
        ]
        var bytes = Data()
        for field in fields {
            bytes.append(Data(field.utf8))
            bytes.append(0)
        }
        try bytes.write(to: record)

        let job = try BuildCapture.SwiftInvocationReader().readFrontendJob(at: record)

        #expect(job.executable == "/Toolchain/usr/bin/swiftc")
        #expect(job.arguments == Array(fields.dropFirst(2)))
    }

    @Test("Swift file lists are expanded into a self-contained captured job")
    func expandsFrontendFileLists() throws {
        let directory = try temporaryDirectory("helix-build-filelist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("First.swift")
        let second = directory.appendingPathComponent("Second.swift")
        try Data("func first() {}\n".utf8).write(to: first)
        try Data("func second() {}\n".utf8).write(to: second)
        let sources = directory.appendingPathComponent("sources.SwiftFileList")
        let primary = directory.appendingPathComponent("primary.SwiftFileList")
        try Data("\(first.path)\n\(second.path)\n".utf8).write(to: sources)
        try Data("\(first.path)\n".utf8).write(to: primary)
        let job = BuildCapture.CapturedFrontendJob(
            executable: "/usr/bin/swiftc",
            arguments: [
                "-module-name", "Fixture",
                "-target", "arm64-apple-ios18.0-simulator",
                "-sdk", "/SDK/iPhoneSimulator.sdk",
                "-filelist", sources.path,
                "-primary-filelist", primary.path,
            ],
            sourceLine: "fixture"
        )

        let normalized = try BuildCapture.FrontendJobNormalizer().normalize(
            job,
            workingDirectory: directory
        )

        #expect(normalized.sourcePaths == [first.path, second.path])
        #expect(normalized.primaryFilePaths == [first.path])
        #expect(!normalized.arguments.contains("-filelist"))
        #expect(!normalized.arguments.contains("-primary-filelist"))
    }

    #if os(macOS)
    @Test("The selected Xcode toolchain passes an isolated Simulator replay probe")
    func frontendReplayProbe() throws {
        let directory = try temporaryDirectory("helix-frontend-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Replay.swift")
        let output = directory.appendingPathComponent("Replay.o")
        try Data("public func replayValue(_ input: Int) -> Int { input + 1 }\n".utf8)
            .write(to: source)
        let compiler = URL(fileURLWithPath: "/usr/bin/swiftc")
        let sdk = try SwiftFrontend.Driver(compilerURL: compiler)
            .sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let normalized = BuildCapture.NormalizedFrontendJob(
            executable: compiler.path,
            arguments: [
                source.path, "-emit-object", "-parse-as-library",
                "-module-name", "ReplayFixture",
                "-target", target,
                "-sdk", sdk.path,
                "-Onone", "-Xfrontend", "-enable-implicit-dynamic",
                "-o", output.path,
            ],
            moduleName: "ReplayFixture",
            targetTriple: target,
            sdkPath: sdk.path,
            sourcePaths: [source.path],
            moduleSearchPaths: [],
            primaryFilePaths: []
        )

        let result = try BuildCapture.DefaultFrontendReplayProbe(runner: .init()).probe(
            .init(
                job: normalized,
                compilerURL: compiler,
                workingDirectory: directory,
                platform: .iOSSimulator
            )
        )

        #expect(result.replayArtifactCount >= 1)
        #expect(result.sdkBuild == sdk.buildVersion)
        #expect(result.toolchainCapabilities.implicitDynamic)
        #expect(result.toolchainCapabilities.privateImports)
        #expect(result.toolchainCapabilities.dynamicReplacementChaining)
        #expect(result.toolchainCapabilities.canonicalSIL)
    }
    #endif

    @Test("Snapshots require stable contents and classify a baseline restore")
    func stableSnapshotAndBaseline() async throws {
        let directory = try temporaryDirectory("helix-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Screen.swift")
        let original = Data("func render() { print(1) }\n".utf8)
        try original.write(to: source)
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Sources/Screen.swift")
        let manifest = try makeManifest(source: source, sourceID: sourceID, contents: original)
        let baseline = PatchScheduling.BaselineStore(installedBaseline: [sourceID: .sha256(original)])

        let changed = Data("func render() { print(2) }\n".utf8)
        try changed.write(to: source)
        let first = try await SourceSnapshot.Snapshotter(
            stabilityDelayNanoseconds: 1_000_000
        ).capture(
            changedPaths: [source.path],
            manifest: manifest,
            revision: .init(rawValue: 1)
        )
        #expect(await baseline.classify(first).changedFiles == [sourceID])
        try await baseline.markApplied(first)

        try original.write(to: source)
        let restored = try await SourceSnapshot.Snapshotter(
            stabilityDelayNanoseconds: 1_000_000
        ).capture(
            changedPaths: [source.path],
            manifest: manifest,
            revision: .init(rawValue: 2)
        )
        #expect(await baseline.classify(restored).restoredToBaseline == [sourceID])
    }

    @Test("Generated Native replacement source includes a per-image registration contract")
    func generatesReplacementSource() throws {
        let source = try NativeGeneration.SourceGenerator().generate(
            moduleName: "Feature",
            sourceFileLogicalPath: "Sources/Feature.swift",
            imports: ["UIKit"],
            roots: [
                .init(
                    originalReference: "value(_:)",
                    replacementDeclaration: "private func replacementValue(_ x: Int) -> Int",
                    body: "    x + 1",
                    sourceLine: 42
                ),
            ]
        )
        #expect(source.contains("@_dynamicReplacement(for: value(_:))"))
        #expect(
            source.contains(
                "@_dynamicReplacement(for: value(_:)) "
                    + "private func replacementValue(_ x: Int) -> Int {    x + 1}"
            )
        )
        #expect(source.contains("@_private(sourceFile: \"Feature.swift\") import Feature"))
        #expect(
            source.contains(
                "#sourceLocation(file: \"Sources/Feature.swift\", line: 42)"
            )
        )
        #expect(source.contains("#sourceLocation()"))
        #expect(source.contains("@_cdecl(\"hlx_generation_registration_v1\")"))

        let materializedSource = try NativeGeneration.SourceGenerator().generate(
            moduleName: "Feature",
            sourceFileLogicalPath: "Sources/Feature.swift",
            privateImportSourceFile: "HelixGenerated.Feature.swift",
            imports: [],
            roots: [
                .init(
                    originalReference: "value(_:)",
                    replacementDeclaration: "func replacementValue(_ x: Int) -> Int",
                    body: " x + 1"
                ),
            ]
        )
        #expect(
            materializedSource.contains(
                "@_private(sourceFile: \"HelixGenerated.Feature.swift\") import Feature"
            )
        )
    }

    @Test("Native builder emits and signs an identity-bound Simulator replacement image")
    func nativeBuilderEndToEnd() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DynamicReplacement", isDirectory: true)
        let output = try temporaryDirectory("helix-native-builder")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = ProcessExecution.Runner()
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let target = "arm64-apple-ios15.0-simulator"
        let featureSource = fixtures.appendingPathComponent("Feature.swift")
        let featureImage = output.appendingPathComponent("libFeature.dylib")
        let featureModule = output.appendingPathComponent("Feature.swiftmodule")
        try requireSuccess(
            runner.run(
                executable: compilerURL,
                arguments: [
                    featureSource.path,
                    "-emit-library", "-emit-module", "-module-name", "Feature",
                    "-target", target, "-sdk", sdk.path, "-Onone",
                    "-Xfrontend", "-enable-implicit-dynamic",
                    "-emit-module-path", featureModule.path,
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/libFeature.dylib",
                    "-o", featureImage.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: output
            )
        )

        let sessionID = UUID()
        let executableUUID = UUID()
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Feature.swift")
        let sourceBytes = try Data(contentsOf: featureSource)
        let manifest = DevBuildManifest.Document(
            sessionBuildID: sessionID,
            workspacePathHash: .sha256(fixtures.path),
            scheme: "Feature",
            configuration: "Debug",
            bundleID: "dev.helix.native-builder",
            executableUUID: executableUUID,
            moduleName: "Feature",
            targetTriple: target,
            architecture: "arm64",
            platform: .iOSSimulator,
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            swiftCompilerFingerprint: toolchain.fingerprint,
            sdkBuild: sdk.buildVersion,
            frontendArguments: [
                "-module-name", "Feature", "-target", target,
                "-sdk", sdk.path, "-Onone", "-enable-implicit-dynamic",
                "-I", output.path, featureSource.path,
            ],
            linkArguments: ["-L", output.path, "-lFeature"],
            moduleSearchPaths: [output.path],
            sourceFiles: [
                .init(
                    id: sourceID,
                    logicalPath: "Feature.swift",
                    absolutePath: featureSource.path,
                    contentHash: .sha256(sourceBytes)
                ),
            ],
            buildProducts: [
                .init(kind: "dylib", path: featureImage.path, contentHash: .sha256(
                    try Data(contentsOf: featureImage)
                )),
            ],
            liveReloadIndexHash: .sha256("native-builder-index"),
            dependencyGraphHash: .sha256("native-builder-dependencies"),
            toolchainCapabilities: .init(
                implicitDynamic: true,
                privateImports: true,
                dynamicReplacementChaining: true,
                nativeInterposing: false,
                canonicalSIL: true
            )
        )
        try manifest.validate()
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: manifest.bundleID,
            buildNumber: "1",
            seed: "native-builder"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Feature",
            sourceFileLogicalID: "Feature.swift",
            canonicalDeclaration: "func helixFixtureValue(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let result = try NativeGeneration.DefaultBuilder(runner: runner).build(
            .init(
                sessionID: sessionID,
                sourceRevision: .init(rawValue: 1),
                generationID: .init(rawValue: 1),
                manifest: manifest,
                compilerURL: compilerURL,
                sourceURLs: [fixtures.appendingPathComponent("Patch.swift")],
                outputDirectory: output.appendingPathComponent("generation", isDirectory: true),
                changedSources: [sourceID],
                changedFunctions: [functionKey]
            )
        )
        #expect(result.descriptor.platform == .iOSSimulator)
        #expect(result.descriptor.architecture == .arm64)
        #expect(result.descriptor.isCodeSigned)
        #expect(result.debugSymbols.imageUUID == result.descriptor.uuid)
        #expect(FileManager.default.fileExists(atPath: result.debugSymbolsURL.path))
        #expect(FileManager.default.fileExists(atPath: result.debugSymbols.dwarfURL.path))
        #expect(
            result.debugSymbols.swiftModuleURL.lastPathComponent
                .hasPrefix("HLXLive_\(sessionID.uuidString.replacingOccurrences(of: "-", with: ""))_g1")
        )
        #expect(
            result.debugSymbols.lldbCommands().first?
                .contains(result.debugSymbols.imageUUID.uuidString) == true
        )
        #expect(throws: DebugSymbols.Error.self) {
            _ = try DebugSymbols.Artifact(
                imageUUID: UUID(),
                bundleURL: result.debugSymbols.bundleURL,
                dwarfURL: result.debugSymbols.dwarfURL,
                swiftModuleURL: result.debugSymbols.swiftModuleURL,
                sourceMappings: result.debugSymbols.sourceMappings
            )
        }
        #expect(
            result.descriptor.installName
                == "@rpath/HLXLive-\(sessionID.uuidString)-g1.dylib"
        )
        try result.artifact.offer.validate()
        let emittedImage = try Data(contentsOf: result.imageURL)
        #expect(result.artifact.payload == emittedImage)
        #expect(emittedImage.range(of: Data("__s_async_hook".utf8)) == nil)
        #expect(emittedImage.range(of: Data("__swift56_hooks".utf8)) == nil)

        var deviceManifest = manifest
        deviceManifest.platform = .iOS
        deviceManifest.targetTriple = "arm64-apple-ios15.0"
        if let targetIndex = deviceManifest.frontendArguments.firstIndex(of: "-target") {
            deviceManifest.frontendArguments[targetIndex + 1] = deviceManifest.targetTriple
        }
        #expect(throws: DevProtocol.Diagnostic.self) {
            _ = try NativeGeneration.DefaultBuilder(runner: runner).build(
                .init(
                    sessionID: sessionID,
                    sourceRevision: .init(rawValue: 2),
                    generationID: .init(rawValue: 2),
                    manifest: deviceManifest,
                    compilerURL: compilerURL,
                    sourceURLs: [fixtures.appendingPathComponent("Patch.swift")],
                    outputDirectory: output,
                    changedSources: [sourceID],
                    changedFunctions: [functionKey]
                )
            )
        }
        do {
            _ = try NativeGeneration.DefaultBuilder(runner: runner).build(
                .init(
                    sessionID: sessionID,
                    sourceRevision: .init(rawValue: 2),
                    generationID: .init(rawValue: 2),
                    manifest: deviceManifest,
                    compilerURL: compilerURL,
                    sourceURLs: [fixtures.appendingPathComponent("Patch.swift")],
                    outputDirectory: output,
                    changedSources: [sourceID],
                    changedFunctions: [functionKey]
                )
            )
            Issue.record("expected a missing device signing identity diagnostic")
        } catch let diagnostic as DevProtocol.Diagnostic {
            #expect(diagnostic.code == "HLXLR405")
        }
    }

    @Test("The qualified Swift toolchain chains two signed replacement generations")
    func dynamicReplacementEndToEnd() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DynamicReplacement", isDirectory: true)
        let output = try temporaryDirectory("helix-dynamic-replacement")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = ProcessExecution.Runner()
        let compiler = URL(fileURLWithPath: "/usr/bin/swiftc")
        let featureImage = output.appendingPathComponent("libFeature.dylib")
        let featureModule = output.appendingPathComponent("Feature.swiftmodule")
        let patchImage = output.appendingPathComponent("libPatch.dylib")
        let secondPatchImage = output.appendingPathComponent("libPatch2.dylib")
        let host = output.appendingPathComponent("Host")

        try requireSuccess(
            runner.run(
                executable: compiler,
                arguments: [
                    fixtures.appendingPathComponent("Feature.swift").path,
                    "-emit-library", "-emit-module", "-module-name", "Feature",
                    "-Xfrontend", "-enable-implicit-dynamic",
                    "-emit-module-path", featureModule.path,
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/libFeature.dylib",
                    "-o", featureImage.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: output
            )
        )
        try requireSuccess(
            runner.run(
                executable: compiler,
                arguments: [
                    fixtures.appendingPathComponent("Patch.swift").path,
                    "-emit-library", "-module-name", "HLXLiveFixture",
                    "-I", output.path, "-L", output.path, "-lFeature",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/libPatch.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", output.path,
                    "-o", patchImage.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: output
            )
        )
        try requireSuccess(
            runner.run(
                executable: compiler,
                arguments: [
                    fixtures.appendingPathComponent("Patch2.swift").path,
                    "-emit-library", "-module-name", "HelixLiveFixture2",
                    "-I", output.path, "-L", output.path, "-lFeature",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/libPatch2.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", output.path,
                    "-o", secondPatchImage.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: output
            )
        )
        for image in [patchImage, secondPatchImage] {
            try requireSuccess(
                runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--force", "--sign", "-", "--timestamp=none", image.path],
                    environment: ProcessInfo.processInfo.environment,
                    workingDirectory: output
                )
            )
        }
        let inspector = MachO.Inspector()
        let firstDescriptor = try inspector.inspect(
            Data(contentsOf: patchImage, options: .mappedIfSafe)
        )
        #expect(firstDescriptor.isCodeSigned)
        #expect(firstDescriptor.platform == .macOS)
        #expect(firstDescriptor.installName == "@rpath/libPatch.dylib")
        #if arch(x86_64)
        let expectedArchitecture = MachO.Architecture.x86_64
        #else
        let expectedArchitecture = MachO.Architecture.arm64
        #endif
        try inspector.preflight(
            firstDescriptor,
            expectedArchitecture: expectedArchitecture,
            expectedInstallName: "@rpath/libPatch.dylib",
            expectedPlatform: .macOS,
            allowedDependencyPrefixes: [
                "/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/",
            ]
        )
        try requireSuccess(
            runner.run(
                executable: compiler,
                arguments: [
                    fixtures.appendingPathComponent("Host.swift").path,
                    "-I", output.path, "-L", output.path, "-lFeature",
                    "-Xlinker", "-rpath", "-Xlinker", output.path,
                    "-o", host.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: output
            )
        )
        let execution = try runner.run(
            executable: host,
            arguments: [patchImage.path, secondPatchImage.path],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: output
        )
        try requireSuccess(execution)
        #expect(
            execution.standardOutput
                .split(whereSeparator: \.isNewline)
                .map(String.init) == [
                    "2,2,24,24,24,24,24",
                    "8,11,48,48,48,48,48",
                    "7",
                    "21,111,72,72,72,72,72",
                    "7",
                ]
        )
    }

    @Test("Release leakage scanner distinguishes Helix Dev ingress from business Bonjour")
    func releaseLeakageAudit() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "NSBonjourServices": ["_business._tcp", "_helix._tcp"],
                "NSLocalNetworkUsageDescription": "Helix developer connection",
            ],
            format: .binary,
            options: 0
        )
        let report = ReleaseLeakage.Scanner(
            allowedBusinessBonjourServices: ["_business._tcp"]
        ).scan(
            executable: Data("prefix DevActivation.Controller suffix".utf8),
            infoPlist: plist,
            loadedImageNames: ["App"]
        )
        #expect(!report.passed)
        #expect(report.findings.filter { $0.severity == .critical }.count == 3)
    }

    @Test("Release leakage scanner rejects the Live Reload API module")
    func releaseLeakageRejectsLiveReloadAPI() {
        let report = ReleaseLeakage.Scanner().scan(
            executable: Data("HelixLiveReloadAPI".utf8),
            infoPlist: nil,
            loadedImageNames: [
                "/private/Frameworks/HelixLiveReloadAPI.framework/HelixLiveReloadAPI",
            ]
        )

        #expect(!report.passed)
        #expect(report.findings.map(\.code).sorted() == ["HLXREL001", "HLXREL002"])
    }

    @Test("Release App audit scans every Mach-O and fails on symbolic links")
    func releaseAppBundleAudit() throws {
        let directory = try temporaryDirectory("helix-release-audit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Fixture"],
            format: .binary,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        var cleanImage = Data([0xcf, 0xfa, 0xed, 0xfe])
        cleanImage.append(Data("production image".utf8))
        try cleanImage.write(to: app.appendingPathComponent("Fixture"))
        var devImage = Data([0xcf, 0xfa, 0xed, 0xfe])
        devImage.append(Data("HelixDevRuntime HLX_DEV_SESSION_SECRET".utf8))
        try devImage.write(
            to: frameworks.appendingPathComponent("HelixDevAppRuntime.framework")
        )

        let report = try ReleaseLeakage.AppBundleAuditor().audit(appURL: app)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.code == "HLXREL001" })
        #expect(report.findings.contains { $0.code == "HLXREL002" })

        try FileManager.default.removeItem(
            at: frameworks.appendingPathComponent("HelixDevAppRuntime.framework")
        )
        let link = frameworks.appendingPathComponent("Hidden")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(throws: ReleaseLeakage.AuditError.symbolicLink("Frameworks/Hidden")) {
            try ReleaseLeakage.AppBundleAuditor().audit(appURL: app)
        }
    }

    @Test("The save pipeline activates changes and emits a baseline-restored generation")
    func savePipelineAndBaselineRestore() async throws {
        let directory = try temporaryDirectory("helix-save-pipeline")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        let recorder = ArtifactRecorder()
        let pipeline = try DevSession.Pipeline(
            identity: fixture.identity,
            manifest: fixture.manifest,
            reloadIndex: fixture.index,
            snapshotter: .init(stabilityDelayNanoseconds: 0, maximumAttempts: 2),
            builder: { request in
                .patch(
                    .init(
                        backend: .hlbc,
                        payload: Data("revision-\(request.snapshot.revision.rawValue)".utf8),
                        changedFunctions: request.candidateFunctionKeys
                    )
                )
            },
            sender: { artifact in
                await recorder.record(artifact)
                return .init(
                    sourceRevision: artifact.offer.sourceRevision,
                    generationID: artifact.offer.generationID,
                    codeStatus: .codeActive,
                    reloadStatus: .refreshed
                )
            }
        )

        try fixture.write("func render() { print(2) }\n")
        let changed = await pipeline.submit(changedPaths: [fixture.sourceURL.path])
        guard case let .activation(changedResult) = changed else {
            Issue.record("expected first save to activate")
            return
        }
        #expect(changedResult.sourceRevision == .init(rawValue: 1))

        try fixture.write(String(decoding: fixture.baseline, as: UTF8.self))
        let restored = await pipeline.submit(changedPaths: [fixture.sourceURL.path])
        guard case let .activation(restoredResult) = restored else {
            Issue.record("expected baseline restore to activate")
            return
        }
        #expect(restoredResult.sourceRevision == .init(rawValue: 2))
        let offers = await recorder.artifacts.map(\.offer)
        #expect(offers.map(\.reason) == [.sourceSaved, .baselineRestored])
        #expect(offers.allSatisfy { $0.reloadHints.first?.policy == .invalidate })
    }

    @Test("A slower older compilation cannot transfer after a newer save completes")
    func savePipelineLatestWins() async throws {
        let directory = try temporaryDirectory("helix-save-latest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        let recorder = ArtifactRecorder()
        let gate = FirstBuildGate()
        let pipeline = try DevSession.Pipeline(
            identity: fixture.identity,
            manifest: fixture.manifest,
            reloadIndex: fixture.index,
            snapshotter: .init(stabilityDelayNanoseconds: 0, maximumAttempts: 2),
            builder: { request in
                await gate.pauseFirst(request.snapshot.revision)
                return .patch(
                    .init(
                        backend: .hlbc,
                        payload: Data("revision-\(request.snapshot.revision.rawValue)".utf8),
                        changedFunctions: request.candidateFunctionKeys
                    )
                )
            },
            sender: { artifact in
                await recorder.record(artifact)
                return .init(
                    sourceRevision: artifact.offer.sourceRevision,
                    generationID: artifact.offer.generationID,
                    codeStatus: .codeActive,
                    reloadStatus: .refreshed
                )
            }
        )

        try fixture.write("func render() { print(2) }\n")
        let first = Task { await pipeline.submit(changedPaths: [fixture.sourceURL.path]) }
        await gate.waitUntilFirstPaused()
        try fixture.write("func render() { print(3) }\n")
        let second = Task { await pipeline.submit(changedPaths: [fixture.sourceURL.path]) }
        let secondResult = await second.value
        await gate.resumeFirst()
        let firstResult = await first.value

        guard case .activation = secondResult else {
            Issue.record("expected latest save to activate")
            return
        }
        guard case let .superseded(revision) = firstResult else {
            Issue.record("expected older build to be superseded")
            return
        }
        #expect(revision == .init(rawValue: 1))
        #expect(await recorder.artifacts.map(\.offer.sourceRevision) == [.init(rawValue: 2)])
    }

    @Test("A real atomic file save is debounced into the known Swift source path")
    func fileSaveMonitor() async throws {
        let directory = try temporaryDirectory("helix-save-monitor")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        let recorder = MonitorRecorder()
        let monitor = try SourceSnapshot.Monitor(
            manifest: fixture.manifest,
            debounceNanoseconds: 20_000_000
        ) { event in
            await recorder.record(event)
        }
        await monitor.start()
        try fixture.write("func render() { print(4) }\n")

        for _ in 0..<100 where await recorder.changedPaths.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await monitor.stop()
        #expect(await recorder.changedPaths == [fixture.sourceURL.path])
    }

    @Test("A monitor catches source edits made before a test App connects")
    func monitorReconcilesFrozenShellBaseline() async throws {
        let directory = try temporaryDirectory("helix-late-connect-monitor")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        try fixture.write("func render() { print(99) }\n")
        let recorder = MonitorRecorder()
        let monitor = try SourceSnapshot.Monitor(
            manifest: fixture.manifest,
            debounceNanoseconds: 20_000_000
        ) { event in
            await recorder.record(event)
        }

        await monitor.start()
        for _ in 0..<100 where await recorder.changedPaths.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await monitor.stop()
        #expect(await recorder.changedPaths == [fixture.sourceURL.path])
    }

    @Test("An in-place file save is observed even when its directory entry is unchanged")
    func inPlaceFileSaveMonitor() async throws {
        let directory = try temporaryDirectory("helix-in-place-save-monitor")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        let recorder = MonitorRecorder()
        let monitor = try SourceSnapshot.Monitor(
            manifest: fixture.manifest,
            debounceNanoseconds: 20_000_000
        ) { event in
            await recorder.record(event)
        }
        await monitor.start()
        let handle = try FileHandle(forWritingTo: fixture.sourceURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("func render() { print(5) }\n".utf8))
        try handle.close()

        for _ in 0..<100 where await recorder.changedPaths.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await monitor.stop()
        #expect(await recorder.changedPaths == [fixture.sourceURL.path])
    }

    @Test("Filesystem noise does not cancel a source delivery already in flight")
    func monitorKeepsInFlightDeliveryAlive() async throws {
        let directory = try temporaryDirectory("helix-monitor-delivery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try PipelineFixture(directory: directory)
        let probe = MonitorDeliveryProbe()
        let monitor = try SourceSnapshot.Monitor(
            manifest: fixture.manifest,
            debounceNanoseconds: 20_000_000
        ) { event in
            guard case .changed = event else { return }
            await probe.deliver()
        }
        await monitor.start()
        try fixture.write("func render() { print(6) }\n")
        await probe.waitUntilStarted()

        // Editors and indexers routinely create unrelated directory entries
        // while a compile is running. Such events may start another scan but
        // must not cancel the delivery that owns the accepted source revision.
        try Data("noise".utf8).write(
            to: directory.appendingPathComponent("editor-noise.tmp"),
            options: .atomic
        )
        await probe.waitUntilFinished()
        await monitor.stop()
        #expect(!(await probe.wasCancelled))
    }

    @Test("Source monitoring rejects oversized files before mapping their contents")
    func monitorRejectsOversizedSource() throws {
        let directory = try temporaryDirectory("helix-monitor-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Large.swift")
        let contents = Data(repeating: UInt8(ascii: "x"), count: 64)
        try contents.write(to: source)
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Sources/Screen.swift")
        let manifest = try makeManifest(source: source, sourceID: sourceID, contents: contents)

        #expect(throws: SourceSnapshot.Error.sourceTooLarge(source.path)) {
            _ = try SourceSnapshot.Monitor(
                manifest: manifest,
                maximumSourceBytes: 32,
                eventHandler: { _ in }
            )
        }
    }

    @Test("Reload Index validation rejects superclass cycles")
    func reloadIndexRejectsSuperclassCycle() throws {
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Sources/Cycle.swift")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.cycle",
            buildNumber: "1",
            seed: "cycle"
        )
        let function = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Cycle",
            sourceFileLogicalID: "Sources/Cycle.swift",
            canonicalDeclaration: "func render()",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
        let first = LiveReload.NominalTypeID.derive(module: "Cycle", canonicalName: "First")
        let second = LiveReload.NominalTypeID.derive(module: "Cycle", canonicalName: "Second")
        let index = ReloadIndex.Document(
            sourceRoots: [.init(sourceFileID: sourceID, roots: [function])],
            roots: [.init(functionKey: function, nominalTypeID: first, role: .unknown)],
            superclassEdges: [
                .init(subtype: first, superclass: second),
                .init(subtype: second, superclass: first),
            ]
        )
        #expect(throws: DevProtocol.Error.self) {
            try index.validate()
        }
    }

    private func makeManifest(
        source: URL,
        sourceID: LiveReload.SourceFileID,
        contents: Data
    ) throws -> DevBuildManifest.Document {
        let manifest = DevBuildManifest.Document(
            sessionBuildID: UUID(),
            workspacePathHash: .sha256(source.deletingLastPathComponent().path),
            scheme: "Fixture",
            configuration: "Debug",
            bundleID: "dev.helix.fixture",
            executableUUID: UUID(),
            moduleName: "Fixture",
            targetTriple: "arm64-apple-ios18.0-simulator",
            architecture: "arm64",
            platform: .iOSSimulator,
            minimumOS: .init(17),
            xcodeBuild: "17F113",
            swiftCompilerFingerprint: "swift-6.3.3",
            sdkBuild: "22A",
            frontendArguments: [
                "-module-name", "Fixture", "-target", "arm64-apple-ios18.0-simulator",
                "-sdk", "/SDK", "-Onone", "-enable-implicit-dynamic", source.path,
            ],
            linkArguments: [],
            moduleSearchPaths: [],
            sourceFiles: [
                .init(
                    id: sourceID,
                    logicalPath: "Sources/Screen.swift",
                    absolutePath: source.path,
                    contentHash: .sha256(contents)
                ),
            ],
            buildProducts: [],
            liveReloadIndexHash: .sha256("index"),
            dependencyGraphHash: .sha256("dependencies"),
            toolchainCapabilities: .init(
                implicitDynamic: true,
                privateImports: true,
                dynamicReplacementChaining: true,
                nativeInterposing: false,
                canonicalSIL: true
            )
        )
        try manifest.validate()
        return manifest
    }

    private func requireSuccess(_ result: ProcessExecution.Result) throws {
        guard result.status == 0 else {
            throw BuildCapture.Error.replayFailed(result.standardError)
        }
    }
}
}

private actor ArtifactRecorder {
    private(set) var artifacts: [DevProtocol.LiveArtifact] = []

    func record(_ artifact: DevProtocol.LiveArtifact) {
        artifacts.append(artifact)
    }
}

private actor MonitorRecorder {
    private(set) var changedPaths = Set<String>()

    func record(_ event: SourceSnapshot.MonitorEvent) {
        if case let .changed(paths) = event {
            changedPaths.formUnion(paths)
        }
    }
}

private actor MonitorDeliveryProbe {
    private(set) var wasCancelled = false
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func deliver() async {
        started = true
        let starts = startWaiters
        startWaiters.removeAll()
        starts.forEach { $0.resume() }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            wasCancelled = true
        }
        finished = true
        let finishes = finishWaiters
        finishWaiters.removeAll()
        finishes.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private actor FirstBuildGate {
    private var isFirstPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseFirst(_ revision: DevProtocol.SourceRevision) async {
        guard revision.rawValue == 1 else { return }
        isFirstPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilFirstPaused() async {
        guard !isFirstPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resumeFirst() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct PipelineFixture {
    let sourceURL: URL
    let baseline = Data("func render() { print(1) }\n".utf8)
    let sourceID: LiveReload.SourceFileID
    let functionKey: Core.FunctionKey
    let index: ReloadIndex.Document
    let manifest: DevBuildManifest.Document
    let identity: DevProtocol.SessionIdentity

    init(directory: URL) throws {
        sourceURL = directory.appendingPathComponent("Screen.swift")
        try baseline.write(to: sourceURL)
        sourceID = .derive(logicalPath: "Sources/Screen.swift")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.pipeline",
            buildNumber: "1",
            seed: "pipeline"
        )
        functionKey = try .derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Screen.swift",
            canonicalDeclaration: "func render()",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
        let nominal = LiveReload.NominalTypeID.derive(
            module: "Fixture",
            canonicalName: "ScreenViewController"
        )
        index = .init(
            sourceRoots: [.init(sourceFileID: sourceID, roots: [functionKey])],
            roots: [
                .init(
                    functionKey: functionKey,
                    nominalTypeID: nominal,
                    role: .drawingOrConfiguration
                ),
            ]
        )
        let indexHash = try index.contentHash()
        let sessionID = UUID()
        let executableUUID = UUID()
        manifest = .init(
            sessionBuildID: sessionID,
            workspacePathHash: .sha256(directory.path),
            scheme: "Fixture",
            configuration: "Debug",
            bundleID: "dev.helix.pipeline",
            executableUUID: executableUUID,
            moduleName: "Fixture",
            targetTriple: "arm64-apple-ios18.0-simulator",
            architecture: "arm64",
            platform: .iOSSimulator,
            minimumOS: .init(17),
            xcodeBuild: "17F113",
            swiftCompilerFingerprint: "swift-pipeline",
            sdkBuild: "22A",
            frontendArguments: [
                "-module-name", "Fixture", "-target", "arm64-apple-ios18.0-simulator",
                "-sdk", "/SDK", "-Onone", "-enable-implicit-dynamic", sourceURL.path,
            ],
            linkArguments: [],
            moduleSearchPaths: [],
            sourceFiles: [
                .init(
                    id: sourceID,
                    logicalPath: "Sources/Screen.swift",
                    absolutePath: sourceURL.path,
                    contentHash: .sha256(baseline)
                ),
            ],
            buildProducts: [],
            liveReloadIndexHash: indexHash,
            dependencyGraphHash: .sha256("dependencies"),
            toolchainCapabilities: .init(
                implicitDynamic: true,
                privateImports: true,
                dynamicReplacementChaining: true,
                nativeInterposing: false,
                canonicalSIL: true
            )
        )
        identity = .init(
            sessionID: sessionID,
            bundleID: manifest.bundleID,
            executableUUID: executableUUID,
            processID: 42,
            platform: manifest.platform,
            architecture: manifest.architecture,
            operatingSystemBuild: "22A",
            xcodeBuild: manifest.xcodeBuild,
            swiftCompilerFingerprint: manifest.swiftCompilerFingerprint,
            liveReloadIndexHash: indexHash,
            supportedBackends: [.hlbc],
            nativeChainingProbePassed: false
        )
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: sourceURL, options: .atomic)
    }
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
