import Foundation
import HelixBytecode

extension CanonicalSIL {
/// Logical Swift text values and their compact HLBC representations.
///
/// `Character` is carried as a VM String whose producers and bridges preserve
/// the one-extended-grapheme invariant. `Substring` is an Array of represented
/// Characters so Collection algorithms can share the same verified machinery
/// as other normalized slices without importing either private Swift layout.
enum TextRepresentation {
    enum Kind: Equatable, Sendable {
        case string
        case substring
        case character

        var valueType: Bytecode.ValueType {
            switch self {
            case .string, .character:
                .string
            case .substring:
                .array(.string)
            }
        }

        var sequenceElement: Bytecode.ValueType? {
            switch self {
            case .string, .substring:
                .string
            case .character:
                nil
            }
        }
    }

    static func kind(of raw: String) -> Kind? {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        switch spelling {
        case "String", "Swift.String":
            return .string
        case "Substring", "Swift.Substring":
            return .substring
        case "Character", "Swift.Character":
            return .character
        default:
            return nil
        }
    }

    /// Recovers the logical element identity erased by the compact VM String
    /// representation. Only concrete wrappers normalized elsewhere in the
    /// compiler are accepted; arbitrary names that merely contain "Character"
    /// do not acquire text semantics.
    static func sequenceElementKind(of raw: String) -> Kind? {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        if let kind = kind(of: spelling) {
            return switch kind {
            case .string, .substring: .character
            case .character: nil
            }
        }

        let directElementWrappers = [
            "Array", "ArraySlice", "Set", "Repeated",
        ]
        for wrapper in directElementWrappers {
            if let argument = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ) {
                return kind(of: argument)
            }
        }

        let sequenceWrappers = ["Slice", "ReversedCollection"]
        for wrapper in sequenceWrappers {
            if let argument = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ) {
                return sequenceElementKind(of: argument)
            }
        }

        for wrapper in ["FlattenSequence", "JoinedSequence"] {
            guard let outer = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ), let inner = directSequenceElementSpelling(of: outer)
            else { continue }
            return sequenceElementKind(of: inner)
        }
        return nil
    }

    /// Returns only element spellings for concrete wrappers whose storage is
    /// normalized by TypeEnvironment. This is intentionally narrower than a
    /// Swift type-system evaluator: unsupported generic witnesses stay closed.
    private static func directSequenceElementSpelling(
        of raw: String
    ) -> String? {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        for wrapper in ["Array", "ArraySlice", "Set", "Repeated"] {
            if let argument = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ) {
                return argument
            }
        }
        for wrapper in ["Slice", "ReversedCollection"] {
            if let argument = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ) {
                return directSequenceElementSpelling(of: argument)
            }
        }
        for wrapper in ["FlattenSequence", "JoinedSequence"] {
            guard let outer = unaryGenericArgument(
                of: spelling,
                names: [wrapper, "Swift.\(wrapper)"]
            ), let inner = directSequenceElementSpelling(of: outer)
            else { continue }
            return directSequenceElementSpelling(of: inner)
        }
        return nil
    }

    private static func unaryGenericArgument(
        of raw: String,
        names: [String]
    ) -> String? {
        for name in names {
            let prefix = name + "<"
            guard raw.hasPrefix(prefix), raw.hasSuffix(">") else { continue }
            let start = raw.index(raw.startIndex, offsetBy: prefix.count)
            return String(raw[start..<raw.index(before: raw.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

}
}
