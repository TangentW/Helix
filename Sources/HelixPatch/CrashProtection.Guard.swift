import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixRuntime
#endif

/// Persistent health journal and crash-loop rollback policy.
public enum CrashProtection {}

extension CrashProtection {
/// Health state recorded for one protected App launch.
public enum LaunchHealth: String, Codable, Hashable, Sendable {
    /// Startup began but the application has not passed its health gate.
    case launching
    /// The application explicitly confirmed a healthy launch.
    case healthy
}

/// Durable crash-protection journal bound to an activation generation.
public struct Journal: Codable, Hashable, Sendable {
    /// Journal schema version.
    public var schemaVersion: UInt16
    /// Generation protected by this launch, if any.
    public var activeGenerationID: Runtime.GenerationID?
    /// Parent generation used for automatic rollback.
    public var parentGenerationID: Runtime.GenerationID?
    /// Hash of the active package.
    public var activePackageHash: Core.Digest?
    /// Time at which the generation became active.
    public var activationTimestampUnixSeconds: Int64?
    /// Nonce identifying this exact App launch.
    public var sessionNonce: UUID
    /// Current launch health.
    public var health: CrashProtection.LaunchHealth
    /// Consecutive unclean launches within the configured window.
    public var consecutiveUncleanLaunches: UInt32
    /// Last journal update time.
    public var updatedAtUnixSeconds: Int64

    /// Creates a complete crash-protection journal value.
    public init(
        schemaVersion: UInt16 = 1,
        activeGenerationID: Runtime.GenerationID?,
        parentGenerationID: Runtime.GenerationID?,
        activePackageHash: Core.Digest? = nil,
        activationTimestampUnixSeconds: Int64? = nil,
        sessionNonce: UUID,
        health: CrashProtection.LaunchHealth,
        consecutiveUncleanLaunches: UInt32,
        updatedAtUnixSeconds: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.activeGenerationID = activeGenerationID
        self.parentGenerationID = parentGenerationID
        self.activePackageHash = activePackageHash
        self.activationTimestampUnixSeconds = activationTimestampUnixSeconds
        self.sessionNonce = sessionNonce
        self.health = health
        self.consecutiveUncleanLaunches = consecutiveUncleanLaunches
        self.updatedAtUnixSeconds = updatedAtUnixSeconds
    }
}

/// Action selected while beginning a protected launch.
public enum Decision: Equatable, Sendable {
    /// Continue with the selected generation and later confirm `sessionNonce`.
    case continueLaunch(sessionNonce: UUID)
    /// Roll back an interrupted generation before continuing launch.
    case rollback(
        interruptedGeneration: Runtime.GenerationID,
        targetGeneration: Runtime.GenerationID?,
        sessionNonce: UUID
    )
}

/// Applies crash-loop policy to the durable launch journal.
///
/// Applications normally use this through ``PatchRuntime/ApplicationSession``.
public final class Guard: @unchecked Sendable {
    private static let journalName = "crash-guard.json"

    /// Store containing the protected journal and activation state.
    public let store: PatchStore.Storage
    /// Unclean launches required before automatic rollback.
    public let uncleanLaunchThreshold: UInt32
    /// Time window in which unclean launches are considered consecutive.
    public let uncleanLaunchWindowSeconds: Int64

    /// Creates a crash guard with an explicit threshold and window.
    public init(
        store: PatchStore.Storage,
        uncleanLaunchThreshold: UInt32 = 2,
        uncleanLaunchWindowSeconds: Int64 = 10 * 60
    ) {
        precondition(uncleanLaunchThreshold > 0)
        precondition(uncleanLaunchWindowSeconds > 0)
        self.store = store
        self.uncleanLaunchThreshold = uncleanLaunchThreshold
        self.uncleanLaunchWindowSeconds = uncleanLaunchWindowSeconds
    }

    /// Starts a protected launch and returns whether rollback is required.
    public func beginLaunch(
        activeGenerationID: Runtime.GenerationID?,
        parentGenerationID: Runtime.GenerationID?,
        activePackageHash: Core.Digest? = nil,
        activationTimestampUnixSeconds: Int64? = nil,
        nowUnixSeconds: Int64
    ) throws -> CrashProtection.Decision {
        try store.updateInternalState(
            CrashProtection.Journal.self,
            name: Self.journalName
        ) { previous in
            if let previous, previous.schemaVersion != 1 {
                throw PatchPackage.Error.activationPersistence(
                    "unsupported Crash Guard journal schema"
                )
            }
            let elapsed = previous.map {
                nowUnixSeconds.subtractingReportingOverflow($0.updatedAtUnixSeconds)
            }
            let withinWindow = elapsed.map {
                !$0.overflow && $0.partialValue >= 0
                    && $0.partialValue <= uncleanLaunchWindowSeconds
            } ?? false
            let sameGenerationFailed = previous?.health == .launching
                && previous?.activeGenerationID == activeGenerationID
                && activeGenerationID != nil
                && withinWindow
            let failureCount: UInt32
            if sameGenerationFailed {
                failureCount = (previous?.consecutiveUncleanLaunches ?? 0) == UInt32.max
                    ? UInt32.max
                    : (previous?.consecutiveUncleanLaunches ?? 0) + 1
            } else {
                failureCount = 0
            }
            let nonce = UUID()
            previous = .init(
                activeGenerationID: activeGenerationID,
                parentGenerationID: parentGenerationID,
                activePackageHash: activePackageHash,
                activationTimestampUnixSeconds: activationTimestampUnixSeconds,
                sessionNonce: nonce,
                health: .launching,
                consecutiveUncleanLaunches: failureCount,
                updatedAtUnixSeconds: nowUnixSeconds
            )

            if let activeGenerationID, failureCount >= uncleanLaunchThreshold {
                return .rollback(
                    interruptedGeneration: activeGenerationID,
                    targetGeneration: parentGenerationID,
                    sessionNonce: nonce
                )
            }
            return .continueLaunch(sessionNonce: nonce)
        }
    }

    /// Confirms that the launch matching `sessionNonce` passed its health gate.
    public func markHealthy(
        sessionNonce: UUID,
        nowUnixSeconds: Int64
    ) throws {
        try store.markLaunchHealthy(
            journalName: Self.journalName,
            sessionNonce: sessionNonce,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    /// Rebinds the current launch journal after an explicit rollback.
    public func retargetAfterRollback(
        sessionNonce: UUID,
        activeState: PatchStore.ActiveState?,
        nowUnixSeconds: Int64
    ) throws {
        try store.updateInternalState(
            CrashProtection.Journal.self,
            name: Self.journalName
        ) { journal in
            guard var current = journal, current.sessionNonce == sessionNonce else {
                throw PatchPackage.Error.activationPersistence("stale Crash Guard session nonce")
            }
            current.activeGenerationID = activeState?.generationID
            current.parentGenerationID = activeState?.parentGenerationID
            current.activePackageHash = activeState?.packageHash
            current.activationTimestampUnixSeconds = activeState?.committedAtUnixSeconds
            current.consecutiveUncleanLaunches = 0
            current.updatedAtUnixSeconds = nowUnixSeconds
            journal = current
        }
    }

    func resetCorruptJournal(
        detail: String,
        nowUnixSeconds: Int64
    ) throws {
        try store.discardInternalStatePreservingEvidence(
            name: Self.journalName,
            reasonCode: "crashGuardJournalCorrupt",
            detail: detail,
            nowUnixSeconds: nowUnixSeconds
        )
    }
}
}
