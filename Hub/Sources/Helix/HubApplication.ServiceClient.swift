#if os(macOS)
import Foundation
import HelixHubCore

extension HubApplication {
protocol ServiceControlling: Sendable {
    func start() async throws -> Hub.ServiceViewState
    func refresh(projectURL: URL?) async throws -> Hub.ServiceViewState
    func rotatePairingCode(projectURL: URL?) async throws
    func stop() async
}

actor ServiceClient: ServiceControlling {
    private let controller: Hub.ServiceController

    init() throws {
        controller = try Hub.ServiceController()
    }

    func start() async throws -> Hub.ServiceViewState {
        try await controller.start()
    }

    func refresh(projectURL: URL?) async throws -> Hub.ServiceViewState {
        try await controller.refresh(projectURL: projectURL)
    }

    func rotatePairingCode(projectURL: URL?) async throws {
        _ = try await controller.rotatePairingCode(projectURL: projectURL)
    }

    func stop() async {
        await controller.stop()
    }
}
}
#endif
