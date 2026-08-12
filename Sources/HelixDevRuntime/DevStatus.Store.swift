import Combine
import Foundation
import HelixDevProtocol
import HelixLiveReloadAPI

/// Observable, presentation-ready state for a Helix development session.
public enum DevStatus {}

extension DevStatus {
/// High-level stage displayed by the on-device debug overlay.
public enum Phase: String, Codable, Hashable, Sendable {
    /// Live Reload has not started or has stopped cleanly.
    case idle
    /// The App is discovering or connecting to its paired daemon.
    case connecting
    /// The authenticated session is ready for messages.
    case authenticated
    /// The daemon is compiling a source revision.
    case compiling
    /// The App is receiving a compiled generation.
    case transferring
    /// A generation is active, regardless of whether UI refresh succeeded.
    case codeActive
    /// The edited source cannot be applied without a full rebuild.
    case rebuildRequired
    /// Native runtime state is uncertain and the App must restart.
    case restartRequired
    /// The connection closed and may be retried.
    case disconnected
    /// Compilation, validation, transfer, or activation failed safely.
    case failed
}

/// Semantic color category for a development status presentation.
public enum Tone: String, Codable, Hashable, Sendable {
    /// Informational state with no success or failure implication.
    case neutral
    /// Work is currently in progress.
    case progress
    /// The latest requested operation completed successfully.
    case success
    /// Code may be active but developer attention is required.
    case warning
    /// The requested operation failed.
    case error
}

/// Immutable status value suitable for UIKit, SwiftUI, logs, or tests.
public struct Snapshot: Codable, Hashable, Sendable {
    /// Monotonically increasing local publication sequence.
    public let sequence: UInt64
    /// Current development-session stage.
    public let phase: DevStatus.Phase
    /// Presentation tone associated with ``phase``.
    public let tone: DevStatus.Tone
    /// Short user-facing summary.
    public let headline: String
    /// Optional diagnostic or next-action detail.
    public let detail: String?
    /// Source revision involved in the latest event.
    public let sourceRevision: DevProtocol.SourceRevision?
    /// Generation involved in the latest event.
    public let generationID: DevProtocol.GenerationID?
    /// Most recently activated source revision.
    public let activeSourceRevision: DevProtocol.SourceRevision?
    /// Generation whose code currently owns dispatch routes.
    public let activeGenerationID: DevProtocol.GenerationID?
    /// Code activation result associated with the latest event.
    public let codeStatus: DevProtocol.CodeActivationStatus?
    /// UI refresh result associated with the latest event.
    public let reloadStatus: DevProtocol.UIReloadStatus?
    /// Local publication time.
    public let updatedAt: Date

    /// Creates an explicit status snapshot.
    public init(
        sequence: UInt64 = 0,
        phase: DevStatus.Phase = .idle,
        tone: DevStatus.Tone = .neutral,
        headline: String = "Idle",
        detail: String? = nil,
        sourceRevision: DevProtocol.SourceRevision? = nil,
        generationID: DevProtocol.GenerationID? = nil,
        activeSourceRevision: DevProtocol.SourceRevision? = nil,
        activeGenerationID: DevProtocol.GenerationID? = nil,
        codeStatus: DevProtocol.CodeActivationStatus? = nil,
        reloadStatus: DevProtocol.UIReloadStatus? = nil,
        updatedAt: Date = Date()
    ) {
        self.sequence = sequence
        self.phase = phase
        self.tone = tone
        self.headline = headline
        self.detail = detail
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.activeSourceRevision = activeSourceRevision
        self.activeGenerationID = activeGenerationID
        self.codeStatus = codeStatus
        self.reloadStatus = reloadStatus
        self.updatedAt = updatedAt
    }
}

/// Opaque token identifying a callback registered with ``Store``.
public struct ObservationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

/// Reduces connection, activation, and reload events into observable UI state.
///
/// The current value is available through ``snapshot`` and is also published
/// through `ObservableObject`. Callback observation is useful for UIKit:
///
/// ```swift
/// let token = store.observe { snapshot in
///     label.text = snapshot.headline
/// }
/// // Later: store.removeObserver(token)
/// ```
@MainActor
public final class Store: ObservableObject {
    /// Main-actor callback invoked with each published snapshot.
    public typealias Observer = @MainActor (DevStatus.Snapshot) -> Void

