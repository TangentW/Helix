import Foundation
import HelixBytecode
import HelixCore
import HelixRuntime
import HelixVerifier

/// Verified package activation, rollback, and revocation operations.
public enum PatchActivation {}

extension PatchActivation {
/// Details returned after a package generation is durably activated.
public struct Result: Sendable {
    /// Lease keeping the new or already-active generation and its images alive.
    public var generationLease: Runtime.GenerationLease
    /// SHA-256 of the complete verified package.
    public var packageHash: Core.Digest
    /// Durable store location of the verified package.
    public var verifiedPackageURL: URL
    /// Shell entries routed to the activated generation.
    public var activatedEntryIndices: [Core.EntryIndex]
}

/// Result of applying a verified revocation snapshot.
public struct RevocationResult: Hashable, Sendable {
    /// Highest accepted revocation epoch.
    public var epoch: UInt64
    /// Generation deactivated because it was revoked, if any.
    public var deactivatedGenerationID: Runtime.GenerationID?
    /// Persistent parent state restored after deactivation.
    public var restoredPersistentState: PatchStore.ActiveState?
    /// Runtime generation active after revocation handling.
    public var restoredRuntimeGenerationID: Runtime.GenerationID?
}

/// Details returned after an explicit active-generation rollback.
public struct RollbackResult: Hashable, Sendable {
    /// Generation removed from active routing.
    public var deactivatedGenerationID: Runtime.GenerationID
    /// Durable parent state restored, or `nil` for the original App body.
    public var restoredState: PatchStore.ActiveState?
    /// Runtime parent generation restored, or `nil` for original.
    public var restoredGenerationID: Runtime.GenerationID?
}

/// Failures specific to serialized activation and recovery.
public enum Failure: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// Another install, rollback, restore, or revocation operation is active.
    case operationInProgress
    /// Both the primary operation and its compensating recovery failed.
    case recoveryFailed(primary: String, recovery: String)

    /// Human-readable serialized activation failure detail.
    public var description: String {
        switch self {
        case .operationInProgress: "another patch activation operation is in progress"
        case let .recoveryFailed(primary, recovery):
            "activation failed (\(primary)); recovery also failed (\(recovery))"
        }
    }
}

/// Advanced package verifier and transactional Runtime activation controller.
///
/// Applications should normally use ``PatchRuntime/ApplicationSession``. This
/// lower-level API exists for custom composition roots and integration tests.
public final class Controller: @unchecked Sendable {
    private struct Prepared {
        var verifiedPackage: PatchPackage.VerifiedPackage
        var generation: Runtime.Generation
        var activatedEntries: [Core.EntryIndex]
    }

    private struct ActiveGeneration {
        var lease: Runtime.GenerationLease
        var state: PatchStore.ActiveState
    }

    /// Runtime Engine receiving verified generations.
    public let runtime: Runtime.Engine
    /// Durable Patch Store used for transactions and recovery.
    public let store: PatchStore.Storage
    /// Exact interface of the running Shell.
    public let shell: Verification.ShellInterface
    /// Capabilities, NativeImports, and resource ceilings enforced by Runtime.
    public let runtimePolicy: Core.RuntimePolicy
    /// Signing roots and revocation state.
    public let trustStore: PatchPackage.TrustStore
    /// Exact running target identity.
    public let targetContext: PatchPackage.TargetContext
    /// Product-owned package acceptance policy.
    public let acceptancePolicy: PatchPackage.AcceptancePolicy
    private let operationLock = NSLock()
    private var operationInProgress = false

    /// Generation registry owned by ``runtime``.
    public var registry: Runtime.GenerationRegistry { runtime.registry }

    /// Creates an explicitly assembled activation controller.
    public init(
        runtime: Runtime.Engine,
        store: PatchStore.Storage,
        shell: Verification.ShellInterface,
        runtimePolicy: Core.RuntimePolicy,
        trustStore: PatchPackage.TrustStore,
        targetContext: PatchPackage.TargetContext,
        acceptancePolicy: PatchPackage.AcceptancePolicy
    ) {
        self.runtime = runtime
        self.store = store
        self.shell = shell
        self.runtimePolicy = runtimePolicy
        self.trustStore = trustStore
        self.targetContext = targetContext
        self.acceptancePolicy = acceptancePolicy
    }

