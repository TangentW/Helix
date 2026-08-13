import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Runtime {
/// Point-in-time view of generation routing and retained resource usage.
public struct RegistrySnapshot: Sendable, Equatable {
    /// Generation currently selected for new root invocations.
    public var activeGenerationID: Runtime.GenerationID?
    /// Highest identity committed during this process lifetime.
    public var highestActivatedGenerationID: Runtime.GenerationID?
    /// Generations retained by rollback policy or an in-flight lease.
    public var loadedGenerationIDs: [Runtime.GenerationID]
    /// Known-bad retained generation identities in ascending order.
    public var quarantinedGenerationIDs: [Runtime.GenerationID]
    /// Unique retained artifact bytes estimated across all live snapshots.
    public var estimatedByteCount: Int
    /// Historical snapshots removed since this registry was created.
    public var compactedGenerationCount: UInt64
}

/// Thread-safe ownership of immutable, materialized generation snapshots.
///
/// Activation and rollback use an expected active ID, providing compare-and-swap
/// semantics against stale callers. Route inheritance is flattened at activation
/// time. Existing invocations own self-contained leases, while superseded
/// snapshots without a lease are compacted to keep long development sessions
/// bounded.
public final class GenerationRegistry: @unchecked Sendable {
    private final class WeakSnapshot {
        weak var value: Runtime.GenerationSnapshot?

        init(_ value: Runtime.GenerationSnapshot) {
            self.value = value
        }
    }

    private struct State {
        var activeID: Runtime.GenerationID?
        var highestActivatedID: Runtime.GenerationID?
        var retained: [Runtime.GenerationID: Runtime.GenerationSnapshot] = [:]
        var snapshots: [Runtime.GenerationID: WeakSnapshot] = [:]
        var quarantined: Set<Runtime.GenerationID> = []
        var compactedGenerationCount: UInt64 = 0
    }

    private let lock = NSLock()
    private let routingLatch = Runtime.AtomicFlag()
    private var state = State()

    /// Maximum snapshots simultaneously retained by rollback policy or leases.
    public let maximumGenerationCount: Int
    /// Maximum unique artifact bytes reachable from simultaneously live snapshots.
    public let maximumEstimatedBytes: Int
    /// Number of active ancestors retained for immediate rollback.
    public let retainedRollbackGenerationCount: Int

    /// Creates an empty registry with positive capacity ceilings.
    ///
    /// The default keeps the active generation and its direct predecessor. Older
    /// snapshots survive only while an invocation or explicit lease pins them.
    public init(
        maximumGenerationCount: Int = 32,
        maximumEstimatedBytes: Int = 64 * 1_024 * 1_024,
        retainedRollbackGenerationCount: Int = 1
    ) {
        precondition(maximumGenerationCount > 0)
        precondition(maximumEstimatedBytes > 0)
        precondition(retainedRollbackGenerationCount >= 0)
        precondition(retainedRollbackGenerationCount < maximumGenerationCount)
        self.maximumGenerationCount = maximumGenerationCount
        self.maximumEstimatedBytes = maximumEstimatedBytes
        self.retainedRollbackGenerationCount = retainedRollbackGenerationCount
    }

    /// Atomically activates a child of the expected current generation.
    ///
    /// The returned lease pins the new materialized snapshot. Before publication,
    /// capacity is evaluated against the new rollback window plus every in-flight
    /// lease. Failure leaves the active generation and retained rollback state
    /// unchanged.
    @discardableResult
    public func activate(
        _ generation: Runtime.Generation,
        expectedActiveID: Runtime.GenerationID?
    ) throws -> Runtime.GenerationLease {
        try publish(
            generation,
            expectedActiveID: expectedActiveID,
            permitsHistoricalIdentity: false
        )
    }

    /// Restores one previously verified durable generation while preserving the
    /// process generation-ID high-water mark.
    ///
    /// This recovery API is valid only when original code is active and the
    /// supplied generation has no in-memory parent. Ordinary activation must use
    /// ``activate(_:expectedActiveID:)`` and remains strictly monotonic.
    @discardableResult
    public func restore(
        _ generation: Runtime.Generation
    ) throws -> Runtime.GenerationLease {
        guard generation.parentID == nil else {
            throw Runtime.ActivationError.parentMismatch(
                expected: nil,
                actual: generation.parentID
            )
        }
        return try publish(
            generation,
            expectedActiveID: nil,
            permitsHistoricalIdentity: true
        )
    }

    private func publish(
        _ generation: Runtime.Generation,
        expectedActiveID: Runtime.GenerationID?,
        permitsHistoricalIdentity: Bool
    ) throws -> Runtime.GenerationLease {
        // Publish before committing the generation. A racing caller may take
        // the slow path slightly early, but can never miss a committed route.
        // The latch is intentionally monotonic so a rolled-back invocation can
        // continue using its thread-pinned generation.
        routingLatch.storeRelease(true)
        return try lock.withLock {
            compactUnleasedSnapshotsLocked()
            guard state.activeID == expectedActiveID else {
                throw Runtime.ActivationError.staleActiveGeneration(
                    expected: expectedActiveID,
                    actual: state.activeID
                )
            }
            guard generation.parentID == expectedActiveID else {
                throw Runtime.ActivationError.parentMismatch(
                    expected: expectedActiveID,
                    actual: generation.parentID
                )
            }
            if let existing = snapshotLocked(for: generation.id) {
                guard permitsHistoricalIdentity,
                      existing.generation.packageID == generation.packageID,
                      existing.generation.packageHash == generation.packageHash
                else {
                    throw Runtime.ActivationError.generationAlreadyExists(generation.id)
                }
                guard !state.quarantined.contains(generation.id) else {
                    throw Runtime.ActivationError.quarantined(generation.id)
                }
                let available = liveSnapshotsLocked()
                let retained = retainedSnapshots(
                    startingAt: existing,
                    available: available
                )
                try validateCapacityLocked(
                    retained: retained,
                    available: available
                )
                state.activeID = generation.id
                applyRetentionLocked(retained)
                return Runtime.GenerationLease(snapshot: existing)
            }
            if !permitsHistoricalIdentity,
               let highest = state.highestActivatedID,
               generation.id <= highest {
                throw Runtime.ActivationError.generationIDNotMonotonic(
                    previous: highest,
                    attempted: generation.id
                )
            }
            guard !state.quarantined.contains(generation.id) else {
                throw Runtime.ActivationError.quarantined(generation.id)
            }

            let parent: Runtime.GenerationSnapshot?
            if let expectedActiveID {
                guard let existing = snapshotLocked(for: expectedActiveID) else {
                    throw Runtime.ActivationError.unknownGeneration(expectedActiveID)
                }
                parent = existing
            } else {
                parent = nil
            }
            let snapshot = Runtime.GenerationSnapshot(
                generation: generation,
                parent: parent
            )
            var available = liveSnapshotsLocked()
            available[generation.id] = snapshot
            let retained = retainedSnapshots(
                startingAt: snapshot,
                available: available
            )
            try validateCapacityLocked(retained: retained, available: available)

            state.activeID = generation.id
            state.highestActivatedID = max(
                state.highestActivatedID ?? generation.id,
                generation.id
            )
            state.snapshots[generation.id] = .init(snapshot)
            applyRetentionLocked(retained)
            return Runtime.GenerationLease(snapshot: snapshot)
        }
    }

    /// Returns a lease pinning the snapshot selected for new invocations.
    public func activeLease() -> Runtime.GenerationLease? {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            guard let activeID = state.activeID,
                  let snapshot = snapshotLocked(for: activeID)
            else {
                return nil
            }
            return Runtime.GenerationLease(snapshot: snapshot)
        }
    }

    var hasEverActivated: Bool {
        routingLatch.loadAcquire()
    }

    /// Resolves an entry through a currently retained materialized snapshot.
    ///
    /// Runtime execution uses its lease directly. This identity-based lookup is
    /// retained for diagnostics and returns `nil` after an unleased historical
    /// generation has been compacted.
    public func route(
        for entry: Core.EntryIndex,
        startingAt generationID: Runtime.GenerationID
    ) -> Runtime.Route? {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            return snapshotLocked(for: generationID)?.routes[entry]?.route
        }
    }

    /// Resolves signed side-effect metadata from a retained snapshot.
    public func entryEffects(
        for entry: Core.EntryIndex,
        startingAt generationID: Runtime.GenerationID
    ) -> Core.Effects? {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            return snapshotLocked(for: generationID)?.entryEffects[entry]
        }
    }

    /// Returns a lease for a generation that is still retained or in flight.
    public func lease(for id: Runtime.GenerationID) -> Runtime.GenerationLease? {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            return snapshotLocked(for: id).map(Runtime.GenerationLease.init)
        }
    }

    /// Atomically moves the active pointer to a retained ancestor or original code.
    ///
    /// Passing `nil` selects original App implementations. A compacted ancestor
    /// is intentionally unavailable; the default rollback window retains the
    /// direct predecessor needed by activation recovery and crash containment.
    @discardableResult
    public func rollback(
        expectedActiveID: Runtime.GenerationID,
        to targetID: Runtime.GenerationID?
    ) throws -> Runtime.GenerationLease? {
        try lock.withLock {
            compactUnleasedSnapshotsLocked()
            guard state.activeID == expectedActiveID else {
                throw Runtime.ActivationError.staleActiveGeneration(
                    expected: expectedActiveID,
                    actual: state.activeID
                )
            }
            let available = liveSnapshotsLocked()
            let target: Runtime.GenerationSnapshot?
            if let targetID {
                guard let existing = available[targetID] else {
                    throw Runtime.ActivationError.unknownGeneration(targetID)
                }
                guard !state.quarantined.contains(targetID) else {
                    throw Runtime.ActivationError.quarantined(targetID)
                }
                guard isAncestor(
                    targetID,
                    of: expectedActiveID,
                    snapshots: available
                ) else {
                    throw Runtime.ActivationError.rollbackTargetIsNotAncestor(
                        target: targetID,
                        active: expectedActiveID
                    )
                }
                target = existing
            } else {
                target = nil
            }

            state.activeID = targetID
            let retained = target.map {
                retainedSnapshots(startingAt: $0, available: available)
            } ?? [:]
            applyRetentionLocked(retained)
            return target.map(Runtime.GenerationLease.init)
        }
    }

    /// Marks a live generation unusable and selects its nearest retained safe ancestor.
    public func quarantine(_ id: Runtime.GenerationID, rollbackIfActive: Bool = true) {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            let available = liveSnapshotsLocked()
            guard available[id] != nil else { return }
            state.quarantined.insert(id)
            guard rollbackIfActive, state.activeID == id else { return }

            var candidate = available[id]?.generation.parentID
            while let generationID = candidate {
                guard let snapshot = available[generationID] else {
                    candidate = nil
                    break
                }
                if !state.quarantined.contains(generationID) { break }
                candidate = snapshot.generation.parentID
            }
            state.activeID = candidate
            let retained: [Runtime.GenerationID: Runtime.GenerationSnapshot]
            if let candidate, let snapshot = available[candidate] {
                retained = retainedSnapshots(
                    startingAt: snapshot,
                    available: available
                )
            } else {
                retained = [:]
            }
            applyRetentionLocked(retained)
        }
    }

    /// Returns a consistent snapshot of active, retained, and compacted state.
    public func snapshot() -> Runtime.RegistrySnapshot {
        lock.withLock {
            compactUnleasedSnapshotsLocked()
            let snapshots = liveSnapshotsLocked()
            let byteEstimate = estimatedBytes(of: snapshots.values)
            return Runtime.RegistrySnapshot(
                activeGenerationID: state.activeID,
                highestActivatedGenerationID: state.highestActivatedID,
                loadedGenerationIDs: snapshots.keys.sorted(),
                quarantinedGenerationIDs: state.quarantined.sorted(),
                estimatedByteCount: byteEstimate.overflow ? Int.max : byteEstimate.value,
                compactedGenerationCount: state.compactedGenerationCount
            )
        }
    }

    private func retainedSnapshots(
        startingAt active: Runtime.GenerationSnapshot,
        available: [Runtime.GenerationID: Runtime.GenerationSnapshot]
    ) -> [Runtime.GenerationID: Runtime.GenerationSnapshot] {
        var result: [Runtime.GenerationID: Runtime.GenerationSnapshot] = [
            active.generation.id: active,
        ]
        var cursor = active
        for _ in 0..<retainedRollbackGenerationCount {
            guard let parentID = cursor.generation.parentID,
                  let parent = available[parentID]
            else {
                break
            }
            result[parentID] = parent
            cursor = parent
        }
        return result
    }

    private func isAncestor(
        _ candidate: Runtime.GenerationID,
        of active: Runtime.GenerationID,
        snapshots: [Runtime.GenerationID: Runtime.GenerationSnapshot]
    ) -> Bool {
        var cursor: Runtime.GenerationID? = active
        while let generationID = cursor, let snapshot = snapshots[generationID] {
            if generationID == candidate { return true }
            cursor = snapshot.generation.parentID
        }
        return false
    }

    private func applyRetentionLocked(
        _ retained: [Runtime.GenerationID: Runtime.GenerationSnapshot]
    ) {
        state.retained = retained
        for (id, snapshot) in retained {
            state.snapshots[id] = .init(snapshot)
        }
        compactUnleasedSnapshotsLocked()
    }

    private func validateCapacityLocked(
        retained: [Runtime.GenerationID: Runtime.GenerationSnapshot],
        available: [Runtime.GenerationID: Runtime.GenerationSnapshot]
    ) throws {
        var planned = available.filter { $0.value.leaseCount > 0 }
        planned.merge(retained) { _, retained in retained }
        guard planned.count <= maximumGenerationCount else {
            throw Runtime.ActivationError.generationLimitReached(
                maximum: maximumGenerationCount
            )
        }
        let byteEstimate = estimatedBytes(of: planned.values)
        guard !byteEstimate.overflow,
              byteEstimate.value <= maximumEstimatedBytes
        else {
            throw Runtime.ActivationError.memoryLimitReached(
                maximumBytes: maximumEstimatedBytes
            )
        }
    }

    private func compactUnleasedSnapshotsLocked() {
        let retainedIDs = Set(state.retained.keys)
        let originalIDs = Set(state.snapshots.keys)
        state.snapshots = state.snapshots.filter { id, weakSnapshot in
            guard let snapshot = weakSnapshot.value else { return false }
            return retainedIDs.contains(id) || snapshot.leaseCount > 0
        }
        let removedCount = originalIDs.subtracting(state.snapshots.keys).count
        if removedCount > 0 {
            let addition = state.compactedGenerationCount.addingReportingOverflow(
                UInt64(removedCount)
            )
            state.compactedGenerationCount = addition.overflow
                ? UInt64.max
                : addition.partialValue
        }
        state.quarantined.formIntersection(state.snapshots.keys)
    }

    private func liveSnapshotsLocked() -> [Runtime.GenerationID: Runtime.GenerationSnapshot] {
        state.snapshots.reduce(into: [:]) { result, element in
            if let snapshot = element.value.value {
                result[element.key] = snapshot
            }
        }
    }

    private func snapshotLocked(
        for id: Runtime.GenerationID
    ) -> Runtime.GenerationSnapshot? {
        state.snapshots[id]?.value
    }

    private func estimatedBytes<S: Sequence>(
        of snapshots: S
    ) -> (value: Int, overflow: Bool) where S.Element == Runtime.GenerationSnapshot {
        var artifacts: [Runtime.GenerationID: Int] = [:]
        for snapshot in snapshots {
            for (owner, byteCount) in snapshot.artifactByteCounts {
                artifacts[owner] = max(artifacts[owner] ?? 0, byteCount)
            }
        }
        var total = 0
        for byteCount in artifacts.values {
            let addition = total.addingReportingOverflow(byteCount)
            guard !addition.overflow else { return (Int.max, true) }
            total = addition.partialValue
        }
        return (total, false)
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
