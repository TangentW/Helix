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
        #expect(throws: DevActivation.ConfigurationError.invalidLimits) {
            try DevActivation.Limits(
                maximumNativeImageCount: Int(UInt32.max) + 1
            ).validate()
        }
        let fixture = try DevRuntimeFixture()
        var adapterIdentity = fixture.identity
        adapterIdentity.loadedDevelopmentAdapterCount = 1
        adapterIdentity.loadedDevelopmentAdapterBytes = 1_024
        adapterIdentity.nativeImageSoftLimitReached = true
        adapterIdentity.nativeStateUncertain = true
        try adapterIdentity.validate()
        adapterIdentity.supportedBackends = [.nativeDynamicReplacement]
        #expect(throws: DevProtocol.Error.self) {
            try adapterIdentity.validate()
        }
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            runtime: try fixture.makeRuntime(
                registry: .init(
                    maximumGenerationCount: 512,
                    maximumEstimatedBytes: 256 * 1_024 * 1_024
                )
            ),
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
            runtime: try fixture.makeRuntime(registry: registry),
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

    @Test("Development Adapters publish atomically, reuse the session Registry, and preserve active code on failure")
    func activatesDevelopmentAdapterAtomically() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try fixture.makeRuntime()
        let adapter = FakeDevelopmentAdapterLoader()
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            runtime: runtime,
            cacheDirectory: directory,
            limits: .init(
                maximumNativeImageCount: 3,
                nativeImageSoftWarningCount: 2
            ),
            developmentAdapterLoader: adapter
        )
        let firstImport = try fixture.developmentImport(
            id: .init(rawValue: 0),
            callee: "Fixture.identityThroughAdapter(_:)"
        )
        let firstPayload = try fixture.nativePayload(
            nativeImport: firstImport,
            includesAdapterImage: true
        )
        let firstResult = await DevRuntimeTests.transfer(
            firstPayload,
            revision: 1,
            generation: 1,
            fixture: fixture,
            controller: controller
        )
        #expect(firstResult.codeStatus == .codeActive)
        #expect(adapter.loadCount == 1)
        #expect(
            await controller.snapshot().activeDevelopmentNativeImports
                == [.init(id: firstImport.id, key: firstImport.key)]
        )

        let input = try VM.Integer(signed: 19, bitWidth: 64, isSigned: true)
        #expect(
            runtime.invoke(entry: fixture.entry, arguments: [.integer(input)])
                == .returned(.integer(input))
        )

        // Model two saves compiled before the first activation result reached
        // the host. The second payload still carries the now-published image;
        // activation must treat it as an idempotent capability replay.
        let overlappingResult = await DevRuntimeTests.transfer(
            firstPayload,
            revision: 2,
            generation: 2,
            fixture: fixture,
            controller: controller
        )
        #expect(overlappingResult.codeStatus == .codeActive)
        #expect(adapter.loadCount == 1)
        #expect((await controller.snapshot()).loadedDevelopmentAdapterCount == 1)

        var reusedImport = firstImport
        reusedImport.imageIndex = nil
        reusedImport.exportSymbol = nil
        let reusedPayload = try fixture.nativePayload(
            nativeImport: reusedImport,
            includesAdapterImage: false
        )
        let reusedResult = await DevRuntimeTests.transfer(
            reusedPayload,
            revision: 3,
            generation: 3,
            fixture: fixture,
            controller: controller
        )
        #expect(reusedResult.codeStatus == .codeActive)
        #expect(adapter.loadCount == 1)

        let rejectedImport = try fixture.developmentImport(
            id: .init(rawValue: 1),
            callee: "Fixture.secondAdapter(_:)"
        )
        adapter.returnEmptyInvokerSetOnce()
        let rejectedPayload = try fixture.nativePayload(
            nativeImport: rejectedImport,
            includesAdapterImage: true
        )
        let rejected = await DevRuntimeTests.transfer(
            rejectedPayload,
            revision: 4,
            generation: 4,
            fixture: fixture,
            controller: controller
        )
        #expect(rejected.codeStatus == .rejected)
        #expect(runtime.registry.snapshot().activeGenerationID == .init(rawValue: 3))
        let snapshot = await controller.snapshot()
        #expect(snapshot.activeDevelopmentNativeImports == [
            .init(id: firstImport.id, key: firstImport.key),
        ])
        #expect(snapshot.loadedDevelopmentAdapterCount == 2)
        #expect(snapshot.nativeImageSoftLimitReached)
        #expect(
            runtime.invoke(entry: fixture.entry, arguments: [.integer(input)])
                == .returned(.integer(input))
        )

        adapter.throwStateUncertainOnce()
        let uncertain = await DevRuntimeTests.transfer(
            rejectedPayload,
            revision: 5,
            generation: 5,
            fixture: fixture,
            controller: controller
        )
        #expect(uncertain.codeStatus == .nativeStateUncertain)
        #expect(uncertain.diagnostic?.code == "HLXLR503")
        #expect((await controller.snapshot()).nativeStateUncertain)
        #expect(adapter.loadCount == 3)

        let blocked = await DevRuntimeTests.transfer(
            rejectedPayload,
            revision: 6,
            generation: 6,
            fixture: fixture,
            controller: controller
        )
        #expect(blocked.codeStatus == .rejected)
        #expect(blocked.diagnostic?.code == "HLXLR502")
        #expect(adapter.loadCount == 3)
        #expect(runtime.registry.snapshot().activeGenerationID == .init(rawValue: 3))
        let reconnect = await controller.currentSessionIdentity()
        #expect(reconnect.activeDevelopmentNativeImports == [
            .init(id: firstImport.id, key: firstImport.key),
        ])
        #expect(reconnect.loadedDevelopmentAdapterCount == 2)
        #expect(reconnect.nativeImageSoftLimitReached)
        #expect(reconnect.nativeStateUncertain)
    }

    @Test("Development native TypeOps publish atomically and survive reconnect inventory")
    func activatesDevelopmentNativeTypesAtomically() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try fixture.makeRuntime()
        let adapter = FakeDevelopmentAdapterLoader()
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            runtime: runtime,
            cacheDirectory: directory,
            developmentAdapterLoader: adapter
        )
        let objectiveCID = Core.TypeID(rawValue: .sha256(
            "DevRuntime.Foundation.NSObject"
        ))
        let objectiveCType = DevProtocol.DevelopmentPayload.NativeType(
            id: objectiveCID,
            canonicalName: "Foundation.NSObject",
            kind: .reference,
            layoutFingerprint: .sha256("Foundation.NSObject.Layout"),
            objectiveCRuntimeName: "NSObject",
            isCopyable: true,
            estimatedSize: 8,
            binding: .objectiveCReference
        )
        let objectiveCResult = await DevRuntimeTests.transfer(
            try fixture.nativeTypePayload(
                nativeType: objectiveCType,
                includesAdapterImage: false
            ),
            revision: 1,
            generation: 1,
            fixture: fixture,
            controller: controller
        )
        #expect(objectiveCResult.codeStatus == .codeActive)
        #expect(adapter.loadCount == 0)

        let swiftID = Core.TypeID(rawValue: .sha256(
            "DevRuntime.Fixture.NativeSnapshot"
        ))
        let swiftType = DevProtocol.DevelopmentPayload.NativeType(
            id: swiftID,
            canonicalName: "Fixture.NativeSnapshot",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.NativeSnapshot.Layout"),
            isCopyable: true,
            estimatedSize: 8,
            binding: .swiftAdapter,
            imageIndex: 0,
            exportSymbol: "hlx_native_type_ops_v1_\(swiftID.rawValue.hex)"
        )
        let swiftPayload = try fixture.nativeTypePayload(
            nativeType: swiftType,
            includesAdapterImage: true
        )
        let swiftResult = await DevRuntimeTests.transfer(
            swiftPayload,
            revision: 2,
            generation: 2,
            fixture: fixture,
            controller: controller
        )
        #expect(swiftResult.codeStatus == .codeActive)
        #expect(adapter.loadCount == 1)
        #expect(await controller.snapshot().activeDevelopmentNativeTypeIDs == [
            objectiveCID, swiftID,
        ].sorted { $0.rawValue < $1.rawValue })

        let replay = await DevRuntimeTests.transfer(
            swiftPayload,
            revision: 3,
            generation: 3,
            fixture: fixture,
            controller: controller
        )
        #expect(replay.codeStatus == .codeActive)
        #expect(adapter.loadCount == 1)

        var changedType = swiftType
        changedType.layoutFingerprint = .sha256(
            "Fixture.NativeSnapshot.ChangedLayout"
        )
        changedType.imageIndex = nil
        changedType.exportSymbol = nil
        let rejected = await DevRuntimeTests.transfer(
            try fixture.nativeTypePayload(
                nativeType: changedType,
                includesAdapterImage: false
            ),
            revision: 4,
            generation: 4,
            fixture: fixture,
            controller: controller
        )
        #expect(rejected.codeStatus == .rejected)
        #expect(runtime.registry.snapshot().activeGenerationID == .init(rawValue: 3))
        let reconnect = await controller.currentSessionIdentity()
        #expect(reconnect.activeDevelopmentNativeTypeIDs == [
            objectiveCID, swiftID,
        ].sorted { $0.rawValue < $1.rawValue })
    }

    @Test("HLBC identity failures retain their actionable diagnostic")
    func preservesHLBCIdentityDiagnostic() async throws {
        let fixture = try DevRuntimeFixture()
        let directory = try temporaryRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DevActivation.Controller(
            identity: fixture.identity,
            shell: fixture.shell,
            runtimePolicy: .init(),
            runtime: try fixture.makeRuntime(),
            cacheDirectory: directory
        )
        let payload = try fixture.payload(sdkBuild: "different-sdk")
        let result = await DevRuntimeTests.transfer(
            payload,
            revision: 1,
            generation: 1,
            fixture: fixture,
            controller: controller
        )
        #expect(result.codeStatus == .rejected)
        #expect(result.diagnostic?.code == "HLXLR304")
        #expect(result.diagnostic?.sourceRevision == .init(rawValue: 1))
        #expect(result.diagnostic?.generationID == .init(rawValue: 1))
        #expect(result.diagnostic?.backend == .hlbc)
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
            runtime: try fixture.makeRuntime(registry: registry),
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
            runtime: try fixture.makeRuntime(registry: registry),
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
            runtime: try fixture.makeRuntime(registry: registry),
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
            sdkBuild: "fixture-sdk",
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
            runtime: try fixture.makeRuntime(),
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

private static func transfer(
    _ payload: Data,
    revision: UInt64,
    generation: UInt64,
    fixture: DevRuntimeFixture,
    controller: DevActivation.Controller
) async -> DevProtocol.ActivationResult {
    do {
        let offer = fixture.offer(
            revision: revision,
            generation: generation,
            payload: payload
        )
        let token = try await controller.accept(offer)
        try await controller.append(
            .init(token: token, offset: 0, bytes: payload)
        )
        return await controller.commit(token)
    } catch {
        return .init(
            sourceRevision: .init(rawValue: revision),
            generationID: .init(rawValue: generation),
            codeStatus: .rejected,
            reloadStatus: .notRequested,
            diagnostic: .init(
                code: "TEST",
                message: String(describing: error),
                sourceRevision: .init(rawValue: revision),
                generationID: .init(rawValue: generation),
                backend: .hlbc,
                nextAction: "inspect test failure"
            )
        )
    }
}

private final class FakeDevelopmentAdapterLoader:
    DevelopmentAdapter.Loading, @unchecked Sendable
{
    private let lock = NSLock()
    private var loads = 0
    private var returnsEmptyOnce = false
    private var throwsStateUncertainOnce = false

    var loadCount: Int {
        lock.withLock { loads }
    }

    func returnEmptyInvokerSetOnce() {
        lock.withLock { returnsEmptyOnce = true }
    }

    func throwStateUncertainOnce() {
        lock.withLock { throwsStateUncertainOnce = true }
    }

    func load(
        bytes: Data,
        descriptor: DevProtocol.DevelopmentPayload.Image,
        imports: [DevProtocol.DevelopmentPayload.NativeImport],
        nativeTypes: [DevProtocol.DevelopmentPayload.NativeType],
        identity: DevProtocol.SessionIdentity,
        cacheDirectory: URL
    ) throws -> DevelopmentAdapter.LoadedImage {
        let mode = lock.withLock {
            loads += 1
            defer {
                returnsEmptyOnce = false
                throwsStateUncertainOnce = false
            }
            return (returnsEmptyOnce, throwsStateUncertainOnce)
        }
        if mode.1 {
            throw DevelopmentAdapter.Error.stateUncertain(
                "test image was mapped before its factory failed"
            )
        }
        let invokers: [any VM.NativeInvoker] = mode.0 ? [] : imports.map {
            nativeImport in
            Runtime.NativeAdapterBody { arguments, _ in
                guard let value = arguments.first else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "test Adapter received no argument"
                    )
                }
                return .returned(value)
            }.makeInvoker(
                id: nativeImport.id,
                key: nativeImport.key,
                parameterTypes: nativeImport.parameterTypes,
                resultType: nativeImport.resultType,
                effects: nativeImport.descriptor.effects,
                contract: nativeImport.contract
            )
        }
        let architecture: MachO.Architecture = identity.architecture == "x86_64"
            ? .x86_64 : .arm64
        let platform: MachO.Platform = switch identity.platform {
        case .iOS: .iOS
        case .iOSSimulator: .iOSSimulator
        case .macOS: .macOS
        }
        let typeOperations: [VM.NativeTypeOperations] = mode.0 ? []
            : nativeTypes.map { nativeType in
                VM.NativeTypeOperations.opaqueValue(
                    id: nativeType.id,
                    canonicalName: nativeType.canonicalName,
                    layoutFingerprint: nativeType.layoutFingerprint,
                    requiresMainActor: nativeType.requiresMainActor,
                    estimatedSize: nativeType.estimatedSize,
                    clone: { (value: FakeDevelopmentNativeValue) in value }
                )
            }
        return .init(
            fileURL: cacheDirectory.appendingPathComponent("FakeAdapter.dylib"),
            byteCount: bytes.count,
            descriptor: .init(
                architecture: architecture,
                fileType: 6,
                uuid: descriptor.uuid,
                installName: descriptor.installName,
                platform: platform,
                codeSignature: .init(dataOffset: 1, dataSize: 1)
            ),
            nativeInvokers: invokers,
            nativeTypeOperations: typeOperations
        )
    }

    func makeCInvoker(
        for nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) throws -> any VM.NativeInvoker {
        throw DevelopmentAdapter.Error.invalidImage(
            "unexpected C invoker in Swift Adapter test"
        )
    }
}

