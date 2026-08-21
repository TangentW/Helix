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

    /// Character and Substring intentionally share compact physical storage
    /// with String and Array<String>. VM-owned Any currently records only that
    /// physical ValueType, so boxing either logical type (including inside an
    /// aggregate) would make Swift dynamic casts unsound. Keep those casts
    /// fail-closed until Any carries a recursive logical type discriminator.
    static func containsAnyErasedIdentity(in raw: String) -> Bool {
        var spelling = normalizedTypeSpelling(raw)
        while spelling.last == "?" || spelling.last == "!" {
            spelling.removeLast()
            spelling = spelling.trimmingCharacters(in: .whitespaces)
        }

        if let kind = kind(of: spelling) {
            return kind == .character || kind == .substring
        }

        if spelling.first == "(", spelling.last == ")" {
            let body = String(spelling.dropFirst().dropLast())
            return splitTopLevel(body, separator: ",").contains {
                containsAnyErasedIdentity(in: tupleElementType($0))
            }
        }

        if spelling.first == "[", spelling.last == "]" {
            let body = String(spelling.dropFirst().dropLast())
            let components = splitTopLevel(body, separator: ":")
            return components.contains(where: containsAnyErasedIdentity)
        }

        guard let open = spelling.firstIndex(of: "<"),
              spelling.last == ">",
              enclosesGenericBody(spelling, openingAt: open)
        else { return false }
        let bodyStart = spelling.index(after: open)
        let bodyEnd = spelling.index(before: spelling.endIndex)
        return splitTopLevel(
            String(spelling[bodyStart..<bodyEnd]),
            separator: ","
        ).contains(where: containsAnyErasedIdentity)
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

    private static func normalizedTypeSpelling(_ raw: String) -> String {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in ", "@in_guaranteed ", "@out ",
            ] where spelling.hasPrefix(prefix) {
                spelling.removeFirst(prefix.count)
                spelling = spelling.trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return spelling
    }

    private static func tupleElementType(_ raw: String) -> String {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        var depth = 0
        for index in spelling.indices {
            switch spelling[index] {
            case "(", "<", "[":
                depth += 1
            case ")", ">", "]":
                depth -= 1
            case ":" where depth == 0:
                return String(spelling[spelling.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
            default:
                break
            }
        }
        return spelling
    }

    private static func splitTopLevel(
        _ raw: String,
        separator: Character
    ) -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[":
                depth += 1
            case ")", ">", "]":
                depth -= 1
            default:
                break
            }
            if raw[index] == separator, depth == 0 {
                result.append(
                    String(raw[start..<index])
                        .trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            }
        }
        result.append(
            String(raw[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result.filter { !$0.isEmpty }
    }

    private static func enclosesGenericBody(
        _ raw: String,
        openingAt open: String.Index
    ) -> Bool {
        var depth = 0
        for index in raw[open...].indices {
            switch raw[index] {
            case "<":
                depth += 1
            case ">":
                depth -= 1
                if depth == 0 {
                    return index == raw.index(before: raw.endIndex)
                }
            default:
                break
            }
        }
        return false
    }
}
}
