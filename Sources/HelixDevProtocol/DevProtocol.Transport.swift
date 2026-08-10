import Foundation

extension DevProtocol {
public protocol ByteTransport: Sendable {
    func send(_ bytes: Data) async throws
    func receiveExactly(_ byteCount: Int) async throws -> Data
    func close() async
}

public protocol MessageChannel: Sendable {
    func send(_ message: DevProtocol.Message) async throws
    func receive() async throws -> DevProtocol.Message
    func close() async
}

public actor AuthenticatedChannel<Transport: DevProtocol.ByteTransport> {
    public let transport: Transport
    public let sessionSecret: Data
    public let codec: DevProtocol.FrameCodec

    public init(
        transport: Transport,
        sessionSecret: Data,
        codec: DevProtocol.FrameCodec = .init()
    ) throws {
        try DevProtocol.FrameCodec.validateSecret(sessionSecret)
        self.transport = transport
        self.sessionSecret = sessionSecret
        self.codec = codec
    }

    public func send(_ message: DevProtocol.Message) async throws {
        try await transport.send(codec.encode(message, sessionSecret: sessionSecret))
    }

    public func receive() async throws -> DevProtocol.Message {
        guard codec.maximumMessageBytes > 0 else {
            throw DevProtocol.Error.frameTooLarge
        }
        let prefix = try await transport.receiveExactly(4)
        guard prefix.count == 4 else { throw DevProtocol.Error.truncatedFrame }
        let length = Int(DevProtocol.FrameCodec.readUInt32(prefix[prefix.startIndex..<prefix.endIndex]))
        guard length <= codec.maximumMessageBytes else {
            throw DevProtocol.Error.frameTooLarge
        }
        let tailCount = length.addingReportingOverflow(32)
        guard !tailCount.overflow else { throw DevProtocol.Error.frameTooLarge }
        let tail = try await transport.receiveExactly(tailCount.partialValue)
        guard tail.count == tailCount.partialValue else {
            throw DevProtocol.Error.truncatedFrame
        }
        var frame = prefix
        frame.append(tail)
        return try codec.decode(frame, sessionSecret: sessionSecret)
    }

    public func close() async {
        await transport.close()
    }
}
}

extension DevProtocol.AuthenticatedChannel: DevProtocol.MessageChannel {}
