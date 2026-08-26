import Foundation
import HelixCore

extension XcodeIntegration {
/// Exact input/output identity for the hidden Bridge compiler phase.
public struct BridgeState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let relativePath = "BridgeState.json"

    public struct Object: Codable, Hashable, Sendable {
        public var contentHash: Core.Digest
        public var byteCount: UInt64

        public init(contentHash: Core.Digest, byteCount: UInt64) {
            self.contentHash = contentHash
            self.byteCount = byteCount
        }
    }

    public var schemaVersion: UInt16
    public var inputHash: Core.Digest
    public var bridge: Object
    public var bootstrap: Object

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        inputHash: Core.Digest,
        bridge: Object,
        bootstrap: Object
    ) {
        self.schemaVersion = schemaVersion
        self.inputHash = inputHash
        self.bridge = bridge
        self.bootstrap = bootstrap
    }

    public func validate() throws {
        let maximum = UInt64(512 * 1_024 * 1_024)
        guard schemaVersion == Self.currentSchemaVersion,
              bridge.byteCount > 0,
              bridge.byteCount <= maximum,
              bootstrap.byteCount > 0,
              bootstrap.byteCount <= maximum
        else { throw XcodeIntegration.Error.invalidPlan }
    }
}

public enum BridgeStateCodec {
    public static let maximumDocumentBytes = 64 * 1_024

    public static func encode(_ state: XcodeIntegration.BridgeState) throws -> Data {
        try state.validate()
        return try Core.CanonicalJSON.encode(state)
    }

    public static func decode(_ data: Data) throws -> XcodeIntegration.BridgeState {
        guard data.count <= maximumDocumentBytes else {
            throw XcodeIntegration.Error.invalidPlan
        }
        let state = try JSONDecoder().decode(
            XcodeIntegration.BridgeState.self,
            from: data
        )
        guard try Core.CanonicalJSON.encode(state) == data else {
            throw XcodeIntegration.Error.invalidPlan
        }
        try state.validate()
        return state
    }
}
}
