import Foundation
import HelixCore

extension DevSession {
/// Canonical on-disk persistence for ``ContextRegistry`` snapshots.
public struct ContextStore: Sendable {
    /// Hard bound applied before and after reading a registry document.
    public static let maximumDocumentBytes = 4 * 1_024 * 1_024

    /// Canonical registry-document location.
    public let url: URL

    /// Creates a store at an explicit location.
    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// Creates the per-user store used by the long-running Helix service.
    public static func applicationSupportStore() throws -> Self {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DevSession.ContextError.invalidDocument(
                "the user Application Support directory is unavailable"
            )
        }
        return .init(
            url: root
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent("BuildContexts.json", isDirectory: false)
        )
    }

    /// Loads and validates a snapshot, or returns an empty list when absent.
    public func load() throws -> [DevSession.BuildContext] {
        guard let document = try loadDocument() else { return [] }
        try document.validate()
        return document.contexts
    }

    /// Removes only Build Contexts written by the obsolete pre-release
    /// protocols, then atomically persists the remaining current contexts.
    /// Unknown versions and malformed current data still fail closed.
    func loadRecoveringObsoleteProtocols() throws -> [DevSession.BuildContext] {
        guard var document = try loadDocument() else { return [] }
        try document.validateEnvelope()
        let originalCount = document.contexts.count
        document.contexts.removeAll {
            Self.obsoletePreReleaseProtocolVersions.contains(
                $0.shellIdentity.build.protocolVersion
            )
        }
        try document.validate()
        guard document.contexts.count != originalCount else { return document.contexts }

        let retained = document.contexts.sorted(by: Document.newestFirst)
        try save(retained)
        return retained
    }

    private func loadDocument() throws -> Document? {
        let data: Data
        do {
            data = try SecureStorage.OwnerFile.read(
                from: url,
                maximumBytes: Self.maximumDocumentBytes
            )
        } catch SecureStorage.OwnerFile.Error.unavailable {
            return nil
        } catch SecureStorage.OwnerFile.Error.tooLarge {
            throw DevSession.ContextError.documentTooLarge
        } catch {
            throw DevSession.ContextError.invalidDocument(
                "the context store must be an owner-only regular file"
            )
        }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch let error as DevSession.ContextError {
            throw error
        } catch {
            throw DevSession.ContextError.invalidDocument(String(describing: error))
        }
    }

    /// Atomically writes a canonical, owner-only snapshot.
    public func save(_ contexts: [DevSession.BuildContext]) throws {
        let document = Document(contexts: contexts.sorted(by: Document.newestFirst))
        try document.validate()
        let data = try Core.CanonicalJSON.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw DevSession.ContextError.documentTooLarge
        }
        do {
            try SecureStorage.OwnerFile.write(
                data,
                to: url,
                maximumBytes: Self.maximumDocumentBytes
            )
        } catch {
            throw DevSession.ContextError.invalidDocument(
                "cannot atomically persist the owner-only context store"
            )
        }
    }

    private struct Document: Codable, Sendable {
        static let currentSchemaVersion: UInt16 = 1
        var schemaVersion: UInt16 = Self.currentSchemaVersion
        var contexts: [DevSession.BuildContext]

        func validate() throws {
            try validateEnvelope()
            guard Set(contexts.map(\.shellIdentity.shellID)).count == contexts.count,
                  Set(contexts.map(\.shellIdentity.build)).count == contexts.count
            else {
                throw DevSession.ContextError.invalidDocument(
                    "shell or exact-build uniqueness is invalid"
                )
            }
            try contexts.forEach { try $0.validate() }
        }

        func validateEnvelope() throws {
            guard schemaVersion == Self.currentSchemaVersion,
                  contexts.count <= 4_096
            else {
                throw DevSession.ContextError.invalidDocument(
                    "schema or count is invalid"
                )
            }
        }

        static func newestFirst(
            _ lhs: DevSession.BuildContext,
            _ rhs: DevSession.BuildContext
        ) -> Bool {
            if lhs.registeredAt != rhs.registeredAt { return lhs.registeredAt > rhs.registeredAt }
            return lhs.shellIdentity.shellID.rawValue.uuidString
                < rhs.shellIdentity.shellID.rawValue.uuidString
        }
    }

    // These identifiers shipped only in local pre-release builds. Their
    // exact-build identities cannot be relabeled as protocol 1 safely.
    private static let obsoletePreReleaseProtocolVersions: Set<UInt16> = [2, 3]
}
}
