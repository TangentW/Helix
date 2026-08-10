import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
import HelixLiveReloadAPI
import Testing

#if canImport(Network) && canImport(Security)
import Network
#endif

extension DevToolsTests {
@Suite("Dev Session configuration and daemon")
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

    #if canImport(Network) && canImport(Security) && os(macOS)
    @Test("Daemon preserves one reconnect grace for authenticated App replacement")
    func daemonHandshake() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let events = DaemonEventRecorder()
        let daemon = try DevSession.Daemon(
            configurationURL: fixture.configurationURL,
            disconnectPolicy: .stopAfterGracePeriod(nanoseconds: 500_000_000),
            eventHandler: { await events.record($0) }
        )
        do {
            let bootstrap = try await daemon.start()
            await #expect(throws: DevSession.DaemonError.alreadyRunning) {
                _ = try await daemon.start()
            }
            let simulator = try #require(bootstrap.environment(for: .simulator))
            let device = bootstrap.environment(for: .device)
            #expect(simulator["HLX_DEV_HOST"] == "127.0.0.1")
            #expect(simulator["HLX_DEV_PORT"] == String(bootstrap.port))
            #expect(device == nil)
            #expect(simulator["HLX_DEV_SESSION_SECRET"]?.count == 64)

            let first = try await connectApp(
                bootstrap: bootstrap,
                identity: fixture.identity,
                nonceByte: 0x5a
            )
            for _ in 0..<200 where await events.connectCount < 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.connectCount == 1)
            await first.close()
            for _ in 0..<200 where await events.disconnectCount < 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.disconnectCount == 1)

            let replacement = try await connectApp(
                bootstrap: bootstrap,
                identity: fixture.identity,
                nonceByte: 0xa5
            )
            for _ in 0..<200 where await events.connectCount < 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.connectCount == 2)
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(!(await events.didStop))

            await replacement.close()
            for _ in 0..<200 where !(await events.didStop) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.didStop)
        } catch {
            await daemon.stop()
            throw error
        }
    }

    @Test("A rejected authenticated replacement restores supervised ownership")
    func rejectedReplacementRestoresOwnership() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let events = DaemonEventRecorder()
        let daemon = try DevSession.Daemon(
            configurationURL: fixture.configurationURL,
            disconnectPolicy: .stopAfterGracePeriod(nanoseconds: 300_000_000),
            eventHandler: { await events.record($0) }
        )
        do {
            let bootstrap = try await daemon.start()
            let first = try await connectApp(
                bootstrap: bootstrap,
                identity: fixture.identity,
                nonceByte: 0x11
            )
            for _ in 0..<200 where await events.connectCount < 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.connectCount == 1)

            var rejectedIdentity = fixture.identity
            rejectedIdentity.highestAppliedSourceRevision = .init(rawValue: 1)
            rejectedIdentity.activeGenerationID = .init(rawValue: 1)
            rejectedIdentity.activeFunctionRoutes = [
                .init(
                    functionKey: .init(rawValue: .sha256("unknown-function")),
                    backend: .hlbc
                ),
            ]
            let rejected = try await connectApp(
                bootstrap: bootstrap,
                identity: rejectedIdentity,
                nonceByte: 0x22
            )
            for _ in 0..<200 where await events.rejectionCount < 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.rejectionCount == 1)
            #expect(!(await events.didStop))
            await rejected.close()

            await first.close()
            for _ in 0..<200 where !(await events.didStop) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await events.didStop)
        } catch {
            await daemon.stop()
            throw error
        }
    }
    #endif
}
}

private actor DaemonEventRecorder {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var rejectionCount = 0
    private(set) var didStop = false

    func record(_ event: DevSession.DaemonEvent) {
        if case .connected = event { connectCount += 1 }
        if case .disconnected = event { disconnectCount += 1 }
        if case .connectionRejected = event { rejectionCount += 1 }
        if case .stopped = event { didStop = true }
    }
}

#if canImport(Network) && canImport(Security) && os(macOS)
private func connectApp(
    bootstrap: DevSession.Bootstrap,
    identity: DevProtocol.SessionIdentity,
    nonceByte: UInt8
) async throws -> DevProtocol.AuthenticatedChannel<NetworkTransport.ByteTransport> {
    let transport = NetworkTransport.ByteTransport.pinnedTLSClient(
        host: "127.0.0.1",
        port: try #require(NWEndpoint.Port(rawValue: bootstrap.port)),
        expectedSPKIHash: bootstrap.spkiSHA256
    )
    try await transport.start()
    let exporter = try transport.tlsExporterHash()
    let channel = try DevProtocol.AuthenticatedChannel(
        transport: transport,
        sessionSecret: bootstrap.sessionSecret
    )
    let nonce = Data(repeating: nonceByte, count: 32)
    try await channel.send(.hello(identity: identity, clientNonce: nonce))
    let response = try await channel.receive()
    guard case let .helloAck(peer, serverNonce, proof) = response else {
        await channel.close()
        throw DevSession.DaemonError.missingPeerIdentity
    }
    #expect(peer == identity)
    #expect(
        try DevProtocol.Handshake.verify(
            proof: proof,
            sessionSecret: bootstrap.sessionSecret,
            clientNonce: nonce,
            serverNonce: serverNonce,
            identity: identity,
            tlsTranscriptHash: exporter
        )
    )
    return channel
}
#endif

private struct DaemonFixture {
    let directory: URL
    let sourceURL: URL
    let manifestURL: URL
    let indexURL: URL
    let archiveURL: URL
    let configurationURL: URL
    let manifest: DevBuildManifest.Document
    let identity: DevProtocol.SessionIdentity

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-daemon-\(UUID().uuidString)",
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
        let bundleID = "dev.helix.daemon"
        let module = "DaemonFixture"
        let executableUUID = UUID()
        let sessionID = UUID()
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: bundleID,
            buildNumber: "1",
            seed: "daemon-fixture"
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
        identity = .init(
            sessionID: sessionID,
            bundleID: bundleID,
            executableUUID: executableUUID,
            processID: 42,
            platform: .iOSSimulator,
            architecture: "arm64",
            operatingSystemBuild: "fixture-OS",
            xcodeBuild: xcodeBuild,
            swiftCompilerFingerprint: compilerFingerprint,
            liveReloadIndexHash: indexHash,
            supportedBackends: [.hlbc],
            nativeChainingProbePassed: false
        )
        let configuration = DevSession.Configuration(
            manifestPath: manifestURL.lastPathComponent,
            reloadIndexPath: indexURL.lastPathComponent,
            interfaceArchivePath: archiveURL.lastPathComponent,
            nativeOutputDirectory: "Native",
            backendPreference: .hlbc,
            advertiseBonjour: false
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
