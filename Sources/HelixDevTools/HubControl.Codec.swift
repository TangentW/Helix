#if os(macOS)
import Foundation
import HelixCore
import HelixDevProtocol

extension HubControl {
/// Canonical, bounded framing for owner-local control messages.
public struct FrameCodec: Sendable {
    public var maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    public func encode(_ request: HubControl.Request) throws -> Data {
        try request.validate()
        return try encodeCanonical(request)
    }

    public func encode(_ response: HubControl.Response) throws -> Data {
        try response.validate()
        return try encodeCanonical(response)
    }

    public func decodeRequest(_ frame: Data) throws -> HubControl.Request {
        let body = try decodeBody(frame)
        let value: HubControl.Request
        do {
            value = try JSONDecoder().decode(HubControl.Request.self, from: body)
        } catch {
            throw HubControl.Error.invalidMessage
        }
        guard try Core.CanonicalJSON.encode(value) == body else {
            throw HubControl.Error.nonCanonicalMessage
        }
        try value.validate()
        return value
    }

    public func decodeResponse(_ frame: Data) throws -> HubControl.Response {
        let body = try decodeBody(frame)
        let value: HubControl.Response
        do {
            value = try JSONDecoder().decode(HubControl.Response.self, from: body)
        } catch {
            throw HubControl.Error.invalidMessage
        }
        guard try Core.CanonicalJSON.encode(value) == body else {
            throw HubControl.Error.nonCanonicalMessage
        }
        try value.validate()
        return value
    }

    private func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        guard maximumMessageBytes > 0 else {
            throw HubControl.Error.invalidConfiguration
        }
        let body = try Core.CanonicalJSON.encode(value)
        guard body.count <= maximumMessageBytes, body.count <= Int(UInt32.max) else {
            throw DevProtocol.Error.frameTooLarge
        }
        var result = Data()
        append(UInt32(body.count), to: &result)
        result.append(body)
        return result
    }

    private func decodeBody(_ frame: Data) throws -> Data {
        guard maximumMessageBytes > 0 else {
            throw HubControl.Error.invalidConfiguration
        }
        guard frame.count >= 4 else { throw DevProtocol.Error.truncatedFrame }
        let length = Int(readUInt32(frame.prefix(4)))
        guard length <= maximumMessageBytes else { throw DevProtocol.Error.frameTooLarge }
        guard frame.count == 4 + length else { throw DevProtocol.Error.truncatedFrame }
        return frame.subdata(in: 4..<frame.count)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    fileprivate func readUInt32(_ data: Data.SubSequence) -> UInt32 {
        data.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }
}

/// Sends and receives control frames over the same TLS transport as App pairing.
public actor Channel<Transport: DevProtocol.ByteTransport> {
    public let transport: Transport
    public let codec: HubControl.FrameCodec

    public init(transport: Transport, codec: HubControl.FrameCodec = .init()) {
        self.transport = transport
        self.codec = codec
    }

    public func send(_ request: HubControl.Request) async throws {
        try await transport.send(codec.encode(request))
    }

    public func send(_ response: HubControl.Response) async throws {
        try await transport.send(codec.encode(response))
    }

    public func receiveRequest() async throws -> HubControl.Request {
        try codec.decodeRequest(await receiveFrame())
    }

    public func receiveResponse() async throws -> HubControl.Response {
        try codec.decodeResponse(await receiveFrame())
    }

    public func close() async {
        await transport.close()
    }

    private func receiveFrame() async throws -> Data {
        let header = try await transport.receiveExactly(4)
        let length = Int(codec.readUInt32(header.prefix(4)))
        guard length <= codec.maximumMessageBytes else {
            throw DevProtocol.Error.frameTooLarge
        }
        let body = try await transport.receiveExactly(length)
        return header + body
    }
}
}
#endif
