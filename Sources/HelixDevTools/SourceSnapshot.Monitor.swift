import Foundation
import HelixCore
import HelixDevProtocol

extension SourceSnapshot {
public enum MonitorEvent: Sendable {
    case changed(Set<String>)
    case rebuildRequired(DevProtocol.Diagnostic)
}

private struct FileFingerprint: Equatable, Sendable {
    var inode: UInt64
    var byteCount: UInt64
    var modificationNanoseconds: UInt64
    var contentHash: Core.Digest
}

private struct WorkspaceScanner: Sendable {
    var sources: [DevBuildManifest.SourceFile]
    var fingerprints: [String: SourceSnapshot.FileFingerprint]
    var maximumSourceBytes: Int

    init(manifest: DevBuildManifest.Document, maximumSourceBytes: Int) throws {
        guard maximumSourceBytes > 0 else {
            throw SourceSnapshot.Error.invalidConfiguration
        }
        sources = manifest.sourceFiles.sorted { $0.absolutePath < $1.absolutePath }
        fingerprints = [:]
        self.maximumSourceBytes = maximumSourceBytes
        for source in sources {
            var fingerprint = try Self.fingerprint(
                source.absolutePath,
                maximumSourceBytes: maximumSourceBytes
            )
            // The frozen Shell, rather than connection time, is the source
            // baseline. This lets an installed test build catch up when it
            // pairs after the developer has already edited a file.
            fingerprint.contentHash = source.contentHash
            fingerprints[source.absolutePath] = fingerprint
        }
    }

    mutating func scan() throws -> Set<String> {
        var changed = Set<String>()
        for source in sources {
            let current = try Self.fingerprint(
                source.absolutePath,
                maximumSourceBytes: maximumSourceBytes
            )
            if fingerprints[source.absolutePath] != current {
                fingerprints[source.absolutePath] = current
                changed.insert(source.absolutePath)
            }
        }
        return changed
    }

    private static func fingerprint(
        _ path: String,
        maximumSourceBytes: Int
    ) throws -> SourceSnapshot.FileFingerprint {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SourceSnapshot.Error.sourceDisappeared(path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        if let size = (attributes[.size] as? NSNumber)?.uint64Value,
           size > UInt64(maximumSourceBytes)
        {
            throw SourceSnapshot.Error.sourceTooLarge(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        guard data.count <= maximumSourceBytes else {
            throw SourceSnapshot.Error.sourceTooLarge(path)
        }
        let date = (attributes[.modificationDate] as? Date) ?? .distantPast
        let interval = date.timeIntervalSince1970 * 1_000_000_000
        let nanoseconds: UInt64
        if interval.isFinite, interval > 0, interval < Double(UInt64.max) {
            nanoseconds = UInt64(interval)
        } else {
            nanoseconds = 0
        }
        return .init(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64(data.count),
            modificationNanoseconds: nanoseconds,
            contentHash: .sha256(data)
        )
    }
}

/// Converts noisy directory notifications into one stable set of known Swift
/// source paths. Unknown target membership remains a full-build condition.
public actor Monitor {
    public typealias EventHandler = @Sendable (SourceSnapshot.MonitorEvent) async -> Void

    public let debounceNanoseconds: UInt64
    public let maximumSourceBytes: Int
    private let watcher: SourceSnapshot.FileWatcher
    private let eventHandler: EventHandler
    private var scanner: SourceSnapshot.WorkspaceScanner
    private var eventTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    private var isStopped = false

    public init(
        manifest: DevBuildManifest.Document,
        debounceNanoseconds: UInt64 = 120_000_000,
        maximumSourceBytes: Int = 8 * 1_024 * 1_024,
        eventHandler: @escaping EventHandler
    ) throws {
        try manifest.validate()
        guard debounceNanoseconds > 0, maximumSourceBytes > 0 else {
            throw SourceSnapshot.Error.invalidConfiguration
        }
        let directories = Set(
            manifest.sourceFiles.map {
                URL(fileURLWithPath: $0.absolutePath).deletingLastPathComponent()
            }
        )
        guard !directories.isEmpty, directories.count <= 1_024 else {
            throw SourceSnapshot.Error.invalidConfiguration
        }
        self.debounceNanoseconds = debounceNanoseconds
        self.maximumSourceBytes = maximumSourceBytes
        // Parent directories report editor-style atomic replacements, while
        // file descriptors report in-place writes that leave directory entries
        // untouched. Watching both makes save detection independent of editor
        // safe-save policy.
        let files = Set(manifest.sourceFiles.map { URL(fileURLWithPath: $0.absolutePath) })
        watcher = try .init(locations: Array(directories.union(files)))
        scanner = try .init(
            manifest: manifest,
            maximumSourceBytes: maximumSourceBytes
        )
        self.eventHandler = eventHandler
    }

    public func start() {
        guard eventTask == nil, !isStopped else { return }
        let events = watcher.events
        eventTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { break }
                await self?.scheduleScan()
            }
        }
        flushAndDeliver()
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        debounceTask?.cancel()
        debounceTask = nil
        let deliveries = deliveryTasks.values
        deliveryTasks.removeAll()
        deliveries.forEach { $0.cancel() }
        eventTask?.cancel()
        eventTask = nil
        watcher.stop()
    }

    private func scheduleScan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                await self?.flushAndDeliver()
            } catch {
                // A newer file event owns the next scan.
            }
        }
    }

    private func flushAndDeliver() {
        guard !isStopped else { return }
        // Once scanning begins, later filesystem noise may schedule another
        // debounce but must not cancel a compilation already in flight.
        debounceTask = nil
        let event: SourceSnapshot.MonitorEvent
        do {
            let paths = try scanner.scan()
            guard !paths.isEmpty else { return }
            event = .changed(paths)
        } catch {
            event = .rebuildRequired(
                .init(
                    code: "HLXLR205",
                    message: String(describing: error),
                    nextAction: "restore target source membership and rebuild the Dev Shell"
                )
            )
        }
        let id = UUID()
        let handler = eventHandler
        deliveryTasks[id] = Task { [weak self] in
            await handler(event)
            await self?.finishDelivery(id)
        }
    }

    private func finishDelivery(_ id: UUID) {
        deliveryTasks[id] = nil
    }
}
}

extension DevSession {
public final class LiveLoop: @unchecked Sendable {
    public typealias ResultHandler = @Sendable (DevSession.PipelineResult) async -> Void

    public let pipeline: DevSession.Pipeline
    public let monitor: SourceSnapshot.Monitor

    public init(
        pipeline: DevSession.Pipeline,
        manifest: DevBuildManifest.Document,
        debounceNanoseconds: UInt64 = 120_000_000,
        maximumSourceBytes: Int = 8 * 1_024 * 1_024,
        resultHandler: @escaping ResultHandler = { _ in }
    ) throws {
        self.pipeline = pipeline
        monitor = try .init(
            manifest: manifest,
            debounceNanoseconds: debounceNanoseconds,
            maximumSourceBytes: maximumSourceBytes
        ) { event in
            switch event {
            case let .changed(paths):
                await resultHandler(await pipeline.submit(changedPaths: paths))
            case let .rebuildRequired(diagnostic):
                await resultHandler(.rebuildRequired(diagnostic))
            }
        }
    }

    public func start() async {
        await monitor.start()
    }

    public func stop() async {
        await monitor.stop()
    }
}
}
