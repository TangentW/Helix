import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        deletions: [String] = [],
        privateDirectories: [String] = []
    ) throws -> [String] {
        let root = root.standardizedFileURL
        guard !mutations.isEmpty || !deletions.isEmpty else { return [] }
        let uniquePaths = Set(mutations.map(\.relativePath))
        let uniqueDeletions = Set(deletions)
        guard uniquePaths.count == mutations.count,
              uniqueDeletions.count == deletions.count,
              uniquePaths.isDisjoint(with: uniqueDeletions)
        else {
            throw Hub.Error.transactionFailed(
                "the transaction contains duplicate or conflicting paths"
            )
        }
        let ordered = try mutations.sorted { $0.relativePath < $1.relativePath }.map {
            try validated($0, root: root)
        }
        let orderedDeletions = try deletions.sorted().map { relativePath in
            (relativePath, try safeURL(relativePath: relativePath, root: root))
        }
        let projects = ordered.filter { $0.url.lastPathComponent == "project.pbxproj" }
        for item in projects {
            try Hub.OpenStepValidation.validate(item.mutation.data)
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
            for (_, url) in orderedDeletions {
                let snapshot = try snapshot(url)
                try ensureSafeParents(of: url, beneath: root)
                guard try entryStatus(at: url) != nil else { continue }
                written.append(snapshot)
                try fileManager.removeItem(at: url)
            }
            // Keep read-back inside the rollback boundary, after all mutations.
            for item in projects {
                try ensureSafeParents(of: item.url, beneath: root)
                guard let actual = try snapshot(item.url).data, actual == item.mutation.data else {
                    throw Hub.Error.transactionFailed("PBX read-back differs at \(item.mutation.relativePath)")
                }
                try Hub.OpenStepValidation.validate(actual)
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
                    } else if try entryStatus(at: snapshot.url) != nil {
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
                    } else if try entryStatus(at: snapshot.url) != nil,
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
        let status = try entryStatus(at: directory)
        let existed = status != nil
        let permissions: Int?
        if let status {
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw Hub.Error.transactionFailed(
                    "private destination is not a real directory"
                )
            }
            permissions = Int(status.st_mode & 0o777)
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
        guard let status = try entryStatus(at: url) else {
            return .init(url: url, data: nil, permissions: nil)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= 64 * 1_024 * 1_024
        else {
            throw Hub.Error.transactionFailed("destination is not a bounded regular file")
        }
        return .init(
            url: url,
            data: try Data(contentsOf: url),
            permissions: Int(status.st_mode & 0o777)
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
        for directory in paths.reversed() {
            guard let status = try entryStatus(at: directory) else { continue }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw Hub.Error.transactionFailed(
                    "destination parent is not a real directory: \(directory.path)"
                )
            }
        }
    }

    /// `FileManager.fileExists` follows links and therefore reports a dangling
    /// symlink as absent. Transactions need the directory entry itself so both
    /// live and dangling links are rejected consistently.
    private func entryStatus(at url: URL) throws -> stat? {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result == 0 { return status }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw Hub.Error.transactionFailed(
            "destination cannot be inspected safely: \(url.path)"
        )
    }
}
}
