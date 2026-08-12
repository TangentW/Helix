#if os(macOS)
import Darwin
import Foundation
import HelixCore

extension HubControl {
/// Owner-only, process-locked publication of the running service endpoint.
public final class RendezvousStore: @unchecked Sendable {
    public static let maximumDocumentBytes = 16 * 1_024

    public let url: URL
    private var lockDescriptor: Int32 = -1

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    deinit {
        release()
    }

    public static func applicationSupportStore() throws -> Self {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HubControl.Error.storageFailure(
                "the user Application Support directory is unavailable"
            )
        }
        return .init(
            url: root
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent("Service.json", isDirectory: false)
        )
    }

    /// Acquires the single-service lock and atomically publishes the endpoint.
    public func publish(_ rendezvous: HubControl.Rendezvous) throws {
        try rendezvous.validate()
        guard lockDescriptor < 0 else {
            throw HubControl.Error.serviceAlreadyRunning
        }
        let directory = url.deletingLastPathComponent()
        do {
            try SecureStorage.OwnerFile.prepareDirectory(directory)
        } catch {
            throw HubControl.Error.storageFailure(String(describing: error))
        }
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw HubControl.Error.storageFailure("cannot open service lock")
        }
        guard fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            _ = Darwin.close(descriptor)
            throw HubControl.Error.serviceAlreadyRunning
        }
        lockDescriptor = descriptor
        do {
            let data = try Core.CanonicalJSON.encode(rendezvous)
            guard data.count <= Self.maximumDocumentBytes else {
                throw HubControl.Error.invalidRendezvous
            }
            try SecureStorage.OwnerFile.write(
                data,
                to: url,
                maximumBytes: Self.maximumDocumentBytes
            )
        } catch {
            release()
            throw error
        }
    }

    /// Reads an owner-only document published by the currently running process.
    public func load() throws -> HubControl.Rendezvous {
        let data: Data
        do {
            data = try SecureStorage.OwnerFile.read(
                from: url,
                maximumBytes: Self.maximumDocumentBytes
            )
        } catch SecureStorage.OwnerFile.Error.unavailable {
            throw HubControl.Error.serviceUnavailable
        } catch {
            throw HubControl.Error.invalidRendezvous
        }
        let rendezvous: HubControl.Rendezvous
        do {
            rendezvous = try JSONDecoder().decode(HubControl.Rendezvous.self, from: data)
        } catch {
            throw HubControl.Error.invalidRendezvous
        }
        guard try Core.CanonicalJSON.encode(rendezvous) == data else {
            throw HubControl.Error.nonCanonicalMessage
        }
        try rendezvous.validate()
        guard kill(rendezvous.processIdentifier, 0) == 0 || errno == EPERM else {
            throw HubControl.Error.serviceUnavailable
        }
        return rendezvous
    }

    /// Removes the endpoint document and releases ownership.
    public func release() {
        guard lockDescriptor >= 0 else { return }
        _ = url.path.withCString(Darwin.unlink)
        _ = flock(lockDescriptor, LOCK_UN)
        _ = Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

}
}
#endif
