import Foundation
import HelixBuildTools
import HelixLiveReloadAPI

extension DevBuildManifest {
/// Host-only policy bound to the manifest's immutable source identities/hashes.
/// Schema 2 prevents an older host from silently ignoring excluded-save guards.
public struct IndexingPolicy: Codable, Hashable, Sendable {
    public var options: FrontendReceipt.IndexingOptions
    public var excludedSourceIDs: [LiveReload.SourceFileID]

    public init(options: FrontendReceipt.IndexingOptions, excludedSourceIDs: [LiveReload.SourceFileID]) {
        self.options = options
        self.excludedSourceIDs = Array(Set(excludedSourceIDs)).sorted { $0.rawValue < $1.rawValue }
    }

    func validate(sources: [DevBuildManifest.SourceFile]) throws {
        try options.validate()
        let known = Set(sources.map(\.id))
        let excluded = Set(excludedSourceIDs)
        var failures: [String] = []
        if excludedSourceIDs != excluded.sorted(by: { $0.rawValue < $1.rawValue }) {
            failures.append("excluded source IDs must be sorted and unique: \(excludedSourceIDs.map { $0.rawValue.hex })")
        }
        let unknown = excluded.subtracting(known)
        if !unknown.isEmpty { failures.append("source IDs absent from manifest: \(unknown.map { $0.rawValue.hex }.sorted())") }
        let missing = sources.filter { !options.includes(logicalPath: $0.logicalPath) && !excluded.contains($0.id) }.map(\.logicalPath).sorted()
        if !missing.isEmpty { failures.append("unprotected paths outside indexing scope: \(missing)") }
        if !failures.isEmpty {
            throw BuildCapture.Error.invalidManifest(failures.joined(separator: "; "))
        }
    }
}
}

extension DevBuildManifest.Document {
    /// The legacy initializer/encoding remains schema 1. Nondefault indexing
    /// explicitly opts this host manifest into schema 2; runtime wire is unchanged.
    public mutating func configureIndexing(
        _ options: FrontendReceipt.IndexingOptions,
        excludedSourcePaths: Set<String>
    ) throws {
        try options.validate()
        guard options.failurePolicy == .excludeUnresolved || excludedSourcePaths.isEmpty else {
            throw BuildCapture.Error.invalidManifest("strict indexing policy conflicts with unresolved exclusion diagnostics at \(excludedSourcePaths.sorted())")
        }
        let known = Set(sourceFiles.map(\.logicalPath))
        let unknown = excludedSourcePaths.subtracting(known)
        guard unknown.isEmpty else {
            throw BuildCapture.Error.invalidManifest("indexing diagnostics name sources absent from this manifest: \(unknown.sorted())")
        }
        let excluded = sourceFiles.filter {
            excludedSourcePaths.contains($0.logicalPath) || !options.includes(logicalPath: $0.logicalPath)
        }.map(\.id)
        if options == .init(), excluded.isEmpty {
            schemaVersion = 1
            indexingPolicy = nil
        } else {
            schemaVersion = Self.currentSchemaVersion
            indexingPolicy = .init(options: options, excludedSourceIDs: excluded)
        }
        try validate()
    }
}
