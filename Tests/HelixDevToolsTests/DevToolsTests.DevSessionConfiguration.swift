import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Dev Session configuration")
struct DevSessionConfiguration {
    @Test("Configuration rejects unknown fields and resolves paths from its own directory")
    func strictConfiguration() throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let prepared = try DevSession.PreparedConfiguration.load(
            configurationURL: fixture.configurationURL
        )
        #expect(prepared.manifest.sessionBuildID == fixture.manifest.sessionBuildID)
        #expect(prepared.resolved.manifestURL == fixture.manifestURL)
        #expect(prepared.resolved.interfaceArchiveURL == fixture.archiveURL)
        #expect(prepared.resolved.document.backendPreference == .automatic)

        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.configurationURL)
            ) as? [String: Any]
        )
        object["sessionSecret"] = "must-never-be-persisted"
        let polluted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DevSession.ConfigurationError.self) {
            _ = try DevSession.Configuration.decode(polluted)
        }
    }

    @Test("Prepared configuration rejects artifacts from different frozen builds")
    func rejectsIdentityMismatch() throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        manifest.executableUUID = UUID()
        try Core.CanonicalJSON.encode(manifest).write(to: fixture.manifestURL)
        #expect(throws: DevSession.ConfigurationError.identityMismatch) {
            _ = try DevSession.PreparedConfiguration.load(
                configurationURL: fixture.configurationURL
            )
        }
    }

}
}

private struct DaemonFixture {
    let directory: URL
    let sourceURL: URL
    let manifestURL: URL
    let indexURL: URL
    let archiveURL: URL
    let configurationURL: URL
    let manifest: DevBuildManifest.Document

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-service-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("Screen.swift")
        manifestURL = directory.appendingPathComponent("DevManifest.json")
        indexURL = directory.appendingPathComponent("ReloadIndex.json")
        archiveURL = directory.appendingPathComponent("Shell.hlxi")
        configurationURL = directory.appendingPathComponent("HelixDev.json")

        let sourceBytes = Data("public func value() -> Int { 1 }\n".utf8)
        try sourceBytes.write(to: sourceURL)
        let logicalPath = "Sources/Screen.swift"
        let sourceID = LiveReload.SourceFileID.derive(logicalPath: logicalPath)
        let bundleID = "dev.helix.service"
        let module = "DaemonFixture"
        let executableUUID = UUID()
        let sessionID = UUID()
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: bundleID,
            buildNumber: "1",
            seed: "service-fixture"
        )
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Int")
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: module,
            sourceFileLogicalID: logicalPath,
            canonicalDeclaration: "func value() -> Int",
            loweredSignature: signature,
            role: .function
        )
        let target = "arm64-apple-ios15.0-simulator"
        let xcodeBuild = "fixture-Xcode"
        let sdkBuild = "fixture-SDK"
        let compilerFingerprint = try ReleaseCompiler.Driver().toolchainIdentity().fingerprint
        let archive = try InterfaceArchive.Archive.make(
            metadata: .init(
                bundleID: bundleID,
                buildNumber: "1",
                shellNamespaceID: namespace,
                machOUUIDs: [executableUUID],
                targetTriple: target,
                minimumOS: .init(15),
                xcodeBuild: xcodeBuild,
                sdkBuild: sdkBuild,
                frontendInvocation: .init(
                    moduleName: module,
                    targetTriple: target,
                    sdkName: "iphonesimulator",
                    sdkBuild: sdkBuild,
                    optimization: "-Onone"
                ),
                transformPipelineHash: .sha256("transform"),
                sourceBaselineHash: .sha256(sourceBytes)
            ),
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: compilerFingerprint
            ),
            capabilities: [.baselineV1],
            sources: [.init(logicalPath: logicalPath, contentHash: .sha256(sourceBytes))],
            functions: [
                .init(
                    key: functionKey,
                    entryIndex: .init(rawValue: 0),
                    moduleName: module,
                    sourceFileLogicalID: logicalPath,
                    canonicalDeclaration: "func value() -> Int",
                    mangledName: "$s13DaemonFixture5valueSiyF",
                    role: .function,
                    loweredSignature: signature,
                    parameterTypes: [],
                    resultType: .int64,
                    effects: .init(),
                    interfaceFingerprint: .sha256("interface"),
                    bodyFingerprint: .sha256("body"),
                    patchability: .eligible,
                    bridgeSymbol: "hlx_entry_0"
                ),
            ],
            bridgeRegistrationCount: 1
        )
        let index = ReloadIndex.Document(
            sourceRoots: [.init(sourceFileID: sourceID, roots: [functionKey])],
            roots: [.init(functionKey: functionKey, nominalTypeID: nil, role: .modelOrService)]
        )
        let indexHash = try index.contentHash()
        manifest = .init(
            sessionBuildID: sessionID,
            workspacePathHash: .sha256(directory.path),
            scheme: "DaemonFixture",
            configuration: "Debug",
            bundleID: bundleID,
            executableUUID: executableUUID,
            moduleName: module,
            targetTriple: target,
            architecture: "arm64",
            platform: .iOSSimulator,
            minimumOS: .init(15),
            xcodeBuild: xcodeBuild,
            swiftCompilerFingerprint: compilerFingerprint,
            sdkBuild: sdkBuild,
            frontendArguments: [
                "-module-name", module, "-target", target,
                "-sdk", "/SDK", "-Onone", "-enable-implicit-dynamic", sourceURL.path,
            ],
            linkArguments: [],
            moduleSearchPaths: [],
            sourceFiles: [
                .init(
                    id: sourceID,
                    logicalPath: logicalPath,
                    absolutePath: sourceURL.path,
                    contentHash: .sha256(sourceBytes)
                ),
            ],
            buildProducts: [],
            liveReloadIndexHash: indexHash,
            dependencyGraphHash: .sha256("dependencies"),
            toolchainCapabilities: .init(
                implicitDynamic: true,
                privateImports: false,
                dynamicReplacementChaining: false,
                nativeInterposing: false,
                canonicalSIL: true
            )
        )
        let configuration = DevSession.Configuration(
            manifestPath: manifestURL.lastPathComponent,
            reloadIndexPath: indexURL.lastPathComponent,
            interfaceArchivePath: archiveURL.lastPathComponent,
            nativeOutputDirectory: "Native"
        )
        try Core.CanonicalJSON.encode(manifest).write(to: manifestURL)
        try Core.CanonicalJSON.encode(index).write(to: indexURL)
        try InterfaceArchive.Codec.encode(archive).write(to: archiveURL)
        try Core.CanonicalJSON.encode(configuration).write(to: configurationURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
