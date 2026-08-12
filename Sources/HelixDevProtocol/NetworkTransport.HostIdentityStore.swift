#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Darwin
import Foundation

extension NetworkTransport {
/// Persists the Helix host key used to pin every development TLS connection.
///
/// The P-256 private key never enters generated project files. Build products
/// receive only the derived SPKI hash, so certificates may be renewed without
/// changing the trust anchor embedded in an App.
public struct HostIdentityStore: Sendable {
    public static let privateKeyByteCount = 32

    /// Location of the raw P-256 private key.
    public let privateKeyURL: URL

    /// Creates a store at an explicit location.
    public init(privateKeyURL: URL) {
        self.privateKeyURL = privateKeyURL.standardizedFileURL
    }

    /// Creates the per-user store under Application Support/Helix.
    public static func applicationSupportStore() throws -> Self {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NetworkTransport.Error.identityStorageFailed(
                "the user Application Support directory is unavailable"
            )
        }
        return .init(
            privateKeyURL: root
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent("HostIdentity.p256", isDirectory: false)
        )
    }

    /// Loads the stable key or creates it once under an interprocess lock.
    public func loadOrCreate(
        now: Date = Date(),
        certificateLifetime: TimeInterval = 30 * 24 * 60 * 60
    ) throws -> NetworkTransport.ServerIdentity {
        try prepareParentDirectory()
        let lockDescriptor = try openLockFile()
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw storageFailure("cannot lock the Host Identity store")
        }

        let rawKey: Data
        do {
            rawKey = try readPrivateKey()
        } catch StoreError.notFound {
            try createPrivateKey()
            rawKey = try readPrivateKey()
        }
        return try NetworkTransport.IdentityFactory.makeServerIdentity(
            privateKeyRawRepresentation: rawKey,
            now: now,
            lifetime: certificateLifetime
        )
    }

    private func prepareParentDirectory() throws {
        let directory = privateKeyURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw storageFailure("cannot create \(directory.path): \(error)")
        }

        var status = stat()
        let result = directory.path.withCString { lstat($0, &status) }
        guard result == 0 else {
            throw storageFailure("cannot inspect \(directory.path)")
        }
        guard status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o022 == 0
        else {
            throw NetworkTransport.Error.insecureIdentityStorage(
                "the key directory must be an owner-controlled directory"
            )
        }
    }

    private func openLockFile() throws -> Int32 {
        let lockURL = privateKeyURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw NetworkTransport.Error.insecureIdentityStorage(
                    "the lock file must not be a symbolic link"
                )
            }
            throw storageFailure("cannot open the Host Identity lock")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            _ = Darwin.close(descriptor)
            throw storageFailure("cannot restrict Host Identity lock permissions")
        }
        return descriptor
    }

    private func readPrivateKey() throws -> Data {
        let descriptor = privateKeyURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw StoreError.notFound }
            if errno == ELOOP {
                throw NetworkTransport.Error.insecureIdentityStorage(
                    "the private key must not be a symbolic link"
                )
            }
            throw storageFailure("cannot open the Host Identity private key")
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw storageFailure("cannot inspect the Host Identity private key")
        }
        guard status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0
        else {
            throw NetworkTransport.Error.insecureIdentityStorage(
                "the private key must be an owner-only regular file"
            )
        }
        guard status.st_size == Self.privateKeyByteCount else {
            throw NetworkTransport.Error.identityStorageFailed(
                "the Host Identity private key has an invalid length"
            )
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard data.count == Self.privateKeyByteCount else {
                throw NetworkTransport.Error.identityStorageFailed(
                    "the Host Identity private key changed while being read"
                )
            }
            _ = try P256.Signing.PrivateKey(rawRepresentation: data)
            return data
        } catch let error as NetworkTransport.Error {
            throw error
        } catch {
            throw NetworkTransport.Error.identityStorageFailed(
                "the Host Identity private key is corrupt"
            )
        }
    }

    private func createPrivateKey() throws {
        let rawKey = P256.Signing.PrivateKey().rawRepresentation
        precondition(rawKey.count == Self.privateKeyByteCount)
        let temporaryURL = privateKeyURL.deletingLastPathComponent()
            .appendingPathComponent(".HostIdentity.\(UUID().uuidString).tmp")
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw storageFailure("cannot create a Host Identity staging file")
        }
        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = temporaryURL.path.withCString(Darwin.unlink)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw storageFailure("cannot restrict Host Identity private-key permissions")
        }
        try write(rawKey, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw storageFailure("cannot synchronize the Host Identity private key")
        }
        guard temporaryURL.path.withCString({ source in
            privateKeyURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }) == 0 else {
            throw storageFailure("cannot publish the Host Identity private key")
        }
        shouldRemoveTemporaryFile = false
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw storageFailure("the generated Host Identity key is empty")
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw storageFailure("cannot write the Host Identity private key")
                }
                offset += written
            }
        }
    }

    private func storageFailure(_ detail: String) -> NetworkTransport.Error {
        .identityStorageFailed("\(detail) (errno \(errno))")
    }
}
}

private enum StoreError: Swift.Error {
    case notFound
}
#endif
