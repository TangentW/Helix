import CryptoKit
import Foundation
import HelixCore
import HelixDevProtocol
@testable import HelixDevTools
import HelixLiveReloadAPI
import Testing

#if canImport(Network) && canImport(Security)
import Network
import Security
#endif

enum DevToolsTests {}

extension DevToolsTests {
@Suite("Authenticated Dev Protocol")
struct ProtocolLayer {
    @Test("The authenticated channel reads one bounded frame from an arbitrary byte stream")
    func authenticatedStreamChannel() async throws {
        let transport = LoopbackTransport()
        let secret = Data(repeating: 0x42, count: 32)
        let channel = try DevProtocol.AuthenticatedChannel(
            transport: transport,
            sessionSecret: secret
        )
        try await channel.send(.heartbeat(99))
        #expect(try await channel.receive() == .heartbeat(99))
        await channel.close()
    }

    #if canImport(Network) && canImport(Security)
    @Test("Pinned TLS identity exports the same channel binding on both peers")
    func pinnedTLSExporter() async throws {
        let identity = try NetworkTransport.IdentityFactory.makeServerIdentity()
        let parameters = try NetworkTransport.ByteTransport.tlsServerParameters(
            identity: identity.identity
        )
        let listener = try NetworkTransport.Listener(parameters: parameters) { transport in
            if let exporter = try? transport.tlsExporterHash() {
                try? await transport.send(exporter.data)
            }
            await transport.close()
        }
        try await listener.start()
        defer { listener.cancel() }
        let port = try #require(listener.port)
        let client = NetworkTransport.ByteTransport.pinnedTLSClient(
            host: "127.0.0.1",
            port: port,
            expectedSPKIHash: identity.spkiHash
        )
        try await client.start()
        defer { Task { await client.close() } }
        let clientExporter = try client.tlsExporterHash()
        let serverExporter = try Core.Digest(
            bytes: await client.receiveExactly(Core.Digest.byteCount)
        )
        #expect(serverExporter == clientExporter)
        #expect(identity.validUntil > Date())
    }
    #endif

