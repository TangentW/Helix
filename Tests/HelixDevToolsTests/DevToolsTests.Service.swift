#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import Network
import HelixCore
import HelixDevProtocol
@testable import HelixDevTools
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Unified Helix service")
struct Service {
    @Test("Service configuration bounds unauthenticated resource use")
    func configurationLimits() {
        #expect(throws: DevSession.ServiceError.invalidConfiguration) {
            try DevSession.ServiceConfiguration(maximumOpenConnections: 0).validate()
        }
        #expect(throws: DevSession.ServiceError.invalidConfiguration) {
            try DevSession.ServiceConfiguration(pairingTimeoutNanoseconds: 99_999_999)
                .validate()
        }
        #expect(throws: Never.self) {
            try DevSession.ServiceConfiguration().validate()
        }
    }

    @Test("One pinned listener pairs and resumes an exact Shell")
    func pairAndResume() async throws {
        let context = try serviceContext()
        let registry = try DevSession.ContextRegistry(contexts: [context])
        let authority = try Pairing.Authority()
        let broker = DevSession.ConnectionBroker(registry: registry, authority: authority)
        let sessions = RecordingSessionServer()
        let identity = try NetworkTransport.IdentityFactory.makeServerIdentity()
        let service = try DevSession.Service(
            configuration: .init(advertiseBonjour: false),
            serverIdentity: identity,
            broker: broker,
            sessionServer: sessions
        )
        let endpoint = try await service.start()
        defer { Task { await service.stop() } }
        let invitation = try await service.createManualInvitation()
        let peer = servicePeer(for: context)

        let firstTransport = try await serviceClient(endpoint: endpoint)
        let firstExporter = try firstTransport.tlsExporterHash()
        let firstChannel = Pairing.Channel(transport: firstTransport)
        let request = Pairing.RedeemRequest(
            code: invitation.code,
            peerIdentity: peer,
            clientNonce: Data(repeating: 0x41, count: 32)
        )
        try await firstChannel.send(.redeem(request))
        let firstResponse = try await firstChannel.receive()
        guard case let .sessionGranted(grant) = firstResponse else {
            Issue.record("Expected a session grant, got \(firstResponse)")
            return
        }
        #expect(try grant.verify(request: request, tlsExporterHash: firstExporter))
        await sessions.waitForAcceptCount(1)

        let secondTransport = try await serviceClient(endpoint: endpoint)
        let secondExporter = try secondTransport.tlsExporterHash()
        let secondChannel = Pairing.Channel(transport: secondTransport)
        let resume = try Pairing.ResumeRequest.signed(
            leaseID: grant.leaseID,
            peerIdentity: peer,
            sessionSecret: grant.sessionSecret,
            tlsExporterHash: secondExporter,
            clientNonce: Data(repeating: 0x52, count: 32)
        )
        try await secondChannel.send(.resume(resume))
        let secondResponse = try await secondChannel.receive()
        guard case let .sessionResumed(resumeGrant) = secondResponse else {
            Issue.record("Expected a resume grant, got \(secondResponse)")
            return
        }
        #expect(
            try resumeGrant.verify(
                request: resume,
                tlsExporterHash: secondExporter,
                sessionSecret: grant.sessionSecret
            )
        )
        await sessions.waitForAcceptCount(2)
        #expect(await sessions.preparedShells == [context.shellIdentity.shellID])
        #expect(await sessions.acceptedPeers == [peer.peerID, peer.peerID])
        await firstTransport.close()
        await secondTransport.close()
        await service.stop()
        #expect(await sessions.didStop)
        #expect(await service.snapshot().state == .stopped)
    }

    @Test("An invalid code is rejected without entering a Shell host")
    func invalidCode() async throws {
        let context = try serviceContext()
        let registry = try DevSession.ContextRegistry(contexts: [context])
        let broker = try DevSession.ConnectionBroker(
            registry: registry,
            authority: Pairing.Authority()
        )
        let sessions = RecordingSessionServer()
        let service = try DevSession.Service(
            configuration: .init(advertiseBonjour: false),
            serverIdentity: NetworkTransport.IdentityFactory.makeServerIdentity(),
            broker: broker,
            sessionServer: sessions
        )
        let endpoint = try await service.start()
        defer { Task { await service.stop() } }
        let transport = try await serviceClient(endpoint: endpoint)
        let channel = Pairing.Channel(transport: transport)
        let request = Pairing.RedeemRequest(
            code: try Pairing.Code("ZZ99"),
            peerIdentity: servicePeer(for: context),
            clientNonce: Data(repeating: 7, count: 32)
        )
        try await channel.send(.redeem(request))
        let response = try await channel.receive()
        guard case let .rejected(rejection) = response else {
            Issue.record("Expected a pairing rejection, got \(response)")
            return
        }
        #expect(rejection.reason == .invalidInvitation)
        #expect(await sessions.acceptedPeers.isEmpty)
        await transport.close()
        await service.stop()
    }

    @Test("The same pinned listener serves owner-local Xcode control")
    func localControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-control-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendezvousStore = HubControl.RendezvousStore(
            url: directory.appendingPathComponent("Service.json")
        )
        let registry = try DevSession.ContextRegistry()
        let broker = try DevSession.ConnectionBroker(
            registry: registry,
            authority: Pairing.Authority()
        )
        let sessions = RecordingSessionServer()
        let service = try DevSession.Service(
            configuration: .init(advertiseBonjour: false),
            serverIdentity: NetworkTransport.IdentityFactory.makeServerIdentity(),
            broker: broker,
            sessionServer: sessions,
            controlSecret: Data(repeating: 0xC7, count: 32),
            rendezvousStore: rendezvousStore
        )
        let endpoint = try await service.start()
        let client = try HubControl.Client(rendezvousStore: rendezvousStore)
        let first = try await client.reserveAutomaticInvitation()
        #expect(first.reservation.kind == .automaticXcode)
        #expect(first.spkiSHA256 == endpoint.spkiSHA256)

        let context = try serviceContext()
        await #expect(throws: HubControl.Error.self) {
            _ = try await client.registerAndActivate(
                invitationID: .init(rawValue: UUID()),
                context: context
            )
        }
        #expect(await registry.contexts().isEmpty)

        let invitation = try await client.registerAndActivate(
            invitationID: first.reservation.invitationID,
            context: context
        )
        #expect(invitation.reservation == first.reservation)
        #expect(invitation.shellIdentity == context.shellIdentity)
        #expect(await registry.context(shellID: context.shellIdentity.shellID) == context)

        let second = try await client.reserveAutomaticInvitation()
        var rotated = context
        rotated.shellIdentity = .init(
            shellID: .init(rawValue: UUID()),
            build: context.shellIdentity.build
        )
        rotated.registeredAt = context.registeredAt.addingTimeInterval(1)
        let rotatedInvitation = try await client.registerAndActivate(
            invitationID: second.reservation.invitationID,
            context: rotated
        )
        #expect(rotatedInvitation.shellIdentity == rotated.shellIdentity)
        #expect(await registry.context(shellID: context.shellIdentity.shellID) == nil)
        #expect(await registry.context(shellID: rotated.shellIdentity.shellID) == rotated)
        #expect(await sessions.removedShells == [context.shellIdentity.shellID])

        let attributes = try FileManager.default.attributesOfItem(
            atPath: rendezvousStore.url.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try rendezvousStore.load().controlSecret == Data(repeating: 0xC7, count: 32))
        await service.stop()
        #expect(!FileManager.default.fileExists(atPath: rendezvousStore.url.path))
    }

    @Test("Control framing is canonical, correlated, and route-versioned")
    func controlFraming() throws {
        let request = HubControl.Request(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            command: .reserveAutomaticInvitation,
            controlSecret: Data(repeating: 0x19, count: 32)
        )
        let codec = HubControl.FrameCodec()
        let frame = try codec.encode(request)
        #expect(try codec.decodeRequest(frame) == request)
        #expect(try request.authenticate(with: Data(repeating: 0x19, count: 32)))
        #expect(!(try request.authenticate(with: Data(repeating: 0x20, count: 32))))
        #expect(
            try NetworkTransport.ConnectionRoute(
                preamble: NetworkTransport.ConnectionRoute.pairing.preamble
            ) == .pairing
        )
        #expect(
            try NetworkTransport.ConnectionRoute(
                preamble: NetworkTransport.ConnectionRoute.localControl.preamble
            ) == .localControl
        )
        var noncanonical = frame
        noncanonical.insert(UInt8(ascii: " "), at: noncanonical.count - 1)
        #expect(throws: (any Swift.Error).self) {
            try codec.decodeRequest(noncanonical)
        }
    }
}
}

