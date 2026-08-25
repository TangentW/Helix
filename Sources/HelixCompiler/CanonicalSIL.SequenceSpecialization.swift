import HelixBytecode

extension CanonicalSIL {
/// A concrete Swift `Sequence` whose iteration semantics are fully represented
/// without invoking a generic witness table at runtime.
enum SequenceSpecialization: Equatable, Sendable {
    /// Swift.String normalized to its extended-grapheme Character sequence.
    /// The source remains a VM String; traversal/materialization creates the
    /// same Array<String> representation used by Character collections.
    case stringCharacters
    case managedCollection(
        type: Bytecode.ValueType,
        element: Bytecode.ValueType
    )
    case progression(CanonicalSIL.Progression.SequenceType)

    var element: Bytecode.ValueType {
        switch self {
        case .stringCharacters:
            .string
        case let .managedCollection(_, element):
            element
        case let .progression(type):
            type.element
        }
    }

    var managedCollectionType: Bytecode.ValueType? {
        guard case let .managedCollection(type, _) = self else { return nil }
        return type
    }

    var normalizedCollectionType: Bytecode.ValueType? {
        switch self {
        case .stringCharacters:
            .array(.string)
        case let .managedCollection(type, _):
            type
        case .progression:
            nil
        }
    }

    /// Whether reverse traversal can preserve the concrete source order.
    /// Finite Range values are materialized through the same bounded Array
    /// adapter already used by `reversed()` and other finite consumers.
    var supportsReverseTraversal: Bool {
        switch self {
        case .stringCharacters:
            true
        case let .managedCollection(type, _):
            if case .array = type { true } else { false }
        case let .progression(type):
            (type.family == .range || type.family == .closedRange)
                && type.supportsIteration
        }
    }

    /// Range<Int>.Index is its element value. ClosedRange uses an opaque Index,
    /// while the remaining progression families are Sequences rather than
    /// integer-indexed Collections; neither may enter index-returning operations.
    var usesElementAsIntegerIndex: Bool {
        guard case let .progression(type) = self else { return false }
        return type.family == .range && type.element == .int64
    }
}
}