    /// Most recently reduced development status.
    @Published public private(set) var snapshot = DevStatus.Snapshot()
    /// Up to 50 recent publications, ordered from oldest to newest.
    public private(set) var history: [DevStatus.Snapshot] = []

    private let historyLimit = 50
    private var observers: [DevStatus.ObservationToken: Observer] = [:]
    private var activeSourceRevision: DevProtocol.SourceRevision?
    private var activeGenerationID: DevProtocol.GenerationID?
    private var pendingUIResult: (
        context: LiveReload.Context,
        status: DevProtocol.UIReloadStatus,
        warnings: [String],
        errors: [String]
    )?

    /// Creates an idle status store.
    public init() {}

    /// Registers an observer and immediately sends the current snapshot.
    ///
    /// Retain the returned token and pass it to ``removeObserver(_:)`` when the
    /// observer no longer needs updates.
    @discardableResult
    public func observe(
        _ observer: @escaping Observer
    ) -> DevStatus.ObservationToken {
        let token = DevStatus.ObservationToken(rawValue: UUID())
        observers[token] = observer
        observer(snapshot)
        return token
    }

    /// Removes a callback observer. Unknown tokens are ignored.
    public func removeObserver(_ token: DevStatus.ObservationToken) {
        observers.removeValue(forKey: token)
    }

    /// Reduces an authenticated session event into presentation state.
    public func handle(_ event: DevRuntimeSession.Event) {
        switch event {
        case .authenticated:
            publish(
                phase: .authenticated,
                tone: .success,
                headline: "Connected"
            )
        case let .compileStarted(revision):
            publish(
                phase: .compiling,
                tone: .progress,
                headline: "Compiling \(revision)",
                sourceRevision: revision
            )
        case let .diagnostics(diagnostics):
            let diagnostic = diagnostics.first
            let rebuild = diagnostic?.code.hasPrefix("HLXLR3") == true
            publish(
                phase: rebuild ? .rebuildRequired : .failed,
                tone: .error,
                headline: rebuild
                    ? "Full rebuild required"
                    : "Compile failed · old code active",
                detail: diagnostic.map {
                    "[\($0.code)] \($0.message) Next: \($0.nextAction)"
                },
                sourceRevision: diagnostic?.sourceRevision,
                generationID: diagnostic?.generationID
            )
        case let .transferAccepted(revision, generation):
            publish(
                phase: .transferring,
                tone: .progress,
                headline: "Transferring \(generation)",
                sourceRevision: revision,
                generationID: generation
            )
        case let .activationCompleted(result):
            record(result)
        case let .closed(reason):
            publish(
                phase: .disconnected,
                tone: .warning,
                headline: "Disconnected",
                detail: reason
            )
        }
    }

    #if canImport(Network) && canImport(Security)
    /// Reduces a connection lifecycle event into presentation state.
    public func handle(_ event: DevConnection.ClientEvent) {
        switch event {
        case let .connecting(attempt):
            publish(
                phase: .connecting,
                tone: .progress,
                headline: "Connecting",
                detail: "Attempt \(attempt)"
            )
        case let .session(event):
            handle(event)
        case let .reconnectScheduled(attempt, delay, reason):
            let seconds = Double(delay) / 1_000_000_000
            publish(
                phase: .disconnected,
                tone: .warning,
                headline: "Reconnecting",
                detail: "Attempt \(attempt) in \(String(format: "%.2f", seconds)) s: \(reason)"
            )
        case .stopped:
            publish(
                phase: .idle,
                tone: .neutral,
                headline: "Live Reload stopped"
            )
        }
    }

    /// Returns a weakly capturing adapter suitable for ``DevConnection/Client``.
    public func connectionEventHandler() -> DevConnection.Client.EventHandler {
        { [weak self] event in
            await self?.handle(event)
        }
    }
    #endif

