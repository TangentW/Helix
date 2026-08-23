import Foundation

extension CanonicalSIL {
enum GenericSignature {}
}

extension CanonicalSIL.GenericSignature {
    static let maximumParameterCount = 64
    static let maximumRequirementCount = 256

    enum Relation: Hashable, Sendable {
        case conformance
        case sameType
    }

    struct Requirement: Hashable, Sendable {
        var left: String
        var relation: Relation
        var right: String
    }

    struct Clause: Hashable, Sendable {
        var parameters: [String]
        var requirements: [Requirement]
    }

    struct FunctionSignature: Hashable, Sendable {
        var range: Range<String.Index>
        var clauses: [Clause]

        var parameters: [String] {
            clauses.flatMap(\.parameters)
        }

        var requirements: [Requirement] {
            clauses.flatMap(\.requirements)
        }
    }

    enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(reason): reason
            }
        }
    }

    static func functionSignature(
        in raw: String
    ) throws -> FunctionSignature? {
        guard let convention = raw.range(of: "@convention(") else {
            throw ParseError.malformed("it has no SIL calling convention")
        }
        let conventionOpen = raw.index(before: convention.upperBound)
        guard let conventionClose = matchingClose(
            for: conventionOpen,
            open: "(",
            close: ")",
            in: raw
        ) else {
            throw ParseError.malformed("its calling convention is unterminated")
        }

        var cursor = raw.index(after: conventionClose)
        skipWhitespace(in: raw, cursor: &cursor)
        guard cursor < raw.endIndex, raw[cursor] == "<" else { return nil }

        let rangeStart = cursor
        var clauses: [Clause] = []
        repeat {
            guard let close = matchingClose(
                for: cursor,
                open: "<",
                close: ">",
                in: raw,
                ignoresFunctionArrow: true
            ) else {
                throw ParseError.malformed(
                    "its generic parameter clause is unterminated"
                )
            }
            let contents = String(raw[raw.index(after: cursor)..<close])
            clauses.append(try clause(contents: contents))
            cursor = raw.index(after: close)
            skipWhitespace(in: raw, cursor: &cursor)
        } while cursor < raw.endIndex && raw[cursor] == "<"

        let parameters = clauses.flatMap(\.parameters)
        guard !parameters.isEmpty else {
            throw ParseError.malformed("it has no generic parameters")
        }
        guard parameters.count <= maximumParameterCount,
              clauses.lazy.map(\.requirements.count).reduce(0, +)
                <= maximumRequirementCount
        else {
            throw ParseError.malformed("its generic signature exceeds limits")
        }
        guard Set(parameters).count == parameters.count else {
            throw ParseError.malformed("it redeclares a generic parameter")
        }
        return .init(
            range: rangeStart..<cursor,
            clauses: clauses
        )
    }

    static func standaloneClause(_ raw: String) throws -> Clause {
        let spelling = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spelling.first == "<", spelling.last == ">",
              let close = matchingClose(
                for: spelling.startIndex,
                open: "<",
                close: ">",
                in: spelling,
                ignoresFunctionArrow: true
              ), close == spelling.index(before: spelling.endIndex)
        else {
            throw ParseError.malformed("generic clause is malformed")
        }
        return try clause(
            contents: String(spelling.dropFirst().dropLast())
        )
    }

    static func splitTopLevel(_ raw: String) throws -> [String] {
        try splitTopLevel(raw, separator: ",")
    }

    static func splitTopLevel(
        _ raw: String,
        separator: Character
    ) throws -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var state = DelimiterState()
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if state.isTopLevel, character == separator {
                result.append(
                    raw[start..<index]
                        .trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            } else {
                guard state.consume(
                    character,
                    previous: previousCharacter(index, in: raw)
                ) else {
                    throw ParseError.malformed("type syntax is unbalanced")
                }
            }
            index = raw.index(after: index)
        }
        guard state.isComplete else {
            throw ParseError.malformed("type syntax is unbalanced")
        }
        let tail = raw[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !result.isEmpty { result.append(tail) }
        return result
    }

    static func splitComposition(_ raw: String) throws -> [String] {
        try splitTopLevel(raw, separator: "&")
    }

    static func partitionTopLevel(
        _ raw: String,
        at marker: String
    ) throws -> (before: String, after: String)? {
        guard !marker.isEmpty,
              let range = try topLevelRange(of: marker, in: raw)
        else { return nil }
        return (
            String(raw[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces),
            String(raw[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        )
    }

    static func substituting(
        _ substitutions: [String: String],
        in text: String,
        preservesQuotedSpellings: Bool = true
    ) throws -> String {
        guard !substitutions.isEmpty else { return text }
        let ordered = substitutions.sorted { left, right in
            if left.key.count != right.key.count {
                return left.key.count > right.key.count
            }
            return left.key < right.key
        }
        var result = text
        for (token, replacement) in ordered {
            guard isTypePath(token), !replacement.isEmpty else {
                throw ParseError.malformed(
                    "generic substitution has an invalid type path"
                )
            }
            result = try replacingToken(
                token,
                with: replacement,
                in: result,
                preservesQuotedSpellings: preservesQuotedSpellings
            )
        }
        return result
    }

    static func containsAny(
        of parameters: [String],
        in text: String
    ) throws -> Bool {
        for parameter in parameters where try containsToken(
            parameter,
            in: text
        ) {
            return true
        }
        return false
    }

    static func concreteBindings(
        template: String,
        concrete: String,
        parameters: [String],
        moduleName: String? = nil
    ) -> [String: String]? {
        let parameterSet = Set(parameters)
        guard !parameterSet.isEmpty else {
            return equivalentType(template, concrete) ? [:] : nil
        }
        var bindings: [String: String] = [:]
        guard matchTypePattern(
            template,
            concrete,
            parameters: parameterSet,
            moduleName: moduleName,
            bindings: &bindings
        ), bindings.count == parameterSet.count
        else { return nil }
        return bindings
    }

    static func equivalentType(_ lhs: String, _ rhs: String) -> Bool {
        CanonicalSIL.SwiftTypeIdentity.normalized(lhs)
            == CanonicalSIL.SwiftTypeIdentity.normalized(rhs)
    }

    static func isParameter(_ raw: String) -> Bool {
        isNamedParameter(raw) || isNumberedArchetype(raw)
    }

    private static func clause(contents raw: String) throws -> Clause {
        let partition = try partitionAtWhere(raw)
        let parameters = try splitTopLevel(partition.parameters)
        guard !parameters.isEmpty,
              parameters.allSatisfy(isParameter),
              Set(parameters).count == parameters.count,
              parameters.count <= maximumParameterCount
        else {
            throw ParseError.malformed(
                "its generic parameter declaration is unsupported"
            )
        }
        let requirements: [Requirement]
        if let rawRequirements = partition.requirements {
            let components = try splitTopLevel(rawRequirements)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty })
            else {
                throw ParseError.malformed("its generic requirements are empty")
            }
            requirements = try components.map(parseRequirement)
        } else {
            requirements = []
        }
        guard requirements.count <= maximumRequirementCount else {
            throw ParseError.malformed(
                "its generic requirements exceed the size limit"
            )
        }
        return .init(parameters: parameters, requirements: requirements)
    }

    private static func partitionAtWhere(
        _ raw: String
    ) throws -> (parameters: String, requirements: String?) {
        var state = DelimiterState()
        var index = raw.startIndex
        while index < raw.endIndex {
            if state.isTopLevel, raw[index...].hasPrefix(" where ") {
                let requirementsStart = raw.index(
                    index,
                    offsetBy: " where ".count
                )
                return (
                    String(raw[..<index])
                        .trimmingCharacters(in: .whitespaces),
                    String(raw[requirementsStart...])
                        .trimmingCharacters(in: .whitespaces)
                )
            }
            guard state.consume(
                raw[index],
                previous: previousCharacter(index, in: raw)
            ) else {
                throw ParseError.malformed("its generic clause is unbalanced")
            }
            index = raw.index(after: index)
        }
        guard state.isComplete else {
            throw ParseError.malformed("its generic clause is unbalanced")
        }
        return (raw.trimmingCharacters(in: .whitespaces), nil)
    }

    private static func parseRequirement(
        _ raw: String
    ) throws -> Requirement {
        for (marker, relation): (String, Relation) in [
            (" == ", .sameType),
            (" : ", .conformance),
        ] {
            guard let range = try topLevelRange(of: marker, in: raw) else {
                continue
            }
            let left = raw[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let right = raw[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard isTypePath(left), !right.isEmpty else {
                throw ParseError.malformed(
                    "unsupported generic requirement \(raw)"
                )
            }
            if relation == .sameType, !isTypeExpression(right) {
                throw ParseError.malformed(
                    "unsupported same-type requirement \(raw)"
                )
            }
            return .init(left: left, relation: relation, right: right)
        }
        throw ParseError.malformed("unsupported generic requirement \(raw)")
    }

    private static func topLevelRange(
        of marker: String,
        in raw: String
    ) throws -> Range<String.Index>? {
        var state = DelimiterState()
        var index = raw.startIndex
        while index < raw.endIndex {
            if state.isTopLevel, raw[index...].hasPrefix(marker) {
                return index..<raw.index(index, offsetBy: marker.count)
            }
            guard state.consume(
                raw[index],
                previous: previousCharacter(index, in: raw)
            ) else {
                throw ParseError.malformed("generic requirement is unbalanced")
            }
            index = raw.index(after: index)
        }
        guard state.isComplete else {
            throw ParseError.malformed("generic requirement is unbalanced")
        }
        return nil
    }

    private static func matchTypePattern(
        _ rawTemplate: String,
        _ rawConcrete: String,
        parameters: Set<String>,
        moduleName: String?,
        bindings: inout [String: String]
    ) -> Bool {
        let template = rawTemplate.trimmingCharacters(in: .whitespaces)
        let concrete = rawConcrete.trimmingCharacters(in: .whitespaces)
        if parameters.contains(template) {
            guard !concrete.isEmpty,
                  (try? containsAny(
                    of: Array(parameters),
                    in: concrete
                  )) == false
            else { return false }
            if let existing = bindings[template] {
                return equivalentType(existing, concrete)
            }
            bindings[template] = concrete
            return true
        }
        guard let templateGeneric = CanonicalSIL.SwiftTypeIdentity.genericType(
            CanonicalSIL.SwiftTypeIdentity.normalized(template)
        ), let concreteGeneric = CanonicalSIL.SwiftTypeIdentity.genericType(
            CanonicalSIL.SwiftTypeIdentity.normalized(concrete)
        ) else {
            return equivalentType(template, concrete)
        }
        guard nominalNamesEquivalent(
            templateGeneric.name,
            concreteGeneric.name,
            moduleName: moduleName
        ), templateGeneric.arguments.count == concreteGeneric.arguments.count
        else { return false }
        for (templateArgument, concreteArgument) in zip(
            templateGeneric.arguments,
            concreteGeneric.arguments
        ) {
            guard matchTypePattern(
                templateArgument,
                concreteArgument,
                parameters: parameters,
                moduleName: moduleName,
                bindings: &bindings
            ) else { return false }
        }
        return true
    }

    private static func nominalNamesEquivalent(
        _ lhs: String,
        _ rhs: String,
        moduleName: String?
    ) -> Bool {
        if lhs == rhs { return true }
        guard let moduleName else { return false }
        return lhs == moduleName + "." + rhs
            || rhs == moduleName + "." + lhs
    }

    private static func replacingToken(
        _ token: String,
        with replacement: String,
        in text: String,
        preservesQuotedSpellings: Bool
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
        guard preservesQuotedSpellings else {
            return replacing(in: text.startIndex..<text.endIndex)
        }

        var result = ""
        var segmentStart = text.startIndex
        var index = text.startIndex
        var quoted = false
        while index < text.endIndex {
            guard text[index] == "\"", !isEscapedQuote(at: index, in: text)
            else {
                index = text.index(after: index)
                continue
            }
            if quoted {
                let end = text.index(after: index)
                result += String(text[segmentStart..<end])
                segmentStart = end
            } else {
                result += replacing(in: segmentStart..<index)
                segmentStart = index
            }
            quoted.toggle()
            index = text.index(after: index)
        }
        guard !quoted else {
            throw ParseError.malformed(
                "its body contains an unterminated quoted spelling"
            )
        }
        result += replacing(in: segmentStart..<text.endIndex)
        return result
    }

    private static func containsToken(
        _ token: String,
        in text: String
    ) throws -> Bool {
        let substituted = try replacingToken(
            token,
            with: "__helix_resolved_type__",
            in: text,
            preservesQuotedSpellings: true
        )
        return substituted != text
    }

    private static func tokenPattern(_ token: String) -> String {
        #"(?<![A-Za-z0-9_τ.])"#
            + NSRegularExpression.escapedPattern(for: token)
            + #"(?![A-Za-z0-9_])"#
    }

    private static func isEscapedQuote(
        at quote: String.Index,
        in text: String
    ) -> Bool {
        var cursor = quote
        var count = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            count += 1
            cursor = previous
        }
        return !count.isMultiple(of: 2)
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

    private static func isTypePath(_ raw: String) -> Bool {
        raw.range(
            of: #"^(?:[A-Za-z_][A-Za-z0-9_]*|τ_[0-9]+_[0-9]+)(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTypeExpression(_ raw: String) -> Bool {
        !raw.isEmpty
            && raw.rangeOfCharacter(from: .newlines) == nil
            && !raw.contains("=")
    }

    private static func skipWhitespace(
        in raw: String,
        cursor: inout String.Index
    ) {
        while cursor < raw.endIndex, raw[cursor].isWhitespace {
            cursor = raw.index(after: cursor)
        }
    }

    private static func matchingClose(
        for openIndex: String.Index,
        open: Character,
        close: Character,
        in text: String,
        ignoresFunctionArrow: Bool = false
    ) -> String.Index? {
        var depth = 0
        var quoted = false
        var escaped = false
        var index = openIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else if character == open {
                depth += 1
            } else if character == close {
                let previous = previousCharacter(index, in: text)
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

    private static func previousCharacter<T: StringProtocol>(
        _ index: T.Index,
        in text: T
    ) -> Character? {
        index > text.startIndex ? text[text.index(before: index)] : nil
    }

    private struct DelimiterState {
        var parentheses = 0
        var angles = 0
        var brackets = 0
        var quoted = false
        var escaped = false

        var isTopLevel: Bool {
            !quoted && parentheses == 0 && angles == 0 && brackets == 0
        }

        var isComplete: Bool {
            isTopLevel && !escaped
        }

        mutating func consume(
            _ character: Character,
            previous: Character?
        ) -> Bool {
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
                return true
            }
            if character == "\"" {
                quoted = true
            } else {
                switch character {
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "<": angles += 1
                case ">":
                    if previous != "-" { angles -= 1 }
                case "[": brackets += 1
                case "]": brackets -= 1
                default: break
                }
            }
            return parentheses >= 0 && angles >= 0 && brackets >= 0
        }
    }
}
