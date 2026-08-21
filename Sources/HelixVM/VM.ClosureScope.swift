import Foundation

extension VM {
/// Runtime identity for a lexical closure's dynamic extent, including Swift's
/// `withoutActuallyEscaping`. Copies and aggregate storage preserve this
/// identity, allowing the interpreter to reject a scoped closure that remains
/// reachable at scope end.
final class ClosureScope: @unchecked Sendable, Hashable {
    private let lock = NSLock()
    private var isActive = true

    static func == (lhs: VM.ClosureScope, rhs: VM.ClosureScope) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func requireActive() throws {
        try lock.withLock {
            guard isActive else {
                throw VM.RuntimeTrap.explicit(
                    "dynamically scoped closure was used after its lifetime ended"
                )
            }
        }
    }

    func end() throws {
        try lock.withLock {
            guard isActive else {
                throw VM.RuntimeTrap.explicit(
                    "closure dynamic scope ended more than once"
                )
            }
            isActive = false
        }
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