    @Test("Liveness timeout closes a blocked channel and reports a stable error")
    func livenessTimeout() async throws {
        let channel = BlockingMessageChannel()
        let configuration = DevProtocol.LivenessConfiguration(
            heartbeatIntervalNanoseconds: 1_000_000,
            receiveTimeoutNanoseconds: 5_000_000
        )
        await #expect(throws: DevProtocol.Error.sessionTimedOut) {
            _ = try await DevProtocol.Liveness.receive(
                from: channel,
                configuration: configuration
            )
        }
        #expect(await channel.isClosed)
        #expect(throws: DevProtocol.Error.self) {
            try DevProtocol.LivenessConfiguration(
                heartbeatIntervalNanoseconds: 5,
                receiveTimeoutNanoseconds: 5
            ).validate()
        }
    }

    @Test("The session inbox filters heartbeat acknowledgements")
    func inboxFiltersHeartbeat() async throws {
        let diagnostic = DevProtocol.Diagnostic(
            code: "HLXLR299",
            message: "fixture diagnostic",
            nextAction: "continue"
        )
        let channel = ScriptedMessageChannel(
            messages: [.heartbeat(7), .diagnostics([diagnostic])]
        )
        let inbox = DevSession.Inbox()
        try await inbox.start(
            channel: channel,
            liveness: .init(
                heartbeatIntervalNanoseconds: 10_000_000,
                receiveTimeoutNanoseconds: 100_000_000
            ),
            terminalHandler: { _ in }
        )
        #expect(try await inbox.receive() == .diagnostics([diagnostic]))
        await inbox.stop()
        await channel.close()
    }

    @Test("Failed pipeline diagnostics are forwarded to the authenticated App")
    func forwardsPipelineDiagnostics() async throws {
        let diagnostic = DevProtocol.Diagnostic(
            code: "HLXLR299",
            message: "fixture compile failure",
            sourceRevision: .init(rawValue: 1),
            nextAction: "correct the source"
        )
        #expect(
            DevSession.PipelineResult.failed(diagnostic)
                .diagnosticsForApp == [diagnostic]
        )
        #expect(
            DevSession.PipelineResult.rebuildRequired(diagnostic)
                .diagnosticsForApp == [diagnostic]
        )
        #expect(
            DevSession.PipelineResult.noSemanticChange(.init(rawValue: 1))
                .diagnosticsForApp == nil
        )

        let fixture = try ProtocolFixture()
        let secret = Data(repeating: 0x4d, count: 32)
        let channel = ScriptedMessageChannel(
            messages: [
                .hello(
                    identity: fixture.identity,
                    clientNonce: Data(repeating: 0x21, count: 16)
                ),
            ]
        )
        let session = try DevSession.Controller(
            expectedIdentity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: .sha256("diagnostic-forwarding"),
            liveness: .init(
                heartbeatIntervalNanoseconds: 2_000_000,
                receiveTimeoutNanoseconds: 20_000_000
            )
        )
        try await session.accept(channel: channel)
        try await session.sendDiagnostics([diagnostic])

        #expect((await channel.sentMessages).contains(.diagnostics([diagnostic])))
        await session.close(reason: "fixture complete")
    }

    @Test("Session close remains bounded when the peer never acknowledges")
    func closeHandshakeTimesOut() async throws {
        let fixture = try ProtocolFixture()
        let secret = Data(repeating: 0x24, count: 32)
        let channel = ScriptedMessageChannel(
            messages: [
                .hello(
                    identity: fixture.identity,
                    clientNonce: Data(repeating: 0x11, count: 16)
                ),
            ]
        )
        let session = try DevSession.Controller(
            expectedIdentity: fixture.identity,
            sessionSecret: secret,
            tlsTranscriptHash: .sha256("close-timeout"),
            liveness: .init(
                heartbeatIntervalNanoseconds: 2_000_000,
                receiveTimeoutNanoseconds: 20_000_000
            )
        )
        try await session.accept(channel: channel)

        let clock = ContinuousClock()
        let start = clock.now
        await session.close(reason: "fixture complete")
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .milliseconds(500))
        #expect((await session.snapshot()).state == .closed)
        #expect(await channel.isClosed)
        let sent = await channel.sentMessages
        #expect(sent.contains { message in
            guard case let .sessionClose(reason) = message else { return false }
            return reason == "fixture complete"
        })
    }

    @Test("Frames and .hlxlive artifacts are canonical, authenticated, and session-bound")
    func frameAndArtifactRoundTrip() throws {
        let fixture = try ProtocolFixture()
        let secret = Data(repeating: 0x77, count: 32)
        let context = LiveReload.Context(
            generationID: 3,
            sourceRevision: 9,
            changedSources: [fixture.sourceID],
            changedFunctions: [fixture.functionKey],
            backend: .hlbc
        )
        let message = DevProtocol.Message.reloadRequest(context)
        let codec = DevProtocol.FrameCodec()
        let frame = try codec.encode(message, sessionSecret: secret)
        #expect(try codec.decode(frame, sessionSecret: secret) == message)
        let closeAck = try codec.encode(.sessionCloseAcknowledged, sessionSecret: secret)
        #expect(
            try codec.decode(closeAck, sessionSecret: secret)
                == .sessionCloseAcknowledged
        )

        var tampered = frame
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        #expect(throws: DevProtocol.Error.invalidAuthentication) {
            _ = try codec.decode(tampered, sessionSecret: secret)
        }

        let payload = Data("hlbc-dev-payload".utf8)
        let offer = fixture.offer(payload: payload)
        let artifact = DevProtocol.LiveArtifact(offer: offer, payload: payload)
        let encoded = try artifact.encoded(sessionSecret: secret)
        let decoded = try DevProtocol.LiveArtifact.decode(encoded, sessionSecret: secret)
        #expect(decoded.offer == offer)
        #expect(decoded.payload == payload)
        #expect(encoded.prefix(8) == DevProtocol.LiveArtifact.magic)
    }

    @Test("Handshake proof binds both nonces, the build identity, and TLS transcript")
    func handshakeProof() throws {
        let fixture = try ProtocolFixture()
        let secret = Data(repeating: 0x31, count: 32)
        let client = Data(repeating: 0x11, count: 16)
        let server = Data(repeating: 0x22, count: 16)
        let transcript = Core.Digest.sha256("tls-transcript")
        let proof = try DevProtocol.Handshake.proof(
            sessionSecret: secret,
            clientNonce: client,
            serverNonce: server,
            identity: fixture.identity,
            tlsTranscriptHash: transcript
        )
        #expect(
            try DevProtocol.Handshake.verify(
                proof: proof,
                sessionSecret: secret,
                clientNonce: client,
                serverNonce: server,
                identity: fixture.identity,
                tlsTranscriptHash: transcript
            )
        )
        #expect(
            try !DevProtocol.Handshake.verify(
                proof: proof,
                sessionSecret: secret,
                clientNonce: client,
                serverNonce: Data(repeating: 0x23, count: 16),
                identity: fixture.identity,
                tlsTranscriptHash: transcript
            )
        )
    }

    @Test("Authenticated framing rejects noncanonical JSON and bounded-input abuse")
    func rejectsAuthenticatedNoncanonicalFrame() throws {
        let secret = Data(repeating: 0x4a, count: 32)
        let message = DevProtocol.Message.heartbeat(7)
        let canonical = try Core.CanonicalJSON.encode(message)
        let object = try JSONSerialization.jsonObject(with: canonical)
        let noncanonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(noncanonical != canonical)
        var frame = Data()
        appendLittleEndian(UInt32(noncanonical.count), to: &frame)
        frame.append(noncanonical)
        frame.append(authenticationTag(
            domain: "HLX.DevFrame.v1",
            body: noncanonical,
            secret: secret
        ))
        #expect(throws: DevProtocol.Error.nonCanonicalMessage) {
            _ = try DevProtocol.FrameCodec().decode(frame, sessionSecret: secret)
        }
        #expect(throws: DevProtocol.Error.frameTooLarge) {
            _ = try DevProtocol.FrameCodec(maximumMessageBytes: 2).encode(
                message,
                sessionSecret: secret
            )
        }
        #expect(throws: DevProtocol.Error.invalidSecretLength) {
            _ = try DevProtocol.FrameCodec().encode(
                message,
                sessionSecret: Data(repeating: 1, count: 4_097)
            )
        }
        #expect(throws: DevProtocol.Error.invalidNonceLength) {
            _ = try DevProtocol.Handshake.proof(
                sessionSecret: secret,
                clientNonce: Data(repeating: 1, count: 65),
                serverNonce: Data(repeating: 2, count: 16),
                identity: try ProtocolFixture().identity,
                tlsTranscriptHash: .sha256("transcript")
            )
        }
    }

    @Test("Artifact authentication binds manifest and payload boundaries")
    func authenticatesArtifactBoundaries() throws {
        let fixture = try ProtocolFixture()
        let secret = Data(repeating: 0x71, count: 32)
        let payload = Data("boundary-sensitive-payload".utf8)
        let artifact = DevProtocol.LiveArtifact(
            offer: fixture.offer(payload: payload),
            payload: payload
        )
        var encoded = try artifact.encoded(sessionSecret: secret)
        let manifestLength = readLittleEndianUInt32(encoded[10..<14])
        let payloadLength = readLittleEndianUInt64(encoded[14..<22])
        #expect(payloadLength > 1)
        writeLittleEndian(manifestLength + 1, into: &encoded, at: 10)
        writeLittleEndian(payloadLength - 1, into: &encoded, at: 14)
        #expect(throws: DevProtocol.Error.invalidAuthentication) {
            _ = try DevProtocol.LiveArtifact.decode(encoded, sessionSecret: secret)
        }
    }

    @Test("Patch offer validation rejects duplicate roots and malformed restore/native modes")
    func validatesOfferSemantics() throws {
        let fixture = try ProtocolFixture()
        let payload = Data("payload".utf8)
        var duplicate = fixture.offer(payload: payload)
        duplicate.changedFunctions.append(fixture.functionKey)
        #expect(throws: DevProtocol.Error.self) {
            try duplicate.validate()
        }

        var malformedRestore = fixture.offer(payload: payload)
        malformedRestore.mode = .restoreOriginals
        malformedRestore.restoredFunctions = malformedRestore.changedFunctions
        #expect(throws: DevProtocol.Error.self) {
            try malformedRestore.validate()
        }

        var native = fixture.offer(payload: payload)
        native.backend = .nativeDynamicReplacement
        #expect(throws: DevProtocol.Error.self) {
            try native.validate()
        }
        native.debugSymbolsUUID = UUID()
        try native.validate()
        native.restoredFunctions = native.changedFunctions
        try native.validate()
    }
}
}

