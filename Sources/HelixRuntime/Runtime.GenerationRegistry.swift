import Foundation
import HelixCore

extension Runtime {
public struct RegistrySnapshot: Sendable, Equatable {
    public var activeGenerationID: Runtime.GenerationID?
    public var loadedGenerationIDs: [Runtime.GenerationID]
    public var quarantinedGenerationIDs: [Runtime.GenerationID]
    public var estimatedByteCount: Int
}

public final class GenerationRegistry: @unchecked Sendable {
    private struct State {
        var activeID: Runtime.GenerationID?
        var generations: [Runtime.GenerationID: Runtime.Generation] = [:]
        var quarantined: Set<Runtime.GenerationID> = []
        var estimatedByteCount = 0
    }

    private let lock = NSLock()
    private let routingLatch = Runtime.AtomicFlag()
    private var state = State()
    public let maximumGenerationCount: Int
    public let maximumEstimatedBytes: Int

    public init(maximumGenerationCount: Int = 32, maximumEstimatedBytes: Int = 64 * 1_024 * 1_024) {
        precondition(maximumGenerationCount > 0)
        precondition(maximumEstimatedBytes > 0)
        self.maximumGenerationCount = maximumGenerationCount
        self.maximumEstimatedBytes = maximumEstimatedBytes
    }

    @discardableResult
    public func activate(
        _ generation: Runtime.Generation,
        expectedActiveID: Runtime.GenerationID?
    ) throws -> Runtime.GenerationLease {
        // Publish before committing the generation. A racing caller may take
        // the slow path slightly early, but can never miss a committed route.
        // The latch is intentionally monotonic so a rolled-back invocation can
        // continue using its thread-pinned generation.
        routingLatch.storeRelease(true)
        return try lock.withLock {
            guard state.activeID == expectedActiveID else {
                throw Runtime.ActivationError.staleActiveGeneration(expected: expectedActiveID, actual: state.activeID)
            }
            guard generation.parentID == expectedActiveID else {
                throw Runtime.ActivationError.parentMismatch(expected: expectedActiveID, actual: generation.parentID)
            }
            guard state.generations[generation.id] == nil else {
                throw Runtime.ActivationError.generationAlreadyExists(generation.id)
            }
            guard !state.quarantined.contains(generation.id) else {
                throw Runtime.ActivationError.quarantined(generation.id)
            }
            guard state.generations.count < maximumGenerationCount else {
                throw Runtime.ActivationError.generationLimitReached(maximum: maximumGenerationCount)
            }
            let newByteCount = state.estimatedByteCount.addingReportingOverflow(generation.estimatedByteCount)
            guard !newByteCount.overflow, newByteCount.partialValue <= maximumEstimatedBytes else {
                throw Runtime.ActivationError.memoryLimitReached(maximumBytes: maximumEstimatedBytes)
            }
            state.generations[generation.id] = generation
            state.estimatedByteCount = newByteCount.partialValue
            state.activeID = generation.id
            return Runtime.GenerationLease(generation: generation)
        }
    }

    public func activeLease() -> Runtime.GenerationLease? {
        lock.withLock {
            guard let activeID = state.activeID, let generation = state.generations[activeID] else { return nil }
            return Runtime.GenerationLease(generation: generation)
        }
    }

    var hasEverActivated: Bool {
        routingLatch.loadAcquire()
    }

    public func route(
        for entry: Core.EntryIndex,
        startingAt generationID: Runtime.GenerationID
    ) -> Runtime.Route? {
        lock.withLock {
            var cursor: Runtime.GenerationID? = generationID
            while let current = cursor, let generation = state.generations[current] {
                if generation.removedEntries.contains(entry) { return nil }
                if let route = generation.routes[entry] { return route }
                cursor = generation.parentID
            }
            return nil
        }
    }

    public func entryEffects(
        for entry: Core.EntryIndex,
        startingAt generationID: Runtime.GenerationID
    ) -> Core.Effects? {
        lock.withLock {
            var cursor: Runtime.GenerationID? = generationID
            while let current = cursor, let generation = state.generations[current] {
                for image in generation.images {
                    if let effects = image.shell.entries[entry]?.effects { return effects }
                }
                cursor = generation.parentID
            }
            return nil
        }
    }

    public func lease(for id: Runtime.GenerationID) -> Runtime.GenerationLease? {
        lock.withLock { state.generations[id].map(Runtime.GenerationLease.init) }
    }

    @discardableResult
    public func rollback(
        expectedActiveID: Runtime.GenerationID,
        to targetID: Runtime.GenerationID?
    ) throws -> Runtime.GenerationLease? {
        try lock.withLock {
            guard state.activeID == expectedActiveID else {
                throw Runtime.ActivationError.staleActiveGeneration(expected: expectedActiveID, actual: state.activeID)
            }
            if let targetID, state.generations[targetID] == nil {
                throw Runtime.ActivationError.unknownGeneration(targetID)
            }
            if let targetID, state.quarantined.contains(targetID) {
                throw Runtime.ActivationError.quarantined(targetID)
            }
            if let targetID, !isAncestor(targetID, of: expectedActiveID, generations: state.generations) {
                throw Runtime.ActivationError.rollbackTargetIsNotAncestor(
                    target: targetID,
                    active: expectedActiveID
                )
            }
            state.activeID = targetID
            return targetID.flatMap { state.generations[$0] }.map(Runtime.GenerationLease.init)
        }
    }

    public func quarantine(_ id: Runtime.GenerationID, rollbackIfActive: Bool = true) {
        lock.withLock {
            state.quarantined.insert(id)
            guard rollbackIfActive, state.activeID == id else { return }
            var candidate = state.generations[id]?.parentID
            while let generationID = candidate, state.quarantined.contains(generationID) {
                candidate = state.generations[generationID]?.parentID
            }
            state.activeID = candidate
        }
    }

    public func snapshot() -> Runtime.RegistrySnapshot {
        lock.withLock {
            Runtime.RegistrySnapshot(
                activeGenerationID: state.activeID,
                loadedGenerationIDs: state.generations.keys.sorted(),
                quarantinedGenerationIDs: state.quarantined.sorted(),
                estimatedByteCount: state.estimatedByteCount
            )
        }
    }

    private func isAncestor(
        _ candidate: Runtime.GenerationID,
        of active: Runtime.GenerationID,
        generations: [Runtime.GenerationID: Runtime.Generation]
    ) -> Bool {
        var cursor: Runtime.GenerationID? = active
        while let generationID = cursor {
            if generationID == candidate { return true }
            cursor = generations[generationID]?.parentID
        }
        return false
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
