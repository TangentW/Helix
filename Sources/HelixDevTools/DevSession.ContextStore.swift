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

    /// Loads and validates a snapshot, or returns an empty list when absent.
    public func load() throws -> [DevSession.BuildContext] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                <= Self.maximumDocumentBytes
        else {
            throw DevSession.ContextError.documentTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumDocumentBytes else {
            throw DevSession.ContextError.documentTooLarge
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            try document.validate()
            return document.contexts
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
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private struct Document: Codable, Sendable {
        static let currentSchemaVersion: UInt16 = 1
        var schemaVersion: UInt16 = Self.currentSchemaVersion
        var contexts: [DevSession.BuildContext]

        func validate() throws {
            guard schemaVersion == Self.currentSchemaVersion,
                  contexts.count <= 4_096,
                  Set(contexts.map(\.shellIdentity.shellID)).count == contexts.count,
                  Set(contexts.map(\.shellIdentity.build)).count == contexts.count
            else {
                throw DevSession.ContextError.invalidDocument(
                    "schema, count, or exact-build uniqueness is invalid"
                )
            }
            try contexts.forEach { try $0.validate() }
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
}
}
