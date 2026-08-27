import Foundation

/// Validates type syntax emitted into generated Swift source. This is a syntax
/// boundary, not a semantic resolver; frozen ValueType checks remain separate.
extension FrontendReceipt {
enum SwiftTypeSpelling {
    /// Returns an equality-only spelling for a native boundary type. This does
    /// not rewrite the declaration emitted by a Catalog; it only folds names
    /// that the Swift compiler prints both qualified and unqualified for the
    /// same standard-library declaration.
    static func canonicalABIIdentity(_ raw: String) -> String {
        replacingNominalAliases(
            in: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            aliases: ["Swift.MainActor": "MainActor"]
        )
    }

    /// Compares the value shape of two observations of one declaration. Typed
    /// AST expressions can omit callback attributes that remain present in a
    /// declaration-level Catalog (for example when an optional callback is
    /// passed as `nil`). Once the declaration USR and call projection agree,
    /// those attributes are refinements supplied by the Catalog, not overload
    /// identity. Optionality and every parameter/result value type remain part
    /// of the match so a different logical specialization cannot be absorbed.
    static func catalogAuthorityMatchIdentity(_ raw: String) -> String {
        let value = canonicalABIIdentity(raw)
        if let callback = FrontendReceipt.FunctionTypeSpelling
            .callbackBoundary(in: value) {
            let parameterSpellings = FrontendReceipt.FunctionTypeSpelling
                .parameterSpellings(
                    in: callback.function.declaredSpelling
                ) ?? callback.function.parameters
            let parameters = parameterSpellings.map(
                catalogAuthorityMatchIdentity
            )
            var function = "(\(parameters.joined(separator: ",")))"
            if callback.function.isAsync { function += " async" }
            if callback.function.isThrowing { function += " throws" }
            function += " -> "
                + catalogAuthorityMatchIdentity(callback.function.result)
            return callback.isOptional
                ? "Swift.Optional<\(function)>" : function
        }
        if let wrapped = optionalWrappedType(value) {
            return "Swift.Optional<"
                + catalogAuthorityMatchIdentity(wrapped) + ">"
        }
        if value.hasPrefix("any ") {
            return "any " + catalogAuthorityMatchIdentity(
                String(value.dropFirst("any ".count))
            )
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let body = String(value.dropFirst().dropLast())
            guard let components = splitTopLevel(body, separator: ":") else {
                return value
            }
            if components.count == 2 {
                return "Swift.Dictionary<"
                    + catalogAuthorityMatchIdentity(components[0]) + ","
                    + catalogAuthorityMatchIdentity(components[1]) + ">"
            }
            if components.count == 1 {
                return "Swift.Array<"
                    + catalogAuthorityMatchIdentity(components[0]) + ">"
            }
            return value
        }
        if value.hasPrefix("("), value.hasSuffix(")"),
           let components = splitTopLevel(
               String(value.dropFirst().dropLast()),
               separator: ","
           ) {
            let types = components.map {
                catalogAuthorityMatchIdentity(removingTupleLabel($0))
            }
            return "(" + types.joined(separator: ",") + ")"
        }
        if let open = value.firstIndex(of: "<"), value.hasSuffix(">") {
            let arguments = String(
                value[value.index(after: open)..<value.index(before: value.endIndex)]
            )
            if let components = splitTopLevel(arguments, separator: ",") {
                return canonicalStandardNominal(String(value[..<open])) + "<"
                    + components.map(catalogAuthorityMatchIdentity)
                        .joined(separator: ",") + ">"
            }
        }
        return canonicalStandardNominal(value)
    }

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

    /// Returns complete dotted nominal tokens without interpreting the
    /// surrounding optional, collection, tuple, generic, callback, or
    /// attribute syntax.
    static func nominalTokens(in raw: String) -> [String] {
        var result: [String] = []
        var token = ""
        func appendToken() {
            guard !token.isEmpty else { return }
            result.append(token)
            token.removeAll(keepingCapacity: true)
        }
        for character in raw {
            if character == "." || character == "_"
                || character.isLetter || character.isNumber {
                token.append(character)
            } else {
                appendToken()
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
        if isVoid(value) { return true }
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

    private static func optionalWrappedType(_ value: String) -> String? {
        if value.hasSuffix("?") || value.hasSuffix("!") {
            return String(value.dropLast())
        }
        for prefix in ["Optional<", "Swift.Optional<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            return String(value.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    private static func removingTupleLabel(_ raw: String) -> String {
        guard let components = splitTopLevel(raw, separator: ":"),
              components.count == 2,
              isModulePath(components[0])
        else { return raw }
        return components[1]
    }

    private static func canonicalStandardNominal(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unqualified = value.hasPrefix("Swift.")
            ? String(value.dropFirst("Swift.".count)) : value
        let standard: Set<String> = [
            "Any", "Bool", "Character", "Double", "Error", "Float",
            "Int", "Int8", "Int16", "Int32", "Int64", "Never", "String",
            "Substring", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Void",
        ]
        guard standard.contains(unqualified) else { return value }
        return unqualified == "Void" ? "()" : "Swift.\(unqualified)"
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
        !value.isEmpty && value.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy { component in
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
