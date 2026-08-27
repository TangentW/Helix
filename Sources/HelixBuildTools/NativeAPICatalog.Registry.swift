import HelixCore

extension NativeAPICatalog {
/// Immutable merged view of cached SDK, dependency, application, and builtin
/// catalogs. Every index resolves back to the same stable `NativeCall.Key`.
public struct Registry: Sendable {
    private let entriesByKey: [
        Core.NativeCall.Key: NativeAPICatalog.Entry
    ]
    private let keysBySwiftName: [String: [Core.NativeCall.Key]]
    private let keysByCompilerSymbol: [String: [Core.NativeCall.Key]]
    private let keysByEntryPoint: [EntryPointIndex: [Core.NativeCall.Key]]

    public init(documents: [NativeAPICatalog.Document]) throws {
        try self.init(documents: documents, validatesDocuments: true)
    }

    init(validatedDocuments documents: [NativeAPICatalog.Document]) throws {
        try self.init(documents: documents, validatesDocuments: false)
    }

    private init(
        documents: [NativeAPICatalog.Document],
        validatesDocuments: Bool
    ) throws {
        var entriesByKey: [
            Core.NativeCall.Key: NativeAPICatalog.Entry
        ] = [:]
        var documentByIdentity: [
            Core.Digest: NativeAPICatalog.Document
        ] = [:]
        for document in documents.sorted(by: {
            $0.identity.cacheKey < $1.identity.cacheKey
        }) {
            if validatesDocuments { try document.validate() }
            let identity = document.identity.cacheKey
            if let existing = documentByIdentity[identity] {
                guard existing == document else {
                    throw NativeAPICatalog.Error.conflictingDocumentIdentity(
                        identity
                    )
                }
                // Multiple dependency paths can legitimately reach the same
                // immutable Catalog snapshot. Loading it remains idempotent.
                continue
            }
            documentByIdentity[identity] = document
            for entry in document.entries {
                if let existing = entriesByKey[entry.key] {
                    guard existing == entry else {
                        throw NativeAPICatalog.Error.conflictingEntry(entry.key)
                    }
                } else {
                    entriesByKey[entry.key] = entry
                }
            }
        }
        self.entriesByKey = entriesByKey

        var keysBySwiftName: [String: Set<Core.NativeCall.Key>] = [:]
        var keysByCompilerSymbol: [String: Set<Core.NativeCall.Key>] = [:]
        var keysByEntryPoint: [EntryPointIndex: Set<Core.NativeCall.Key>] = [:]
        for entry in entriesByKey.values {
            for name in entry.swiftNames {
                keysBySwiftName[name, default: []].insert(entry.key)
            }
            for symbol in entry.compilerSymbols {
                keysByCompilerSymbol[symbol, default: []].insert(entry.key)
            }
            let index = EntryPointIndex(
                backend: entry.descriptor.target.backend,
                module: entry.descriptor.target.module,
                owner: entry.descriptor.target.owner,
                entryPoint: entry.descriptor.target.entryPoint
            )
            keysByEntryPoint[index, default: []].insert(entry.key)
        }
        self.keysBySwiftName = keysBySwiftName.mapValues { $0.sorted() }
        self.keysByCompilerSymbol = keysByCompilerSymbol.mapValues { $0.sorted() }
        self.keysByEntryPoint = keysByEntryPoint.mapValues { $0.sorted() }
    }

    public var count: Int { entriesByKey.count }

    public subscript(
        key: Core.NativeCall.Key
    ) -> NativeAPICatalog.Entry? {
        entriesByKey[key]
    }

    public func entries(
        swiftName: String
    ) -> [NativeAPICatalog.Entry] {
        (keysBySwiftName[swiftName] ?? []).compactMap { entriesByKey[$0] }
    }

    public func entries(
        compilerSymbol: String
    ) -> [NativeAPICatalog.Entry] {
        (keysByCompilerSymbol[compilerSymbol] ?? []).compactMap {
            entriesByKey[$0]
        }
    }

    public func entries(
        backend: Core.NativeCall.Backend,
        module: String,
        owner: String? = nil,
        entryPoint: String
    ) -> [NativeAPICatalog.Entry] {
        let index = EntryPointIndex(
            backend: backend,
            module: module,
            owner: owner,
            entryPoint: entryPoint
        )
        return (keysByEntryPoint[index] ?? []).compactMap { entriesByKey[$0] }
    }

    public func resolve(
        descriptor: Core.NativeCall.Descriptor
    ) throws -> NativeAPICatalog.Entry? {
        let canonical = try descriptor.canonicalized()
        let key = try Core.NativeCall.Key.derive(descriptor: canonical)
        guard let entry = entriesByKey[key] else { return nil }
        guard entry.descriptor == canonical else {
            // SHA-256 collisions are not an accepted ambiguity at this trust
            // boundary even though they are computationally infeasible.
            throw NativeAPICatalog.Error.conflictingEntry(key)
        }
        return entry
    }

    private struct EntryPointIndex: Hashable, Sendable {
        var backend: Core.NativeCall.Backend
        var module: String
        var owner: String?
        var entryPoint: String
    }
}
}