private struct FakeDevelopmentNativeValue: Sendable {
    var rawValue: Int
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
        let encodedBytecode = try Bytecode.Encoder.encode(
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
        bytecode = try Self.developmentPayload(
            bytecode: encodedBytecode,
            shellHash: shellHash,
            compilerFingerprint: compatibility.compilerFingerprint
        )
        shell = try .init(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    parameterConventions: function.parameterConventions,
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
            sdkBuild: "22A",
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
        let encodedBytecode = try Bytecode.Encoder.encode(
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
        return try Self.developmentPayload(
            bytecode: encodedBytecode,
            shellHash: shellHash,
            compilerFingerprint: compatibility.compilerFingerprint
        )
    }

    func payload(sdkBuild: String) throws -> Data {
        let artifact = try DevProtocol.DevelopmentPayload.Artifact.decode(
            bytecode
        )
        return try DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: shellHash,
            compilerFingerprint: compatibility.compilerFingerprint,
            sdkBuild: sdkBuild,
            targetTriple: artifact.manifest.targetTriple,
            bytecode: artifact.bytecode
        ).encoded()
    }

    func developmentImport(
        id: Core.NativeImportID,
        callee: String
    ) throws -> DevProtocol.DevelopmentPayload.NativeImport {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: callee,
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            effects: .init(),
            contract: contract
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        return .init(
            id: id,
            key: key,
            descriptor: descriptor,
            parameterTypes: [.int64],
            resultType: .int64,
            contract: contract,
            binding: .swiftAdapter,
            imageIndex: 0,
            exportSymbol: "hlx_swift_adapter_body_v1_\(key.rawValue.hex)"
        )
    }

    func nativePayload(
        nativeImport: DevProtocol.DevelopmentPayload.NativeImport,
        includesAdapterImage: Bool
    ) throws -> Data {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "nativeIdentity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeApply(
                            result: .init(rawValue: 1),
                            importID: nativeImport.id,
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let requirement = Bytecode.ImportRequirement(
            id: nativeImport.id,
            key: nativeImport.key,
            descriptor: nativeImport.descriptor,
            contract: nativeImport.contract
        )
        let encodedBytecode = try Bytecode.Encoder.encode(
            .init(
                name: "DevRuntimeNativeFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: [.baselineV1, .nativeImportsV1],
                functions: [function],
                entries: [
                    .init(
                        entryIndex: entry,
                        functionKey: functionKey,
                        functionID: function.id
                    ),
                ],
                imports: [requirement]
            )
        )
        let image = Data("fake-signed-adapter-\(nativeImport.key)".utf8)
        let descriptor = DevProtocol.DevelopmentPayload.Image(
            installName: "@rpath/HLXDevAdapter-\(nativeImport.key.rawValue.hex).dylib",
            uuid: UUID(),
            byteLength: UInt64(image.count),
            sha256: .sha256(image)
        )
        var transactionImport = nativeImport
        transactionImport.imageIndex = includesAdapterImage ? 0 : nil
        transactionImport.exportSymbol = includesAdapterImage
            ? "hlx_swift_adapter_body_v1_\(nativeImport.key.rawValue.hex)"
            : nil
        return try DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: shellHash,
            compilerFingerprint: compatibility.compilerFingerprint,
            sdkBuild: "22A",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: encodedBytecode,
            nativeImports: [transactionImport],
            imageDescriptors: includesAdapterImage ? [descriptor] : [],
            images: includesAdapterImage ? [image] : []
        ).encoded()
    }

