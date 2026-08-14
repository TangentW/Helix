#if os(macOS)
import Foundation
@testable import HelixHubApp
import HelixHubCore
import Testing

extension HubApplicationTests {
@MainActor
@Suite("Helix Hub application service model")
struct Model {
    @Test("A failed service start remains retryable")
    func failedStartCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ServiceStub(startSteps: [.fail, .succeed])
        var factoryCallCount = 0
        let model = HubApplication.Model(
            projectStoreFactory: fixture.projectStore,
            serviceFactory: {
                factoryCallCount += 1
                return service
            }
        )

        await model.run()

        #expect(factoryCallCount == 1)
        #expect(!model.isStartingService)
        #expect(!model.serviceIsRunning)
        #expect(model.notice?.recovery == .retryService)
        #expect(model.operationLabel == "Helix service is offline.")

        await model.retryService()

        let counts = await service.counts()
        #expect(factoryCallCount == 2)
        #expect(counts.starts == 2)
        #expect(counts.stops == 1)
        #expect(model.serviceIsRunning)
        #expect(model.notice == nil)
        #expect(model.operationLabel == "Helix service is ready.")
    }

    @Test("A failed pairing-code rotation remains retryable")
    func failedPairingCodeCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ServiceStub(
            startSteps: [.succeed],
            rotationSteps: [.fail, .succeed]
        )
        let model = HubApplication.Model(
            projectStoreFactory: fixture.projectStore,
            serviceFactory: { service }
        )

        await model.run()

        #expect(model.serviceIsRunning)
        #expect(model.notice?.recovery == .retryPairingCode)
        #expect(!model.isRotatingPairingCode)

        await model.retryPairingCode()

        let counts = await service.counts()
        #expect(counts.rotations == 2)
        #expect(model.serviceIsRunning)
        #expect(model.notice == nil)
        #expect(!model.isRotatingPairingCode)
    }

    @Test("Repeated view tasks initialize the service only once")
    func runIsIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ServiceStub(startSteps: [.succeed])
        var factoryCallCount = 0
        let model = HubApplication.Model(
            projectStoreFactory: fixture.projectStore,
            serviceFactory: {
                factoryCallCount += 1
                return service
            }
        )

        await model.run()
        await model.run()

        let counts = await service.counts()
        #expect(factoryCallCount == 1)
        #expect(counts.starts == 1)
    }

    @Test("Pairing rotation waits for an in-flight refresh")
    func pairingRotationSerializesWithRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ServiceStub(
            startSteps: [.succeed],
            blockRefreshAtCount: 3
        )
        let model = HubApplication.Model(
            projectStoreFactory: fixture.projectStore,
            serviceFactory: { service }
        )
        await model.run()
        await service.waitForRefresh(count: 3)

        let retry = Task { await model.retryPairingCode() }
        while !model.isRotatingPairingCode { await Task.yield() }

        var counts = await service.counts()
        #expect(counts.refreshes == 3)
        #expect(counts.rotations == 1)

        await service.releaseBlockedRefresh()
        await retry.value

        counts = await service.counts()
        #expect(counts.refreshes == 5)
        #expect(counts.rotations == 2)
        #expect(!model.isRotatingPairingCode)
        #expect(model.notice == nil)
    }

    private struct Fixture {
        let directory: URL
        let projectStore: () throws -> Hub.ProjectStore

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HelixHubModel-\(UUID().uuidString)")
            self.directory = directory
            let url = directory.appendingPathComponent("HubProjects.json")
            projectStore = { try Hub.ProjectStore(url: url) }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor ServiceStub: HubApplication.ServiceControlling {
        enum Step: Sendable { case fail, succeed }

        struct Counts: Sendable {
            var starts: Int
            var refreshes: Int
            var rotations: Int
            var stops: Int
        }

        private var startSteps: [Step]
        private var rotationSteps: [Step]
        private let blockRefreshAtCount: Int?
        private var startCount = 0
        private var refreshCount = 0
        private var rotationCount = 0
        private var stopCount = 0
        private var refreshWaiters: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        private var blockedRefresh: CheckedContinuation<Void, Never>?

        init(
            startSteps: [Step],
            rotationSteps: [Step] = [],
            blockRefreshAtCount: Int? = nil
        ) {
            self.startSteps = startSteps
            self.rotationSteps = rotationSteps
            self.blockRefreshAtCount = blockRefreshAtCount
        }

        func start() throws -> Hub.ServiceViewState {
            startCount += 1
            if next(&startSteps) == .fail { throw StubError.start }
            return runningState()
        }

        func refresh(projectURL: URL?) async -> Hub.ServiceViewState {
            refreshCount += 1
            let ready = refreshWaiters.filter { $0.count <= refreshCount }
            refreshWaiters.removeAll { $0.count <= refreshCount }
            ready.forEach { $0.continuation.resume() }
            if refreshCount == blockRefreshAtCount {
                await withCheckedContinuation { blockedRefresh = $0 }
            }
            return runningState()
        }

        func rotatePairingCode(projectURL: URL?) throws {
            rotationCount += 1
            if next(&rotationSteps) == .fail { throw StubError.pairing }
        }

        func stop() {
            stopCount += 1
        }

        func counts() -> Counts {
            .init(
                starts: startCount,
                refreshes: refreshCount,
                rotations: rotationCount,
                stops: stopCount
            )
        }

        func waitForRefresh(count: Int) async {
            guard refreshCount < count else { return }
            await withCheckedContinuation {
                refreshWaiters.append((count, $0))
            }
        }

        func releaseBlockedRefresh() {
            blockedRefresh?.resume()
            blockedRefresh = nil
        }

        private func next(_ steps: inout [Step]) -> Step {
            steps.isEmpty ? .succeed : steps.removeFirst()
        }

        private func runningState() -> Hub.ServiceViewState {
            .init(
                mode: .embedded,
                service: .init(
                    state: .running,
                    endpoint: nil,
                    openConnectionCount: 0,
                    pendingPairingCount: 0
                ),
                manualInvitations: [],
                buildContexts: [],
                recentEvents: []
            )
        }
    }

    private enum StubError: Swift.Error, CustomStringConvertible, Sendable {
        case start
        case pairing

        var description: String {
            switch self {
            case .start: "scripted start failure"
            case .pairing: "scripted pairing failure"
            }
        }
    }
}
}
#endif