private func authenticationTag(domain: String, body: Data, secret: Data) -> Data {
    var hasher = Core.StableHasher(domain: domain)
    hasher.append(body)
    return Data(
        HMAC<SHA256>.authenticationCode(
            for: hasher.finalize().data,
            using: SymmetricKey(data: secret)
        )
    )
}

private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 0, through: 24, by: 8) {
        data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
    }
}

private func readLittleEndianUInt32(_ data: Data.SubSequence) -> UInt32 {
    data.enumerated().reduce(UInt32(0)) {
        $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
}

private func readLittleEndianUInt64(_ data: Data.SubSequence) -> UInt64 {
    data.enumerated().reduce(UInt64(0)) {
        $0 | (UInt64($1.element) << UInt64($1.offset * 8))
    }
}

private func writeLittleEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
    for byteOffset in 0..<4 {
        data[offset + byteOffset] = UInt8(
            truncatingIfNeeded: value >> UInt32(byteOffset * 8)
        )
    }
}

private func writeLittleEndian(_ value: UInt64, into data: inout Data, at offset: Int) {
    for byteOffset in 0..<8 {
        data[offset + byteOffset] = UInt8(
            truncatingIfNeeded: value >> UInt64(byteOffset * 8)
        )
    }
}

extension DevToolsTests {
private actor LoopbackTransport: DevProtocol.ByteTransport {
    private var bytes = Data()
    private var isClosed = false

    func send(_ bytes: Data) throws {
        guard !isClosed else { throw DevProtocol.Error.truncatedFrame }
        self.bytes.append(bytes)
    }

    func receiveExactly(_ byteCount: Int) throws -> Data {
        guard !isClosed, byteCount >= 0, bytes.count >= byteCount else {
            throw DevProtocol.Error.truncatedFrame
        }
        let value = bytes.prefix(byteCount)
        bytes.removeFirst(byteCount)
        return Data(value)
    }

    func close() {
        isClosed = true
        bytes.removeAll()
    }
}

private actor BlockingMessageChannel: DevProtocol.MessageChannel {
    private var waiter: CheckedContinuation<DevProtocol.Message, any Swift.Error>?
    private(set) var isClosed = false

    func send(_ message: DevProtocol.Message) throws {}

    func receive() async throws -> DevProtocol.Message {
        guard !isClosed, waiter == nil else { throw DevProtocol.Error.truncatedFrame }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() {
        isClosed = true
        waiter?.resume(throwing: DevProtocol.Error.truncatedFrame)
        waiter = nil
    }
}

private actor ScriptedMessageChannel: DevProtocol.MessageChannel {
    private var messages: [DevProtocol.Message]
    private(set) var isClosed = false
    private var waiter: CheckedContinuation<DevProtocol.Message, any Swift.Error>?
    private(set) var sentMessages: [DevProtocol.Message] = []

    init(messages: [DevProtocol.Message]) {
        self.messages = messages
    }

    func send(_ message: DevProtocol.Message) throws {
        guard !isClosed else { throw DevProtocol.Error.truncatedFrame }
        sentMessages.append(message)
    }

    func receive() async throws -> DevProtocol.Message {
        guard !isClosed, waiter == nil else { throw DevProtocol.Error.truncatedFrame }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() {
        isClosed = true
        waiter?.resume(throwing: DevProtocol.Error.truncatedFrame)
        waiter = nil
    }
}

private struct ProtocolFixture {
    let sessionID = UUID(uuidString: "866810BE-D54D-46EC-927C-68673B74C11C")!
    let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Sources/Profile.swift")
    let functionKey: Core.FunctionKey
    let identity: DevProtocol.SessionIdentity

    init() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.live",
            buildNumber: "1",
            seed: "protocol"
        )
        functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Profile",
            sourceFileLogicalID: "Sources/Profile.swift",
            canonicalDeclaration: "func render()",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
        identity = .init(
            sessionID: sessionID,
            bundleID: "dev.helix.live",
            executableUUID: UUID(uuidString: "FC852B22-02CB-432C-B7F5-5654EF2314E0")!,
            processID: 42,
            platform: .iOSSimulator,
            architecture: "arm64",
            operatingSystemBuild: "22A",
            xcodeBuild: "17F113",
            swiftCompilerFingerprint: "swift-6.3.3",
            liveReloadIndexHash: .sha256("index"),
            supportedBackends: [.hlbc, .nativeDynamicReplacement],
            nativeChainingProbePassed: true
        )
    }

    func offer(payload: Data) -> DevProtocol.PatchOffer {
        .init(
            sessionID: sessionID,
            sourceRevision: .init(rawValue: 9),
            generationID: .init(rawValue: 3),
            backend: .hlbc,
            payloadByteLength: UInt64(payload.count),
            payloadSHA256: .sha256(payload),
            changedSources: [sourceID],
            changedFunctions: [functionKey]
        )
    }
}
}
