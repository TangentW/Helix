import Foundation
import HelixCore

extension BuildCapture {
public struct SourceMapping: Hashable, Sendable {
    public var logicalPath: String
    public var url: URL

    public init(logicalPath: String, url: URL) {
        self.logicalPath = logicalPath
        self.url = url
    }
}

/// Converts the exact source set selected by Swift Driver into stable logical
/// paths without persisting build-machine absolute paths in the Shell archive.
public struct SourceMapper: Sendable {
    public init() {}

    public func map(
        _ job: BuildCapture.NormalizedFrontendJob,
        workspaceRoot: URL
    ) throws -> [BuildCapture.SourceMapping] {
        try map(sourcePaths: job.sourcePaths, workspaceRoot: workspaceRoot)
    }

    public func map(
        sourcePaths: [String],
        workspaceRoot: URL
    ) throws -> [BuildCapture.SourceMapping] {
        let root = workspaceRoot.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              let rootAttributes = try? FileManager.default.attributesOfItem(
                  atPath: resolvedRoot.path
              ),
              (rootAttributes[.type] as? FileAttributeType) == .typeDirectory,
              !sourcePaths.isEmpty,
              sourcePaths.count <= 65_536
        else {
            throw BuildCapture.Error.malformedCommand(
                "captured source mapping has no valid workspace root or source set"
            )
        }

        var mappings: [BuildCapture.SourceMapping] = []
        var resolvedSources = Set<String>()
        var logicalPaths = Set<String>()
        for path in sourcePaths.sorted() {
            guard path.hasPrefix("/"),
                  path.hasSuffix(".swift"),
                  path.utf8.count <= 64 * 1_024,
                  !path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  })
            else {
                throw BuildCapture.Error.malformedCommand(
                    "captured Swift source path is invalid: \(path)"
                )
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: resolved.path
            ),
                (attributes[.type] as? FileAttributeType) == .typeRegular,
                resolvedSources.insert(resolved.path).inserted
            else {
                throw BuildCapture.Error.malformedCommand(
                    "captured Swift source is missing, not regular, or aliased: \(path)"
                )
            }

            let logicalPath = relativePath(of: url, in: root)
                ?? relativePath(of: resolved, in: resolvedRoot)
                ?? externalLogicalPath(for: url)
            guard isSafeLogicalPath(logicalPath),
                  logicalPaths.insert(logicalPath).inserted
            else {
                throw BuildCapture.Error.malformedCommand(
                    "captured Swift sources do not have unique safe logical paths"
                )
            }
            mappings.append(.init(logicalPath: logicalPath, url: url))
        }
        return mappings.sorted { $0.logicalPath < $1.logicalPath }
    }

    private func relativePath(of source: URL, in root: URL) -> String? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(prefix) else { return nil }
        return String(source.path.dropFirst(prefix.count))
    }

    private func externalLogicalPath(for source: URL) -> String {
        var hasher = Core.StableHasher(domain: "HLX.XcodeCapturedSource.v1")
        hasher.append(source.path)
        return "__HelixExternal/\(hasher.finalize().hex)/\(source.lastPathComponent)"
    }

    private func isSafeLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              path.hasSuffix(".swift"),
              path.utf8.count <= 64 * 1_024,
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("")
            && !components.contains(".")
            && !components.contains("..")
    }
}
}
