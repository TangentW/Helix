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
            try DevSession.ServiceConfiguration(maximumPendingConnections: 0).validate()
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
}
}

private actor RecordingSessionServer: DevSession.SessionServing {
    private(set) var preparedShells: [DevProtocol.ShellID] = []
    private(set) var acceptedPeers: [DevProtocol.PeerID] = []
    private(set) var didStop = false
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

    func remove(shellID _: DevProtocol.ShellID) {}

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
