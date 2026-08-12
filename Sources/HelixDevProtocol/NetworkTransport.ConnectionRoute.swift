import Foundation

extension NetworkTransport {
/// Identifies the protocol carried by a newly established Helix TLS connection.
///
/// The preamble is intentionally outside either framed protocol so the single
/// `_helix._tcp` listener can route App pairing and owner-local Hub control
/// without protocol guessing.
public enum ConnectionRoute: Sendable {
    case pairing
    case localControl

    /// Fixed byte count consumed before the first framed message.
    public static let preambleByteCount = 8

    /// Stable, versioned wire preamble.
    public var preamble: Data {
        switch self {
        case .pairing:
            Data([0x48, 0x4c, 0x58, 0x50, 0x41, 0x49, 0x52, 0x01])
        case .localControl:
            Data([0x48, 0x4c, 0x58, 0x43, 0x54, 0x52, 0x4c, 0x01])
        }
    }

    /// Decodes one exact preamble and rejects unknown protocol versions.
    public init(preamble: Data) throws {
        guard preamble.count == Self.preambleByteCount else {
            throw DevProtocol.Error.truncatedFrame
        }
        if preamble == Self.pairing.preamble {
            self = .pairing
        } else if preamble == Self.localControl.preamble {
            self = .localControl
        } else {
            throw DevProtocol.Error.malformedMessage(
                "unknown Helix connection route or protocol version"
            )
        }
    }
}
}
