import Dispatch
import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

#if canImport(Darwin)
import Darwin
#endif

public enum SourceSnapshot {}

extension SourceSnapshot {
public struct File: Codable, Hashable, Sendable {
    public var id: LiveReload.SourceFileID
    public var logicalPath: String
    public var absolutePath: String
    public var inode: UInt64
    public var byteCount: UInt64
    public var modificationNanoseconds: UInt64
    public var contentHash: Core.Digest
    public var contents: Data

    public init(
        id: LiveReload.SourceFileID,
        logicalPath: String,
        absolutePath: String,
        inode: UInt64,
        byteCount: UInt64,
        modificationNanoseconds: UInt64,
        contentHash: Core.Digest,
        contents: Data
    ) {
        self.id = id
        self.logicalPath = logicalPath
        self.absolutePath = absolutePath
        self.inode = inode
        self.byteCount = byteCount
        self.modificationNanoseconds = modificationNanoseconds
        self.contentHash = contentHash
        self.contents = contents
    }
}

public struct Document: Codable, Hashable, Sendable {
    public var revision: DevProtocol.SourceRevision
    public var files: [SourceSnapshot.File]
    public var aggregateHash: Core.Digest

    public init(revision: DevProtocol.SourceRevision, files: [SourceSnapshot.File]) {
        self.revision = revision
        self.files = files.sorted { $0.logicalPath < $1.logicalPath }
        var hasher = Core.StableHasher(domain: "HLX.SourceSnapshot.v1")
        for file in self.files {
            hasher.append(file.id.rawValue)
            hasher.append(file.contentHash)
        }
        aggregateHash = hasher.finalize()
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case sourceNotInManifest(String)
    case sourceDisappeared(String)
    case sourceDidNotStabilize(String)
    case notSwiftSource(String)
    case sourceTooLarge(String)
    case invalidConfiguration

    public var description: String {
        switch self {
        case let .sourceNotInManifest(path): "source is not in Dev Build Manifest: \(path)"
        case let .sourceDisappeared(path): "source disappeared while snapshotting: \(path)"
        case let .sourceDidNotStabilize(path): "source did not stabilize: \(path)"
        case let .notSwiftSource(path): "source is not a Swift file: \(path)"
        case let .sourceTooLarge(path): "source exceeds the configured byte limit: \(path)"
        case .invalidConfiguration: "source snapshot configuration is invalid"
        }
    }
}

public struct Snapshotter: Sendable {
    public var stabilityDelayNanoseconds: UInt64
    public var maximumAttempts: Int
    public var maximumSourceBytes: Int

    public init(
        stabilityDelayNanoseconds: UInt64 = 25_000_000,
        maximumAttempts: Int = 4,
        maximumSourceBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.stabilityDelayNanoseconds = stabilityDelayNanoseconds
        self.maximumAttempts = maximumAttempts
        self.maximumSourceBytes = maximumSourceBytes
    }

    public func capture(
        changedPaths: Set<String>,
        manifest: DevBuildManifest.Document,
        revision: DevProtocol.SourceRevision
    ) async throws -> SourceSnapshot.Document {
        guard maximumAttempts > 0, maximumSourceBytes > 0, revision.rawValue > 0 else {
            throw SourceSnapshot.Error.invalidConfiguration
        }
        try manifest.validate()
        let byPath = Dictionary(uniqueKeysWithValues: manifest.sourceFiles.map {
            (URL(fileURLWithPath: $0.absolutePath).standardizedFileURL.path, $0)
        })
        var snapshots: [SourceSnapshot.File] = []
        for path in changedPaths.sorted() {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalized.hasSuffix(".swift") else { throw SourceSnapshot.Error.notSwiftSource(path) }
            guard let source = byPath[normalized] else {
                throw SourceSnapshot.Error.sourceNotInManifest(path)
            }
            snapshots.append(try await stableRead(source))
        }
        return .init(revision: revision, files: snapshots)
    }

    private func stableRead(_ source: DevBuildManifest.SourceFile) async throws -> SourceSnapshot.File {
        for _ in 0..<maximumAttempts {
            guard let first = try read(source) else {
                throw SourceSnapshot.Error.sourceDisappeared(source.absolutePath)
            }
            try await Task.sleep(nanoseconds: stabilityDelayNanoseconds)
            guard let second = try read(source) else {
                throw SourceSnapshot.Error.sourceDisappeared(source.absolutePath)
            }
            if first.inode == second.inode,
               first.byteCount == second.byteCount,
               first.modificationNanoseconds == second.modificationNanoseconds,
               first.contentHash == second.contentHash
            {
                return second
            }
        }
        throw SourceSnapshot.Error.sourceDidNotStabilize(source.absolutePath)
    }

    private func read(_ source: DevBuildManifest.SourceFile) throws -> SourceSnapshot.File? {
        guard FileManager.default.fileExists(atPath: source.absolutePath) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.absolutePath)
        if let size = (attributes[.size] as? NSNumber)?.uint64Value,
           size > UInt64(maximumSourceBytes)
        {
            throw SourceSnapshot.Error.sourceTooLarge(source.absolutePath)
        }
        let data = try Data(
            contentsOf: URL(fileURLWithPath: source.absolutePath),
            options: .mappedIfSafe
        )
        guard data.count <= maximumSourceBytes else {
            throw SourceSnapshot.Error.sourceTooLarge(source.absolutePath)
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64(data.count)
        let date = (attributes[.modificationDate] as? Date) ?? .distantPast
        let interval = date.timeIntervalSince1970 * 1_000_000_000
        let nanos: UInt64
        if interval.isFinite, interval > 0, interval < Double(UInt64.max) {
            nanos = UInt64(interval)
        } else {
            nanos = 0
        }
        return .init(
            id: source.id,
            logicalPath: source.logicalPath,
            absolutePath: source.absolutePath,
            inode: inode,
            byteCount: size,
            modificationNanoseconds: nanos,
            contentHash: .sha256(data),
            contents: data
        )
    }
}

public final class FileWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var continuation: AsyncStream<URL>.Continuation?
    public let events: AsyncStream<URL>

    public init(locations: [URL], queue: DispatchQueue = .init(label: "dev.helix.file-watcher")) throws {
        var captured: AsyncStream<URL>.Continuation?
        events = AsyncStream { continuation in captured = continuation }
        continuation = captured

        #if canImport(Darwin)
        for location in Set(locations.map(\.standardizedFileURL)) {
            let descriptor = Darwin.open(location.path, O_EVTONLY)
            guard descriptor >= 0 else {
                stop()
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.yield(location)
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
        #else
        throw BuildCapture.Error.invalidManifest("file watching requires Darwin")
        #endif
    }

    public func stop() {
        lock.lock()
        let oldSources = sources
        sources.removeAll()
        let oldContinuation = continuation
        continuation = nil
        lock.unlock()

        oldSources.forEach { $0.cancel() }
        oldContinuation?.finish()
    }

    private func yield(_ directory: URL) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(directory)
    }

    deinit {
        stop()
    }
}
}
