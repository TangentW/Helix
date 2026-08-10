import CryptoKit
import Foundation
import HelixCore

/// Bounded transports that stage package bytes in a ``PatchStore``.
public enum PatchDownload {}

extension PatchDownload {
/// A completed incoming package ready for verification and activation.
public struct Artifact: Sendable {
    /// Unique identifier of the incoming transaction.
    public var downloadID: UUID
    /// Private temporary file managed by the Patch Store.
    public var partialURL: URL
    /// Complete package bytes read back after synchronization.
    public var packageBytes: Data
    /// SHA-256 computed while receiving bytes and rechecked after finalize.
    public var sha256: Core.Digest
}

/// A thread-safe, single-use streaming package receiver.
///
/// Append chunks in order, then call ``finish()`` exactly once. On transport
/// failure, call ``cancel()`` to remove the private partial file.
public final class Receiver: @unchecked Sendable {
    private enum State {
        case receiving
        case finished
        case failed
        case cancelled
    }

    /// Store that owns the private incoming file.
    public let store: PatchStore.Storage
    /// Stable identifier for this receive operation.
    public let downloadID: UUID
    /// Hard ceiling for accumulated package bytes.
    public let maximumPackageBytes: Int
    /// Optional exact byte count supplied by the transport.
    public let expectedByteCount: Int?
    /// Optional expected transport digest.
    public let expectedSHA256: Core.Digest?
    /// Private incoming path created by the store.
    public let partialURL: URL

    private let lock = NSLock()
    private var state = State.receiving
    private var byteCount = 0
    private var hasher = SHA256()
    private var handle: FileHandle?

    /// Opens a new private incoming transaction.
    public init(
        store: PatchStore.Storage,
        downloadID: UUID = UUID(),
        maximumPackageBytes: Int = PatchPackage.DecodingLimits().maximumPackageBytes,
        expectedByteCount: Int? = nil,
        expectedSHA256: Core.Digest? = nil
    ) throws {
        guard maximumPackageBytes > 0,
              expectedByteCount.map({ $0 >= 0 && $0 <= maximumPackageBytes }) ?? true
        else {
            throw PatchPackage.Error.limitExceeded("incoming package bytes")
        }
        self.store = store
        self.downloadID = downloadID
        self.maximumPackageBytes = maximumPackageBytes
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        let opened = try store.openIncomingFile(downloadID: downloadID)
        partialURL = opened.0
        handle = opened.1
    }

    /// Appends the next chunk while enforcing the configured byte ceiling.
    public func append(_ bytes: Data) throws {
        try lock.withLock {
            guard state == .receiving, let handle else {
                throw PatchPackage.Error.activationPersistence(
                    "incoming receiver is not accepting bytes"
                )
            }
            let total = byteCount.addingReportingOverflow(bytes.count)
            guard !total.overflow, total.partialValue <= maximumPackageBytes else {
                state = .failed
                try? handle.close()
                self.handle = nil
                throw PatchPackage.Error.limitExceeded("incoming package bytes")
            }
            do {
                try handle.write(contentsOf: bytes)
                hasher.update(data: bytes)
                byteCount = total.partialValue
            } catch {
                state = .failed
                try? handle.close()
                self.handle = nil
                throw PatchPackage.Error.activationPersistence(
                    "cannot append incoming package: \(error)"
                )
            }
        }
    }

    /// Synchronizes, closes, verifies, and reads back the complete artifact.
    public func finish() throws -> PatchDownload.Artifact {
        try lock.withLock {
            guard state == .receiving, let handle else {
                throw PatchPackage.Error.activationPersistence(
                    "incoming receiver cannot be finished"
                )
            }
            do {
                try handle.synchronize()
                try handle.close()
                self.handle = nil
            } catch {
                state = .failed
                self.handle = nil
                throw PatchPackage.Error.activationPersistence(
                    "cannot finalize incoming package: \(error)"
                )
            }
            guard expectedByteCount == nil || expectedByteCount == byteCount else {
                state = .failed
                throw PatchPackage.Error.payloadLengthMismatch("incoming package")
            }
            let digest = try Core.Digest(bytes: Data(hasher.finalize()))
            guard expectedSHA256 == nil || expectedSHA256 == digest else {
                state = .failed
                throw PatchPackage.Error.payloadHashMismatch("incoming package")
            }
            let bytes: Data
            do {
                bytes = try store.readIncomingFile(
                    downloadID: downloadID,
                    maximumBytes: maximumPackageBytes
                )
            } catch {
                state = .failed
                throw PatchPackage.Error.activationPersistence(
                    "cannot read finalized incoming package: \(error)"
                )
            }
            guard bytes.count == byteCount, Core.Digest.sha256(bytes) == digest else {
                state = .failed
                throw PatchPackage.Error.payloadHashMismatch("incoming package after finalize")
            }
            state = .finished
            return .init(
                downloadID: downloadID,
                partialURL: partialURL,
                packageBytes: bytes,
                sha256: digest
            )
        }
    }

    /// Closes and removes an unfinished incoming transaction.
    public func cancel() throws {
        try lock.withLock {
            guard state != .finished else {
                throw PatchPackage.Error.activationPersistence(
                    "a finished incoming package cannot be cancelled"
                )
            }
            try? handle?.close()
            handle = nil
            try store.removeIncoming(downloadID: downloadID)
            state = .cancelled
        }
    }

    deinit {
        try? handle?.close()
    }
}
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
