import Foundation
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Development backend routing")
struct BackendRouting {
    @Test("Automatic selection is Bytecode-only while Native remains explicit")
    func automaticSelection() throws {
        let fixture = try RoutingFixture()
        let selector = DevBackendSelection.Selector()
        let automatic = selector.select(
            fixture.input(candidateFunctions: [fixture.first])
        )
        #expect(automatic.backend == .hlbc)
        #expect(automatic.reason == .hlbcUnifiedDefault)

        let explicitNative = selector.select(
            fixture.input(
                candidateFunctions: [fixture.first],
                preference: .native
            )
        )
        #expect(explicitNative.backend == .nativeDynamicReplacement)
        #expect(explicitNative.reason == .forcedNative)

        var budgetIdentity = fixture.identity
        budgetIdentity.nativeImageSoftLimitReached = true
        let budget = selector.select(
            fixture.input(identity: budgetIdentity, candidateFunctions: [fixture.first])
        )
        #expect(budget.backend == .hlbc)
        #expect(budget.reason == .hlbcUnifiedDefault)

        let forced = selector.select(
            fixture.input(
                identity: budgetIdentity,
                candidateFunctions: [fixture.first],
                preference: .native
            )
        )
        #expect(forced.backend == nil)
        #expect(forced.reason == .forcedBackendUnavailable)

        var nativeOnly = fixture.input(candidateFunctions: [fixture.first])
        nativeOnly.hlbcEligibleFunctions = []
        #expect(selector.select(nativeOnly).backend == nil)
        #expect(selector.select(nativeOnly).reason == .unsupported)
    }

    @Test("Reconnect affinity overrides preference and mixed transactions are rejected")
    func reconnectAffinity() throws {
        let fixture = try RoutingFixture()
        var identity = fixture.identity
        identity.highestAppliedSourceRevision = .init(rawValue: 4)
        identity.activeGenerationID = .init(rawValue: 3)
        identity.activeFunctionRoutes = [
            .init(functionKey: fixture.first, backend: .hlbc),
        ]
        try identity.validate()
        var input = fixture.input(
            identity: identity,
            candidateFunctions: [fixture.first],
            preference: .native
        )
        let required = DevBackendSelection.Selector().select(input)
        #expect(required.backend == .hlbc)
        #expect(required.reason == .activeBackendRequired)

        identity.activeFunctionRoutes.append(
            .init(functionKey: fixture.second, backend: .nativeDynamicReplacement)
        )
        identity.activeFunctionRoutes.sort {
            $0.functionKey.description < $1.functionKey.description
        }
        input.identity = identity
        input.candidateFunctions = [fixture.first, fixture.second]
        let mixed = DevBackendSelection.Selector().select(input)
        #expect(mixed.backend == nil)
        #expect(mixed.reason == .mixedActiveBackends)
    }

    @Test("Router advances affinity only after activation and restoration removes it")
    func activationTransaction() async throws {
        let fixture = try RoutingFixture()
        let compilers = fixture.fakeCompilers()
        let router = try DevCompilation.Router(
            identity: fixture.identity,
            reloadIndex: fixture.index,
            preference: .native,
            nativeImageSoftLimit: 1,
            compilers: compilers
        )
        let request = fixture.request(functions: [fixture.first], revision: 1, generation: 1)
        let outcome = try await router.build(request)
        let patch = try #require(outcome.patch)
        #expect(patch.backend == .nativeDynamicReplacement)
        #expect(await router.activeFunctionRoutes.isEmpty)

        let changedOffer = fixture.offer(
            backend: .nativeDynamicReplacement,
            functions: [fixture.first],
            revision: 1,
            generation: 1
        )
        #expect(
            await router.didReceiveActivation(
                offer: changedOffer,
                result: fixture.success(for: changedOffer)
            )
        )
        #expect(
            await router.activeFunctionRoutes
                == [.init(functionKey: fixture.first, backend: .nativeDynamicReplacement)]
        )

        let restoreOffer = fixture.offer(
            backend: .nativeDynamicReplacement,
            functions: [fixture.first],
            restored: [fixture.first],
            revision: 2,
            generation: 2
        )
        #expect(
            await router.didReceiveActivation(
                offer: restoreOffer,
                result: fixture.success(for: restoreOffer)
            )
        )
        #expect(await router.activeFunctionRoutes.isEmpty)

        let afterBudget = await router.selection(for: [fixture.second])
        #expect(afterBudget.backend == nil)
        #expect(afterBudget.reason == .forcedBackendUnavailable)
    }

    @Test("Uncertain Native activation disables future Native selection")
    func uncertainNativeState() async throws {
        let fixture = try RoutingFixture()
        let router = try DevCompilation.Router(
            identity: fixture.identity,
            reloadIndex: fixture.index,
            preference: .native,
            compilers: fixture.fakeCompilers()
        )
        let offer = fixture.offer(
            backend: .nativeDynamicReplacement,
            functions: [fixture.first],
            revision: 1,
            generation: 1
        )
        let result = DevProtocol.ActivationResult(
            sourceRevision: offer.sourceRevision,
            generationID: offer.generationID,
            codeStatus: .nativeStateUncertain,
            reloadStatus: .notRequested,
            diagnostic: .init(
                code: "HLXLR503",
                message: "registration state is uncertain",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: offer.backend,
                previousCodeRemainsActive: false,
                nextAction: "restart the App"
            )
        )
        let recorded = await router.didReceiveActivation(offer: offer, result: result)
        #expect(!recorded)
        let decision = await router.selection(for: [fixture.second])
        #expect(decision.backend == nil)
        #expect(decision.reason == .forcedBackendUnavailable)
        #expect(await router.activeFunctionRoutes.isEmpty)
    }
}
}

