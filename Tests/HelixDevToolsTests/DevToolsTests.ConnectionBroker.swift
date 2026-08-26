import Foundation
import HelixCore
import HelixDevProtocol
@testable import HelixDevTools
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Unified connection broker")
struct ConnectionBroker {
    @Test("A manual code selects the exact registered project build")
    func manualPairing() async throws {
        let first = try brokerContext(index: 1, workspace: "/tmp/First.xcworkspace")
        let second = try brokerContext(index: 2, workspace: "/tmp/Second.xcworkspace")
        let broker = try await makeBroker(contexts: [first, second])
        let now = Date(timeIntervalSince1970: 1_000)
        let invitation = try await broker.createManualInvitation(
            workspacePathHash: first.workspacePathHash,
            now: now
        )
        let transcript = Core.Digest.sha256("manual-exporter")

        await expectBrokerFailure(.invalidInvitation) {
            _ = try await broker.redeem(
                redeemRequest(for: second, code: invitation.code),
                rateLimitKey: .init(stableSource: "peer-a"),
                tlsExporterHash: transcript,
                now: now.addingTimeInterval(1)
            )
        }
        #expect(await broker.manualInvitations(now: now.addingTimeInterval(1)).count == 1)

        let request = redeemRequest(for: first, code: invitation.code)
        let authorization = try await broker.redeem(
            request,
            rateLimitKey: .init(stableSource: "peer-a"),
            tlsExporterHash: transcript,
            now: now.addingTimeInterval(2)
        )
        #expect(authorization.context == first)
        #expect(try authorization.session.grant.verify(
            request: request,
            tlsExporterHash: transcript,
            now: now.addingTimeInterval(2)
        ))
        #expect(await broker.manualInvitations(now: now.addingTimeInterval(2)).isEmpty)
    }

    @Test("An Xcode invitation binds only after its final context exists")
    func automaticPairing() async throws {
        let context = try brokerContext(index: 3)
        let registry = try DevSession.ContextRegistry()
        let authority = try Pairing.Authority()
        let broker = DevSession.ConnectionBroker(registry: registry, authority: authority)
        let now = Date(timeIntervalSince1970: 2_000)
        let reservation = try await broker.reserveAutomaticInvitation(now: now)

        await expectBrokerFailure(.buildMismatch) {
            _ = try await broker.activateAutomaticInvitation(
                invitationID: reservation.invitationID,
                shellID: context.shellIdentity.shellID,
                now: now.addingTimeInterval(1)
            )
        }
        _ = try await registry.register(context)
        let invitation = try await broker.activateAutomaticInvitation(
            invitationID: reservation.invitationID,
            shellID: context.shellIdentity.shellID,
            now: now.addingTimeInterval(2)
        )
        #expect(invitation.code == reservation.code)
        let authorization = try await broker.redeem(
            redeemRequest(for: context, code: invitation.code),
            rateLimitKey: .init(stableSource: "peer-b"),
            tlsExporterHash: .sha256("automatic-exporter"),
            now: now.addingTimeInterval(3)
        )
        #expect(authorization.context == context)
    }

    @Test("Concurrent redemption has exactly one winner")
    func concurrentSingleUse() async throws {
        let context = try brokerContext(index: 4)
        let broker = try await makeBroker(contexts: [context])
        let now = Date(timeIntervalSince1970: 3_000)
        let invitation = try await broker.createManualInvitation(now: now)
        let pairRequest = redeemRequest(for: context, code: invitation.code)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for source in ["peer-c1", "peer-c2"] {
                group.addTask {
                    do {
                        _ = try await broker.redeem(
                            pairRequest,
                            rateLimitKey: .init(stableSource: source),
                            tlsExporterHash: .sha256("single-use-exporter"),
                            now: now.addingTimeInterval(1)
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test("A displayed manual code expires before first redemption")
    func manualExpiration() async throws {
        let context = try brokerContext(index: 5)
        let configuration = Pairing.AuthorityConfiguration(invitationLifetime: 10)
        let broker = try await makeBroker(
            contexts: [context],
            authorityConfiguration: configuration
        )
        let now = Date(timeIntervalSince1970: 4_000)
        let invitation = try await broker.createManualInvitation(now: now)
        await expectBrokerFailure(.expiredInvitation) {
            _ = try await broker.redeem(
                redeemRequest(for: context, code: invitation.code),
                rateLimitKey: .init(stableSource: "peer-d"),
                tlsExporterHash: .sha256("expired-exporter"),
                now: now.addingTimeInterval(11)
            )
        }
    }

    @Test("Reconnect leases resolve the same Build Context")
    func reconnect() async throws {
        let context = try brokerContext(index: 6)
        let broker = try await makeBroker(contexts: [context])
        let now = Date(timeIntervalSince1970: 5_000)
        let invitation = try await broker.createManualInvitation(now: now)
        let peer = peerIdentity(for: context)
        let established = try await broker.redeem(
            .init(
                code: invitation.code,
                peerIdentity: peer,
                clientNonce: Data(repeating: 3, count: 32)
            ),
            rateLimitKey: .init(stableSource: "peer-e"),
            tlsExporterHash: .sha256("initial-exporter"),
            now: now.addingTimeInterval(1)
        )
        let resumeExporter = Core.Digest.sha256("resume-exporter")
        let resume = try Pairing.ResumeRequest.signed(
            leaseID: established.session.grant.leaseID,
            peerIdentity: peer,
            sessionSecret: established.session.grant.sessionSecret,
            tlsExporterHash: resumeExporter
        )
        let resumed = try await broker.resume(
            resume,
            tlsExporterHash: resumeExporter,
            now: now.addingTimeInterval(2)
        )
        #expect(resumed.context == context)
        #expect(resumed.session.sessionSecret == established.session.grant.sessionSecret)
    }
}
}

private func makeBroker(
    contexts: [DevSession.BuildContext],
    authorityConfiguration: Pairing.AuthorityConfiguration = .init()
) async throws -> DevSession.ConnectionBroker {
    let registry = try DevSession.ContextRegistry()
    for context in contexts { _ = try await registry.register(context) }
    return try .init(
        registry: registry,
        authority: Pairing.Authority(configuration: authorityConfiguration)
    )
}

private func brokerContext(
    index: Int,
    workspace: String = "/tmp/Fixture.xcworkspace"
) throws -> DevSession.BuildContext {
    let workspace = URL(fileURLWithPath: workspace).standardizedFileURL.path
    guard let executableUUID = UUID(
        uuidString: String(format: "20000000-0000-0000-0000-%012d", index)
    ), let shellUUID = UUID(
        uuidString: String(format: "30000000-0000-0000-0000-%012d", index)
    ) else {
        throw DevSession.ContextError.invalidValue
    }
    let build = DevProtocol.PeerBuildIdentity(
        bundleID: "dev.helix.broker.\(index)",
        executableUUID: executableUUID,
        platform: .iOS,
        architecture: "arm64",
        xcodeBuild: "18A1",
        sdkBuild: "22A1",
        swiftCompilerFingerprint: "swift-broker-\(index)",
        liveReloadIndexHash: .sha256("broker-index-\(index)")
    )
    let context = DevSession.BuildContext(
        shellIdentity: .init(shellID: .init(rawValue: shellUUID), build: build),
        workspacePathHash: .sha256(workspace),
        workspacePath: workspace,
        configurationPath: "/tmp/helix/broker/\(index)/HelixDev.json",
        scheme: "Fixture",
        buildConfiguration: "Debug",
        moduleName: "FixtureFeature",
        registeredAt: Date(timeIntervalSince1970: TimeInterval(index))
    )
    try context.validate()
    return context
}

private func peerIdentity(
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

private func redeemRequest(
    for context: DevSession.BuildContext,
    code: Pairing.Code
) -> Pairing.RedeemRequest {
    .init(
        code: code,
        peerIdentity: peerIdentity(for: context),
        clientNonce: Data(repeating: 9, count: 32)
    )
}

private func expectBrokerFailure(
    _ expected: Pairing.Rejection.Reason,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected pairing failure \(expected.rawValue)")
    } catch let failure as Pairing.Failure {
        #expect(failure.reason == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
