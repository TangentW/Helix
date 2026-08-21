import HelixBytecode

extension CanonicalSIL {
/// A mutable, variable-length Swift collection whose complete value semantics
/// fit the represented HLBC storage model. Logical String storage is normalized
/// to extended-grapheme Character elements only while an edit is in progress;
/// represented Array-backed values can be edited directly.
enum RangeReplaceableCollectionRepresentation: Equatable, Sendable {
    case representedArray(element: Bytecode.ValueType)
    case stringCharacters

    init?(sequence: CanonicalSIL.SequenceSpecialization) {
        switch sequence {
        case .stringCharacters:
            self = .stringCharacters
        case let .managedCollection(type, element)
        where type == .array(element):
            self = .representedArray(element: element)
        case .managedCollection, .progression:
            return nil
        }
    }

    var storageType: Bytecode.ValueType {
        switch self {
        case let .representedArray(element):
            .array(element)
        case .stringCharacters:
            .string
        }
    }

    var element: Bytecode.ValueType {
        switch self {
        case let .representedArray(element):
            element
        case .stringCharacters:
            .string
        }
    }

    var elementsType: Bytecode.ValueType {
        .array(element)
    }

    var sequence: CanonicalSIL.SequenceSpecialization {
        switch self {
        case let .representedArray(element):
            .managedCollection(type: .array(element), element: element)
        case .stringCharacters:
            .stringCharacters
        }
    }
}
}
