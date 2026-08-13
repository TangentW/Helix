import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Pairing {
/// Canonical, length-prefixed framing used before a session secret exists.
public struct FrameCodec: Sendable {
    /// Maximum accepted JSON body size.
    public var maximumMessageBytes: Int

    /// Creates a codec with a bounded message size.
    public init(maximumMessageBytes: Int = 64 * 1_024) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    /// Encodes one validated pairing message.
    public func encode(_ message: Pairing.Message) throws -> Data {
        guard maximumMessageBytes > 0 else { throw DevProtocol.Error.frameTooLarge }
        try message.validate()
        let body = try Core.CanonicalJSON.encode(message)
        guard body.count <= maximumMessageBytes, body.count <= Int(UInt32.max) else {
            throw DevProtocol.Error.frameTooLarge
        }
        var frame = Data()
        DevProtocol.FrameCodec.append(UInt32(body.count), to: &frame)
        frame.append(body)
        return frame
    }

    /// Decodes exactly one complete canonical frame.
    public func decode(_ frame: Data) throws -> Pairing.Message {
        guard maximumMessageBytes > 0 else { throw DevProtocol.Error.frameTooLarge }
        guard frame.count >= 4 else { throw DevProtocol.Error.truncatedFrame }
        let length = Int(DevProtocol.FrameCodec.readUInt32(frame.prefix(4)))
        guard length <= maximumMessageBytes else { throw DevProtocol.Error.frameTooLarge }
        guard frame.count == 4 + length else { throw DevProtocol.Error.truncatedFrame }
        let body = frame.dropFirst(4)
        let message: Pairing.Message
        do {
            message = try JSONDecoder().decode(Pairing.Message.self, from: body)
        } catch {
            throw DevProtocol.Error.malformedMessage(String(describing: error))
        }
        guard try Core.CanonicalJSON.encode(message) == body else {
            throw DevProtocol.Error.nonCanonicalMessage
        }
        try message.validate()
        return message
    }
}

/// Serializes pairing messages over a byte transport.
public actor Channel<Transport: DevProtocol.ByteTransport> {
    /// Underlying TLS byte transport.
    public let transport: Transport
    /// Framing policy used by the channel.
    public let codec: Pairing.FrameCodec

    public init(transport: Transport, codec: Pairing.FrameCodec = .init()) {
        self.transport = transport
        self.codec = codec
    }

    /// Sends one pairing message.
    public func send(_ message: Pairing.Message) async throws {
        try await transport.send(codec.encode(message))
    }

    /// Receives one complete pairing message.
    public func receive() async throws -> Pairing.Message {
        let header = try await transport.receiveExactly(4)
        let length = Int(DevProtocol.FrameCodec.readUInt32(header.prefix(4)))
        guard length <= codec.maximumMessageBytes else {
            throw DevProtocol.Error.frameTooLarge
        }
        let body = try await transport.receiveExactly(length)
        return try codec.decode(header + body)
    }

    /// Closes the underlying transport.
    public func close() async {
        await transport.close()
    }
}
}
