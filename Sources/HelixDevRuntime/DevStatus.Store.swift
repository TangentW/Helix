import Combine
import Foundation
import HelixDevProtocol
import HelixLiveReloadAPI

public enum DevStatus {}

extension DevStatus {
public enum Phase: String, Codable, Hashable, Sendable {
    case idle
    case connecting
    case authenticated
    case compiling
    case transferring
    case codeActive
    case rebuildRequired
    case restartRequired
    case disconnected
    case failed
}

public enum Tone: String, Codable, Hashable, Sendable {
    case neutral
    case progress
    case success
    case warning
    case error
}

public struct Snapshot: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let phase: DevStatus.Phase
    public let tone: DevStatus.Tone
    public let headline: String
    public let detail: String?
    public let sourceRevision: DevProtocol.SourceRevision?
    public let generationID: DevProtocol.GenerationID?
    public let activeSourceRevision: DevProtocol.SourceRevision?
    public let activeGenerationID: DevProtocol.GenerationID?
    public let codeStatus: DevProtocol.CodeActivationStatus?
    public let reloadStatus: DevProtocol.UIReloadStatus?
    public let updatedAt: Date

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

public struct ObservationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

@MainActor
public final class Store: ObservableObject {
    public typealias Observer = @MainActor (DevStatus.Snapshot) -> Void

    @Published public private(set) var snapshot = DevStatus.Snapshot()
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

    public init() {}

    @discardableResult
    public func observe(
        _ observer: @escaping Observer
    ) -> DevStatus.ObservationToken {
        let token = DevStatus.ObservationToken(rawValue: UUID())
        observers[token] = observer
        observer(snapshot)
        return token
    }

    public func removeObserver(_ token: DevStatus.ObservationToken) {
        observers.removeValue(forKey: token)
    }

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
                    "\($0.message) Next: \($0.nextAction)"
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

    public func connectionEventHandler() -> DevConnection.Client.EventHandler {
        { [weak self] event in
            await self?.handle(event)
        }
    }
    #endif

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