    func nativeTypePayload(
        nativeType: DevProtocol.DevelopmentPayload.NativeType,
        includesAdapterImage: Bool
    ) throws -> Data {
        let base = try DevProtocol.DevelopmentPayload.Artifact.decode(bytecode)
        let image = Data("fake-type-adapter-\(nativeType.id)".utf8)
        let imageIdentity = Core.Digest.sha256(image)
        let descriptor = DevProtocol.DevelopmentPayload.Image(
            installName: "@rpath/HLXDevAdapter-\(imageIdentity.hex).dylib",
            uuid: UUID(),
            byteLength: UInt64(image.count),
            sha256: imageIdentity
        )
        var transactionType = nativeType
        transactionType.imageIndex = includesAdapterImage ? 0 : nil
        transactionType.exportSymbol = includesAdapterImage
            ? "hlx_native_type_ops_v1_\(nativeType.id.rawValue.hex)"
            : nil
        return try DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: shellHash,
            compilerFingerprint: compatibility.compilerFingerprint,
            sdkBuild: "22A",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: base.bytecode,
            nativeTypes: [transactionType],
            imageDescriptors: includesAdapterImage ? [descriptor] : [],
            images: includesAdapterImage ? [image] : []
        ).encoded()
    }

    func makeRuntime(
        registry: Runtime.GenerationRegistry = .init()
    ) throws -> Runtime.Engine {
        let originals = try Runtime.OriginalCatalog([
            .init(
                index: entry,
                parameterTypes: [.int64],
                resultType: .int64,
                invoke: { arguments in .returned(arguments[0]) }
            ),
        ])
        return Runtime.Engine(
            registry: registry,
            originals: originals,
            shellInterfaceHash: shellHash
        )
    }

    private static func developmentPayload(
        bytecode: Data,
        shellHash: Core.Digest,
        compilerFingerprint: String
    ) throws -> Data {
        try DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: shellHash,
            compilerFingerprint: compilerFingerprint,
            sdkBuild: "22A",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: bytecode
        ).encoded()
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
