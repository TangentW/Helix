import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Invocation-local, single-owner storage used while a collection transform
/// accumulates an Array. It never appears in a function ABI or VM boundary.
public final class ArrayBuilder: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    private let lock = NSLock()
    let elementType: Bytecode.ValueType
    private var elements: [VM.Value] = []
    private var isFinished = false

    init(elementType: Bytecode.ValueType) {
        self.elementType = elementType
    }

    func append(_ value: VM.Value) throws {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit("Array builder is already finished")
            }
            guard value.hasRuntimeType(elementType) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: elementType,
                    actual: value.type
                )
            }
            elements.append(value)
        }
    }

    func append(contentsOf values: [VM.Value]) throws {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit("Array builder is already finished")
            }
            if let mismatched = values.first(where: { !$0.hasRuntimeType(elementType) }) {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: elementType,
                    actual: mismatched.type
                )
            }
            elements.append(contentsOf: values)
        }
    }

    func finish() throws -> [VM.Value] {
        try lock.withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit("Array builder is already finished")
            }
            isFinished = true
            let result = elements
            elements = []
            return result
        }
    }

    func valuesForInspection() -> [VM.Value] {
        lock.withLock { elements }
    }

    public static func == (lhs: VM.ArrayBuilder, rhs: VM.ArrayBuilder) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "ArrayBuilder<\(elementType)>"
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
