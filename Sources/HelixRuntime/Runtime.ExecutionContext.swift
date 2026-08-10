import Foundation
import HelixCore
import HelixVM

extension Runtime {
public final class ExecutionContext: @unchecked Sendable {
    public let lease: Runtime.GenerationLease
    private let lock = NSLock()
    private var budgetStorage: VM.InvocationBudget?
    private var activeRoutes: Set<Core.EntryIndex> = []

    init(lease: Runtime.GenerationLease) {
        self.lease = lease
    }

    func budget() -> VM.InvocationBudget {
        lock.withLock {
            if let budgetStorage { return budgetStorage }
            let budget = VM.InvocationBudget(limits: lease.generation.resourceLimits)
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
    private let key: String

    init() {
        key = "dev.helix.execution-context.\(UUID().uuidString)"
    }

    var current: Runtime.ExecutionContext? {
        Thread.current.threadDictionary[key] as? Runtime.ExecutionContext
    }

    func withContext<T>(_ context: Runtime.ExecutionContext, body: () throws -> T) rethrows -> T {
        if let current { return try bodyWithExisting(current, body: body) }
        Thread.current.threadDictionary[key] = context
        defer { Thread.current.threadDictionary.removeObject(forKey: key) }
        return try body()
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
