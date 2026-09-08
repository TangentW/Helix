import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

extension DevSession {
public struct BuildRequest: Sendable {
    public var snapshot: SourceSnapshot.Document
    public var classification: PatchScheduling.SnapshotClassification
    public var generationID: DevProtocol.GenerationID
    public var candidateFunctionKeys: Set<Core.FunctionKey>
    public var reason: LiveReload.Reason

    public init(
        snapshot: SourceSnapshot.Document,
        classification: PatchScheduling.SnapshotClassification,
        generationID: DevProtocol.GenerationID,
        candidateFunctionKeys: Set<Core.FunctionKey>,
        reason: LiveReload.Reason
    ) {
        self.snapshot = snapshot
        self.classification = classification
        self.generationID = generationID
        self.candidateFunctionKeys = candidateFunctionKeys
        self.reason = reason
    }
}

public struct BuiltPatch: Sendable {
    public var backend: LiveReload.Backend
    public var payload: Data
    public var changedFunctions: Set<Core.FunctionKey>
    public var restoredFunctions: Set<Core.FunctionKey>
    public var debugSymbolsUUID: UUID?
    public var debugSymbols: DebugSymbols.Artifact?
    public var mode: DevProtocol.PatchMode

    public init(
        backend: LiveReload.Backend,
        payload: Data,
        changedFunctions: Set<Core.FunctionKey>,
        restoredFunctions: Set<Core.FunctionKey> = [],
        debugSymbolsUUID: UUID? = nil,
        debugSymbols: DebugSymbols.Artifact? = nil,
        mode: DevProtocol.PatchMode = .replacement
    ) {
        self.backend = backend
        self.payload = payload
        self.changedFunctions = changedFunctions
        self.restoredFunctions = restoredFunctions
        self.debugSymbolsUUID = debugSymbols?.imageUUID ?? debugSymbolsUUID
        self.debugSymbols = debugSymbols
        self.mode = mode
    }
}

public enum BuildOutcome: Sendable {
    case patch(DevSession.BuiltPatch)
    case noSemanticChange
    case rebuildRequired(DevProtocol.Diagnostic)
}

public enum PipelineResult: Sendable {
    case activation(DevProtocol.ActivationResult)
    case noSemanticChange(DevProtocol.SourceRevision)
    case rebuildRequired(DevProtocol.Diagnostic)
    case failed(DevProtocol.Diagnostic)
    case superseded(DevProtocol.SourceRevision)

    /// Diagnostics that must cross the authenticated channel so the App-side
    /// status surface cannot remain on an earlier progress state.
    var diagnosticsForApp: [DevProtocol.Diagnostic]? {
        switch self {
        case let .failed(diagnostic), let .rebuildRequired(diagnostic):
            [diagnostic]
        case .activation, .noSemanticChange, .superseded:
            nil
        }
    }
}

public enum PipelineEvent: Sendable {
    case snapshotting(DevProtocol.SourceRevision, [String])
    case compiling(DevProtocol.SourceRevision, DevProtocol.GenerationID)
    case transferring(DevProtocol.PatchOffer)
    case debugSymbols(DebugSymbols.Artifact)
    case completed(DevSession.PipelineResult)
}

/// Coordinates stable source capture, compilation, latest-wins scheduling, and
/// one-at-a-time activation. A compiler implementation is injected so Native
/// and HLBC backends share exactly the same transaction semantics.
public actor Pipeline {
    public typealias Builder = @Sendable (
        DevSession.BuildRequest
    ) async throws -> DevSession.BuildOutcome
    public typealias Sender = @Sendable (
        DevProtocol.LiveArtifact
    ) async throws -> DevProtocol.ActivationResult
    public typealias Superseder = @Sendable (DevProtocol.SourceRevision) async -> Void
    public typealias EventHandler = @Sendable (DevSession.PipelineEvent) async -> Void
    public typealias ActivationHandler = @Sendable (
        DevProtocol.PatchOffer,
        DevProtocol.ActivationResult
    ) async -> Void

    public let identity: DevProtocol.SessionIdentity
    public let manifest: DevBuildManifest.Document
    public let reloadIndex: ReloadIndex.Document

    private let snapshotter: SourceSnapshot.Snapshotter
    private let baseline: PatchScheduling.BaselineStore
    private let builder: Builder
    private let sender: Sender
    private let superseder: Superseder
    private let eventHandler: EventHandler
    private let activationHandler: ActivationHandler
    private var highestAllocatedRevision: DevProtocol.SourceRevision
    private var highestAllocatedGeneration: DevProtocol.GenerationID
    private var newestRevision: DevProtocol.SourceRevision
    private var transferIsBusy = false
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        identity: DevProtocol.SessionIdentity,
        manifest: DevBuildManifest.Document,
        reloadIndex: ReloadIndex.Document,
        snapshotter: SourceSnapshot.Snapshotter = .init(),
        builder: @escaping Builder,
        sender: @escaping Sender,
        superseder: @escaping Superseder = { _ in },
        eventHandler: @escaping EventHandler = { _ in },
        activationHandler: @escaping ActivationHandler = { _, _ in }
    ) throws {
        try identity.validate()
        try manifest.validate()
        try reloadIndex.validate()
        guard identity.sessionID == manifest.sessionBuildID,
              identity.bundleID == manifest.bundleID,
              identity.executableUUID == manifest.executableUUID,
              identity.platform == manifest.platform,
              identity.architecture == manifest.architecture,
              identity.xcodeBuild == manifest.xcodeBuild,
              identity.swiftCompilerFingerprint == manifest.swiftCompilerFingerprint,
              identity.liveReloadIndexHash == manifest.liveReloadIndexHash,
              try reloadIndex.contentHash() == manifest.liveReloadIndexHash
        else {
            throw DevProtocol.Diagnostic.sessionMismatch(
                "Dev Manifest, Reload Index, and running process do not share one identity"
            )
        }
        self.identity = identity
        self.manifest = manifest
        self.reloadIndex = reloadIndex
        self.snapshotter = snapshotter
        baseline = .init(
            installedBaseline: Dictionary(
                uniqueKeysWithValues: manifest.sourceFiles.map { ($0.id, $0.contentHash) }
            )
        )
        self.builder = builder
        self.sender = sender
        self.superseder = superseder
        self.eventHandler = eventHandler
        self.activationHandler = activationHandler
        highestAllocatedRevision = identity.highestAppliedSourceRevision
        newestRevision = identity.highestAppliedSourceRevision
        highestAllocatedGeneration = identity.activeGenerationID ?? .init(rawValue: 0)
    }

