#if canImport(Darwin)
import Darwin
import Foundation

/// Filesystem primitives shared by persistent Helix service stores.
enum SecureStorage {}

extension SecureStorage {
/// Atomic owner-only regular-file storage with no final-component symlink following.
struct OwnerFile {
    enum Error: Swift.Error {
        case unavailable
        case insecure
        case tooLarge
        case io(String)
    }

    static func read(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else { throw Error.tooLarge }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw Error.unavailable }
            throw Error.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0
        else {
            throw Error.insecure
        }
        guard status.st_size > 0, status.st_size <= maximumBytes else {
            throw Error.tooLarge
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw Error.io(String(describing: error))
        }
        guard data.count == Int(status.st_size) else {
            throw Error.insecure
        }
        return data
    }

    static func write(
        _ data: Data,
        to url: URL,
        maximumBytes: Int
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw Error.tooLarge
        }
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw Error.io("cannot create staging file")
        }
        var removeTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if removeTemporary {
                _ = temporary.path.withCString(Darwin.unlink)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw Error.io("cannot restrict staging permissions")
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw Error.io("cannot synchronize staging file")
        }
        guard temporary.path.withCString({ source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }) == 0 else {
            throw Error.io("cannot publish owner-only file")
        }
        removeTemporary = false
    }

    /// Moves an owner-only regular file aside without following a symbolic
    /// link. Callers use this only for reconstructible local state whose
    /// contents failed semantic decoding; insecure filesystem objects remain a
    /// hard failure.
    static func quarantine(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw Error.unavailable }
            throw Error.insecure
        }
        defer { _ = Darwin.close(descriptor) }

        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0,
              url.path.withCString({ lstat($0, &current) }) == 0,
              opened.st_uid == geteuid(),
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & 0o077 == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino
        else {
            throw Error.insecure
        }

        let destination = directory.appendingPathComponent(
            ".\(url.lastPathComponent).invalid-\(UUID().uuidString)"
        )
        guard url.path.withCString({ source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }) == 0 else {
            if errno == ENOENT { throw Error.unavailable }
            throw Error.io("cannot quarantine invalid owner-only file")
        }
        return destination
    }

    static func prepareDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Error.io(String(describing: error))
        }
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o022 == 0
        else {
            throw Error.insecure
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw Error.tooLarge }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw Error.io("cannot write staging file")
                }
                offset += count
            }
        }
    }
}
}
#endif
