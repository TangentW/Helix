import Foundation
import HelixCore

extension XcodeIntegration {
/// A verified shortcut for unchanged Prepare inputs and output artifacts.
/// Live Reload separately asks Hub whether its embedded reservation remains
/// authoritative before reusing or refreshing invitation-specific outputs.
public struct PrepareState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let relativePath = "PrepareState.json"

    public struct Artifact: Codable, Hashable, Sendable {
        public var path: String
        public var contentHash: Core.Digest
        public var byteCount: UInt64
        public var permissions: UInt16

        public init(
            path: String,
            contentHash: Core.Digest,
            byteCount: UInt64,
            permissions: UInt16
        ) {
            self.path = path
            self.contentHash = contentHash
            self.byteCount = byteCount
            self.permissions = permissions
        }
    }

    public var schemaVersion: UInt16
    public var inputHash: Core.Digest
    public var artifacts: [Artifact]
    public var eligibleFunctionCount: UInt32
    public var rejectedFunctionCount: UInt32
    /// Additive informational field; older states omit it. Input hashes bind
    /// the indexing policy independently of these display counts.
    public var excludedDeclarationCount: UInt32?
    /// A background Catalog was missing when these artifacts were published.
    /// The next Prepare must recheck the cache instead of treating this Shell
    /// as the final no-op result for otherwise identical inputs.
    public var requiresNativeAPICatalogRefresh: Bool

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        inputHash: Core.Digest,
        artifacts: [Artifact],
        eligibleFunctionCount: UInt32,
        rejectedFunctionCount: UInt32,
        requiresNativeAPICatalogRefresh: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.inputHash = inputHash
        self.artifacts = artifacts.sorted { $0.path < $1.path }
        self.eligibleFunctionCount = eligibleFunctionCount
        self.rejectedFunctionCount = rejectedFunctionCount
        self.excludedDeclarationCount = nil
        self.requiresNativeAPICatalogRefresh =
            requiresNativeAPICatalogRefresh
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !artifacts.isEmpty,
              artifacts.count <= 100_000,
              artifacts == artifacts.sorted(by: { $0.path < $1.path }),
              Set(artifacts.map(\.path)).count == artifacts.count,
              artifacts.allSatisfy({ artifact in
                  Self.isSafeRelativePath(artifact.path)
                      && artifact.byteCount <= UInt64(512 * 1_024 * 1_024)
                      && [UInt16(0o600), 0o644, 0o755]
                          .contains(artifact.permissions)
              })
        else {
            throw XcodeIntegration.Error.invalidPlan
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public enum PrepareStateCodec {
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024

    public static func encode(_ state: XcodeIntegration.PrepareState) throws -> Data {
        try state.validate()
        return try Core.CanonicalJSON.encode(state)
    }

    public static func decode(_ data: Data) throws -> XcodeIntegration.PrepareState {
        guard data.count <= maximumDocumentBytes else {
            throw XcodeIntegration.Error.invalidPlan
        }
        let state = try JSONDecoder().decode(
            XcodeIntegration.PrepareState.self,
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
