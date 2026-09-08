import Darwin
import Foundation
import HelixCore

extension BuildCache.CompilerInputs {
struct Fingerprinter {
    var hasher = Core.StableHasher(domain: "HLX.CompilerInputs.v1")
    var fileCount: UInt64 = 0
    var byteCount: UInt64 = 0
    var isComplete: Bool
    var incompleteReasons = Set<String>()
    private var seenResolvedFiles: [String: (byteCount: UInt64, hash: Core.Digest)] = [:]

    init(isComplete: Bool) {
        self.isComplete = isComplete
    }

    mutating func markIncomplete(_ reason: String) {
        isComplete = false
        incompleteReasons.insert(reason)
    }

    @discardableResult
    mutating func appendFile(
        _ url: URL,
        logicalPath: String,
        maximumBytes: Int = 512 * 1_024 * 1_024,
        identityTransform: (Data) throws -> Data = { $0 }
    ) throws -> Data {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let data = try Self.readStableData(
            resolved,
            maximumBytes: maximumBytes
        )
        let physicalDigest = Core.Digest.sha256(data)
        if let previous = seenResolvedFiles[resolved.path] {
            guard previous.byteCount == UInt64(data.count),
                  previous.hash == physicalDigest
            else {
                throw BuildCache.Error.io(
                    "compiler input changed between references"
                )
            }
        } else {
            seenResolvedFiles[resolved.path] = (
                UInt64(data.count),
                physicalDigest
            )
            fileCount += 1
            let (sum, overflow) = byteCount.addingReportingOverflow(
                UInt64(data.count)
            )
            guard !overflow else {
                throw BuildCache.Error.io("compiler input size overflow")
            }
            byteCount = sum
        }
        // Logical aliases matter to module selection even when they resolve to
        // the same bytes, so every compiler-visible role enters the identity.
        // The resolved host path does not: identical module bytes copied to a
        // different project or DerivedData root remain the same compiler fact.
        let identity = try identityTransform(data)
        hasher.append(logicalPath)
        hasher.append(UInt64(identity.count))
        hasher.append(Core.Digest.sha256(identity))
        return data
    }

    mutating func appendReferencedPath(
        _ url: URL,
        logicalPath: String,
        compilerInterfacesOnly: Bool = false,
        excluding excludedURL: URL? = nil
    ) throws {
        let original = url.standardizedFileURL
        var information = Darwin.stat()
        guard lstat(original.path, &information) == 0 else {
            hasher.append(logicalPath)
            if errno == ENOENT {
                hasher.append("missing")
            } else {
                hasher.append("unreadable")
                markIncomplete("Unreadable referenced compiler input: \(original.path)")
            }
            return
        }
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        guard lstat(resolved.path, &information) == 0 else {
            markIncomplete("Unresolved referenced compiler input: \(original.path)")
            return
        }
        let excluded = excludedURL?.resolvingSymlinksInPath()
            .standardizedFileURL.path
        if information.st_mode & S_IFMT == S_IFREG {
            guard resolved.path != excluded,
                  !compilerInterfacesOnly
                      || BuildCache.CompilerInputs.isCompilerInterfacePath(
                          resolved.path
                      )
            else { return }
            try appendFile(resolved, logicalPath: logicalPath)
            return
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            markIncomplete("Unsupported referenced compiler input node: \(original.path)")
            return
        }
        let subpaths = try BuildCache.CompilerInputs.boundedSubpaths(
            of: resolved,
            maximumCount: 250_000
        )
        for subpath in subpaths {
            if compilerInterfacesOnly,
               !BuildCache.CompilerInputs.isCompilerInterfacePath(subpath) {
                continue
            }
            let child = resolved.appendingPathComponent(subpath)
            var childInformation = Darwin.stat()
            guard lstat(child.path, &childInformation) == 0 else {
                markIncomplete("Referenced compiler input disappeared or became unreadable: \(child.path)")
                continue
            }
            if childInformation.st_mode & S_IFMT == S_IFLNK {
                let target = child.resolvingSymlinksInPath().standardizedFileURL
                guard lstat(target.path, &childInformation) == 0 else {
                    markIncomplete("Unresolved referenced compiler input symlink: \(child.path)")
                    continue
                }
                guard childInformation.st_mode & S_IFMT == S_IFREG else {
                    // Avoid a cycle-prone second traversal through directory
                    // links. An uncached frontend remains authoritative.
                    markIncomplete("Referenced compiler input symlink does not resolve to a regular file: \(child.path) -> \(target.path)")
                    continue
                }
                if target.path == excluded { continue }
                try appendFile(
                    target,
                    logicalPath: "\(logicalPath)/\(subpath)"
                )
            } else if childInformation.st_mode & S_IFMT == S_IFREG {
                if child.standardizedFileURL.path == excluded { continue }
                try appendFile(
                    child,
                    logicalPath: "\(logicalPath)/\(subpath)"
                )
            }
            if fileCount > 100_000 || byteCount > 1_024 * 1_024 * 1_024 {
                markIncomplete("Compiler input budget exceeded at \(child.path): \(fileCount) files, \(byteCount) bytes")
                return
            }
        }
    }

    static func readStableData(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw BuildCache.Error.io("cannot open compiler input")
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var before = Darwin.stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= maximumBytes
        else {
            throw BuildCache.Error.io(
                "compiler input is not a bounded file"
            )
        }
        let data = try handle.readToEnd() ?? Data()
        var after = Darwin.stat()
        guard fstat(descriptor, &after) == 0,
              data.count == before.st_size,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw BuildCache.Error.io("compiler input changed while reading")
        }
        return data
    }
}
}
