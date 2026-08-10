import Darwin
import Foundation
import HelixCore

extension PatchDownload {
/// A bounded file-backed transport used by demos, tests, MDM drops, and other
/// control-plane-independent integrations. Bytes still pass through the same
/// streaming receiver, hash checks, verifier, store, and activation WAL.
public struct LocalFileTransport: Sendable {
    public var chunkByteCount: Int

    public init(chunkByteCount: Int = 64 * 1_024) {
        self.chunkByteCount = chunkByteCount
    }

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
