import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Internal invocation scope that pins one immutable generation across nested calls.
///
/// Runtime exposes the pinned lease for diagnostics, but applications do not
/// construct or retain execution contexts directly.
public final class ExecutionContext: @unchecked Sendable {
    /// Lease retaining the generation selected at the root call boundary.
    public let lease: Runtime.GenerationLease
    private let lock = NSLock()
    private var budgetStorage: VM.InvocationBudget?
    private var activeRoutes: Set<Core.EntryIndex> = []

    init(lease: Runtime.GenerationLease) {
        self.lease = lease
    }

    func budget(isMainActorRoot: Bool? = nil) -> VM.InvocationBudget {
        lock.withLock {
            if let budgetStorage { return budgetStorage }
            let budget = VM.InvocationBudget(
                limits: lease.resourceLimits,
                isMainThread: isMainActorRoot ?? Thread.isMainThread
            )
            budgetStorage = budget
            return budget
        }
    }

    func enter(entry: Core.EntryIndex) -> Bool {
        lock.withLock { activeRoutes.insert(entry).inserted }
    }

    var isExecutingPatch: Bool {
        lock.withLock { !activeRoutes.isEmpty }
    }

    func leave(entry: Core.EntryIndex) {
        _ = lock.withLock { activeRoutes.remove(entry) }
    }
}

final class ExecutionContextStorage: @unchecked Sendable {
    private struct AsyncBinding: Sendable {
        var storageID: UUID
        var context: Runtime.ExecutionContext
    }

    private enum AsyncScope {
        @TaskLocal static var binding: AsyncBinding?
    }

    private let storageID = UUID()
    private let key: String

    init() {
        key = "dev.helix.execution-context.\(UUID().uuidString)"
    }

    var current: Runtime.ExecutionContext? {
        if let asyncCurrent { return asyncCurrent }
        return Thread.current.threadDictionary[key]
            as? Runtime.ExecutionContext
    }

    private var asyncCurrent: Runtime.ExecutionContext? {
        guard let binding = AsyncScope.binding,
              binding.storageID == storageID else { return nil }
        return binding.context
    }

    func withContext<T>(_ context: Runtime.ExecutionContext, body: () throws -> T) rethrows -> T {
        if let current { return try bodyWithExisting(current, body: body) }
        Thread.current.threadDictionary[key] = context
        defer { Thread.current.threadDictionary.removeObject(forKey: key) }
        return try body()
    }

    /// Task-local storage keeps the pinned generation and root budget stable
    /// when Swift resumes an async bridge on another worker thread. Synchronous
    /// nested calls consult the same binding through ``current``.
    func withContext<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ context: Runtime.ExecutionContext,
        body: () async throws -> T
    ) async rethrows -> T {
        _ = isolation
        // A thread-local synchronous context must be promoted into TaskLocal
        // storage before the first await; otherwise executor migration would
        // silently lose its generation lease and root budget.
        if asyncCurrent != nil {
            return try await body()
        }
        return try await AsyncScope.$binding.withValue(
            .init(storageID: storageID, context: context)
        ) {
            try await body()
        }
    }

    /// Temporarily replaces a different generation context for a callback on
    /// an object pinned to an older immutable image, then restores the caller.
    func withIsolatedContext<T>(
        _ context: Runtime.ExecutionContext,
        body: () throws -> T
    ) rethrows -> T {
        if asyncCurrent != nil {
            return try AsyncScope.$binding.withValue(
                .init(storageID: storageID, context: context)
            ) {
                try body()
            }
        }
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = context
        defer {
            if let previous {
                Thread.current.threadDictionary[key] = previous
            } else {
                Thread.current.threadDictionary.removeObject(forKey: key)
            }
        }
        return try body()
    }

    func withIsolatedContext<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ context: Runtime.ExecutionContext,
        body: () async throws -> T
    ) async rethrows -> T {
        _ = isolation
        return try await AsyncScope.$binding.withValue(
            .init(storageID: storageID, context: context)
        ) {
            try await body()
        }
    }

    private func bodyWithExisting<T>(_ context: Runtime.ExecutionContext, body: () throws -> T) rethrows -> T {
        _ = context
        return try body()
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