private extension DevSession.BuildOutcome {
    var patch: DevSession.BuiltPatch? {
        if case let .patch(value) = self { return value }
        return nil
    }
}

private struct RoutingFixture {
    let first = Core.FunctionKey(rawValue: .sha256("routing-first"))
    let second = Core.FunctionKey(rawValue: .sha256("routing-second"))
    let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Sources/Screen.swift")
    let sessionID = UUID()
    let identity: DevProtocol.SessionIdentity
    let index: ReloadIndex.Document

    init() throws {
        let resolvedIndex = ReloadIndex.Document(
            sourceRoots: [
                .init(sourceFileID: sourceID, roots: [first, second]),
            ],
            roots: [
                .init(functionKey: first, nominalTypeID: nil, role: .modelOrService),
                .init(functionKey: second, nominalTypeID: nil, role: .modelOrService),
            ]
        )
        index = resolvedIndex
        identity = .init(
            sessionID: sessionID,
            bundleID: "dev.helix.routing",
            executableUUID: UUID(),
            processID: 42,
            platform: .iOSSimulator,
            architecture: "arm64",
            operatingSystemBuild: "22A",
            xcodeBuild: "17A",
            swiftCompilerFingerprint: "swift-routing",
            liveReloadIndexHash: try resolvedIndex.contentHash(),
            supportedBackends: [.hlbc, .nativeDynamicReplacement],
            nativeChainingProbePassed: true
        )
    }

    func input(
        identity: DevProtocol.SessionIdentity? = nil,
        candidateFunctions: Set<Core.FunctionKey>,
        preference: DevBackendSelection.Preference = .automatic
    ) -> DevBackendSelection.Input {
        .init(
            identity: identity ?? self.identity,
            candidateFunctions: candidateFunctions,
            nativeEligibleFunctions: [first, second],
            hlbcEligibleFunctions: [first, second],
            preference: preference
        )
    }

    func fakeCompilers() -> [DevCompilation.BackendCompiler] {
        [LiveReload.Backend.hlbc, .nativeDynamicReplacement].map { backend in
            .init(
                backend: backend,
                eligibleFunctionKeys: [first, second],
                build: { request in
                    .patch(
                        .init(
                            backend: backend,
                            payload: Data([backend == .hlbc ? 0x01 : 0x02]),
                            changedFunctions: request.candidateFunctionKeys,
                            debugSymbolsUUID: backend == .nativeDynamicReplacement ? UUID() : nil
                        )
                    )
                },
                didActivate: { _ in true }
            )
        }
    }

    func request(
        functions: Set<Core.FunctionKey>,
        revision: UInt64,
        generation: UInt64
    ) -> DevSession.BuildRequest {
        let bytes = Data("changed".utf8)
        let file = SourceSnapshot.File(
            id: sourceID,
            logicalPath: "Sources/Screen.swift",
            absolutePath: "/tmp/Screen.swift",
            inode: 1,
            byteCount: UInt64(bytes.count),
            modificationNanoseconds: 1,
            contentHash: .sha256(bytes),
            contents: bytes
        )
        return .init(
            snapshot: .init(revision: .init(rawValue: revision), files: [file]),
            classification: .init(changedFiles: [sourceID], restoredToBaseline: []),
            generationID: .init(rawValue: generation),
            candidateFunctionKeys: functions,
            reason: .sourceSaved
        )
    }

    func offer(
        backend: LiveReload.Backend,
        functions: [Core.FunctionKey],
        restored: [Core.FunctionKey] = [],
        revision: UInt64,
        generation: UInt64
    ) -> DevProtocol.PatchOffer {
        let payload = Data([0x01])
        return .init(
            sessionID: sessionID,
            sourceRevision: .init(rawValue: revision),
            generationID: .init(rawValue: generation),
            backend: backend,
            payloadByteLength: UInt64(payload.count),
            payloadSHA256: .sha256(payload),
            changedSources: [sourceID],
            changedFunctions: functions,
            restoredFunctions: restored,
            debugSymbolsUUID: backend == .nativeDynamicReplacement ? UUID() : nil,
            reason: restored.isEmpty ? .sourceSaved : .baselineRestored
        )
    }

    func success(for offer: DevProtocol.PatchOffer) -> DevProtocol.ActivationResult {
        .init(
            sourceRevision: offer.sourceRevision,
            generationID: offer.generationID,
            codeStatus: .codeActive,
            reloadStatus: .refreshed
        )
    }
}
