import Foundation
import HelixDevProtocol
import HelixDevRuntime
import HelixLiveReloadAPI
import Testing

extension DevRuntimeTests {
@Suite("Live Reload state and guardrails")
struct LiveReloadState {
    @Test("Reload planning ignores service hints and deterministically escalates UI policy")
    func plansReloadActions() throws {
        let type = LiveReload.NominalTypeID.derive(
            module: "Feature",
            canonicalName: "ScreenViewController"
        )
        let result = ReloadPlanning.Planner().plan([
            .init(nominalTypeID: nil, policy: .observeOnly),
            .init(
                nominalTypeID: type,
                policy: .invalidate,
                invalidationHints: [.constraints]
            ),
            .init(
                nominalTypeID: type,
                policy: .invalidate,
                invalidationHints: [.layout, .display]
            ),
        ])
        let action = try #require(result.actions.first)
        #expect(result.actions.count == 1)
        #expect(action.policy == .invalidate)
        #expect(action.invalidationHints == [.constraints, .layout, .display])
        #expect(result.warnings.isEmpty)

        let escalated = ReloadPlanning.Planner().plan([
            .init(
                nominalTypeID: type,
                policy: .invalidate,
                invalidationHints: [.layout]
            ),
            .init(nominalTypeID: type, policy: .invokeHook),
        ])
        #expect(escalated.actions.first?.policy == .invokeHook)
        #expect(escalated.actions.first?.invalidationHints.isEmpty == true)
    }

    @Test("Reload planning quarantines conflicting factories and malformed hints")
    func rejectsAmbiguousReloadPlan() {
        let type = LiveReload.NominalTypeID.derive(
            module: "Feature",
            canonicalName: "ScreenViewController"
        )
        let result = ReloadPlanning.Planner().plan([
            .init(
                nominalTypeID: type,
                policy: .recreate,
                factoryID: .init(rawValue: "first")
            ),
            .init(
                nominalTypeID: type,
                policy: .recreate,
                factoryID: .init(rawValue: "second")
            ),
            .init(nominalTypeID: type, policy: .invalidate),
            .init(
                nominalTypeID: nil,
                policy: .invalidate,
                invalidationHints: [.layout]
            ),
        ])
        #expect(result.actions.isEmpty)
        #expect(result.warnings.count == 3)
    }

    @MainActor
    @Test("DevState stores typed temporary values without retaining their owner")
    func devStateLifetime() {
        final class Owner {}

        let storage = LiveReload.DevState()
        var owner: Owner? = Owner()
        weak let weakOwner = owner
        storage[owner!, key: "counter", default: 0] = 7
        #expect(storage[owner!, key: "counter", default: 0] == 7)
        #expect(storage.liveOwnerCount == 1)

        storage.removeAllValues(for: owner!)
        #expect(storage.liveOwnerCount == 0)
        storage[owner!, key: "name", default: "initial"] = "updated"
        owner = nil
        #expect(weakOwner == nil)
        #expect(storage.liveOwnerCount == 0)
    }

    @Test("A throwing critical section always unblocks future reload work")
    func criticalSectionCleanup() async {
        enum FixtureError: Error { case failed }

        let guardrail = LiveReload.Guard()
        do {
            _ = try await guardrail.withCriticalSection("database transaction") {
                #expect(await guardrail.isBlocked)
                #expect(await guardrail.activeLabels == ["database transaction"])
                throw FixtureError.failed
            } as Void
            Issue.record("expected fixture failure")
        } catch FixtureError.failed {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await !guardrail.isBlocked)
        await guardrail.waitUntilUnblocked()
    }
}
}
