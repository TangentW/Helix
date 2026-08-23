import Foundation
import HelixCore

extension CanonicalSIL {
enum GenericFunction {
    struct Specialization: Hashable, Sendable {
        var arguments: [String]
        var concreteLoweredType: String
    }

    struct Materialized: Sendable {
        var descriptor: Specialization
        var function: CanonicalSIL.Function
    }

    enum SpecializationError: Error, Equatable, Sendable,
        CustomStringConvertible {
        case malformedSignature(String)
        case invalidArguments(String)

        var description: String {
            switch self {
            case let .malformedSignature(reason):
                "generic function signature is malformed: \(reason)"
            case let .invalidArguments(reason):
                "generic function specialization is invalid: \(reason)"
            }
        }
    }

    static func isGeneric(loweredType: String) -> Bool {
        (try? genericClause(in: loweredType)) != nil
    }

    static func arguments(in raw: String) throws -> [String] {
        let values = try splitTopLevel(raw)
        guard !values.isEmpty else {
            throw SpecializationError.invalidArguments(
                "the call supplies no concrete type arguments"
            )
        }
        for value in values {
            guard !value.isEmpty else {
                throw SpecializationError.invalidArguments(
                    "the call contains an empty type argument"
                )
            }
            guard value.range(
                of: #"(?<![A-Za-z0-9_τ])τ_[0-9]+_[0-9]+(?![A-Za-z0-9_])"#,
                options: .regularExpression
            ) == nil else {
                throw SpecializationError.invalidArguments(
                    "the call retains an unresolved archetype \(value)"
                )
            }
            guard value != "_", value.range(
                of: #"(?:^|[^A-Za-z0-9_])repeat\s+each(?:$|[^A-Za-z0-9_])"#,
                options: .regularExpression
            ) == nil else {
                throw SpecializationError.invalidArguments(
                    "the call contains an unresolved type placeholder or pack \(value)"
                )
            }
        }
        return values
    }

