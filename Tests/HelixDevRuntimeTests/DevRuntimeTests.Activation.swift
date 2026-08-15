import Foundation
import HelixBytecode
import HelixCore
import HelixDevProtocol
import HelixDevRuntime
import HelixDevTools
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier
import HelixVM
import Testing

enum DevRuntimeTests {}

extension DevRuntimeTests {
@Suite("Debug-only activation controller")
struct ActivationController {
    @Test("Activation rejects inconsistent limits and uses a continuous-reload registry budget")
    func validatesActivationConfiguration() async throws {
        #expect(throws: DevActivation.ConfigurationError.invalidLimits) {
            try DevActivation.Limits(
                maximumNativePayloadBytes: 128,
                maximumNativeImageCount: 10,
                nativeImageSoftWarningCount: 11,
                maximumNativeMappedBytes: 64
            ).validate()
        }
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            cacheDirectory: directory
        )
        #expect(await controller.registry.maximumGenerationCount == 512)
        #expect(!(await controller.snapshot()).nativeImageSoftLimitReached)
    }

    @Test("A chunked HLBC generation verifies, activates, and publishes reload separately")
    func activatesHLBCTransaction() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ReloadRecorder()
        let registry = Runtime.GenerationRegistry()
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            registry: registry,
            cacheDirectory: directory,
            reloadHandler: { context, _ in
                await recorder.record(context)
                return .refreshed
            }
        )
        let offer = fixture.offer(revision: 1, generation: 1)
        let token = try await controller.accept(offer)
        let split = fixture.bytecode.count / 2
        try await controller.append(
            .init(token: token, offset: 0, bytes: fixture.bytecode.prefix(split))
        )
        try await controller.append(
            .init(
                token: token,
                offset: UInt64(split),
                bytes: fixture.bytecode.suffix(fixture.bytecode.count - split)
            )
        )
        let result = await controller.commit(token)
        #expect(result.codeStatus == .codeActive)
        #expect(result.reloadStatus == .refreshed)
        #expect(await recorder.count == 1)

        let snapshot = await controller.snapshot()
        #expect(snapshot.highestAppliedRevision == .init(rawValue: 1))
        #expect(snapshot.activeGenerationID == .init(rawValue: 1))
        #expect(!snapshot.hasPendingTransfer)
        #expect(
            snapshot.activeFunctionRoutes
                == [.init(functionKey: fixture.functionKey, backend: .hlbc)]
        )
        let reconnectIdentity = await controller.currentSessionIdentity()
        #expect(reconnectIdentity.highestAppliedSourceRevision == .init(rawValue: 1))
        #expect(reconnectIdentity.activeGenerationID == .init(rawValue: 1))
        #expect(reconnectIdentity.activeFunctionRoutes == snapshot.activeFunctionRoutes)

        let lease = try #require(registry.activeLease())
        let image = try #require(lease.generation.images.first)
        let input = try VM.Integer(signed: 6, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: image,
                arguments: [.integer(input)]
            ) == .returned(.integer(input))
        )

        do {
            _ = try await controller.accept(offer)
            Issue.record("expected stale source revision rejection")
        } catch let diagnostic as DevProtocol.Diagnostic {
            #expect(diagnostic.code == "HLXLR201")
        }
    }

    @Test("A corrupt transfer cannot replace the current generation")
    func rejectsCorruptPayload() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = Runtime.GenerationRegistry()
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            registry: registry,
            cacheDirectory: directory
        )
        let offer = fixture.offer(revision: 1, generation: 1)
        let token = try await controller.accept(offer)
        var corrupt = fixture.bytecode
        corrupt[corrupt.startIndex] ^= 1
        try await controller.append(.init(token: token, offset: 0, bytes: corrupt))
        let result = await controller.commit(token)

        #expect(result.codeStatus == .rejected)
        #expect(result.diagnostic?.code == "HLXLR403")
        #expect(registry.snapshot().activeGenerationID == nil)
    }

    @Test("A 128-generation HLBC soak stays bounded and survives a failed save")
    func continuousHLBCActivationIsBounded() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = Runtime.GenerationRegistry(
            maximumGenerationCount: 4,
            maximumEstimatedBytes: 4 * 1_024 * 1_024
        )
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            registry: registry,
            cacheDirectory: directory
        )

        var previousPayload = fixture.bytecode
        var activePayload = fixture.bytecode
        for rawID in UInt64(1)...128 {
            let payload = try fixture.payload(returning: Int64(rawID))
            previousPayload = activePayload
            activePayload = payload
            let offer = fixture.offer(
                revision: rawID,
                generation: rawID,
                payload: payload
            )
            let token = try await controller.accept(offer)
            try await controller.append(
                .init(token: token, offset: 0, bytes: payload)
            )
            #expect(await controller.commit(token).codeStatus == .codeActive)
        }

        var registrySnapshot = registry.snapshot()
        #expect(registrySnapshot.activeGenerationID == .init(rawValue: 128))
        #expect(
            registrySnapshot.loadedGenerationIDs
                == [.init(rawValue: 127), .init(rawValue: 128)]
        )
        #expect(registrySnapshot.compactedGenerationCount == 126)
        #expect(
            registrySnapshot.estimatedByteCount
                <= previousPayload.count + activePayload.count
        )
        let activationSnapshot = await controller.snapshot()
        #expect(
            activationSnapshot.retainedHLBCGenerationIDs
                == [.init(rawValue: 127), .init(rawValue: 128)]
        )
        #expect(
            activationSnapshot.highestActivatedHLBCGenerationID
                == .init(rawValue: 128)
        )
        #expect(
            activationSnapshot.retainedHLBCBytes
                == registrySnapshot.estimatedByteCount
        )
        #expect(activationSnapshot.compactedHLBCGenerationCount == 126)
        let activeImage = try #require(registry.activeLease()?.generation.images.first)
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: activeImage,
                arguments: [.integer(try VM.Integer(signed: 0, bitWidth: 64, isSigned: true))]
            ) == .returned(
                .integer(try VM.Integer(signed: 128, bitWidth: 64, isSigned: true))
            )
        )

        let failedPayload = try fixture.payload(returning: 129)
        let failedOffer = fixture.offer(
            revision: 129,
            generation: 129,
            payload: failedPayload
        )
        let failedToken = try await controller.accept(failedOffer)
        var corrupt = failedPayload
        corrupt[corrupt.startIndex] ^= 1
        try await controller.append(
            .init(token: failedToken, offset: 0, bytes: corrupt)
        )
        #expect(await controller.commit(failedToken).codeStatus == .rejected)
        registrySnapshot = registry.snapshot()
        #expect(registrySnapshot.activeGenerationID == .init(rawValue: 128))
        #expect(
            registrySnapshot.loadedGenerationIDs
                == [.init(rawValue: 127), .init(rawValue: 128)]
        )
        #expect(registrySnapshot.highestActivatedGenerationID == .init(rawValue: 128))

        let recoveredPayload = try fixture.payload(returning: 130)
        let recoveredOffer = fixture.offer(
            revision: 130,
            generation: 130,
            payload: recoveredPayload
        )
        let recoveredToken = try await controller.accept(recoveredOffer)
        try await controller.append(
            .init(token: recoveredToken, offset: 0, bytes: recoveredPayload)
        )
        #expect(await controller.commit(recoveredToken).codeStatus == .codeActive)
        registrySnapshot = registry.snapshot()
        #expect(
            registrySnapshot.loadedGenerationIDs
                == [.init(rawValue: 128), .init(rawValue: 130)]
        )
    }

    @Test("A zero-payload restore generation removes the prior HLBC route")
    func restoresOriginalRoute() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = Runtime.GenerationRegistry()
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            registry: registry,
            cacheDirectory: directory
        )

        let patchOffer = fixture.offer(revision: 1, generation: 1)
        let patchToken = try await controller.accept(patchOffer)
        try await controller.append(
            .init(token: patchToken, offset: 0, bytes: fixture.bytecode)
        )
        #expect(await controller.commit(patchToken).codeStatus == .codeActive)

        let restoreOffer = DevProtocol.PatchOffer(
            sessionID: fixture.sessionID,
            sourceRevision: .init(rawValue: 2),
            generationID: .init(rawValue: 2),
            backend: .hlbc,
            payloadByteLength: 0,
            payloadSHA256: .sha256(Data()),
            changedSources: [.derive(logicalPath: "Sources/Fixture.swift")],
            changedFunctions: [fixture.functionKey],
            restoredFunctions: [fixture.functionKey],
            reason: .baselineRestored,
            mode: .restoreOriginals
        )
        let restoreToken = try await controller.accept(restoreOffer)
        let result = await controller.commit(restoreToken)

        #expect(result.codeStatus == .codeActive)
        #expect(registry.snapshot().activeGenerationID == .init(rawValue: 2))
        #expect(
            registry.route(for: fixture.entry, startingAt: .init(rawValue: 2)) == nil
        )
        #expect(await controller.snapshot().highestAppliedRevision == .init(rawValue: 2))
        #expect(await controller.currentSessionIdentity().activeFunctionRoutes.isEmpty)
    }

    @Test("The Native loader binds a signed image to process architecture, platform, UUID, and install name")
    func loadsIdentityBoundNativeImage() throws {
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Registration.swift")
        try Data(
            """
            @_cdecl("hlx_generation_registration_v1")
            public func generationRegistration() -> UInt32 { 1 }
            """.utf8
        ).write(to: sourceURL)
        let sessionID = UUID()
        let generation = DevProtocol.GenerationID(rawValue: 1)
        let stem = "HLXLive-\(sessionID.uuidString)-g\(generation.rawValue)"
        let imageURL = directory.appendingPathComponent("\(stem).dylib")
        let runner = ProcessExecution.Runner()
        try requireProcessSuccess(
            runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/swiftc"),
                arguments: [
                    sourceURL.path, "-emit-library", "-module-name", "NativeLoaderFixture",
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/\(stem).dylib",
                    "-o", imageURL.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: directory
            )
        )
        try requireProcessSuccess(
            runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", "--timestamp=none", imageURL.path],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: directory
            )
        )
        let bytes = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        let descriptor = try MachO.Inspector().inspect(bytes)
        let imageUUID: UUID
        if let uuid = descriptor.uuid {
            imageUUID = uuid
        } else {
            throw NativeImage.Error.invalidImage("signed fixture has no Mach-O UUID")
        }
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.native-loader",
            buildNumber: "1",
            seed: "fixture"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Registration.swift",
            canonicalDeclaration: "func value()",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
        #if arch(x86_64)
        let architecture = "x86_64"
        let mismatchedArchitecture = "arm64"
        #else
        let architecture = "arm64"
        let mismatchedArchitecture = "x86_64"
        #endif
        var identity = DevProtocol.SessionIdentity(
            sessionID: sessionID,
            bundleID: "dev.helix.native-loader",
            executableUUID: UUID(),
            processID: 101,
            platform: .macOS,
            architecture: architecture,
            operatingSystemBuild: "fixture",
            xcodeBuild: "fixture",
            swiftCompilerFingerprint: "fixture",
            liveReloadIndexHash: .sha256("index"),
            supportedBackends: [.nativeDynamicReplacement],
            nativeChainingProbePassed: true
        )
        let offer = DevProtocol.PatchOffer(
            sessionID: sessionID,
            sourceRevision: .init(rawValue: 1),
            generationID: generation,
            backend: .nativeDynamicReplacement,
            payloadByteLength: UInt64(bytes.count),
            payloadSHA256: .sha256(bytes),
            changedSources: [.derive(logicalPath: "Registration.swift")],
            changedFunctions: [functionKey],
            debugSymbolsUUID: imageUUID
        )
        try offer.validate()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        identity.architecture = mismatchedArchitecture
        #expect(throws: NativeImage.Error.self) {
            _ = try NativeImage.SystemLoader().load(
                bytes: bytes,
                offer: offer,
                identity: identity,
                cacheDirectory: cache
            )
        }
        identity.architecture = architecture
        let loaded = try NativeImage.SystemLoader().load(
            bytes: bytes,
            offer: offer,
            identity: identity,
            cacheDirectory: cache
        )
        #expect(loaded.generationID == generation)
        #expect(loaded.registeredRootCount == 1)
        #expect(loaded.descriptor.uuid == offer.debugSymbolsUUID)
        #expect(FileManager.default.fileExists(atPath: loaded.fileURL.path))
    }

    @Test("The authenticated Mac/App session transfers and activates one complete generation")
    func authenticatedSessionEndToEnd() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = Data(repeating: 0x5a, count: 32)
        let transcript = Core.Digest.sha256("session-e2e-transcript")
        let pair = DuplexTransport.makePair()
        let hostChannel = try DevProtocol.AuthenticatedChannel(
            transport: pair.host,
            sessionSecret: secret
        )
        let appChannel = try DevProtocol.AuthenticatedChannel(
            transport: pair.app,
            sessionSecret: secret
        )
        let recorder = ReloadRecorder()
        // This positive-path integration test runs beside compiler-heavy suites
        // in CI. Keep the production-sized receive window; short deadlines are
        // exercised independently by the liveness failure tests.
        let liveness = DevProtocol.LivenessConfiguration(
            heartbeatIntervalNanoseconds: 100_000_000,
            receiveTimeoutNanoseconds: 30_000_000_000
        )
        let activation = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            cacheDirectory: directory,
            reloadHandler: { context, _ in
                await recorder.record(context)
                return .refreshed
            }
        )
        let appSession = try DevRuntimeSession.Controller(
            identity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: transcript,
            activation: activation,
            liveness: liveness
        )
        let hostSession = try DevSession.Controller(
            expectedIdentity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: transcript,
            chunkByteCount: 17,
            liveness: liveness
        )
        let appTask = Task {
            do {
                try await appSession.run(channel: appChannel)
            } catch {
                throw SessionStageError(stage: "first App session", underlying: error)
            }
        }

        do {
            try await hostSession.accept(channel: hostChannel)
        } catch {
            throw SessionStageError(stage: "first host handshake", underlying: error)
        }
        let offer = fixture.offer(revision: 1, generation: 1)
        let result: DevProtocol.ActivationResult
        do {
            result = try await hostSession.transfer(
                .init(offer: offer, payload: fixture.bytecode)
            )
        } catch {
            throw SessionStageError(stage: "first host transfer", underlying: error)
        }
        #expect(result.codeStatus == .codeActive)
        #expect(result.reloadStatus == .refreshed)
        #expect(await recorder.count == 1)
        let hostSnapshot = await hostSession.snapshot()
        #expect(hostSnapshot.state == .ready)
        #expect(hostSnapshot.highestAppliedRevision == .init(rawValue: 1))
        #expect(hostSnapshot.activeGenerationID == .init(rawValue: 1))
        #expect(hostSnapshot.transferredPayloadBytes == UInt64(fixture.bytecode.count))

        await hostSession.close()
        try await appTask.value

        // Reconnect with the launch identity: the runtime must replace its
        // mutable fields with the activation controller's current inventory.
        let reconnectPair = DuplexTransport.makePair()
        let reconnectHostChannel = try DevProtocol.AuthenticatedChannel(
            transport: reconnectPair.host,
            sessionSecret: secret
        )
        let reconnectAppChannel = try DevProtocol.AuthenticatedChannel(
            transport: reconnectPair.app,
            sessionSecret: secret
        )
        let reconnectApp = try DevRuntimeSession.Controller(
            identity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: transcript,
            activation: activation,
            liveness: liveness
        )
        let reconnectHost = try DevSession.Controller(
            expectedIdentity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: transcript,
            liveness: liveness
        )
        let reconnectTask = Task {
            do {
                try await reconnectApp.run(channel: reconnectAppChannel)
            } catch {
                throw SessionStageError(stage: "reconnected App session", underlying: error)
            }
        }
        do {
            try await reconnectHost.accept(channel: reconnectHostChannel)
        } catch {
            throw SessionStageError(stage: "reconnected host handshake", underlying: error)
        }
        let reconnectSnapshot = await reconnectHost.snapshot()
        #expect(
            reconnectSnapshot.peerIdentity?.highestAppliedSourceRevision
                == .init(rawValue: 1)
        )
        #expect(reconnectSnapshot.peerIdentity?.activeGenerationID == .init(rawValue: 1))
        #expect(
            reconnectSnapshot.peerIdentity?.activeFunctionRoutes
                == [.init(functionKey: fixture.functionKey, backend: .hlbc)]
        )
        await reconnectHost.close()
        try await reconnectTask.value
    }
}
}

