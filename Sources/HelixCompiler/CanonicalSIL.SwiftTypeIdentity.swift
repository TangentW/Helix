import Foundation

extension CanonicalSIL {
/// Canonical source-level type identities retained across representations that
/// deliberately erase Swift distinctions such as `Int` versus `Int64`, tuple
/// labels, or `String` versus `Character`.
enum SwiftTypeIdentity {
    static func normalized(_ raw: String) -> String {
        canonicalize(compact(raw))
    }

    /// Returns the concrete `Sequence.Element` identity for every sequence
    /// family whose storage can already be represented by the compiler. This
    /// is intentionally not a protocol-conformance solver: unknown wrappers
    /// stay closed even if their physical HLBC shape happens to match.
    static func representedSequenceElement(of raw: String) -> String? {
        representedSequenceElement(ofNormalized: normalized(raw))
    }

    /// The currently represented mutable variable-length collection family.
    /// `Slice` is admitted recursively only when its base is itself in that
    /// family; read-only adapters such as ReversedCollection and Repeated must
    /// not become mutable merely because they normalize to an Array in HLBC.
    static func isRepresentedRangeReplaceableCollection(
        _ raw: String
    ) -> Bool {
        isRepresentedRangeReplaceableCollection(
            normalized: normalized(raw)
        )
    }

    private static func representedSequenceElement(
        ofNormalized type: String
    ) -> String? {
        switch type {
        case "String", "Substring":
            return "Character"
        default:
            break
        }

        if type.hasSuffix(".Keys") || type.hasSuffix(".Values") {
            let selectsKey = type.hasSuffix(".Keys")
            let suffix = selectsKey ? ".Keys" : ".Values"
            let base = String(type.dropLast(suffix.count))
            guard let dictionary = genericType(base),
                  dictionary.name == "Dictionary",
                  dictionary.arguments.count == 2
            else { return nil }
            return dictionary.arguments[selectsKey ? 0 : 1]
        }

        guard let generic = genericType(type) else { return nil }
        switch generic.name {
        case "Array", "ArraySlice", "Set", "Repeated", "Range",
             "ClosedRange", "StrideTo", "StrideThrough":
            guard generic.arguments.count == 1 else { return nil }
            return generic.arguments[0]

        case "Slice", "ReversedCollection":
            guard generic.arguments.count == 1 else { return nil }
            return representedSequenceElement(
                ofNormalized: generic.arguments[0]
            )

        case "EnumeratedSequence":
            guard generic.arguments.count == 1,
                  let element = representedSequenceElement(
                      ofNormalized: generic.arguments[0]
                  )
            else { return nil }
            return "(offset:Int,element:\(element))"

        case "Zip2Sequence":
            guard generic.arguments.count == 2,
                  let lhs = representedSequenceElement(
                      ofNormalized: generic.arguments[0]
                  ),
                  let rhs = representedSequenceElement(
                      ofNormalized: generic.arguments[1]
                  )
            else { return nil }
            return "(\(lhs),\(rhs))"

        case "FlattenSequence", "JoinedSequence":
            guard generic.arguments.count == 1,
                  let innerSequence = representedSequenceElement(
                      ofNormalized: generic.arguments[0]
                  )
            else { return nil }
            return representedSequenceElement(ofNormalized: innerSequence)

        case "Dictionary":
            guard generic.arguments.count == 2 else { return nil }
            return "(key:\(generic.arguments[0]),value:\(generic.arguments[1]))"

        default:
            return nil
        }
    }

    private static func isRepresentedRangeReplaceableCollection(
        normalized type: String
    ) -> Bool {
        if type == "String" || type == "Substring" { return true }
        guard let generic = genericType(type) else { return false }
        switch generic.name {
        case "Array", "ArraySlice":
            return generic.arguments.count == 1
        case "Slice":
            return generic.arguments.count == 1
                && isRepresentedRangeReplaceableCollection(
                    normalized: generic.arguments[0]
                )
        default:
            return false
        }
    }

    private static func compact(_ raw: String) -> String {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in ", "@in_guaranteed ", "@out ",
            ] where spelling.hasPrefix(prefix) {
                spelling.removeFirst(prefix.count)
                spelling = spelling.trimmingCharacters(in: .whitespaces)
                removedPrefix = true
                break
            }
        }

