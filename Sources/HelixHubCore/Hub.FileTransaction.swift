import Foundation

extension Hub {
struct FileMutation: Sendable {
    var relativePath: String
    var data: Data
    var permissions: Int
}

struct FileTransaction {
    private struct Snapshot {
        var url: URL
        var data: Data?
        var permissions: Int?
    }

    private struct DirectorySnapshot {
        var url: URL
        var existed: Bool
        var permissions: Int?
    }

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func commit(
        root: URL,
        mutations: [Hub.FileMutation],
        privateDirectories: [String] = []
    ) throws -> [String] {
        let root = root.standardizedFileURL
        guard !mutations.isEmpty else { return [] }
        let uniquePaths = Set(mutations.map(\.relativePath))
        guard uniquePaths.count == mutations.count else {
            throw Hub.Error.transactionFailed("the write set contains duplicate paths")
        }
        let ordered = try mutations.sorted { $0.relativePath < $1.relativePath }.map {
            try validated($0, root: root)
        }
        var directorySnapshots: [DirectorySnapshot] = []
        var written: [Snapshot] = []
        do {
            for path in privateDirectories.sorted() {
                directorySnapshots.append(try preparePrivateDirectory(
                    relativePath: path,
                    root: root
                ))
            }
            for item in ordered {
                let snapshot = try snapshot(item.url)
                try ensureSafeParents(of: item.url, beneath: root)
                try fileManager.createDirectory(
                    at: item.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                written.append(snapshot)
                try item.mutation.data.write(to: item.url, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: item.mutation.permissions],
                    ofItemAtPath: item.url.path
                )
            }
            return ordered.map { $0.mutation.relativePath }
        } catch {
            let original = error
            var rollbackFailure: Swift.Error?
            for snapshot in written.reversed() {
                do {
                    if let data = snapshot.data {
                        try data.write(to: snapshot.url, options: .atomic)
                        if let permissions = snapshot.permissions {
                            try fileManager.setAttributes(
                                [.posixPermissions: permissions],
                                ofItemAtPath: snapshot.url.path
                            )
                        }
                    } else if fileManager.fileExists(atPath: snapshot.url.path) {
                        try fileManager.removeItem(at: snapshot.url)
                    }
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                }
            }
            for snapshot in directorySnapshots.reversed() {
                do {
                    if snapshot.existed, let permissions = snapshot.permissions {
                        try fileManager.setAttributes(
                            [.posixPermissions: permissions],
                            ofItemAtPath: snapshot.url.path
                        )
                    } else if fileManager.fileExists(atPath: snapshot.url.path),
                              try fileManager.contentsOfDirectory(
                                atPath: snapshot.url.path
                              ).isEmpty {
                        try fileManager.removeItem(at: snapshot.url)
                    }
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                }
            }
            if let rollbackFailure {
                throw Hub.Error.transactionFailed(
                    "write failed (\(original)); rollback also failed (\(rollbackFailure))"
                )
            }
            throw Hub.Error.transactionFailed("write failed and was rolled back: \(original)")
        }
    }

    private func preparePrivateDirectory(
        relativePath: String,
        root: URL
    ) throws -> DirectorySnapshot {
        let directory = try safeURL(relativePath: relativePath, root: root)
        try ensureSafeParents(of: directory, beneath: root)
        let existed = fileManager.fileExists(atPath: directory.path)
        let permissions: Int?
        if existed {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                throw Hub.Error.transactionFailed(
                    "private destination is not a real directory"
                )
            }
            permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        } else {
            permissions = nil
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return .init(url: directory, existed: existed, permissions: permissions)
    }

    private func validated(
        _ mutation: Hub.FileMutation,
        root: URL
    ) throws -> (mutation: Hub.FileMutation, url: URL) {
        guard (0...0o777).contains(mutation.permissions),
              mutation.data.count <= 64 * 1_024 * 1_024
        else {
            throw Hub.Error.transactionFailed(
                "invalid permissions or oversized file at \(mutation.relativePath)"
            )
        }
        return (mutation, try safeURL(relativePath: mutation.relativePath, root: root))
    }

    private func safeURL(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0")
        else {
            throw Hub.Error.transactionFailed("unsafe project-relative path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(""), !components.contains("."),
              !components.contains("..")
        else {
            throw Hub.Error.transactionFailed("unsafe project-relative path")
        }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw Hub.Error.transactionFailed("file escaped the selected source root")
        }
        return url
    }

    private func snapshot(_ url: URL) throws -> Snapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return .init(url: url, data: nil, permissions: nil)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 64 * 1_024 * 1_024
        else {
            throw Hub.Error.transactionFailed("destination is not a bounded regular file")
        }
        return .init(
            url: url,
            data: try Data(contentsOf: url),
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    private func ensureSafeParents(of url: URL, beneath root: URL) throws {
        var cursor = url.deletingLastPathComponent()
        var paths: [URL] = []
        while cursor.path != root.path {
            guard cursor.path.hasPrefix(root.path + "/") else {
                throw Hub.Error.transactionFailed("destination escaped the selected source root")
            }
            paths.append(cursor)
            cursor.deleteLastPathComponent()
        }
        for directory in paths.reversed() where fileManager.fileExists(atPath: directory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                throw Hub.Error.transactionFailed(
                    "destination parent is not a real directory: \(directory.path)"
                )
            }
        }
    }
}
}
