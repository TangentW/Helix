import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
/// Parses the canonical, recursive spelling emitted by
/// `Bytecode.ValueType.description`.
///
/// This is deliberately separate from Swift source/SIL type resolution. A
/// synthetic local type identity may contain compiler-private value shapes
/// such as closures, mutable cells, or Native TypeIDs that are not Swift type
/// syntax and must not be interpreted through source-name lookup.
enum ValueTypeSpelling {
    static func parse(_ raw: String) throws -> Bytecode.ValueType {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw malformed(raw) }

        switch text {
        case "Void": return .void
        case "Never": return .never
        case "Bool": return .bool
        case "String": return .string
        case "Any": return .any
        case "any Error": return .error
        default: break
        }

        if let width = integerWidth(in: text, prefix: "Int") {
            return .integer(bitWidth: width, signed: true)
        }
        if let width = integerWidth(in: text, prefix: "UInt") {
            return .integer(bitWidth: width, signed: false)
        }
        if let width = integerWidth(in: text, prefix: "Float") {
            return .float(bitWidth: width)
        }

        if text.hasPrefix("@closure") {
            return .closure(
                try parseClosureSignature(
                    String(text.dropFirst("@closure".count)),
                    original: raw
                )
            )
        }
        if let body = try genericBody(in: text, prefix: "Array") {
            return .array(try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "Optional") {
            return .optional(try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "Set") {
            return .set(try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "Dictionary") {
            let arguments = try splitTopLevel(body)
            guard arguments.count == 2 else { throw malformed(raw) }
            return .dictionary(
                key: try parse(arguments[0]),
                value: try parse(arguments[1])
            )
        }
        if let body = try genericBody(in: text, prefix: "Native") {
            do {
                return .native(
                    .init(rawValue: try Core.Digest(hex: body))
                )
            } catch {
                throw malformed(raw)
            }
        }
        if let body = try genericBody(in: text, prefix: "@address") {
            return .address(try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "@mutableCell") {
            return .mutableCell(try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "@weak") {
            return .nonOwningReference(kind: .weak, pointee: try parse(body))
        }
        if let body = try genericBody(in: text, prefix: "@unowned") {
            return .nonOwningReference(
                kind: .unowned,
                pointee: try parse(body)
            )
        }
        if let body = try genericBody(in: text, prefix: "@dictionaryState") {
            let arguments = try splitTopLevel(body)
            guard arguments.count == 2 else { throw malformed(raw) }
            return .dictionaryState(
                key: try parse(arguments[0]),
                value: try parse(arguments[1])
            )
        }
        if text.hasPrefix("@arrayState."),
           let delimiter = text.firstIndex(of: "<") {
            let kindStart = text.index(
                text.startIndex,
                offsetBy: "@arrayState.".count
            )
            let kindSpelling = String(text[kindStart..<delimiter])
            guard let kind = Bytecode.ArrayStateKind(rawValue: kindSpelling),
                  let body = try genericBody(
                      in: text,
                      prefix: "@arrayState.\(kindSpelling)"
                  )
            else { throw malformed(raw) }
            return .arrayState(kind: kind, element: try parse(body))
        }
        if text.hasPrefix("("), text.hasSuffix(")") {
            let body = String(text.dropFirst().dropLast())
            return .tuple(try splitTopLevel(body).map(parse))
        }

        // Local type keys are already fully qualified before they enter a
        // synthetic identity. Keeping them opaque also preserves nested
        // synthetic Result identities without reparsing Swift generic syntax.
        guard !text.hasPrefix("@") else { throw malformed(raw) }
        return .local(.init(rawValue: text))
    }

    private static func parseClosureSignature(
        _ raw: String,
        original: String
    ) throws -> Bytecode.ClosureSignature {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var thrownType: Bytecode.ValueType?
        var mayAllocate = false
        var hasExternalSideEffects = false
        var requiresMainActor = false
        var isAsync = false

        if text.hasPrefix("[") {
            guard let close = matchingDelimiter(
                in: text,
                opening: "[",
                closing: "]",
                at: text.startIndex
            ) else { throw malformed(original) }
            let effects = String(
                text[text.index(after: text.startIndex)..<close]
            )
            guard !effects.isEmpty else { throw malformed(original) }
            var seen = Set<String>()
            for effect in try splitTopLevel(effects) {
                if effect.hasPrefix("throws("), effect.hasSuffix(")") {
                    guard seen.insert("throws").inserted else {
                        throw malformed(original)
                    }
                    thrownType = try parse(
                        String(effect.dropFirst("throws(".count).dropLast())
                    )
                    continue
                }
                guard seen.insert(effect).inserted else {
                    throw malformed(original)
                }
                switch effect {
                case "allocates": mayAllocate = true
                case "external": hasExternalSideEffects = true
                case "MainActor": requiresMainActor = true
                case "async": isAsync = true
                default: throw malformed(original)
                }
            }
            text = String(text[text.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }

        guard let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(in: text)
        else { throw malformed(original) }
        let prefix = String(text[..<arrow.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard prefix.hasPrefix("("), prefix.hasSuffix(")"),
              let close = prefix.lastIndex(of: ")"),
              let open = CanonicalSIL.FunctionTypeSyntax
                .matchingOpeningParenthesis(for: close, in: prefix),
              open == prefix.startIndex
        else { throw malformed(original) }

        let parameterBody = String(prefix.dropFirst().dropLast())
        let parameterSpellings = try splitTopLevel(parameterBody)
        var parameters: [Bytecode.ValueType] = []
        var conventions: [Bytecode.ParameterConvention] = []
        parameters.reserveCapacity(parameterSpellings.count)
        conventions.reserveCapacity(parameterSpellings.count)
        for rawParameter in parameterSpellings {
            var parameter = rawParameter
            let convention: Bytecode.ParameterConvention
            if parameter.hasPrefix("@borrowed ") {
                parameter.removeFirst("@borrowed ".count)
                convention = .borrowed
            } else if parameter.hasPrefix("@inout ") {
                parameter.removeFirst("@inout ".count)
                convention = .inout
            } else {
                convention = .owned
            }
            parameters.append(try parse(parameter))
            conventions.append(convention)
        }

        let result = try parse(
            String(text[arrow.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        )
        return .init(
            parameters: parameters,
            parameterConventions: conventions,
            result: result,
            thrownType: thrownType,
            effects: .init(
                mayThrow: thrownType != nil,
                mayAllocate: mayAllocate,
                hasExternalSideEffects: hasExternalSideEffects,
                requiresMainActor: requiresMainActor,
                isAsync: isAsync
            )
        )
    }

    private static func integerWidth(
        in text: String,
        prefix: String
    ) -> UInt16? {
        guard text.hasPrefix(prefix) else { return nil }
        let suffix = text.dropFirst(prefix.count)
        guard !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber)
        else { return nil }
        return UInt16(suffix)
    }

    private static func genericBody(
        in text: String,
        prefix: String
    ) throws -> String? {
        let opening = prefix + "<"
        guard text.hasPrefix(opening) else { return nil }
        guard text.hasSuffix(">"),
              let delimiter = text.index(
                  text.startIndex,
                  offsetBy: prefix.count,
                  limitedBy: text.endIndex
              ),
              let close = matchingDelimiter(
                  in: text,
                  opening: "<",
                  closing: ">",
                  at: delimiter
              ),
              close == text.index(before: text.endIndex)
        else { throw malformed(text) }
        return String(text[text.index(after: delimiter)..<close])
    }

    private static func splitTopLevel(_ raw: String) throws -> [String] {
        guard !raw.isEmpty else { return [] }
        var result: [String] = []
        var start = raw.startIndex
        var parentheses = 0
        var angles = 0
        var brackets = 0
        for index in raw.indices {
            switch raw[index] {
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "<": angles += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angles -= 1 }
            case "[": brackets += 1
            case "]": brackets -= 1
            case "," where parentheses == 0 && angles == 0 && brackets == 0:
                let component = String(raw[start..<index])
                    .trimmingCharacters(in: .whitespaces)
                guard !component.isEmpty else { throw malformed(raw) }
                result.append(component)
                start = raw.index(after: index)
            default: break
            }
            guard parentheses >= 0, angles >= 0, brackets >= 0 else {
                throw malformed(raw)
            }
        }
        guard parentheses == 0, angles == 0, brackets == 0 else {
            throw malformed(raw)
        }
        let final = String(raw[start...])
            .trimmingCharacters(in: .whitespaces)
        guard !final.isEmpty else { throw malformed(raw) }
        result.append(final)
        return result
    }

    private static func matchingDelimiter(
        in text: String,
        opening: Character,
        closing: Character,
        at start: String.Index
    ) -> String.Index? {
        guard text.indices.contains(start), text[start] == opening else {
            return nil
        }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == opening {
                depth += 1
            } else if character == closing {
                if closing == ">", index > text.startIndex,
                   text[text.index(before: index)] == "-" {
                    index = text.index(after: index)
                    continue
                }
                depth -= 1
                if depth == 0 { return index }
            }
            guard depth >= 0 else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func malformed(_ raw: String) -> CanonicalSIL.LoweringError {
        .malformedSIL("invalid canonical value-type spelling: \(raw)")
    }
}
}