    /// Records a final code activation result.
    ///
    /// A UI result reported slightly before activation completion is correlated
    /// by source revision and generation rather than being lost.
    public func record(_ result: DevProtocol.ActivationResult) {
        let pending = pendingUIResult.flatMap {
            $0.context.generationID == result.generationID.rawValue
                && $0.context.sourceRevision == result.sourceRevision.rawValue
                ? $0
                : nil
        }
        pendingUIResult = nil
        switch result.codeStatus {
        case .codeActive:
            activeSourceRevision = result.sourceRevision
            activeGenerationID = result.generationID
            let status = pending?.status ?? result.reloadStatus
            let presentation = presentation(for: status)
            publish(
                phase: .codeActive,
                tone: pending?.errors.isEmpty == false ? .warning : presentation.tone,
                headline: presentation.headline,
                detail: ((pending?.errors ?? []) + (pending?.warnings ?? [])).first,
                sourceRevision: result.sourceRevision,
                generationID: result.generationID,
                codeStatus: result.codeStatus,
                reloadStatus: status
            )
        case .rejected:
            publish(
                phase: .failed,
                tone: .error,
                headline: "Patch rejected · old code active",
                detail: result.diagnostic?.description,
                sourceRevision: result.sourceRevision,
                generationID: result.generationID,
                codeStatus: result.codeStatus,
                reloadStatus: result.reloadStatus
            )
        case .nativeStateUncertain:
            publish(
                phase: .restartRequired,
                tone: .error,
                headline: "Restart required",
                detail: result.diagnostic?.description,
                sourceRevision: result.sourceRevision,
                generationID: result.generationID,
                codeStatus: result.codeStatus,
                reloadStatus: result.reloadStatus
            )
        }
    }

    /// Records the UI refresh outcome for an activated generation.
    ///
    /// The result updates the current presentation immediately when the matching
    /// generation is already active, or is held until its activation result arrives.
    public func recordUIResult(
        context: LiveReload.Context,
        _ status: DevProtocol.UIReloadStatus,
        warnings: [String],
        errors: [String]
    ) {
        pendingUIResult = (context, status, warnings, errors)
        guard activeGenerationID?.rawValue == context.generationID,
              activeSourceRevision?.rawValue == context.sourceRevision
        else { return }
        pendingUIResult = nil
        let presentation = presentation(for: status)
        publish(
            phase: .codeActive,
            tone: errors.isEmpty ? presentation.tone : .warning,
            headline: presentation.headline,
            detail: (errors + warnings).first,
            sourceRevision: snapshot.sourceRevision,
            generationID: snapshot.generationID,
            codeStatus: .codeActive,
            reloadStatus: status
        )
    }

    private func presentation(
        for status: DevProtocol.UIReloadStatus
    ) -> (headline: String, tone: DevStatus.Tone) {
        switch status {
        case .notRequested:
            ("Code active", .success)
        case .refreshed:
            ("Code active · UI refreshed", .success)
        case .manualRefreshRequired:
            ("Code active · manual refresh required", .warning)
        case .failed:
            ("Code active · UI refresh failed", .warning)
        }
    }

    private func publish(
        phase: DevStatus.Phase,
        tone: DevStatus.Tone,
        headline: String,
        detail: String? = nil,
        sourceRevision: DevProtocol.SourceRevision? = nil,
        generationID: DevProtocol.GenerationID? = nil,
        codeStatus: DevProtocol.CodeActivationStatus? = nil,
        reloadStatus: DevProtocol.UIReloadStatus? = nil
    ) {
        let next = DevStatus.Snapshot(
            sequence: snapshot.sequence + 1,
            phase: phase,
            tone: tone,
            headline: headline,
            detail: detail.map { String($0.prefix(2_048)) },
            sourceRevision: sourceRevision,
            generationID: generationID,
            activeSourceRevision: activeSourceRevision,
            activeGenerationID: activeGenerationID,
            codeStatus: codeStatus,
            reloadStatus: reloadStatus
        )
        snapshot = next
        history.append(next)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        for observer in observers.values { observer(next) }
    }
}
}