private actor RecordingSessionServer: DevSession.SessionServing {
    private(set) var preparedShells: [DevProtocol.ShellID] = []
    private(set) var acceptedPeers: [DevProtocol.PeerID] = []
    private(set) var didStop = false
    private(set) var removedShells: [DevProtocol.ShellID] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func prepare(context: DevSession.BuildContext) {
        if !preparedShells.contains(context.shellIdentity.shellID) {
            preparedShells.append(context.shellIdentity.shellID)
        }
    }

    func accept(
        authorization: DevSession.SessionAuthorization,
        transport _: NetworkTransport.ByteTransport
    ) {
        acceptedPeers.append(authorization.peerIdentity.peerID)
        let ready = waiters.filter { acceptedPeers.count >= $0.0 }
        waiters.removeAll { acceptedPeers.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func stopAll() { didStop = true }

    func remove(shellID: DevProtocol.ShellID) { removedShells.append(shellID) }

    func waitForAcceptCount(_ count: Int) async {
        guard acceptedPeers.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private func serviceClient(
    endpoint: DevSession.ServiceEndpoint
) async throws -> NetworkTransport.ByteTransport {
    guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
        throw DevSession.ServiceError.invalidConfiguration
    }
    let transport = NetworkTransport.ByteTransport.pinnedTLSClient(
        host: "127.0.0.1",
        port: port,
        expectedSPKIHash: endpoint.spkiSHA256
    )
    try await transport.start()
    try await transport.send(NetworkTransport.ConnectionRoute.pairing.preamble)
    return transport
}

private func serviceContext() throws -> DevSession.BuildContext {
    let workspace = "/tmp/HelixServiceFixture.xcworkspace"
    let build = DevProtocol.PeerBuildIdentity(
        bundleID: "dev.helix.service.fixture",
        executableUUID: UUID(),
        platform: .iOS,
        architecture: "arm64",
        xcodeBuild: "18A1",
        swiftCompilerFingerprint: "swift-service",
        liveReloadIndexHash: .sha256("service-index")
    )
    let context = DevSession.BuildContext(
        shellIdentity: .init(shellID: .init(rawValue: UUID()), build: build),
        workspacePathHash: .sha256(workspace),
        workspacePath: workspace,
        configurationPath: "/tmp/helix/service/HelixDev.json",
        scheme: "Fixture",
        buildConfiguration: "Debug",
        moduleName: "FixtureFeature"
    )
    try context.validate()
    return context
}

private func servicePeer(
    for context: DevSession.BuildContext
) -> DevProtocol.PeerIdentity {
    .init(
        peerID: .init(rawValue: UUID()),
        build: context.shellIdentity.build,
        processID: 42,
        operatingSystemBuild: "23A1",
        supportedBackends: [.hlbc]
    )
}
#endif
