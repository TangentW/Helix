import Foundation
import HelixBytecode
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Dev prepare build identity")
struct Preparer {
    @Test("One replayed Xcode frontend job freezes a self-consistent Dev Manifest")
    func preparesManifest() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }

        let result = try fixture.preparer().prepare(fixture.request())
        let expectedIndexHash = try fixture.index.contentHash()

        #expect(result.manifest.bundleID == fixture.bundleID)
        #expect(result.manifest.executableUUID == fixture.executableUUID)
        #expect(result.manifest.sourceFiles.map(\.logicalPath) == [fixture.logicalPath])
        #expect(result.manifest.sourceFiles.first?.absolutePath == fixture.sourceURL.path)
        #expect(result.manifest.liveReloadIndexHash == expectedIndexHash)
        #expect(result.manifest.swiftCompilerFingerprint == fixture.compilerFingerprint)
        #expect(result.manifest.toolchainCapabilities.dynamicReplacementChaining)
        #expect(result.selectedJob.arguments.contains("-enable-implicit-dynamic"))
        #expect(result.probe.replayArtifactCount == 1)
        try result.manifest.validate()
    }

    @Test("Workspace bundles resolve logical sources from their parent directory")
    func resolvesSourcesBesideWorkspaceBundle() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        let workspace = fixture.directory.appendingPathComponent(
            "PrepareFixture.xcworkspace",
            isDirectory: true
        )

        let result = try fixture.preparer().prepare(
            fixture.request(workspaceURL: workspace)
        )

        #expect(result.manifest.sourceFiles.first?.absolutePath == fixture.sourceURL.path)
        #expect(result.manifest.workspacePathHash == .sha256(workspace.standardizedFileURL.path))
    }

    @Test("A materialized Xcode source is rebound to its editable Swift source")
    func mapsCompiledSourceToEditableSource() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        let compiledDirectory = fixture.directory.appendingPathComponent(
            "DerivedSources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: compiledDirectory,
            withIntermediateDirectories: true
        )
        let compiled = compiledDirectory.appendingPathComponent("HelixGenerated.Screen.swift")
        try Data(contentsOf: fixture.sourceURL).write(to: compiled, options: .atomic)
        let command = try String(contentsOf: fixture.activityURL, encoding: .utf8)
            .replacingOccurrences(of: fixture.sourceURL.path, with: compiled.path)
        try Data(command.utf8).write(to: fixture.activityURL, options: .atomic)
        var request = fixture.request()
        request.sourceMappings = [fixture.logicalPath: fixture.sourceURL]
        request.compiledSourceMappings = [fixture.logicalPath: compiled]

        let result = try fixture.preparer().prepare(request)

        #expect(result.selectedJob.sourcePaths == [compiled.path])
        #expect(result.manifest.sourceFiles.first?.absolutePath == fixture.sourceURL.path)
        #expect(result.manifest.sourceFiles.first?.contentHash == fixture.archive.sources[0].contentHash)
        #expect(
            result.manifest.sourceFiles.first?.privateImportSourceFile
                == "HelixGenerated.Screen.swift"
        )
    }

    @Test("A Swift Driver command takes precedence over its expanded frontend phase")
    func prefersDriverOverExpandedFrontend() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        let frontend = try String(contentsOf: fixture.activityURL, encoding: .utf8)
        let driver = frontend.replacingOccurrences(of: "-frontend -c", with: "-c")
        try Data((frontend + driver).utf8).write(to: fixture.activityURL, options: .atomic)

        let result = try fixture.preparer().prepare(fixture.request())

        #expect(result.selectedJob.arguments.contains("-c"))
        #expect(!result.selectedJob.arguments.contains("-frontend"))
    }

    @Test("Primary-file jobs may differ only in replaceable inputs and outputs")
    func rejectsSemanticJobDisagreement() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        let original = try String(contentsOf: fixture.activityURL, encoding: .utf8)
        let conflicting = original.replacingOccurrences(
            of: "-Onone",
            with: "-Onone -D CONFLICTING_BUILD_SETTING"
        )
        try Data((original + conflicting).utf8).write(to: fixture.activityURL, options: .atomic)

        #expect(throws: DevSession.PrepareError.inconsistentFrontendJobs) {
            _ = try fixture.preparer().prepare(fixture.request())
        }
    }

    @Test("A source changed after the indexed build cannot become the Dev baseline")
    func rejectsSourceBaselineDrift() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        try Data("public func value() -> Int { 2 }\n".utf8)
            .write(to: fixture.sourceURL, options: .atomic)

        #expect(throws: DevSession.PrepareError.sourceBaselineMismatch(fixture.logicalPath)) {
            _ = try fixture.preparer().prepare(fixture.request())
        }
    }

    @Test("Xcode, SDK, compiler, and executable identity are not advisory")
    func rejectsProbeIdentityDrift() throws {
        let fixture = try PrepareFixture()
        defer { fixture.remove() }
        var mismatched = fixture.probeResult
        mismatched.xcodeBuild = "different-Xcode"
        let preparer = DevSession.Preparer(probe: FixtureProbe(result: mismatched))

        do {
            _ = try preparer.prepare(fixture.request())
            Issue.record("Expected the frozen Xcode identity to be rejected")
        } catch let error as DevSession.PrepareError {
            #expect(error.description.contains("xcodeBuild"))
        }
    }
}
}

