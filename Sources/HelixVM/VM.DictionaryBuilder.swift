import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Invocation-local, single-owner storage for Dictionary accumulation. The
/// builder preserves first-key identity and insertion order while replacing
/// values for equivalent keys. It never crosses a function or VM boundary.
public final class DictionaryBuilder: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    private let lock = NSLock()
    let keyType: Bytecode.ValueType
    let valueType: Bytecode.ValueType
    private var entries: [VM.DictionaryEntry]
    private var isFinished = false

    init(
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType,
        entries: [VM.DictionaryEntry] = []
    ) {
        self.keyType = keyType
        self.valueType = valueType
        self.entries = entries
    }

    func withEntries<Result>(
        _ body: ([VM.DictionaryEntry]) throws -> Result
    ) throws -> Result {
        try withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Dictionary builder is already finished"
                )
            }
            return try body(entries)
        }
    }

    func set(
        key: VM.Value,
        value: VM.Value,
        matchingIndex: Int?
    ) throws {
        try withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Dictionary builder is already finished"
                )
            }
            guard key.type == keyType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: keyType,
                    actual: key.type
                )
            }
            guard value.type == valueType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: valueType,
                    actual: value.type
                )
            }
            if let matchingIndex {
                guard entries.indices.contains(matchingIndex) else {
                    throw VM.RuntimeTrap.invalidProgramCounter
                }
                entries[matchingIndex].value = value
            } else {
                entries.append(.init(key: key, value: value))
            }
        }
    }

    func appendArrayElement(
        key: VM.Value,
        element: VM.Value,
        matchingIndex: Int?
    ) throws {
        try withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Dictionary builder is already finished"
                )
            }
            guard key.type == keyType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: keyType,
                    actual: key.type
                )
            }
            guard case let .array(elementType) = valueType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .array(element.type),
                    actual: valueType
                )
            }
            guard element.type == elementType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: elementType,
                    actual: element.type
                )
            }
            guard let matchingIndex else {
                entries.append(
                    .init(
                        key: key,
                        value: .array([element], elementType: elementType)
                    )
                )
                return
            }
            guard entries.indices.contains(matchingIndex),
                  entries[matchingIndex].value.type == valueType
            else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }

            // Move the uniquely owned Array buffer out of the entry before
            // appending. Keeping the old enum payload alive here would force
            // Swift COW to copy the entire group on every element.
            var owned = entries[matchingIndex].value
            guard case .array(var elements, let actualType) = owned,
                  actualType == elementType
            else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            entries[matchingIndex].value = .array(
                [],
                elementType: elementType
            )
            owned = .array([], elementType: elementType)
            elements.append(element)
            entries[matchingIndex].value = .array(
                elements,
                elementType: elementType
            )
        }
    }

    func finish() throws -> [VM.DictionaryEntry] {
        try withLock {
            guard !isFinished else {
                throw VM.RuntimeTrap.explicit(
                    "Dictionary builder is already finished"
                )
            }
            isFinished = true
            let result = entries
            entries = []
            return result
        }
    }

    public static func == (
        lhs: VM.DictionaryBuilder,
        rhs: VM.DictionaryBuilder
    ) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "DictionaryBuilder<\(keyType), \(valueType)>"
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
}
