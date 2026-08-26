#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
@testable import HelixHubCore
import HelixCore
import HelixDevProtocol
import HelixDevTools
import Testing

@Suite("Helix Hub service facade", .serialized)
struct ServiceControllerTests {
    @Test("Embedded service exposes pairing and project-scoped contexts")
    func embedded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = try controller(fixture: fixture)
        let started = try await controller.start()
        #expect(started.mode == .embedded)
        #expect(started.service.state == .running)

        let invitation = try await controller.rotatePairingCode(
            projectURL: fixture.projectURL
        )
        #expect(invitation.workspacePathHash == fixture.context.workspacePathHash)
        let state = try await controller.refresh(projectURL: fixture.projectURL)
        #expect(state.currentInvitation == invitation)
        #expect(state.currentInvitationMatches(projectURL: fixture.projectURL))
        #expect(!state.currentInvitationMatches(projectURL: nil))
        #expect(state.buildContexts == [fixture.context])
        #expect(state.recentEvents.contains { $0.level == .success })
        try await controller.cancelPairingCode(
            invitationID: invitation.reservation.invitationID
        )
        #expect(try await controller.refresh().manualInvitations.isEmpty)
        await controller.stop()
        #expect(try await controller.refresh().mode == .stopped)
    }

    @Test("Thin frontend adopts an already running service")
    func external() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = try makeService(fixture: fixture, eventHandler: { _ in })
        _ = try await external.start()
        defer { Task { await external.stop() } }

        let controller = try controller(fixture: fixture)
        let started = try await controller.start()
        #expect(started.mode == .external)
        #expect(started.service.state == .running)
        let invitation = try await controller.rotatePairingCode()
        let state = try await controller.refresh()
        #expect(state.currentInvitation == invitation)
        #expect(state.currentInvitationMatches(projectURL: nil))
        #expect(!state.currentInvitationMatches(projectURL: fixture.projectURL))
        await controller.stop()
        #expect(await external.snapshot().state == .running)
        await external.stop()
    }

    private func controller(fixture: Fixture) throws -> Hub.ServiceController {
        let client = try HubControl.Client(
            rendezvousStore: .init(url: fixture.rendezvousURL)
        )
        return Hub.ServiceController(controlClient: client) { handler in
            try makeService(fixture: fixture, eventHandler: handler)
        }
    }

    private func makeService(
        fixture: Fixture,
        eventHandler: @escaping DevSession.Service.EventHandler
    ) throws -> DevSession.Service {
        let registry = try DevSession.ContextRegistry(contexts: [fixture.context])
        let broker = try DevSession.ConnectionBroker(
            registry: registry,
            authority: Pairing.Authority()
        )
        return try .init(
            configuration: .init(advertiseBonjour: false),
            serverIdentity: NetworkTransport.IdentityFactory.makeServerIdentity(),
            broker: broker,
            sessionServer: EmptySessionServer(),
            controlSecret: Data(repeating: 0x71, count: 32),
            rendezvousStore: .init(url: fixture.rendezvousURL),
            toolExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            eventHandler: eventHandler
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-controller-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("Example.xcodeproj").standardizedFileURL
        let build = DevProtocol.PeerBuildIdentity(
            bundleID: "dev.example.hub",
            executableUUID: UUID(),
            platform: .iOS,
            architecture: "arm64",
            xcodeBuild: "18A1",
            sdkBuild: "22A1",
            swiftCompilerFingerprint: "swift-hub",
            liveReloadIndexHash: .sha256("hub-index")
        )
        let context = DevSession.BuildContext(
            shellIdentity: .init(shellID: .init(rawValue: UUID()), build: build),
            workspacePathHash: .sha256(projectURL.path),
            workspacePath: projectURL.path,
            configurationPath: root.appendingPathComponent("HelixDev.json").path,
            scheme: "Example",
            buildConfiguration: "Debug",
            moduleName: "ExampleFeature"
        )
        try context.validate()
        return .init(
            root: root,
            projectURL: projectURL,
            rendezvousURL: root.appendingPathComponent("Service.json"),
            context: context
        )
    }

    private struct Fixture: Sendable {
        var root: URL
        var projectURL: URL
        var rendezvousURL: URL
        var context: DevSession.BuildContext
    }
}

private actor EmptySessionServer: DevSession.SessionServing {
    func prepare(context _: DevSession.BuildContext) {}
    func accept(
        authorization _: DevSession.SessionAuthorization,
        transport _: NetworkTransport.ByteTransport
    ) {}
    func remove(shellID _: DevProtocol.ShellID) {}
    func stopAll() {}
}
#endif