    public func submit(changedPaths: Set<String>) async -> DevSession.PipelineResult {
        let revision: DevProtocol.SourceRevision
        do {
            revision = try allocateRevision()
        } catch let diagnostic as DevProtocol.Diagnostic {
            let result = DevSession.PipelineResult.failed(diagnostic)
            await eventHandler(.completed(result))
            return result
        } catch {
            let result = DevSession.PipelineResult.failed(
                diagnostic(
                    code: "HLXLR205",
                    message: String(describing: error),
                    revision: nil,
                    nextAction: "restart the Dev Session"
                )
            )
            await eventHandler(.completed(result))
            return result
        }
        newestRevision = revision
        await superseder(revision)
        await eventHandler(.snapshotting(revision, changedPaths.sorted()))

        do {
            guard !changedPaths.isEmpty else {
                let result = DevSession.PipelineResult.noSemanticChange(revision)
                await eventHandler(.completed(result))
                return result
            }
            let snapshot = try await snapshotter.capture(
                changedPaths: changedPaths,
                manifest: manifest,
                revision: revision
            )
            guard revision == newestRevision else {
                return await complete(.superseded(revision))
            }
            let classification = await baseline.classify(snapshot)
            guard !classification.changedFiles.isEmpty else {
                try await baseline.markAccepted(snapshot)
                return await complete(.noSemanticChange(revision))
            }
            let excludedIDs = Set(manifest.indexingPolicy?.excludedSourceIDs ?? [])
                .intersection(classification.changedFiles)
            if !excludedIDs.isEmpty {
                let paths = manifest.sourceFiles.filter { excludedIDs.contains($0.id) }.map(\.logicalPath).sorted()
                let sample = paths.prefix(8).joined(separator: ", ")
                let examples = String(decoding: sample.utf8.prefix(8 * 1_024), as: UTF8.self)
                // Do not advance the accepted baseline: repeated saves must
                // continue to warn until the edit is rebuilt or reverted.
                return await complete(.rebuildRequired(diagnostic(
                    code: "HLXLR209",
                    message: "Saved changes touch \(paths.count) file(s) excluded from live indexing: \(examples)"
                        + (paths.count > 8 || sample.utf8.count > 8 * 1_024 ? " (sample limited to 8 paths / 8192 bytes)" : ""),
                    revision: revision,
                    nextAction: "Build/Run the App normally. Files containing unresolved declarations are conservatively excluded from live saves; inspect FrontendDiagnostics.json or helix xcode exclusions."
                )))
            }
            let changedSourceIDs = Set(snapshot.files.map(\.id))
            let candidateFunctions = candidateFunctions(for: changedSourceIDs)
            let reason: LiveReload.Reason = Set(classification.changedFiles)
                == Set(classification.restoredToBaseline) ? .baselineRestored : .sourceSaved
            let generation = try allocateGeneration(revision: revision)
            await eventHandler(.compiling(revision, generation))
            let buildOutcome = try await builder(
                .init(
                    snapshot: snapshot,
                    classification: classification,
                    generationID: generation,
                    candidateFunctionKeys: candidateFunctions,
                    reason: reason
                )
            )
            guard revision == newestRevision else {
                return await complete(.superseded(revision))
            }
            switch buildOutcome {
            case .noSemanticChange:
                try await baseline.markAccepted(snapshot)
                return await complete(.noSemanticChange(revision))
            case let .rebuildRequired(diagnostic):
                return await complete(.rebuildRequired(diagnostic))
            case let .patch(patch):
                guard !patch.changedFunctions.isEmpty,
                      patch.changedFunctions.isSubset(of: candidateFunctions),
                      patch.restoredFunctions.isSubset(of: patch.changedFunctions),
                      patch.debugSymbols == nil
                        || patch.debugSymbols?.imageUUID == patch.debugSymbolsUUID
                else {
                    throw diagnostic(
                        code: "HLXLR205",
                        message: "compiler output is empty or not rooted in the current Reload Index",
                        revision: revision,
                        generation: generation,
                        backend: patch.backend,
                        nextAction: "rebuild the Dev Shell and its Reload Index"
                    )
                }
                let hints = try reloadIndex.hints(
                    changedSources: changedSourceIDs,
                    changedFunctions: patch.changedFunctions
                )
                let affectedTypes = Set(hints.compactMap(\.nominalTypeID))
                let offer = DevProtocol.PatchOffer(
                    sessionID: identity.sessionID,
                    sourceRevision: revision,
                    generationID: generation,
                    backend: patch.backend,
                    payloadByteLength: UInt64(patch.payload.count),
                    payloadSHA256: .sha256(patch.payload),
                    changedSources: Array(changedSourceIDs),
                    changedFunctions: Array(patch.changedFunctions),
                    restoredFunctions: Array(patch.restoredFunctions),
                    affectedNominalTypes: Array(affectedTypes),
                    reloadHints: hints,
                    debugSymbolsUUID: patch.debugSymbolsUUID,
                    reason: reason,
                    mode: patch.mode
                )
                try offer.validate()
                await acquireTransfer()
                guard revision == newestRevision else {
                    releaseTransfer()
                    return await complete(.superseded(revision))
                }
                await eventHandler(.transferring(offer))
                let activation: DevProtocol.ActivationResult
                do {
                    activation = try await sender(.init(offer: offer, payload: patch.payload))
                    releaseTransfer()
                } catch {
                    releaseTransfer()
                    throw error
                }
                if activation.codeStatus == .codeActive {
                    try await baseline.markAccepted(snapshot)
                    if let debugSymbols = patch.debugSymbols {
                        await eventHandler(.debugSymbols(debugSymbols))
                    }
                }
                await activationHandler(offer, activation)
                return await complete(.activation(activation))
            }
        } catch is CancellationError {
            return await complete(.superseded(revision))
        } catch let diagnostic as DevProtocol.Diagnostic {
            return await complete(.failed(diagnostic))
        } catch {
            return await complete(
                .failed(
                    diagnostic(
                        code: "HLXLR299",
                        message: String(describing: error),
                        revision: revision,
                        nextAction: "fix the source or Dev Session error and save again"
                    )
                )
            )
        }
    }

