#if canImport(SwiftUI)
import HelixCore
import HelixDevProtocol
import HelixDevRuntime
import HelixLiveReloadAPI
import Testing

extension DevRuntimeTests {
@MainActor
@Suite("SwiftUI Live Reload pulse")
struct SwiftUIReloadTests {
    @Test("Pulse publishes only to matching type channels and catch-all boundaries")
    func targetsMatchingBoundaries() throws {
        let pulse = LiveReload.Pulse()
        let first = typeID("First")
        let second = typeID("Second")
        let firstToken = pulse.registerBoundary(for: first)
        let secondToken = pulse.registerBoundary(
            for: second,
            mode: .recreateSubtree
        )
        let catchAllToken = pulse.registerBoundary()

        let firstResult = try pulse.advance(
            context(generation: 1, reason: .manual),
            affectedNominalTypes: [first]
        )
        #expect(firstResult.matchedBoundaryCount == 2)
        #expect(pulse.refreshSequence(for: first) == 1)
        #expect(pulse.refreshSequence(for: second) == 0)
        #expect(pulse.refreshSequence(for: nil) == 1)

        let secondResult = try pulse.advance(
            context(generation: 2, reason: .manual),
            affectedNominalTypes: [second]
        )
        #expect(secondResult.matchedBoundaryCount == 2)
        #expect(pulse.refreshSequence(for: first) == 1)
        #expect(pulse.refreshSequence(for: second) == 2)
        #expect(pulse.refreshSequence(for: nil) == 2)

        pulse.unregisterBoundary(firstToken)
        pulse.unregisterBoundary(secondToken)
        pulse.unregisterBoundary(catchAllToken)
        #expect(pulse.activeBoundaryCount == 0)
    }

    @Test("Automatic duplicate is idempotent and an older generation is rejected")
    func rejectsStaleGeneration() throws {
        let pulse = LiveReload.Pulse()
        let id = typeID("Screen")
        _ = pulse.registerBoundary(for: id)
        let current = try context(generation: 2)
        let first = try pulse.advance(current, affectedNominalTypes: [id])
        let duplicate = try pulse.advance(current, affectedNominalTypes: [id])

        #expect(first.didPublish)
        #expect(!duplicate.didPublish)
        #expect(pulse.snapshot.sequence == 1)
        var conflicting = current
        conflicting.sourceRevision = 3
        #expect(throws: LiveReload.ValidationError.self) {
            _ = try pulse.advance(conflicting, affectedNominalTypes: [id])
        }
        #expect(throws: LiveReload.ValidationError.self) {
            _ = try pulse.advance(
                context(generation: 1),
                affectedNominalTypes: [id]
            )
        }
    }

    @Test("Coordinator reports targeted and manual body refreshes truthfully")
    func coordinatorRefreshesBoundaries() throws {
        let pulse = LiveReload.Pulse()
        let id = typeID("Profile")
        _ = pulse.registerBoundary(for: id)
        let coordinator = SwiftUIReload.Coordinator(pulse: pulse)
        let automatic = try context(generation: 1)

        let report = coordinator.reload(
            context: automatic,
            hints: [
                .init(
                    nominalTypeID: id,
                    policy: .invalidate,
                    invalidationHints: [.layout]
                ),
            ]
        )
        #expect(report.status == .refreshed)
        #expect(report.matchedBoundaryCount == 1)
        #expect(report.refreshedBoundaryCount == 1)

        let manual = coordinator.manualReload(context: automatic)
        #expect(manual.status == .refreshed)
        #expect(pulse.snapshot.sequence == 2)

        let unknown = coordinator.reload(
            context: try context(generation: 2),
            hints: [
                .init(
                    nominalTypeID: typeID("Unknown"),
                    policy: .invalidate,
                    invalidationHints: [.display]
                ),
            ]
        )
        #expect(unknown.status == .manualRefreshRequired)
        #expect(unknown.refreshedBoundaryCount == 0)
    }

    private func typeID(_ name: String) -> LiveReload.NominalTypeID {
        .derive(module: "SwiftUIFixture", canonicalName: name)
    }

    private func context(
        generation: UInt64,
        reason: LiveReload.Reason = .sourceSaved
    ) throws -> LiveReload.Context {
        if reason == .manual {
            return .init(
                generationID: generation,
                changedFunctions: [],
                reason: .manual
            )
        }
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.swiftui-tests",
            buildNumber: "1",
            seed: "swiftui-tests"
        )
        let function = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "SwiftUIFixture",
            sourceFileLogicalID: "Screen.swift",
            canonicalDeclaration: "var body: some View",
            loweredSignature: .init(parameters: [], result: "SwiftUI.View"),
            role: .getter
        )
        return .init(
            generationID: generation,
            sourceRevision: generation,
            changedFunctions: [function],
            backend: .nativeDynamicReplacement,
            reason: reason
        )
    }
}
}
#endif
