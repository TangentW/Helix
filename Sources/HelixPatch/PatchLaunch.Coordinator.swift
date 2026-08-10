import Foundation
import HelixCore
import HelixRuntime

public enum PatchLaunch {}

extension PatchLaunch {
public enum RecoveryIssueCode: String, Hashable, Sendable {
    case activationStateReset
    case crashGuardJournalReset
    case containmentPersistenceFailed
    case launchRestoreFailed
    case fallbackRestoreFailed
    case rollbackStateReset
}

public struct RecoveryIssue: Hashable, Sendable {
    public var code: PatchLaunch.RecoveryIssueCode
    public var detail: String
}

public struct Result: Sendable {
    public var sessionNonce: UUID
    public var activeGenerationID: Runtime.GenerationID?
    public var interruptedActivation: PatchStore.Recovery?
    public var crashGuardRollbackGenerationID: Runtime.GenerationID?
    public var recoveryIssues: [PatchLaunch.RecoveryIssue]

    public var restoreFailure: String? {
        guard !recoveryIssues.isEmpty else { return nil }
        return recoveryIssues
            .map { "\($0.code.rawValue): \($0.detail)" }
            .joined(separator: "; ")
    }
}

public final class Coordinator: @unchecked Sendable {
    public let activation: PatchActivation.Controller
    public let crashGuard: CrashProtection.Guard

    public init(
        activation: PatchActivation.Controller,
        crashGuard: CrashProtection.Guard
    ) {
        precondition(activation.store === crashGuard.store)
        self.activation = activation
        self.crashGuard = crashGuard
    }

    public func prepareLaunch(nowUnixSeconds: Int64) throws -> PatchLaunch.Result {
        var issues: [PatchLaunch.RecoveryIssue] = []
        var interrupted: PatchStore.Recovery?
        var state: PatchStore.ActiveState?
        do {
            interrupted = try activation.store.recoverInterruptedActivation()
            if let interrupted,
               let issue = containmentIssue(
                   packageHash: interrupted.packageHash,
                   reasonCode: "activationInterrupted",
                   detail: "activation WAL had no matching committed state",
                   nowUnixSeconds: nowUnixSeconds
               ) {
                issues.append(issue)
            }
            state = try activation.store.activeState()
        } catch {
            try resetActivationState(
                primary: error,
                reasonCode: "activationStateCorrupt",
                issueCode: .activationStateReset,
                nowUnixSeconds: nowUnixSeconds,
                issues: &issues
            )
            interrupted = nil
            state = nil
        }

        let decision: CrashProtection.Decision
        do {
            decision = try beginCrashGuard(state: state, nowUnixSeconds: nowUnixSeconds)
        } catch {
            let detail = String(describing: error)
            issues.append(.init(code: .crashGuardJournalReset, detail: detail))
            do {
                try crashGuard.resetCorruptJournal(
                    detail: detail,
                    nowUnixSeconds: nowUnixSeconds
                )
                decision = try beginCrashGuard(
                    state: state,
                    nowUnixSeconds: nowUnixSeconds
                )
            } catch let recoveryError {
                throw PatchActivation.Failure.recoveryFailed(
                    primary: detail,
                    recovery: "Crash Guard journal reset failed: \(recoveryError)"
                )
            }
        }

        let sessionNonce: UUID
        var crashRollback: Runtime.GenerationID?
        switch decision {
        case let .continueLaunch(nonce):
            sessionNonce = nonce
        case let .rollback(interruptedGeneration, _, nonce):
            sessionNonce = nonce
            crashRollback = interruptedGeneration
            if let active = state {
                if let issue = containmentIssue(
                    packageHash: active.packageHash,
                    reasonCode: "crashLoop",
                    detail: "consecutive unclean launches crossed the local threshold",
                    nowUnixSeconds: nowUnixSeconds
                ) {
                    issues.append(issue)
                }
                state = try rollbackOrReset(
                    expectedActiveID: interruptedGeneration,
                    context: "Crash Guard rollback",
                    nowUnixSeconds: nowUnixSeconds,
                    issues: &issues
                )
                try crashGuard.retargetAfterRollback(
                    sessionNonce: nonce,
                    activeState: state,
                    nowUnixSeconds: nowUnixSeconds
                )
            }
        }

        if state != nil {
            do {
                _ = try activation.restoreCommittedActive(nowUnixSeconds: nowUnixSeconds)
            } catch let failure as PatchActivation.Failure
                where failure == .operationInProgress {
                throw failure
            } catch {
                let detail = String(describing: error)
                issues.append(.init(code: .launchRestoreFailed, detail: detail))
                if let failed = state {
                    if let issue = containmentIssue(
                        packageHash: failed.packageHash,
                        reasonCode: "launchRestoreFailed",
                        detail: detail,
                        nowUnixSeconds: nowUnixSeconds
                    ) {
                        issues.append(issue)
                    }
                    state = try rollbackOrReset(
                        expectedActiveID: failed.generationID,
                        context: "primary launch restore",
                        nowUnixSeconds: nowUnixSeconds,
                        issues: &issues
                    )
                    try crashGuard.retargetAfterRollback(
                        sessionNonce: sessionNonce,
                        activeState: state,
                        nowUnixSeconds: nowUnixSeconds
                    )
                    if state != nil {
                        do {
                            _ = try activation.restoreCommittedActive(
                                nowUnixSeconds: nowUnixSeconds
                            )
                        } catch let failure as PatchActivation.Failure
                            where failure == .operationInProgress {
                            throw failure
                        } catch {
                            let fallbackDetail = String(describing: error)
                            issues.append(.init(
                                code: .fallbackRestoreFailed,
                                detail: fallbackDetail
                            ))
                            if let fallback = state {
                                if let issue = containmentIssue(
                                    packageHash: fallback.packageHash,
                                    reasonCode: "fallbackRestoreFailed",
                                    detail: fallbackDetail,
                                    nowUnixSeconds: nowUnixSeconds
                                ) {
                                    issues.append(issue)
                                }
                                state = try rollbackOrReset(
                                    expectedActiveID: fallback.generationID,
                                    context: "fallback launch restore",
                                    nowUnixSeconds: nowUnixSeconds,
                                    issues: &issues
                                )
                                try crashGuard.retargetAfterRollback(
                                    sessionNonce: sessionNonce,
                                    activeState: state,
                                    nowUnixSeconds: nowUnixSeconds
                                )
                            }
                        }
                    }
                }
            }
        }

        return .init(
            sessionNonce: sessionNonce,
            activeGenerationID: activation.runtime.registry.snapshot().activeGenerationID,
            interruptedActivation: interrupted,
            crashGuardRollbackGenerationID: crashRollback,
            recoveryIssues: issues
        )
    }

