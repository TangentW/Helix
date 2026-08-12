import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
import Testing

enum DevProtocolTests {}

extension DevProtocolTests {
@Suite("Hub pairing protocol")
struct PairingProtocol {
    @Test("Four-character codes are canonical, readable, and random")
    func pairingCodes() throws {
        #expect(try Pairing.Code("a2k9").rawValue == "A2K9")
        #expect(throws: DevProtocol.Error.invalidPairingCode) {
            _ = try Pairing.Code("AI10")
        }
        #expect(throws: DevProtocol.Error.invalidPairingCode) {
            _ = try Pairing.Code("ABC")
        }

        let samples = try Set((0..<128).map { _ in try Pairing.Code.random() })
        #expect(samples.count > 120)
        #expect(samples.allSatisfy { code in
            code.rawValue.count == Pairing.Code.characterCount
                && code.rawValue.allSatisfy(Pairing.Code.alphabet.contains)
        })
    }

    @Test("Pairing frames are bounded, canonical, and stream-safe")
    func pairingFrames() throws {
        let fixture = Fixture()
        let message = Pairing.Message.redeem(fixture.request(code: try .init("A2K9")))
        let codec = Pairing.FrameCodec()
        let encoded = try codec.encode(message)
        #expect(try codec.decode(encoded) == message)

        let body = try Core.CanonicalJSON.encode(message)
        let object = try JSONSerialization.jsonObject(with: body)
        let noncanonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        var frame = Data(littleEndianBytes: UInt32(noncanonical.count))
        frame.append(noncanonical)
        #expect(throws: DevProtocol.Error.nonCanonicalMessage) {
            _ = try codec.decode(frame)
        }
        #expect(throws: DevProtocol.Error.frameTooLarge) {
            _ = try Pairing.FrameCodec(maximumMessageBytes: 2).encode(message)
        }
        #expect(throws: DevProtocol.Error.truncatedFrame) {
            _ = try codec.decode(encoded.dropLast())
        }
    }

    @Test("An exact-Shell invitation is single-use and transcript-bound")
    func exactShellInvitation() async throws {
        let fixture = Fixture()
        let authority = try Pairing.Authority()
        let now = Date(timeIntervalSince1970: 1_000)
        let invitation = try await authority.issue(
            kind: .automaticXcode,
            shellIdentity: fixture.shellIdentity,
            now: now
        )
        let request = fixture.request(code: invitation.code)
        let transcript = Core.Digest.sha256("tls-exporter")
        let established = try await authority.redeem(
            request,
            rateLimitKey: .init(stableSource: "peer-a"),
            tlsExporterHash: transcript,
            now: now.addingTimeInterval(1)
        )

        #expect(established.shellIdentity == fixture.shellIdentity)
        #expect(established.peerIdentity == fixture.peerIdentity)
        #expect(try established.grant.verify(
            request: request,
            tlsExporterHash: transcript,
            now: now.addingTimeInterval(1)
        ))
        #expect(try !established.grant.verify(
            request: request,
            tlsExporterHash: .sha256("another-exporter"),
            now: now.addingTimeInterval(1)
        ))
        #expect(try !established.grant.verify(
            request: request,
            tlsExporterHash: transcript,
            now: established.grant.expiresAt.addingTimeInterval(1)
        ))
        await expectFailure(.invalidInvitation) {
            _ = try await authority.redeem(
                request,
                rateLimitKey: .init(stableSource: "peer-a"),
                tlsExporterHash: transcript,
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test("Reservations bind only once to a final linked Shell")
    func reservationBinding() async throws {
        let fixture = Fixture()
        let authority = try Pairing.Authority()
        let now = Date(timeIntervalSince1970: 2_000)
        let reservation = try await authority.reserve(kind: .automaticXcode, now: now)
        let invitation = try await authority.activate(
            invitationID: reservation.invitationID,
            shellIdentity: fixture.shellIdentity,
            now: now.addingTimeInterval(1)
        )
        #expect(invitation.reservation == reservation)
        await expectFailure(.invalidInvitation) {
            _ = try await authority.activate(
                invitationID: reservation.invitationID,
                shellIdentity: fixture.shellIdentity,
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test("Expired invitations preserve a useful rejection reason")
    func expiration() async throws {
        let fixture = Fixture()
        let authority = try Pairing.Authority(
            configuration: .init(invitationLifetime: 10)
        )
        let now = Date(timeIntervalSince1970: 3_000)
        let invitation = try await authority.issue(
            kind: .manual,
            shellIdentity: fixture.shellIdentity,
            now: now
        )
        await expectFailure(.expiredInvitation) {
            _ = try await authority.redeem(
                fixture.request(code: invitation.code),
                rateLimitKey: .init(stableSource: "peer-b"),
                tlsExporterHash: .sha256("expired"),
                now: now.addingTimeInterval(11)
            )
        }
        let counts = await authority.counts(now: now.addingTimeInterval(11))
        #expect(counts.invitations == 0)
    }

    @Test("Build mismatch and unknown-code attempts fail closed")
    func onlineAttemptLimits() async throws {
        let fixture = Fixture()
        let authority = try Pairing.Authority(
            configuration: .init(
                maximumFailedAttempts: 2,
                attemptWindow: 30,
                lockoutDuration: 30
            )
        )
        let now = Date(timeIntervalSince1970: 4_000)
        let invitation = try await authority.issue(
            kind: .manual,
            shellIdentity: fixture.shellIdentity,
            now: now
        )
        let mismatched = Fixture(executableUUID: UUID()).request(code: invitation.code)
        await expectFailure(.buildMismatch) {
            _ = try await authority.redeem(
                mismatched,
                rateLimitKey: .init(stableSource: "peer-c"),
                tlsExporterHash: .sha256("mismatch"),
                now: now.addingTimeInterval(1)
            )
        }
        await expectFailure(.attemptLimitReached) {
            _ = try await authority.redeem(
                mismatched,
                rateLimitKey: .init(stableSource: "peer-c"),
                tlsExporterHash: .sha256("mismatch"),
                now: now.addingTimeInterval(2)
            )
        }

        let unknown = try differentCode(from: invitation.code)
        let source = Pairing.RateLimitKey(stableSource: "peer-d")
        await expectFailure(.invalidInvitation) {
            _ = try await authority.redeem(
                fixture.request(code: unknown),
                rateLimitKey: source,
                tlsExporterHash: .sha256("unknown"),
                now: now.addingTimeInterval(3)
            )
        }
        await expectFailure(.invalidInvitation) {
            _ = try await authority.redeem(
                fixture.request(code: unknown),
                rateLimitKey: source,
                tlsExporterHash: .sha256("unknown"),
                now: now.addingTimeInterval(34)
            )
        }
        await expectFailure(.attemptLimitReached) {
            _ = try await authority.redeem(
                fixture.request(code: unknown),
                rateLimitKey: source,
                tlsExporterHash: .sha256("unknown"),
                now: now.addingTimeInterval(35)
            )
        }
    }

    @Test("A lease resumes only the same peer, build, secret, and TLS transcript")
    func leaseResume() async throws {
        let fixture = Fixture()
        let authority = try Pairing.Authority()
        let now = Date(timeIntervalSince1970: 5_000)
        let transcript = Core.Digest.sha256("initial-exporter")
        let invitation = try await authority.issue(
            kind: .manual,
            shellIdentity: fixture.shellIdentity,
            now: now
        )
        let established = try await authority.redeem(
            fixture.request(code: invitation.code),
            rateLimitKey: .init(stableSource: "peer-e"),
            tlsExporterHash: transcript,
            now: now.addingTimeInterval(1)
        )
        let resumeTranscript = Core.Digest.sha256("resume-exporter")
        let request = try Pairing.ResumeRequest.signed(
            leaseID: established.grant.leaseID,
            peerIdentity: fixture.peerIdentity,
            sessionSecret: established.grant.sessionSecret,
            tlsExporterHash: resumeTranscript,
            clientNonce: Data(repeating: 0x19, count: 32)
        )
        let resumed = try await authority.resume(
            request,
            tlsExporterHash: resumeTranscript,
            now: now.addingTimeInterval(2)
        )
        #expect(try resumed.grant.verify(
            request: request,
            tlsExporterHash: resumeTranscript,
            sessionSecret: established.grant.sessionSecret,
            now: now.addingTimeInterval(2)
        ))

        await expectFailure(.invalidLease) {
            _ = try await authority.resume(
                request,
                tlsExporterHash: resumeTranscript,
                now: now.addingTimeInterval(3)
            )
        }

        await expectFailure(.invalidLease) {
            _ = try await authority.resume(
                request,
                tlsExporterHash: .sha256("wrong-exporter"),
                now: now.addingTimeInterval(4)
            )
        }
        let otherPeer = Fixture(peerID: UUID()).peerIdentity
        let forged = try Pairing.ResumeRequest.signed(
            leaseID: established.grant.leaseID,
            peerIdentity: otherPeer,
            sessionSecret: established.grant.sessionSecret,
            tlsExporterHash: resumeTranscript
        )
        await expectFailure(.invalidLease) {
            _ = try await authority.resume(
                forged,
                tlsExporterHash: resumeTranscript,
                now: now.addingTimeInterval(5)
            )
        }
    }
}
}

private struct Fixture {
    let shellIdentity: DevProtocol.ShellIdentity
    let peerIdentity: DevProtocol.PeerIdentity

    init(executableUUID: UUID = UUID(), peerID: UUID = UUID()) {
        let build = DevProtocol.PeerBuildIdentity(
            bundleID: "dev.helix.fixture",
            executableUUID: executableUUID,
            platform: .iOS,
            architecture: "arm64",
            xcodeBuild: "18A1",
            swiftCompilerFingerprint: "swift-fixture",
            liveReloadIndexHash: .sha256("reload-index")
        )
        shellIdentity = .init(shellID: .init(rawValue: UUID()), build: build)
        peerIdentity = .init(
            peerID: .init(rawValue: peerID),
            build: build,
            processID: 42,
            operatingSystemBuild: "23A1",
            supportedBackends: [.hlbc, .nativeDynamicReplacement]
        )
    }

    func request(code: Pairing.Code) -> Pairing.RedeemRequest {
        .init(code: code, peerIdentity: peerIdentity, clientNonce: Data(repeating: 7, count: 32))
    }
}

private func expectFailure(
    _ reason: Pairing.Rejection.Reason,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected pairing failure \(reason.rawValue)")
    } catch let failure as Pairing.Failure {
        #expect(failure.reason == reason)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func differentCode(from code: Pairing.Code) throws -> Pairing.Code {
    for candidate in ["AAAA", "BBBB", "2222"] {
        let value = try Pairing.Code(candidate)
        if value != code { return value }
    }
    throw DevProtocol.Error.secureRandomFailed
}

private extension Data {
    init<T: FixedWidthInteger>(littleEndianBytes value: T) {
        var value = value.littleEndian
        self = Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
}
