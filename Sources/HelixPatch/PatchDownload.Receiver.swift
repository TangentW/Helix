import CryptoKit
import Foundation
import HelixCore

public enum PatchDownload {}

extension PatchDownload {
public struct Artifact: Sendable {
    public var downloadID: UUID
    public var partialURL: URL
    public var packageBytes: Data
    public var sha256: Core.Digest
}

public final class Receiver: @unchecked Sendable {
    private enum State {
        case receiving
        case finished
        case failed
        case cancelled
    }

    public let store: PatchStore.Storage
    public let downloadID: UUID
    public let maximumPackageBytes: Int
    public let expectedByteCount: Int?
    public let expectedSHA256: Core.Digest?
    public let partialURL: URL

    private let lock = NSLock()
    private var state = State.receiving
    private var byteCount = 0
    private var hasher = SHA256()
    private var handle: FileHandle?

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