    private func candidateFunctions(
        for sourceIDs: Set<LiveReload.SourceFileID>
    ) -> Set<Core.FunctionKey> {
        Set(
            reloadIndex.sourceRoots
                .filter { sourceIDs.contains($0.sourceFileID) }
                .flatMap(\.roots)
        )
    }

    private func allocateRevision() throws -> DevProtocol.SourceRevision {
        let next = highestAllocatedRevision.rawValue.addingReportingOverflow(1)
        guard !next.overflow else {
            throw diagnostic(
                code: "HLXLR205",
                message: "source revision space is exhausted",
                revision: highestAllocatedRevision,
                nextAction: "restart the Dev Session"
            )
        }
        let revision = DevProtocol.SourceRevision(rawValue: next.partialValue)
        highestAllocatedRevision = revision
        return revision
    }

    private func allocateGeneration(
        revision: DevProtocol.SourceRevision
    ) throws -> DevProtocol.GenerationID {
        let next = highestAllocatedGeneration.rawValue.addingReportingOverflow(1)
        guard !next.overflow else {
            throw diagnostic(
                code: "HLXLR205",
                message: "generation ID space is exhausted",
                revision: revision,
                nextAction: "restart the Dev App"
            )
        }
        let generation = DevProtocol.GenerationID(rawValue: next.partialValue)
        highestAllocatedGeneration = generation
        return generation
    }

    private func acquireTransfer() async {
        if !transferIsBusy {
            transferIsBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            transferWaiters.append(continuation)
        }
    }

    private func releaseTransfer() {
        guard !transferWaiters.isEmpty else {
            transferIsBusy = false
            return
        }
        transferWaiters.removeFirst().resume()
    }

    private func complete(
        _ result: DevSession.PipelineResult
    ) async -> DevSession.PipelineResult {
        await eventHandler(.completed(result))
        return result
    }

    private func diagnostic(
        code: String,
        message: String,
        revision: DevProtocol.SourceRevision?,
        generation: DevProtocol.GenerationID? = nil,
        backend: LiveReload.Backend? = nil,
        nextAction: String
    ) -> DevProtocol.Diagnostic {
        .init(
            code: code,
            message: message,
            sourceRevision: revision,
            generationID: generation,
            backend: backend,
            nextAction: nextAction
        )
    }
}
}
