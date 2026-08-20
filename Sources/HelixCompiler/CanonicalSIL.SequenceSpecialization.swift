import HelixBytecode

extension CanonicalSIL {
/// A concrete Swift `Sequence` whose iteration semantics are fully represented
/// without invoking a generic witness table at runtime.
enum SequenceSpecialization: Equatable, Sendable {
    case managedCollection(
        type: Bytecode.ValueType,
        element: Bytecode.ValueType
    )
    case progression(CanonicalSIL.Progression.SequenceType)

    var element: Bytecode.ValueType {
        switch self {
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
}
}