    /// Verifies package bytes, commits them to the store, and activates a generation.
    public func installAndActivate(
        packageBytes: Data,
        generationID: Runtime.GenerationID,
        expectedActiveID: Runtime.GenerationID?,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result {
        try withExclusiveOperation {
            try installAndActivateLocked(
                packageBytes: packageBytes,
                generationID: generationID,
                expectedActiveID: expectedActiveID,
                nowUnixSeconds: nowUnixSeconds
            )
        }
    }

    /// Activates an artifact previously completed by ``PatchDownload/Receiver``.
    public func installAndActivate(
        artifact: PatchDownload.Artifact,
        generationID: Runtime.GenerationID,
        expectedActiveID: Runtime.GenerationID?,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result {
        guard artifact.partialURL.standardizedFileURL
                == store.makeIncomingURL(downloadID: artifact.downloadID).standardizedFileURL,
              artifact.sha256 == Core.Digest.sha256(artifact.packageBytes)
        else {
            throw PatchPackage.Error.activationPersistence(
                "incoming artifact does not belong to this Patch Store"
            )
        }
        defer { try? store.removeIncoming(downloadID: artifact.downloadID) }
        return try installAndActivate(
            packageBytes: artifact.packageBytes,
            generationID: generationID,
            expectedActiveID: expectedActiveID,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    /// Restores the durable active package while preparing an App launch.
    public func restoreCommittedActive(
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result? {
        try withExclusiveOperation {
            try restoreCommittedActiveLocked(nowUnixSeconds: nowUnixSeconds)
        }
    }

    /// Persists a verified revocation snapshot and deactivates a revoked generation.
    public func applyRevocationSnapshot(
        _ snapshot: PatchPackage.RevocationSnapshot,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.RevocationResult {
        try withExclusiveOperation {
            let currentTrust = try effectiveTrustStore()
            let updatedTrust = try currentTrust.applying(
                snapshot,
                nowUnixSeconds: nowUnixSeconds,
                clockSkewAllowanceSeconds: acceptancePolicy.clockSkewAllowanceSeconds
            )
            try store.recordVerifiedRevocation(
                snapshot: snapshot,
                effectiveTrustStore: updatedTrust
            )

            guard let activeState = try store.activeState(),
                  updatedTrust.revokedPackageHashes.contains(activeState.packageHash)
                    || updatedTrust.revokedKeyIDs.contains(activeState.signerKeyID)
            else {
                return .init(
                    epoch: updatedTrust.revocationEpoch,
                    deactivatedGenerationID: nil,
                    restoredPersistentState: try store.activeState(),
                    restoredRuntimeGenerationID: runtime.registry.snapshot().activeGenerationID
                )
            }

            var containmentFailures: [String] = []
            do {
                try quarantineAndBlock(
                    packageHash: activeState.packageHash,
                    reasonCode: "signedRevocation",
                    detail: "package or signing key was revoked at epoch \(snapshot.epoch)",
                    nowUnixSeconds: nowUnixSeconds
                )
            } catch {
                containmentFailures.append("persist containment: \(error)")
            }
            if let activeLease = runtime.registry.activeLease() {
                do {
                    // A parent may use the same revoked leaf. Drop to originals
                    // first, then re-verify the persisted LKG before restoring it.
                    try runtime.rollback(expectedActiveID: activeLease.generation.id, to: nil)
                } catch {
                    runtime.registry.quarantine(activeLease.generation.id)
                    if runtime.registry.snapshot().activeGenerationID != nil {
                        containmentFailures.append("runtime deactivation: \(error)")
                    }
                }
            }
            var restored: PatchStore.ActiveState?
            do {
                restored = try store.rollbackToLastKnownGood(
                    expectedActiveID: activeState.generationID
                )
                if let revokedLKG = restored,
                   updatedTrust.revokedPackageHashes.contains(revokedLKG.packageHash)
                    || updatedTrust.revokedKeyIDs.contains(revokedLKG.signerKeyID) {
                    try quarantineAndBlock(
                        packageHash: revokedLKG.packageHash,
                        reasonCode: "signedRevocation",
                        detail: "last-known-good is covered by revocation epoch \(snapshot.epoch)",
                        nowUnixSeconds: nowUnixSeconds
                    )
                    restored = try store.rollbackToLastKnownGood(
                        expectedActiveID: revokedLKG.generationID
                    )
                }
            } catch {
                containmentFailures.append("persistent rollback: \(error)")
            }
            if restored != nil, runtime.registry.activeLease() == nil {
                do {
                    _ = try restoreCommittedActiveLocked(nowUnixSeconds: nowUnixSeconds)
                } catch {
                    containmentFailures.append("LKG restore: \(error)")
                }
            }
            if !containmentFailures.isEmpty {
                throw PatchActivation.Failure.recoveryFailed(
                    primary: "signed revocation epoch \(snapshot.epoch) was persisted",
                    recovery: containmentFailures.joined(separator: "; ")
                )
            }
            return .init(
                epoch: updatedTrust.revocationEpoch,
                deactivatedGenerationID: activeState.generationID,
                restoredPersistentState: restored,
                restoredRuntimeGenerationID: runtime.registry.snapshot().activeGenerationID
            )
        }
    }

    /// Marks the active generation as healthy in durable state.
    public func markActiveHealthy(nowUnixSeconds: Int64) throws {
        guard let activeID = runtime.registry.snapshot().activeGenerationID else {
            throw PatchPackage.Error.activationPersistence("Runtime has no active generation")
        }
        try store.markActiveHealthy(
            expectedActiveID: activeID,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    /// Explicitly returns to the persisted last-known-good generation (or the
    /// original App body). Runtime routing moves first; persistence is retried
    /// once to cover a rename-visible/fsync-error boundary.
    public func rollbackActive(
        expectedActiveID: Runtime.GenerationID
    ) throws -> PatchActivation.RollbackResult {
        try withExclusiveOperation {
            guard let active = try store.activeState(),
                  active.generationID == expectedActiveID,
                  runtime.registry.snapshot().activeGenerationID == expectedActiveID
            else {
                throw PatchPackage.Error.activationPersistence(
                    "memory and persistent active generations disagree before rollback"
                )
            }
            try runtime.rollback(
                expectedActiveID: expectedActiveID,
                to: active.parentGenerationID
            )
            let restored: PatchStore.ActiveState?
            do {
                restored = try store.rollbackToLastKnownGood(
                    expectedActiveID: expectedActiveID
                )
            } catch {
                let primary = error
                let visible: PatchStore.ActiveState?
                let didReadVisible: Bool
                do {
                    visible = try store.activeState()
                    didReadVisible = true
                } catch {
                    visible = nil
                    didReadVisible = false
                }
                if didReadVisible,
                   visible?.generationID == active.parentGenerationID {
                    restored = visible
                } else {
                    do {
                        restored = try store.rollbackToLastKnownGood(
                            expectedActiveID: expectedActiveID
                        )
                    } catch {
                        throw PatchActivation.Failure.recoveryFailed(
                            primary: String(describing: primary),
                            recovery: "persistent rollback retry failed: \(error)"
                        )
                    }
                }
            }
            guard restored?.generationID == active.parentGenerationID,
                  runtime.registry.snapshot().activeGenerationID
                    == active.parentGenerationID
            else {
                throw PatchActivation.Failure.recoveryFailed(
                    primary: "explicit rollback published inconsistent targets",
                    recovery: "restart the App so launch recovery can restore persisted state"
                )
            }
            return .init(
                deactivatedGenerationID: expectedActiveID,
                restoredState: restored,
                restoredGenerationID: active.parentGenerationID
            )
        }
    }

    private func installAndActivateLocked(
        packageBytes: Data,
        generationID: Runtime.GenerationID,
        expectedActiveID: Runtime.GenerationID?,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result {
        let packageHash = Core.Digest.sha256(packageBytes)
        if try store.localBlock(for: packageHash) != nil {
            throw PatchPackage.Error.packageLocallyBlocked(packageHash)
        }
        let structuralPackage = try PatchPackage.Container.decode(packageBytes)
        let antiRollback = try store.antiRollbackState(
            campaignID: structuralPackage.manifest.campaignID,
            shellInterfaceHash: targetContext.shellInterfaceHash
        )
        let verifiedPackage = try PatchPackage.Verifier().verify(
            bytes: packageBytes,
            trustStore: try effectiveTrustStore(),
            targetContext: targetContext,
            acceptancePolicy: acceptancePolicy,
            antiRollbackState: antiRollback,
            nowUnixSeconds: nowUnixSeconds
        )
        let active = try alignedActiveGeneration()
        if let active,
           active.lease.generation.packageHash.constantTimeEquals(
               verifiedPackage.packageHash
           ) {
            guard active.state.signerKeyID
                    == verifiedPackage.package.manifest.security.signerKeyID
            else {
                throw PatchPackage.Error.activationPersistence(
                    "active generation signer does not match its package"
                )
            }
            let packageURL = try store.persistVerifiedPackage(
                packageBytes,
                packageHash: verifiedPackage.packageHash
            )
            return .init(
                generationLease: active.lease,
                packageHash: verifiedPackage.packageHash,
                verifiedPackageURL: packageURL,
                activatedEntryIndices: active.lease.generation.routes.keys.sorted()
            )
        }

        let activeLease = active?.lease
        guard activeLease?.generation.id == expectedActiveID else {
            throw Runtime.ActivationError.staleActiveGeneration(
                expected: expectedActiveID,
                actual: activeLease?.generation.id
            )
        }
        if let requiredParent = verifiedPackage.package.manifest.rollback.parentGenerationPackageHash,
           activeLease?.generation.packageHash != requiredParent
        {
            throw Runtime.ActivationError.invalidGeneration("package parent hash does not match active generation")
        }
        if let activePackageID = activeLease?.generation.packageID,
           verifiedPackage.package.manifest.rollback.mutuallyExclusivePackageIDs.contains(activePackageID)
        {
            throw Runtime.ActivationError.invalidGeneration("active package is mutually exclusive")
        }

        let prepared = try prepareGeneration(
            verifiedPackage: verifiedPackage,
            generationID: generationID,
            parentID: expectedActiveID,
            nowUnixSeconds: nowUnixSeconds
        )
        let generation = prepared.generation

        let packageURL = try store.persistVerifiedPackage(
            packageBytes,
            packageHash: verifiedPackage.packageHash
        )
        // Re-check the monotonic ledger while holding its storage lock. This is
        // the authoritative anti-rollback transition after expensive verify.
        try store.recordSeen(
            manifest: verifiedPackage.package.manifest,
            packageHash: verifiedPackage.packageHash,
            shellInterfaceHash: targetContext.shellInterfaceHash
        )
        let pending = PatchStore.PendingActivation(
            targetGenerationID: generationID,
            parentGenerationID: expectedActiveID,
            packageID: generation.packageID,
            packageHash: generation.packageHash,
            signerKeyID: verifiedPackage.package.manifest.security.signerKeyID,
            createdAtUnixSeconds: nowUnixSeconds
        )
        try store.beginActivation(pending)
        let committedState = PatchStore.ActiveState(
            generationID: generationID,
            parentGenerationID: expectedActiveID,
            packageID: generation.packageID,
            packageHash: generation.packageHash,
            signerKeyID: verifiedPackage.package.manifest.security.signerKeyID,
            activationNonce: pending.nonce,
            committedAtUnixSeconds: nowUnixSeconds
        )

        var activated = false
        do {
            let lease = try runtime.activate(generation, expectedActiveID: expectedActiveID)
            activated = true
            do {
                try store.commitActivation(committedState)
            } catch {
                // A rename can become visible before a durability-strengthening
                // fsync reports failure. Keep memory aligned with the visible
                // committed record; a remaining matching WAL is launch-safe.
                guard try store.isActivationCommitted(committedState) else { throw error }
            }
            return .init(
                generationLease: lease,
                packageHash: generation.packageHash,
                verifiedPackageURL: packageURL,
                activatedEntryIndices: prepared.activatedEntries
            )
        } catch {
            let primary = error
            var recoveryFailures: [String] = []
            if activated {
                do {
                    try runtime.rollback(expectedActiveID: generationID, to: expectedActiveID)
                } catch {
                    runtime.registry.quarantine(generationID)
                    recoveryFailures.append("runtime rollback: \(error)")
                }
            }
            do {
                _ = try store.recoverInterruptedActivation()
            } catch {
                recoveryFailures.append("WAL recovery: \(error)")
            }
            if !recoveryFailures.isEmpty {
                throw PatchActivation.Failure.recoveryFailed(
                    primary: String(describing: primary),
                    recovery: recoveryFailures.joined(separator: "; ")
                )
            }
            if case Runtime.ActivationError.invalidGeneration = primary {
                do {
                    try quarantineAndBlock(
                        packageHash: generation.packageHash,
                        reasonCode: "runtimeBindingFailed",
                        detail: String(describing: primary),
                        nowUnixSeconds: nowUnixSeconds
                    )
                } catch {
                    throw PatchActivation.Failure.recoveryFailed(
                        primary: String(describing: primary),
                        recovery: "cannot persist local containment: \(error)"
                    )
                }
            }
            throw primary
        }
    }

    private func restoreCommittedActiveLocked(
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result? {
        guard runtime.registry.activeLease() == nil else {
            throw Runtime.ActivationError.invalidGeneration(
                "cold-start restore requires an empty Runtime registry"
            )
        }
        guard let state = try store.activeState() else { return nil }
        let bytes = try store.verifiedPackageBytes(packageHash: state.packageHash)
        if try store.localBlock(for: state.packageHash) != nil {
            throw PatchPackage.Error.packageLocallyBlocked(state.packageHash)
        }
        let verified = try PatchPackage.Verifier().verify(
            bytes: bytes,
            trustStore: try effectiveTrustStore(),
            targetContext: targetContext,
            acceptancePolicy: acceptancePolicy,
            // A committed active/LKG record is a local recovery decision,
            // not a new distribution candidate. All other checks still run.
            antiRollbackState: nil,
            nowUnixSeconds: nowUnixSeconds
        )
        guard verified.packageHash == state.packageHash,
              verified.package.manifest.packageID == state.packageID,
              verified.package.manifest.security.signerKeyID == state.signerKeyID
        else {
            throw PatchPackage.Error.activationPersistence(
                "committed state does not match its verified package"
            )
        }
        let prepared = try prepareGeneration(
            verifiedPackage: verified,
            generationID: state.generationID,
            parentID: nil,
            nowUnixSeconds: nowUnixSeconds
        )
        let lease = try runtime.restore(prepared.generation)
        let url = store.verifiedURL
            .appendingPathComponent(state.packageHash.hex, isDirectory: true)
            .appendingPathComponent("package.hlxp")
        return .init(
            generationLease: lease,
            packageHash: state.packageHash,
            verifiedPackageURL: url,
            activatedEntryIndices: prepared.activatedEntries
        )
    }

    private func alignedActiveGeneration() throws -> ActiveGeneration? {
        let lease = runtime.registry.activeLease()
        let state = try store.activeState()
        switch (lease, state) {
        case (nil, nil):
            return nil
        case let (lease?, state?):
            guard state.generationID == lease.generation.id,
                  state.packageID == lease.generation.packageID,
                  state.packageHash.constantTimeEquals(lease.generation.packageHash)
            else {
                throw PatchPackage.Error.activationPersistence(
                    "memory and persistent active generations disagree"
                )
            }
            return .init(lease: lease, state: state)
        case (.some, nil), (nil, .some):
            throw PatchPackage.Error.activationPersistence(
                "memory and persistent active generations disagree"
            )
        }
    }

    private func prepareGeneration(
        verifiedPackage: PatchPackage.VerifiedPackage,
        generationID: Runtime.GenerationID,
        parentID: Runtime.GenerationID?,
        nowUnixSeconds: Int64
    ) throws -> Prepared {
        let hlbcDescriptors = verifiedPackage.selectedPayloads.filter { $0.backend == .hlbc }
        guard hlbcDescriptors.count == verifiedPackage.selectedPayloads.count else {
            throw PatchPackage.Error.invalidManifest(
                "controlled Native payloads require the Native activation backend"
            )
        }
        guard !hlbcDescriptors.isEmpty else { throw PatchPackage.Error.noPayloadForTarget }

        var images: [Verification.Image] = []
        var estimatedBytes = 0
        var activatedEntries = Set<Core.EntryIndex>()
        for descriptor in hlbcDescriptors {
            let bytes = try verifiedPackage.payload(for: descriptor)
            let image = try Verification.Engine().verify(
                bytes: bytes,
                shell: shell,
                policy: runtimePolicy
            )
            try verifyDescriptor(descriptor, matches: image)
            images.append(image)
            let addition = estimatedBytes.addingReportingOverflow(bytes.count)
            guard !addition.overflow else {
                throw PatchPackage.Error.limitExceeded("generation byte estimate")
            }
            estimatedBytes = addition.partialValue
            activatedEntries.formUnion(descriptor.entryIndices)
        }

        let generation = try Runtime.Generation(
            id: generationID,
            parentID: parentID,
            packageID: verifiedPackage.package.manifest.packageID,
            packageHash: verifiedPackage.packageHash,
            images: images,
            estimatedByteCount: estimatedBytes,
            createdAt: Date(timeIntervalSince1970: TimeInterval(nowUnixSeconds))
        )
        return .init(
            verifiedPackage: verifiedPackage,
            generation: generation,
            activatedEntries: activatedEntries.sorted()
        )
    }

    private func effectiveTrustStore() throws -> PatchPackage.TrustStore {
        let persisted = try store.revocationState()
        return trustStore.mergingPersistedRevocations(
            epoch: persisted.highestSeenEpoch,
            revokedKeyIDs: persisted.revokedKeyIDs,
            revokedPackageHashes: persisted.revokedPackageHashes
        )
    }

    private func quarantineAndBlock(
        packageHash: Core.Digest,
        reasonCode: String,
        detail: String,
        nowUnixSeconds: Int64
    ) throws {
        try store.blockLocally(
            .init(
                packageHash: packageHash,
                reasonCode: reasonCode,
                detail: detail,
                blockedAtUnixSeconds: nowUnixSeconds
            )
        )
        try store.quarantine(
            .init(
                packageHash: packageHash,
                reasonCode: reasonCode,
                detail: detail,
                quarantinedAtUnixSeconds: nowUnixSeconds
            )
        )
    }

    private func verifyDescriptor(
        _ descriptor: PatchPackage.PayloadDescriptor,
        matches image: Verification.Image
    ) throws {
        guard descriptor.capabilities == image.module.capabilities else {
            throw PatchPackage.Error.invalidManifest(
                "payload \(descriptor.path) capability report does not match HLBC"
            )
        }
        guard descriptor.quotas == image.module.requestedResources else {
            throw PatchPackage.Error.invalidManifest(
                "payload \(descriptor.path) quota report does not match HLBC"
            )
        }
        let actualEntries = image.module.entries.map(\.entryIndex)
        let actualKeys = image.module.entries.map(\.functionKey)
        guard Set(actualEntries) == Set(descriptor.entryIndices),
              Set(actualKeys) == Set(descriptor.changedFunctionKeys)
        else {
            throw PatchPackage.Error.invalidManifest(
                "payload \(descriptor.path) identity report does not match HLBC"
            )
        }
    }

    private func withExclusiveOperation<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        operationLock.lock()
        guard !operationInProgress else {
            operationLock.unlock()
            throw PatchActivation.Failure.operationInProgress
        }
        operationInProgress = true
        operationLock.unlock()
        defer {
            operationLock.lock()
            operationInProgress = false
            operationLock.unlock()
        }
        return try operation()
    }
}
}
