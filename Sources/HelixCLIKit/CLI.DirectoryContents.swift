import Darwin
import Foundation

extension CLI {
enum DirectoryContents {}
}

extension CLI.DirectoryContents {
    /// Enumerates no more entries than the caller already expects and rejects
    /// unexpected paths immediately. This keeps cache validation proportional
    /// to a trusted manifest instead of an arbitrary directory tree.
    static func exactSubpaths(
        of root: URL,
        expected: Set<String>
    ) -> [String]? {
        let root = root.standardizedFileURL
        var remaining = expected
        var observed: [String] = []
        observed.reserveCapacity(expected.count)
        var directories: [(url: URL, prefix: String)] = [(root, "")]
        while let directory = directories.popLast() {
            let descriptor = Darwin.open(
                directory.url.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            guard descriptor >= 0 else { return nil }
            guard let stream = fdopendir(descriptor) else {
                Darwin.close(descriptor)
                return nil
            }
            var directorySucceeded = true
            errno = 0
            while let entry = readdir(stream) {
                guard let name = withUnsafePointer(to: &entry.pointee.d_name, {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(validatingCString: $0)
                    }
                }) else {
                    directorySucceeded = false
                    break
                }
                if name == "." || name == ".." { continue }
                let relative = directory.prefix.isEmpty
                    ? name : directory.prefix + "/" + name
                guard observed.count < expected.count,
                      remaining.remove(relative) != nil
                else {
                    directorySucceeded = false
                    break
                }
                observed.append(relative)

                var information = Darwin.stat()
                guard fstatat(
                    dirfd(stream),
                    name,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    directorySucceeded = false
                    break
                }
                if information.st_mode & S_IFMT == S_IFDIR {
                    directories.append((
                        directory.url.appendingPathComponent(name),
                        relative
                    ))
                }
            }
            let readError = errno
            guard closedir(stream) == 0,
                  directorySucceeded,
                  readError == 0
            else { return nil }
        }
        guard remaining.isEmpty else { return nil }
        return observed
    }
}