    public func markHealthy(sessionNonce: UUID, nowUnixSeconds: Int64) throws {
        try crashGuard.markHealthy(
            sessionNonce: sessionNonce,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    private func beginCrashGuard(
        state: PatchStore.ActiveState?,
        nowUnixSeconds: Int64
    ) throws -> CrashProtection.Decision {
        try crashGuard.beginLaunch(
            activeGenerationID: state?.generationID,
            parentGenerationID: state?.parentGenerationID,
            activePackageHash: state?.packageHash,
            activationTimestampUnixSeconds: state?.committedAtUnixSeconds,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    private func containmentIssue(
        packageHash: Core.Digest,
        reasonCode: String,
        detail: String,
        nowUnixSeconds: Int64
    ) -> PatchLaunch.RecoveryIssue? {
        var failures: [String] = []
        do {
            try activation.store.blockLocally(
                .init(
                    packageHash: packageHash,
                    reasonCode: reasonCode,
                    detail: detail,
                    blockedAtUnixSeconds: nowUnixSeconds
                )
            )
        } catch {
            failures.append("local block: \(error)")
        }
        do {
            try activation.store.quarantine(
                .init(
                    packageHash: packageHash,
                    reasonCode: reasonCode,
                    detail: detail,
                    quarantinedAtUnixSeconds: nowUnixSeconds
                )
            )
        } catch {
            failures.append("quarantine: \(error)")
        }
        guard !failures.isEmpty else { return nil }
        return .init(
            code: .containmentPersistenceFailed,
            detail: "\(reasonCode): \(failures.joined(separator: ", "))"
        )
    }

    private func rollbackOrReset(
        expectedActiveID: Runtime.GenerationID,
        context: String,
        nowUnixSeconds: Int64,
        issues: inout [PatchLaunch.RecoveryIssue]
    ) throws -> PatchStore.ActiveState? {
        do {
            return try activation.store.rollbackToLastKnownGood(
                expectedActiveID: expectedActiveID
            )
        } catch {
            try resetActivationState(
                primary: error,
                reasonCode: "rollbackStateCorrupt",
                issueCode: .rollbackStateReset,
                context: context,
                nowUnixSeconds: nowUnixSeconds,
                issues: &issues
            )
            return nil
        }
    }

    private func resetActivationState(
        primary: any Swift.Error,
        reasonCode: String,
        issueCode: PatchLaunch.RecoveryIssueCode,
        context: String = "launch metadata",
        nowUnixSeconds: Int64,
        issues: inout [PatchLaunch.RecoveryIssue]
    ) throws {
        let detail = "\(context): \(primary)"
        issues.append(.init(code: issueCode, detail: detail))
        do {
            try activation.store.resetActivationStatePreservingEvidence(
                reasonCode: reasonCode,
                detail: detail,
                nowUnixSeconds: nowUnixSeconds
            )
        } catch {
            throw PatchActivation.Failure.recoveryFailed(
                primary: detail,
                recovery: "activation state reset failed: \(error)"
            )
        }
    }
}
}