extension DevRuntimeTests {
private actor ReloadRecorder {
    private(set) var contexts: [LiveReload.Context] = []
    var count: Int { contexts.count }

    func record(_ context: LiveReload.Context) {
        contexts.append(context)
    }
}

private struct DevRuntimeFixture {
    let sessionID = UUID(uuidString: "3CF22EF2-CE41-4A6F-8B6B-A56FFCA1AC86")!
    let shellHash = Core.Digest.sha256("dev-runtime-shell")
    let entry = Core.EntryIndex(rawValue: 1)
    let compatibility: Core.Compatibility
    let functionKey: Core.FunctionKey
    let bytecode: Data
    let shell: Verification.ShellInterface
    let identity: DevProtocol.SessionIdentity

    init() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime.fixture",
            buildNumber: "1",
            seed: "dev-runtime"
        )
        compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-dev-runtime"
        )
        functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        bytecode = try Bytecode.Encoder.encode(
            .init(
                name: "DevRuntimeFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                functions: [function],
                entries: [
                    .init(entryIndex: entry, functionKey: functionKey, functionID: function.id),
                ]
            )
        )
        shell = try .init(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        identity = .init(
            sessionID: sessionID,
            bundleID: "dev.helix.runtime.fixture",
            executableUUID: UUID(),
            processID: 100,
            platform: .iOSSimulator,
            architecture: "arm64",
            operatingSystemBuild: "22A",
            xcodeBuild: "17F113",
            swiftCompilerFingerprint: "swift-dev-runtime",
            liveReloadIndexHash: .sha256("index"),
            supportedBackends: [.hlbc],
            nativeChainingProbePassed: false
        )
    }

    func offer(revision: UInt64, generation: UInt64) -> DevProtocol.PatchOffer {
        offer(revision: revision, generation: generation, payload: bytecode)
    }

    func offer(
        revision: UInt64,
        generation: UInt64,
        payload: Data
    ) -> DevProtocol.PatchOffer {
        .init(
            sessionID: sessionID,
            sourceRevision: .init(rawValue: revision),
            generationID: .init(rawValue: generation),
            backend: .hlbc,
            payloadByteLength: UInt64(payload.count),
            payloadSHA256: .sha256(payload),
            changedSources: [.derive(logicalPath: "Sources/Fixture.swift")],
            changedFunctions: [functionKey]
        )
    }

    func payload(returning value: Int64) throws -> Data {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: UInt64(bitPattern: value)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        return try Bytecode.Encoder.encode(
            .init(
                name: "DevRuntimeFixture-\(value)",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                functions: [function],
                entries: [
                    .init(
                        entryIndex: entry,
                        functionKey: functionKey,
                        functionID: function.id
                    ),
                ]
            )
        )
    }
}

