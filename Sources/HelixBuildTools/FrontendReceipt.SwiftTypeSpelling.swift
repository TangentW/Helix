import Foundation

/// Validates type syntax emitted into generated Swift source. This is a syntax
/// boundary, not a semantic resolver; frozen ValueType checks remain separate.
extension FrontendReceipt {
enum SwiftTypeSpelling {
    /// Rewrites only complete nominal tokens, preserving the surrounding
    /// optional, collection, tuple, generic, and function-type syntax.
    static func replacingNominalAliases(
        in raw: String,
        aliases: [String: String]
    ) -> String {
        guard !aliases.isEmpty else { return raw }
        var result = ""
        var token = ""
        func replacement(for value: String) -> String {
            if let exact = aliases[value] { return exact }
            var end = value.endIndex
            while let separator = value[..<end].lastIndex(of: ".") {
                let prefix = String(value[..<separator])
                if let replacement = aliases[prefix] {
                    return replacement + value[separator...]
                }
                end = separator
            }
            return value
        }
        func appendToken() {
            guard !token.isEmpty else { return }
            result += replacement(for: token)
            token.removeAll(keepingCapacity: true)
        }
        for character in raw {
            if character == "." || character == "_"
                || character.isLetter || character.isNumber {
                token.append(character)
            } else {
                appendToken()
                result.append(character)
            }
        }
        appendToken()
        return result
    }

    static func isGeneratedType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value.utf8.count <= 64 * 1_024
            && isType(value, allowsImplicitlyUnwrappedOptional: true)
    }

    private static func isType(
        _ value: String,
        allowsImplicitlyUnwrappedOptional: Bool = false
    ) -> Bool {
        if let function = FrontendReceipt.FunctionTypeSpelling.parse(value) {
            guard function.isSynchronousNonthrowing,
                  let parameters = FrontendReceipt.FunctionTypeSpelling
                    .parameterSpellings(in: value)
            else { return false }
            return parameters.allSatisfy {
                isType($0, allowsImplicitlyUnwrappedOptional: true)
            } && (isVoid(function.result) || isType(
                function.result,
                allowsImplicitlyUnwrappedOptional: true
            ))
        }
        if value.hasPrefix("@") { return false }
        if value.hasPrefix("any ") {
            let existential = value.dropFirst("any ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !existential.isEmpty
                && !existential.hasPrefix("any ")
                && isType(existential)
        }
        if value.hasSuffix("!") {
            let wrapped = String(value.dropLast())
            return allowsImplicitlyUnwrappedOptional
                && !wrapped.hasSuffix("?")
                && !wrapped.hasSuffix("!")
                && isType(wrapped)
        }
        if value.hasSuffix("?") {
            return isType(String(value.dropLast()))
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let body = String(value.dropFirst().dropLast())
            guard let components = splitTopLevel(body, separator: ":") else {
                return false
            }
            switch components.count {
            case 1:
                return isType(components[0])
            case 2:
                return isType(components[0]) && isType(components[1])
            default:
                return false
            }
        }
        if value.hasPrefix("("), value.hasSuffix(")") {
            let body = String(value.dropFirst().dropLast())
            guard let components = splitTopLevel(body, separator: ","),
                  components.count >= 2
            else { return false }
            return components.allSatisfy { isType($0) }
        }
        if let open = value.firstIndex(of: "<") {
            guard value.hasSuffix(">"),
                  isModulePath(String(value[..<open]))
            else { return false }
            let body = String(
                value[value.index(after: open)..<value.index(before: value.endIndex)]
            )
            guard let arguments = splitTopLevel(body, separator: ","),
                  !arguments.isEmpty
            else { return false }
            return arguments.allSatisfy { isType($0) }
        }
        return isModulePath(value)
    }

    private static func isVoid(_ value: String) -> Bool {
        ["()", "Void", "Swift.Void"].contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func splitTopLevel(
        _ raw: String,
        separator: Character
    ) -> [String]? {
        var result: [String] = []
        var start = raw.startIndex
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        for index in raw.indices {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0, bracketDepth >= 0 else {
                return nil
            }
            if raw[index] == separator,
               angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 {
                let component = raw[start..<index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty else { return nil }
                result.append(component)
                start = raw.index(after: index)
            }
        }
        guard angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 else {
            return nil
        }
        let tail = raw[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        result.append(tail)
        return result
    }

    private static func isModulePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".").allSatisfy { component in
            guard let first = component.first, first == "_" || first.isLetter else {
                return false
            }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }
}
}
