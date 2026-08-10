import Darwin
import Foundation
import HelixCore

extension PatchDownload {
/// A bounded file-backed transport used by demos, tests, MDM drops, and other
/// control-plane-independent integrations. Bytes still pass through the same
/// streaming receiver, hash checks, verifier, store, and activation WAL.
public struct LocalFileTransport: Sendable {
    /// Number of bytes read and appended per streaming iteration.
    public var chunkByteCount: Int

    /// Creates a local transport with a bounded chunk size.
    public init(chunkByteCount: Int = 64 * 1_024) {
        self.chunkByteCount = chunkByteCount
    }

    /// Streams a regular, non-symbolic-link file into a Patch Store transaction.
    ///
    /// - Parameters:
    ///   - sourceURL: Private local package file.
    ///   - store: Store that owns the incoming transaction.
    ///   - expectedSHA256: Optional digest supplied by the download control plane.
    ///   - maximumPackageBytes: Hard package-size ceiling.
    /// - Returns: A finalized artifact ready for activation.
    public func receive(
        from sourceURL: URL,
        into store: PatchStore.Storage,
        expectedSHA256: Core.Digest? = nil,
        maximumPackageBytes: Int = PatchPackage.DecodingLimits().maximumPackageBytes
    ) throws -> PatchDownload.Artifact {
        guard sourceURL.isFileURL,
              (1...1_024 * 1_024).contains(chunkByteCount),
              maximumPackageBytes > 0
        else {
            throw PatchPackage.Error.activationPersistence(
                "local patch transport configuration is invalid"
            )
        }
        let descriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PatchPackage.Error.activationPersistence(
                "local patch source is missing or is a symbolic link"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumPackageBytes
        else {
            throw PatchPackage.Error.limitExceeded("local patch source bytes")
        }
        let expectedByteCount = Int(information.st_size)
        let receiver = try PatchDownload.Receiver(
            store: store,
            maximumPackageBytes: maximumPackageBytes,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256
        )
        do {
            while true {
                let bytes = try handle.read(upToCount: chunkByteCount) ?? Data()
                if bytes.isEmpty { break }
                try receiver.append(bytes)
            }
            return try receiver.finish()
        } catch {
            try? receiver.cancel()
            throw error
        }
    }
}
}