private struct DuplexTransport: DevProtocol.ByteTransport {
    struct Pair {
        var host: DuplexTransport
        var app: DuplexTransport
    }

    let inbound: DuplexBuffer
    let outbound: DuplexBuffer

    static func makePair() -> Pair {
        let hostToApp = DuplexBuffer()
        let appToHost = DuplexBuffer()
        return .init(
            host: .init(inbound: appToHost, outbound: hostToApp),
            app: .init(inbound: hostToApp, outbound: appToHost)
        )
    }

    func send(_ bytes: Data) async throws {
        try await outbound.write(bytes)
    }

    func receiveExactly(_ byteCount: Int) async throws -> Data {
        try await inbound.read(byteCount)
    }

    func close() async {
        await inbound.close()
        await outbound.close()
    }
}

private actor DuplexBuffer {
    private struct PendingRead {
        var byteCount: Int
        var continuation: CheckedContinuation<Data, any Error>
    }

    private var bytes = Data()
    private var pending: PendingRead?
    private var isClosed = false

    func write(_ value: Data) throws {
        guard !isClosed else { throw DevProtocol.Error.truncatedFrame }
        bytes.append(value)
        satisfyPendingRead()
    }

    func read(_ byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else { throw DevProtocol.Error.truncatedFrame }
        if bytes.count >= byteCount { return remove(byteCount) }
        guard !isClosed, pending == nil else {
            throw DevProtocol.Error.truncatedFrame
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = .init(byteCount: byteCount, continuation: continuation)
        }
    }

    func close() {
        isClosed = true
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: DevProtocol.Error.truncatedFrame)
        }
    }

    private func satisfyPendingRead() {
        guard let pending, bytes.count >= pending.byteCount else { return }
        self.pending = nil
        pending.continuation.resume(returning: remove(pending.byteCount))
    }

    private func remove(_ byteCount: Int) -> Data {
        let value = Data(bytes.prefix(byteCount))
        bytes.removeFirst(byteCount)
        return value
    }
}

private struct SessionStageError: Swift.Error, CustomStringConvertible {
    var stage: String
    var underlying: any Swift.Error

    var description: String {
        "\(stage) failed: \(underlying)"
    }
}
}

private func temporaryRuntimeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("helix-dev-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func requireProcessSuccess(_ result: ProcessExecution.Result) throws {
    guard result.status == 0 else {
        throw BuildCapture.Error.replayFailed(result.standardError)
    }
}