    static func appliedArguments(
        to value: String,
        in line: String
    ) -> String? {
        guard let marker = line.range(of: value + "<") else {
            return nil
        }
        let open = line.index(before: marker.upperBound)
        guard let close = matchingClose(
            for: open,
            open: "<",
            close: ">",
            in: line,
            ignoresFunctionArrow: true
        ) else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    static func specialize(
        _ function: CanonicalSIL.Function,
        arguments rawArguments: String
    ) throws -> Materialized {
        let clause = try genericClause(in: function.loweredType)
        guard clause.parameters.allSatisfy(isNamedParameter) else {
            throw SpecializationError.malformedSignature(
                "its declaration does not expose stable named generic parameters"
            )
        }
        let arguments = try arguments(in: rawArguments)
        guard clause.parameters.count == arguments.count else {
            throw SpecializationError.invalidArguments(
                "the declaration has \(clause.parameters.count) type parameters "
                    + "but the call supplies \(arguments.count)"
            )
        }

        let typeWithoutClause = String(
            function.loweredType[..<clause.range.lowerBound]
        ) + String(function.loweredType[clause.range.upperBound...])
        let substitutions = Array(zip(clause.parameters, arguments)).sorted {
            left, right in
            left.0.count > right.0.count
        }
        var concreteType = typeWithoutClause
        var concreteBody = function.body
        for (parameter, argument) in substitutions {
            concreteType = try replacingToken(
                parameter,
                with: argument,
                in: concreteType
            )
            concreteBody = try replacingToken(
                parameter,
                with: argument,
                in: concreteBody
            )
        }
        for parameter in clause.parameters {
            let typeRetainsParameter = try containsToken(
                parameter,
                in: concreteType
            )
            let bodyRetainsParameter = try containsToken(
                parameter,
                in: concreteBody
            )
            guard !typeRetainsParameter, !bodyRetainsParameter
            else {
                throw SpecializationError.invalidArguments(
                    "the concrete body retains generic parameter \(parameter)"
                )
            }
        }

        let descriptor = Specialization(
            arguments: arguments,
            concreteLoweredType: concreteType
        )
        let symbol = syntheticSymbol(
            for: function.mangledName,
            originalLoweredType: function.loweredType,
            arguments: arguments
        )
        return .init(
            descriptor: descriptor,
            function: .init(
                mangledName: symbol,
                loweredType: concreteType,
                body: concreteBody,
                isolation: function.isolation,
                declarationLocation: function.declarationLocation,
                debugLineLocations: function.debugLineLocations,
                isExternalDefinition: function.isExternalDefinition
            )
        )
    }

    static func validatesCallType(
        _ appliedLoweredType: String,
        against referenceLoweredType: String
    ) -> Bool {
        appliedLoweredType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == referenceLoweredType
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Clause {
        var range: Range<String.Index>
        var parameters: [String]
    }

    private static func genericClause(in raw: String) throws -> Clause {
        guard let convention = raw.range(of: "@convention(") else {
            throw SpecializationError.malformedSignature(
                "it has no SIL calling convention"
            )
        }
        let conventionOpen = raw.index(before: convention.upperBound)
        guard let conventionClose = matchingClose(
            for: conventionOpen,
            open: "(",
            close: ")",
            in: raw
        ) else {
            throw SpecializationError.malformedSignature(
                "its calling convention is unterminated"
            )
        }

        var index = raw.index(after: conventionClose)
        while index < raw.endIndex, raw[index].isWhitespace {
            index = raw.index(after: index)
        }
        // An outer generic signature immediately follows the calling
        // convention. A later `<...>` can belong to `@substituted` or a
        // parameter type and must not be mistaken for declaration generics.
        guard index < raw.endIndex, raw[index] == "<" else {
            throw SpecializationError.malformedSignature(
                "it is not a generic SIL function type"
            )
        }
        guard let close = matchingClose(
            for: index,
            open: "<",
            close: ">",
            in: raw,
            ignoresFunctionArrow: true
        ) else {
            throw SpecializationError.malformedSignature(
                "its generic parameter clause is unterminated"
            )
        }
        let contents = String(raw[raw.index(after: index)..<close])
        let declaration = try declarationPrefix(contents)
        let parameters = try splitTopLevel(declaration)
        guard !parameters.isEmpty else {
            throw SpecializationError.malformedSignature(
                "it has an empty generic parameter clause"
            )
        }
        for parameter in parameters {
            guard isNamedParameter(parameter)
                || isNumberedArchetype(parameter) else {
                throw SpecializationError.malformedSignature(
                    "unsupported generic parameter \(parameter)"
                )
            }
        }
        return .init(
            range: index..<raw.index(after: close),
            parameters: parameters
        )
    }

    private static func declarationPrefix(_ raw: String) throws -> String {
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            if parenthesisDepth == 0,
               angleDepth == 0,
               bracketDepth == 0,
               raw[index...].hasPrefix(" where ") {
                return String(raw[..<index])
                    .trimmingCharacters(in: .whitespaces)
            }
            switch raw[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else {
                throw SpecializationError.malformedSignature(
                    "its generic requirements are unbalanced"
                )
            }
            index = raw.index(after: index)
        }
        guard parenthesisDepth == 0,
              angleDepth == 0,
              bracketDepth == 0 else {
            throw SpecializationError.malformedSignature(
                "its generic requirements are unbalanced"
            )
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private static func splitTopLevel(_ raw: String) throws -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            switch raw[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "," where parenthesisDepth == 0
                && angleDepth == 0 && bracketDepth == 0:
                result.append(
                    raw[start..<index]
                        .trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            default: break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else {
                throw SpecializationError.invalidArguments(
                    "the type argument list is unbalanced"
                )
            }
            index = raw.index(after: index)
        }
        guard parenthesisDepth == 0,
              angleDepth == 0,
              bracketDepth == 0 else {
            throw SpecializationError.invalidArguments(
                "the type argument list is unbalanced"
            )
        }
        let tail = raw[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !result.isEmpty { result.append(tail) }
        return result
    }

    private static func replacingToken(
        _ token: String,
        with replacement: String,
        in text: String
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: tokenPattern(token))
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        func replacing(in range: Range<String.Index>) -> String {
            let value = String(text[range])
            return expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: template
            )
        }

        var result = ""
        var segmentStart = text.startIndex
        var index = text.startIndex
        var isInsideQuotedSpelling = false
        // SIL quotes both user string literals and debug spellings. Neither
        // participates in generic type substitution.
        while index < text.endIndex {
            guard text[index] == "\"", !isEscapedQuote(at: index, in: text)
            else {
                index = text.index(after: index)
                continue
            }
            if isInsideQuotedSpelling {
                let end = text.index(after: index)
                result += String(text[segmentStart..<end])
                segmentStart = end
            } else {
                result += replacing(in: segmentStart..<index)
                segmentStart = index
            }
            isInsideQuotedSpelling.toggle()
            index = text.index(after: index)
        }
        if isInsideQuotedSpelling {
            throw SpecializationError.malformedSignature(
                "its body contains an unterminated quoted spelling"
            )
        }
        result += replacing(in: segmentStart..<text.endIndex)
        return result
    }

    private static func isEscapedQuote(
        at quote: String.Index,
        in text: String
    ) -> Bool {
        var cursor = quote
        var backslashCount = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func isNamedParameter(_ raw: String) -> Bool {
        raw != "_" && raw.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isNumberedArchetype(_ raw: String) -> Bool {
        raw.range(
            of: #"^τ_[0-9]+_[0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsToken(
        _ token: String,
        in text: String
    ) throws -> Bool {
        let pattern = tokenPattern(token)
        var segmentStart = text.startIndex
        var index = text.startIndex
        var isInsideQuotedSpelling = false
        while index < text.endIndex {
            guard text[index] == "\"", !isEscapedQuote(at: index, in: text)
            else {
                index = text.index(after: index)
                continue
            }
            if isInsideQuotedSpelling {
                segmentStart = text.index(after: index)
            } else if text[segmentStart..<index].range(
                of: pattern,
                options: .regularExpression
            ) != nil {
                return true
            }
            isInsideQuotedSpelling.toggle()
            index = text.index(after: index)
        }
        if isInsideQuotedSpelling {
            throw SpecializationError.malformedSignature(
                "its body contains an unterminated quoted spelling"
            )
        }
        return text[segmentStart...].range(
            of: pattern,
            options: .regularExpression
        ) != nil
    }

    private static func tokenPattern(_ token: String) -> String {
        #"(?<![A-Za-z0-9_])"#
            + NSRegularExpression.escapedPattern(for: token)
            + #"(?![A-Za-z0-9_])"#
    }

    private static func matchingClose(
        for openIndex: String.Index,
        open: Character,
        close: Character,
        in text: String,
        ignoresFunctionArrow: Bool = false
    ) -> String.Index? {
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            if text[index] == open {
                depth += 1
            } else if text[index] == close {
                let previous = index > text.startIndex
                    ? text[text.index(before: index)] : nil
                if !ignoresFunctionArrow || previous != "-" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            guard depth >= 0 else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func syntheticSymbol(
        for baseSymbol: String,
        originalLoweredType: String,
        arguments: [String]
    ) -> String {
        var hasher = Core.StableHasher(domain: "HLX.GenericSpecialization.v1")
        hasher.append(baseSymbol)
        hasher.append(originalLoweredType)
        hasher.append(UInt64(arguments.count))
        for argument in arguments { hasher.append(argument) }
        return "$hlx_generic_specialization_\(hasher.finalize().hex)"
    }
}
}