private struct FixtureProbe: BuildCapture.Probing {
    var result: BuildCapture.ProbeResult

    func probe(_ request: BuildCapture.ProbeRequest) throws -> BuildCapture.ProbeResult {
        #expect(request.job.moduleName == "PrepareFixture")
        #expect(request.platform == .iOSSimulator)
        return result
    }
}

private final class PrepareFixture {
    let directory: URL
    let sourceURL: URL
    let activityURL: URL
    let archiveURL: URL
    let indexURL: URL
    let executableURL: URL
    let logicalPath = "Sources/Screen.swift"
    let bundleID = "dev.helix.prepare-fixture"
    let moduleName = "PrepareFixture"
    let targetTriple = "arm64-apple-ios15.0-simulator"
    let xcodeBuild = "17F113"
    let sdkBuild = "23F81a"
    let compilerFingerprint = "sha256:prepare-fixture"
    let executableUUID = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!
    let archive: InterfaceArchive.Archive
    let index: ReloadIndex.Document

    var probeResult: BuildCapture.ProbeResult {
        .init(
            swiftCompilerFingerprint: compilerFingerprint,
            xcodeBuild: xcodeBuild,
            sdkBuild: sdkBuild,
            replayArtifactCount: 1,
            toolchainCapabilities: .init(
                implicitDynamic: true,
                privateImports: true,
                dynamicReplacementChaining: true,
                nativeInterposing: false,
                canonicalSIL: true
            )
        )
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-prepare-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourcesDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcesDirectory,
            withIntermediateDirectories: true
        )
        sourceURL = sourcesDirectory.appendingPathComponent("Screen.swift")
        activityURL = directory.appendingPathComponent("Build.log")
        archiveURL = directory.appendingPathComponent("Shell.hlxi")
        indexURL = directory.appendingPathComponent("ReloadIndex.json")
        executableURL = directory.appendingPathComponent("PrepareFixtureApp")

