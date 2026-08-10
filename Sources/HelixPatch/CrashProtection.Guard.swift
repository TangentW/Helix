import Foundation
import HelixCore
import HelixRuntime

public enum CrashProtection {}

extension CrashProtection {
public enum LaunchHealth: String, Codable, Hashable, Sendable {
    case launching
    case healthy
}

public struct Journal: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var activeGenerationID: Runtime.GenerationID?
    public var parentGenerationID: Runtime.GenerationID?
    public var activePackageHash: Core.Digest?
    public var activationTimestampUnixSeconds: Int64?
    public var sessionNonce: UUID
    public var health: CrashProtection.LaunchHealth
    public var consecutiveUncleanLaunches: UInt32
    public var updatedAtUnixSeconds: Int64

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

public enum Decision: Equatable, Sendable {
    case continueLaunch(sessionNonce: UUID)
    case rollback(
        interruptedGeneration: Runtime.GenerationID,
        targetGeneration: Runtime.GenerationID?,
        sessionNonce: UUID
    )
}

public final class Guard: @unchecked Sendable {
    private static let journalName = "crash-guard.json"

    public let store: PatchStore.Storage
    public let uncleanLaunchThreshold: UInt32
    public let uncleanLaunchWindowSeconds: Int64

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
