import Darwin
import Foundation

extension BuildCache.CompilerInputs {
/// Owned by one synchronous Catalog plan, never shared across tasks or builds.
/// Only directory membership is reused; selected file bytes are always reread.
final class DirectoryInventoryCache {
    private struct DirectoryVersion: Equatable {
        var path: String
        var device: dev_t
        var inode: ino_t
        var mode: mode_t
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var changedSeconds: Int
        var changedNanoseconds: Int

        static func read(_ url: URL) throws -> Self {
            var information = Darwin.stat()
            guard lstat(url.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR else {
                throw BuildCache.Error.io("compiler input directory changed or became unreadable")
            }
            return .init(
                path: url.path, device: information.st_dev, inode: information.st_ino,
                mode: information.st_mode,
                modifiedSeconds: information.st_mtimespec.tv_sec,
                modifiedNanoseconds: information.st_mtimespec.tv_nsec,
                changedSeconds: information.st_ctimespec.tv_sec,
                changedNanoseconds: information.st_ctimespec.tv_nsec
            )
        }

        var isCurrent: Bool {
            (try? Self.read(URL(fileURLWithPath: path, isDirectory: true))) == self
        }
    }

    private struct Inventory {
        var paths: [String]
        var directories: [DirectoryVersion]

        var isCurrent: Bool { directories.allSatisfy(\.isCurrent) }

        static func read(_ root: URL, maximumCount: Int) throws -> Self {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            var pending = [root]
            var result = Self(paths: [], directories: [])
            while let directory = pending.popLast() {
                // Capture before listing this directory so a concurrent add,
                // delete, rename, or permission change cannot bless stale entries.
                let version = try DirectoryVersion.read(directory)
                var traversalFailed = false
                guard let children = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants],
                    errorHandler: { _, _ in
                        traversalFailed = true
                        return false
                    }
                ) else {
                    throw BuildCache.Error.io("cannot enumerate compiler input directory")
                }
                while let child = children.nextObject() as? URL {
                    guard result.paths.count < maximumCount else {
                        throw BuildCache.Error.io("compiler input directory exceeds entry limit")
                    }
                    let path = child.standardizedFileURL.path
                    guard path.hasPrefix(prefix) else {
                        throw BuildCache.Error.io("compiler input enumeration escaped its root")
                    }
                    result.paths.append(String(path.dropFirst(prefix.count)))
                    var information = Darwin.stat()
                    guard lstat(path, &information) == 0 else {
                        throw BuildCache.Error.io("compiler input directory changed while listing")
                    }
                    // Directory links are listed, but not traversed. The
                    // fingerprinter retains its existing cycle/alias policy.
                    if information.st_mode & S_IFMT == S_IFDIR {
                        pending.append(child)
                    }
                }
                guard !traversalFailed else {
                    throw BuildCache.Error.io("compiler input directory traversal failed")
                }
                result.directories.append(version)
            }
            guard result.isCurrent else {
                throw BuildCache.Error.io("compiler input directories changed while listing")
            }
            result.paths.sort()
            return result
        }
    }

    private let maximumCachedEntries: Int
    private var inventories: [String: Inventory] = [:]
    private(set) var cachedEntryCount = 0
    private(set) var enumerationCount = 0

    init(maximumCachedEntries: Int = 250_000) {
        precondition(maximumCachedEntries >= 0)
        self.maximumCachedEntries = maximumCachedEntries
    }

    func subpaths(of root: URL, maximumCount: Int) throws -> [String] {
        guard maximumCount > 0 else {
            throw BuildCache.Error.io("directory entry limit is invalid")
        }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        if let cached = inventories[resolved.path], cached.isCurrent {
            guard cached.paths.count <= maximumCount else {
                throw BuildCache.Error.io("compiler input directory exceeds entry limit")
            }
            return cached.paths
        }
        if let stale = inventories.removeValue(forKey: resolved.path) {
            cachedEntryCount -= stale.paths.count + 1
        }
        enumerationCount += 1
        let inventory = try Inventory.read(resolved, maximumCount: maximumCount)
        let cost = inventory.paths.count + 1
        if cost <= maximumCachedEntries {
            if cachedEntryCount > maximumCachedEntries - cost {
                inventories.removeAll(keepingCapacity: true)
                cachedEntryCount = 0
            }
            inventories[resolved.path] = inventory
            cachedEntryCount += cost
        }
        return inventory.paths
    }
}
}
