import Darwin
import Foundation

extension CLI {
struct DirectoryPublication: Sendable {
    var reusedFileCount: UInt64
    var writtenFileCount: UInt64
    var wasNoOp: Bool
}

struct FileSystem: Sendable {
    let currentDirectoryURL: URL

    private var manager: Foundation.FileManager { .default }

    init(currentDirectoryURL: URL) {
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
    }

    func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return currentDirectoryURL.appendingPathComponent(path).standardizedFileURL
    }

    func read(_ path: String) throws -> Data {
        let url = resolve(path)
        guard manager.fileExists(atPath: url.path) else {
            throw CLI.Error.input("file does not exist: \(url.path)")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CLI.Error.input("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    func readPrivateKeyDocument(_ path: String) throws -> Data {
        let url = resolve(path)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CLI.Error.insecurePrivateKey(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            throw CLI.Error.insecurePrivateKey(url.path)
        }
        do {
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= 64 * 1_024 else {
                throw CLI.Error.input("private key document exceeds 64 KiB")
            }
            return data
        } catch let error as CLI.Error {
            throw error
        } catch {
            throw CLI.Error.input("cannot read private key document: \(error.localizedDescription)")
        }
    }

    func preflight(_ urls: [URL], force: Bool) throws {
        var paths = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            guard paths.insert(path).inserted else {
                throw CLI.Error.input("two outputs resolve to the same path: \(path)")
            }
            if !force, manager.fileExists(atPath: path) {
                throw CLI.Error.outputExists(path)
            }
            let parent = url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw CLI.Error.input("output directory does not exist: \(parent.path)")
            }
        }
    }

    func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CLI.Error.input("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    /// Commits a complete generated-source tree with a single directory rename.
    /// Readers therefore observe either the previous build or the complete new one.
    @discardableResult
    func writeDirectory(
        _ artifacts: [String: Data],
        to outputURL: URL,
        force: Bool,
        privatePaths: Set<String> = [],
        executablePaths: Set<String> = []
    ) throws -> CLI.DirectoryPublication {
        let target = outputURL.standardizedFileURL
        guard !artifacts.isEmpty,
              target.path != "/",
              target.path != currentDirectoryURL.path,
              !target.lastPathComponent.isEmpty
        else {
            throw CLI.Error.input("unsafe or empty output directory")
        }
        let parent = target.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue
        else {
            throw CLI.Error.input("output directory does not exist: \(parent.path)")
        }
        if !force, manager.fileExists(atPath: target.path) {
            throw CLI.Error.outputExists(target.path)
        }
        for path in artifacts.keys {
            guard Self.isSafeRelativePath(path) else {
                throw CLI.Error.input("unsafe generated artifact path: \(path)")
            }
        }
        let artifactPaths = Set(artifacts.keys)
        guard privatePaths.isSubset(of: artifactPaths),
              executablePaths.isSubset(of: artifactPaths),
              privatePaths.isDisjoint(with: executablePaths)
        else {
            throw CLI.Error.input(
                "private and executable output modes must name disjoint artifacts"
            )
        }
        let permissions = Dictionary(uniqueKeysWithValues: artifactPaths.map { path in
            (path, executablePaths.contains(path) ? UInt16(0o755)
                : privatePaths.contains(path) ? UInt16(0o600) : UInt16(0o644))
        })
        if Self.directoryMatches(
            target,
            artifacts: artifacts,
            permissions: permissions,
            manager: manager
        ) {
            return .init(
                reusedFileCount: UInt64(artifacts.count),
                writtenFileCount: 0,
                wasNoOp: true
            )
        }

        let staging = parent.appendingPathComponent(
            ".helix-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingExists = true
        defer {
            if stagingExists { try? manager.removeItem(at: staging) }
        }
        var reusedFileCount: UInt64 = 0
        var writtenFileCount: UInt64 = 0
        for (path, data) in artifacts.sorted(by: { $0.key < $1.key }) {
            let destination = staging.appendingPathComponent(path)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let mode = permissions[path]!
            let existing = target.appendingPathComponent(path)
            if Self.regularFileMatches(existing, data: data, permissions: mode),
               Darwin.link(existing.path, destination.path) == 0,
               Self.regularFileMatches(destination, data: data, permissions: mode) {
                reusedFileCount += 1
            } else {
                _ = Darwin.unlink(destination.path)
                try data.write(to: destination, options: .atomic)
                try manager.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: destination.path
                )
                writtenFileCount += 1
            }
        }

        if manager.fileExists(atPath: target.path) {
            let status = staging.path.withCString { stagingPath in
                target.path.withCString { targetPath in
                    renameatx_np(
                        AT_FDCWD,
                        stagingPath,
                        AT_FDCWD,
                        targetPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard status == 0 else {
                throw CLI.Error.input(
                    "cannot atomically publish generated directory: "
                        + String(cString: strerror(errno))
                )
            }
            // The old tree now occupies the staging path and is removed by
            // defer; the target was never absent from the filesystem.
        } else {
            try manager.moveItem(at: staging, to: target)
            stagingExists = false
        }
        return .init(
            reusedFileCount: reusedFileCount,
            writtenFileCount: writtenFileCount,
            wasNoOp: false
        )
    }

    func requireExtension(_ expected: String, for url: URL) throws {
        let actual = url.pathExtension.lowercased()
        guard actual == expected.lowercased() else {
            throw CLI.Error.invalidOutputExtension(expected: expected, actual: actual)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func directoryMatches(
        _ root: URL,
        artifacts: [String: Data],
        permissions: [String: UInt16],
        manager: FileManager
    ) -> Bool {
        var rootInformation = Darwin.stat()
        let rootStatus = lstat(root.path, &rootInformation)
        guard rootStatus == 0,
              rootInformation.st_mode & S_IFMT == S_IFDIR
        else { return false }
        var expected = Set(artifacts.keys)
        for path in artifacts.keys {
            var current = ""
            for component in path.split(separator: "/").dropLast() {
                current = current.isEmpty
                    ? String(component) : "\(current)/\(component)"
                expected.insert(current)
            }
        }
        guard let subpaths = CLI.DirectoryContents.exactSubpaths(
            of: root,
            expected: expected
        ) else { return false }
        for relative in subpaths {
            let url = root.appendingPathComponent(relative)
            if let data = artifacts[relative], let mode = permissions[relative] {
                guard regularFileMatches(url, data: data, permissions: mode) else {
                    return false
                }
            } else {
                var information = Darwin.stat()
                guard lstat(url.path, &information) == 0,
                      information.st_mode & S_IFMT == S_IFDIR
                else { return false }
            }
        }
        return true
    }

    private static func regularFileMatches(
        _ url: URL,
        data expected: Data,
        permissions: UInt16
    ) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_mode & 0o777 == permissions,
              information.st_size == expected.count
        else { return false }
        do {
            let observed = try handle.readToEnd() ?? Data()
            return observed == expected
        } catch {
            return false
        }
    }
}
}
