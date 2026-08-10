import Darwin
import Foundation

extension DevProcess {
public final class LifetimeLock: @unchecked Sendable {
    private var descriptor: Int32

    public init(url: URL) throws {
        guard url.isFileURL, url.path != "/" else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        do {
            try Self.validate(descriptor: descriptor, path: url.path)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw DevProcess.Error.lifecycleConflict
            }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    public func publish(owner: DevProcess.LifetimeOwner) throws {
        guard descriptor >= 0 else {
            throw DevProcess.Error.lifecycleConflict
        }
        let data = try DevProcess.LifetimeOwnerCodec.encode(owner)
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw DevProcess.Error.insecureFile("lifecycle lock")
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else {
                    throw DevProcess.Error.insecureFile("lifecycle lock")
                }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else {
                    throw DevProcess.Error.insecureFile("lifecycle lock")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw DevProcess.Error.insecureFile("lifecycle lock")
        }
    }

    public static func owner(at url: URL) throws -> DevProcess.LifetimeOwner? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw DevProcess.Error.insecureFile(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try validate(descriptor: descriptor, path: url.path)
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_size >= 0,
              information.st_size <= 64 * 1_024
        else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return nil }
        return try DevProcess.LifetimeOwnerCodec.decode(data)
    }

    public static func isHeld(at url: URL) throws -> Bool {
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            if errno == ENOENT { return false }
            throw DevProcess.Error.insecureFile(url.path)
        }
        defer { Darwin.close(descriptor) }
        try validate(descriptor: descriptor, path: url.path)
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        return true
    }

    private static func validate(descriptor: Int32, path: String) throws {
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            throw DevProcess.Error.insecureFile(path)
        }
    }

    deinit { unlock() }
}
}