        let compact = spelling.filter { !$0.isWhitespace }
        let qualifier = "Swift."
        let qualifierBoundaries: Set<Character> = ["<", "(", "[", ",", ":"]
        var result = ""
        var index = compact.startIndex
        while index < compact.endIndex {
            let isBoundary = index == compact.startIndex
                || qualifierBoundaries.contains(
                    compact[compact.index(before: index)]
                )
            if isBoundary, compact[index...].hasPrefix(qualifier) {
                index = compact.index(index, offsetBy: qualifier.count)
                continue
            }
            result.append(compact[index])
            index = compact.index(after: index)
        }
        return result
    }

    private static func canonicalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        if raw.last == "?" || raw.last == "!" {
            return "Optional<\(canonicalize(String(raw.dropLast())))>"
        }

        if raw.first == "[", raw.last == "]",
           encloses(raw, opening: "[", closing: "]") {
            let body = String(raw.dropFirst().dropLast())
            let components = splitTopLevel(body, separator: ":")
            if components.count == 2 {
                return "Dictionary<\(canonicalize(components[0])),"
                    + "\(canonicalize(components[1]))>"
            }
            return "Array<\(canonicalize(body))>"
        }

        if raw.first == "(", raw.last == ")",
           encloses(raw, opening: "(", closing: ")") {
            let body = String(raw.dropFirst().dropLast())
            if body.isEmpty { return "()" }
            let components = splitTopLevel(body, separator: ",")
            if components.count == 1 {
                return canonicalTupleElement(components[0])
            }
            return "(" + components.map {
                canonicalTupleElement($0)
            }.joined(separator: ",") + ")"
        }

        if let generic = parsedGenericType(raw) {
            let name = generic.name == "Optional" ? "Optional" : generic.name
            return name + "<" + generic.arguments.map(canonicalize)
                .joined(separator: ",") + ">" + generic.suffix
        }
        return raw
    }

    private static func genericType(
        _ raw: String
    ) -> (name: String, arguments: [String])? {
        guard let generic = parsedGenericType(raw), generic.suffix.isEmpty
        else { return nil }
        return (generic.name, generic.arguments)
    }

    private static func parsedGenericType(
        _ raw: String
    ) -> (name: String, arguments: [String], suffix: String)? {
        guard let open = raw.firstIndex(of: "<"), open != raw.startIndex
        else { return nil }
        var depth = 0
        var close: String.Index?
        var index = open
        while index < raw.endIndex {
            switch raw[index] {
            case "<":
                depth += 1
            case ">":
                depth -= 1
                guard depth >= 0 else { return nil }
                if depth == 0 {
                    close = index
                    index = raw.endIndex
                    continue
                }
            default:
                break
            }
            if index < raw.endIndex {
                index = raw.index(after: index)
            }
        }
        guard let close, depth == 0 else { return nil }
        let bodyStart = raw.index(after: open)
        let suffixStart = raw.index(after: close)
        let body = String(raw[bodyStart..<close])
        guard !body.isEmpty else { return nil }
        let arguments = splitTopLevel(
            body,
            separator: ","
        )
        guard !arguments.isEmpty,
              arguments.allSatisfy({ !$0.isEmpty })
        else { return nil }
        return (
            name: String(raw[..<open]),
            arguments: arguments,
            suffix: String(raw[suffixStart...])
        )
    }

    private static func canonicalTupleElement(_ raw: String) -> String {
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[":
                depth += 1
            case ")", ">", "]":
                depth -= 1
            case ":" where depth == 0:
                let label = String(raw[..<index])
                let type = String(raw[raw.index(after: index)...])
                return "\(label):\(canonicalize(type))"
            default:
                break
            }
        }
        return canonicalize(raw)
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
                result.append(String(raw[start..<index]))
                start = raw.index(after: index)
            }
        }
        result.append(String(raw[start...]))
        return result
    }

    private static func encloses(
        _ raw: String,
        opening: Character,
        closing: Character
    ) -> Bool {
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case opening:
                depth += 1
            case closing:
                depth -= 1
                if depth == 0 {
                    return index == raw.index(before: raw.endIndex)
                }
            default:
                break
            }
            guard depth >= 0 else { return false }
        }
        return false
    }
}
}
