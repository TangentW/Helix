import HelixDevProtocol
import HelixDevRuntime
import HelixLiveReloadAPI
import Testing

extension DevRuntimeTests {
@MainActor
@Suite("Development status model")
struct StatusTests {
    @Test("Manual pairing and terminal connection failures are explicit")
    func modelsPairingLifecycle() throws {
        let store = DevStatus.Store()
        #expect(store.connectionState == .idle)
        store.handle(.awaitingManualPairing)
        #expect(store.snapshot.phase == .awaitingPairing)
        #expect(store.connectionState == .awaitingPairing)
        #expect(store.snapshot.detail?.contains("Networking is off") == true)

        store.handle(.pairing(attempt: 2))
        #expect(store.snapshot.phase == .connecting)
        #expect(store.connectionState == .connecting)
        #expect(store.snapshot.detail?.contains("2") == true)

        store.handle(.failed("invitation expired"))
        #expect(store.snapshot.phase == .failed)
        #expect(store.connectionState == .failed)
        #expect(store.snapshot.tone == .error)
        #expect(store.snapshot.detail == "invitation expired")
    }

    @Test("Code diagnostics do not erase authenticated transport state")
    func separatesConnectionAndCompilationState() {
        let store = DevStatus.Store()
        store.handle(DevRuntimeSession.Event.authenticated)
        #expect(store.connectionState == .authenticated)

        store.handle(
            DevRuntimeSession.Event.diagnostics([
                .init(
                    code: "HLXLR299",
                    message: "unsupported source",
                    sourceRevision: .init(rawValue: 1),
                    nextAction: "correct the source"
                ),
            ])
        )
        #expect(store.snapshot.phase == .failed)
        #expect(store.connectionState == .authenticated)

        store.handle(DevRuntimeSession.Event.closed("service restarted"))
        #expect(store.connectionState == .disconnected)
        store.handle(
            DevConnection.ClientEvent.reconnectScheduled(
                attempt: 1,
                delayNanoseconds: 1_000_000,
                reason: "service restarted"
            )
        )
        #expect(store.connectionState == .retrying)
    }

    @Test("Session events preserve the distinction between code and UI state")
    func modelsSessionLifecycle() {
        let store = DevStatus.Store()
        store.handle(.compileStarted(.init(rawValue: 4)))
        #expect(store.snapshot.phase == .compiling)
        #expect(store.snapshot.sourceRevision == .init(rawValue: 4))

        store.handle(
            .activationCompleted(
                .init(
                    sourceRevision: .init(rawValue: 4),
                    generationID: .init(rawValue: 3),
                    codeStatus: .codeActive,
                    reloadStatus: .manualRefreshRequired
                )
            )
        )
        #expect(store.snapshot.phase == .codeActive)
        #expect(store.snapshot.tone == .warning)
        #expect(store.snapshot.headline.contains("manual refresh"))
        #expect(store.snapshot.codeStatus == .codeActive)
        #expect(store.snapshot.activeGenerationID == .init(rawValue: 3))

        store.handle(.compileStarted(.init(rawValue: 5)))
        #expect(store.snapshot.phase == .compiling)
        #expect(store.snapshot.generationID == nil)
        #expect(store.snapshot.activeGenerationID == .init(rawValue: 3))
    }

    @Test("Rebuild diagnostics and uncertain Native state are explicit")
    func modelsFailureActions() {
        let store = DevStatus.Store()
        store.handle(
            .diagnostics([
                .init(
                    code: "HLXLR299",
                    message: "unsupported compiler shape",
                    sourceRevision: .init(rawValue: 1),
                    nextAction: "correct the source and save again"
                ),
            ])
        )
        #expect(store.snapshot.phase == .failed)
        #expect(store.snapshot.tone == .error)
        #expect(store.snapshot.headline == "Compile failed · old code active")
        #expect(store.snapshot.detail?.contains("HLXLR299") == true)
        #expect(store.snapshot.detail?.contains("correct the source") == true)

        store.handle(
            .diagnostics([
                .init(
                    code: "HLXLR301",
                    message: "stored layout changed",
                    sourceRevision: .init(rawValue: 2),
                    nextAction: "perform a full build"
                ),
            ])
        )
        #expect(store.snapshot.phase == .rebuildRequired)
        #expect(store.snapshot.detail?.contains("full build") == true)

        store.record(
            .init(
                sourceRevision: .init(rawValue: 2),
                generationID: .init(rawValue: 2),
                codeStatus: .nativeStateUncertain,
                reloadStatus: .notRequested,
                diagnostic: .init(
                    code: "HLXLR503",
                    message: "loader state is uncertain",
                    nextAction: "restart the App"
                )
            )
        )
        #expect(store.snapshot.phase == .restartRequired)
        #expect(store.snapshot.headline == "Restart required")
    }

    @Test("Observers receive bounded, monotonic snapshots")
    func observesBoundedHistory() {
        let store = DevStatus.Store()
        var sequences: [UInt64] = []
        let token = store.observe { sequences.append($0.sequence) }
        for revision in 1...60 {
            store.handle(.compileStarted(.init(rawValue: UInt64(revision))))
        }
        store.removeObserver(token)

        #expect(sequences.first == 0)
        #expect(sequences.last == 60)
        #expect(store.history.count == 50)
        #expect(store.history.first?.sequence == 11)
    }

    @Test("UI detail produced during activation is merged after code becomes active")
    func mergesPendingUIResult() {
        let store = DevStatus.Store()
        let context = LiveReload.Context(
            generationID: 8,
            sourceRevision: 9,
            changedFunctions: [],
            reason: .manual
        )
        store.recordUIResult(
            context: context,
            .refreshed,
            warnings: ["layout warning"],
            errors: []
        )
        #expect(store.snapshot.phase == .idle)

        store.record(
            .init(
                sourceRevision: .init(rawValue: 9),
                generationID: .init(rawValue: 8),
                codeStatus: .codeActive,
                reloadStatus: .refreshed
            )
        )
        #expect(store.snapshot.phase == .codeActive)
        #expect(store.snapshot.reloadStatus == .refreshed)
        #expect(store.snapshot.detail == "layout warning")
        #expect(store.snapshot.activeGenerationID == .init(rawValue: 8))
    }
}
}