        let sourceData = Data("public func value() -> Int { 1 }\n".utf8)
        try sourceData.write(to: sourceURL, options: .atomic)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: bundleID,
            buildNumber: "1",
            seed: "prepare-fixture"
        )
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Int")
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: moduleName,
            sourceFileLogicalID: logicalPath,
            canonicalDeclaration: "func value() -> Int",
            loweredSignature: signature,
            role: .function
        )
        archive = try InterfaceArchive.Archive.make(
            metadata: .init(
                bundleID: bundleID,
                buildNumber: "1",
                shellNamespaceID: namespace,
                machOUUIDs: [executableUUID],
                targetTriple: targetTriple,
                minimumOS: .init(15),
                xcodeBuild: xcodeBuild,
                sdkBuild: sdkBuild,
                frontendInvocation: .init(
                    moduleName: moduleName,
                    targetTriple: targetTriple,
                    sdkName: "iphonesimulator",
                    sdkBuild: sdkBuild,
                    optimization: "-Onone"
                ),
                transformPipelineHash: .sha256("prepare-transform"),
                sourceBaselineHash: .sha256(sourceData)
            ),
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: compilerFingerprint
            ),
            capabilities: [.baselineV1],
            sources: [.init(logicalPath: logicalPath, contentHash: .sha256(sourceData))],
            functions: [
                .init(
                    key: functionKey,
                    entryIndex: .init(rawValue: 0),
                    moduleName: moduleName,
                    sourceFileLogicalID: logicalPath,
                    canonicalDeclaration: "func value() -> Int",
                    mangledName: "$s14PrepareFixture5valueSiyF",
                    role: .function,
                    loweredSignature: signature,
                    parameterTypes: [],
                    resultType: .int64,
                    effects: .init(),
                    interfaceFingerprint: .sha256("prepare-interface"),
                    bodyFingerprint: .sha256("prepare-body"),
                    patchability: .eligible,
                    bridgeSymbol: "hlx_entry_0"
                ),
            ],
            bridgeRegistrationCount: 1
        )
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: logicalPath)
        index = .init(
            sourceRoots: [.init(sourceFileID: sourceID, roots: [functionKey])],
            roots: [.init(functionKey: functionKey, nominalTypeID: nil, role: .modelOrService)]
        )
        try InterfaceArchive.Codec.encode(archive).write(to: archiveURL, options: .atomic)
        try Core.CanonicalJSON.encode(index).write(to: indexURL, options: .atomic)
        try makeMachO(uuid: executableUUID).write(to: executableURL, options: .atomic)
        let outputURL = directory.appendingPathComponent("Screen.o")
        let command = [
            "/usr/bin/swiftc", "-frontend", "-c",
            "-module-name", moduleName,
            "-target", targetTriple,
            "-sdk", "/SDK/iPhoneSimulator.sdk",
            "-Onone", "-enable-implicit-dynamic",
            "-primary-file", sourceURL.path,
            "-I", directory.path,
            "-o", outputURL.path,
        ].map(shellQuote).joined(separator: " ") + "\n"
        try Data(command.utf8).write(to: activityURL, options: .atomic)
    }

    func request(workspaceURL: URL? = nil) -> DevSession.PrepareRequest {
        .init(
            activityLogURL: activityURL,
            workingDirectory: directory,
            workspaceURL: workspaceURL ?? directory,
            scheme: moduleName,
            configuration: "Debug",
            bundleID: bundleID,
            moduleName: moduleName,
            executableURL: executableURL,
            reloadIndexURL: indexURL,
            interfaceArchiveURL: archiveURL,
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
            sessionBuildID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    func preparer() -> DevSession.Preparer<FixtureProbe> {
        .init(probe: .init(result: probeResult))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func shellQuote(_ value: String) -> String {
        guard value.contains(where: \.isWhitespace) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func makeMachO(uuid: UUID) -> Data {
        var data = Data()
        append(UInt32(0xfeedfacf), to: &data)
        append(UInt32(0x0100000c), to: &data)
        append(UInt32(0), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(48), to: &data)
        append(UInt32(0), to: &data)
        append(UInt32(0), to: &data)
        append(UInt32(0x1b), to: &data)
        append(UInt32(24), to: &data)
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        append(UInt32(0x32), to: &data)
        append(UInt32(24), to: &data)
        append(UInt32(7), to: &data)
        append(UInt32(0x000f0000), to: &data)
        append(UInt32(0x001a0500), to: &data)
        append(UInt32(0), to: &data)
        return data
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
