import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

public enum PatchScheduling {}

extension PatchScheduling {
public enum BuildOutcome: Sendable {
    case artifact(DevProtocol.LiveArtifact)
    case noSemanticChange(DevProtocol.SourceRevision)
    case rebuildRequired(DevProtocol.Diagnostic)
    case failed(DevProtocol.Diagnostic)
    case superseded(DevProtocol.SourceRevision)
}

public actor Scheduler {
    public typealias Builder = @Sendable (SourceSnapshot.Document) async throws -> PatchScheduling.BuildOutcome
    public typealias ResultHandler = @Sendable (PatchScheduling.BuildOutcome) async -> Void

    private var highestScheduledRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var currentTask: Task<Void, Never>?
    private let resultHandler: ResultHandler

    public init(resultHandler: @escaping ResultHandler) {
        self.resultHandler = resultHandler
    }

    public func submit(
        _ snapshot: SourceSnapshot.Document,
        builder: @escaping Builder
    ) throws {
        guard snapshot.revision > highestScheduledRevision else {
            throw DevProtocol.Diagnostic.staleRevision(
                snapshot.revision,
                highest: highestScheduledRevision
            )
        }
        highestScheduledRevision = snapshot.revision
        currentTask?.cancel()
        currentTask = Task { [snapshot, builder] in
            let outcome: PatchScheduling.BuildOutcome
            do {
                outcome = try await builder(snapshot)
            } catch is CancellationError {
                outcome = .superseded(snapshot.revision)
            } catch let diagnostic as DevProtocol.Diagnostic {
                outcome = .failed(diagnostic)
            } catch {
                outcome = .failed(
                    .init(
                        code: "HLXLR299",
                        message: String(describing: error),
                        sourceRevision: snapshot.revision,
                        previousCodeRemainsActive: true,
                        nextAction: "fix the compile error and save again"
                    )
                )
            }
            await self.finish(outcome, revision: snapshot.revision)
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    public var highestRevision: DevProtocol.SourceRevision { highestScheduledRevision }

    private func finish(
        _ outcome: PatchScheduling.BuildOutcome,
        revision: DevProtocol.SourceRevision
    ) async {
        guard revision == highestScheduledRevision else {
            await resultHandler(.superseded(revision))
            return
        }
        currentTask = nil
        await resultHandler(outcome)
    }
}

public actor BaselineStore {
    public let installedBaseline: [LiveReload.SourceFileID: Core.Digest]
    private var lastApplied: [LiveReload.SourceFileID: Core.Digest]
    private var highestAppliedRevision = DevProtocol.SourceRevision(rawValue: 0)

    public init(installedBaseline: [LiveReload.SourceFileID: Core.Digest]) {
        self.installedBaseline = installedBaseline
        lastApplied = installedBaseline
    }

    public func classify(_ snapshot: SourceSnapshot.Document) -> PatchScheduling.SnapshotClassification {
        var changed: [LiveReload.SourceFileID] = []
        var restored: [LiveReload.SourceFileID] = []
        for file in snapshot.files {
            if lastApplied[file.id] != file.contentHash { changed.append(file.id) }
            if installedBaseline[file.id] == file.contentHash,
               lastApplied[file.id] != file.contentHash
            {
                restored.append(file.id)
            }
        }
        return .init(
            changedFiles: changed.sorted { $0.description < $1.description },
            restoredToBaseline: restored.sorted { $0.description < $1.description }
        )
    }

    public func markAccepted(_ snapshot: SourceSnapshot.Document) throws {
        guard snapshot.revision > highestAppliedRevision else {
            throw DevProtocol.Diagnostic.staleRevision(
                snapshot.revision,
                highest: highestAppliedRevision
            )
        }
        for file in snapshot.files { lastApplied[file.id] = file.contentHash }
        highestAppliedRevision = snapshot.revision
    }

    public func markApplied(_ snapshot: SourceSnapshot.Document) throws {
        try markAccepted(snapshot)
    }
}

public struct SnapshotClassification: Hashable, Sendable {
    public var changedFiles: [LiveReload.SourceFileID]
    public var restoredToBaseline: [LiveReload.SourceFileID]

    public init(
        changedFiles: [LiveReload.SourceFileID],
        restoredToBaseline: [LiveReload.SourceFileID]
    ) {
        self.changedFiles = changedFiles
        self.restoredToBaseline = restoredToBaseline
    }
}
}
