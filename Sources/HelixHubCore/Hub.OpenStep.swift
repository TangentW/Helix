import Foundation

extension Hub {
enum OpenStep {
    static let maximumDocumentBytes = 32 * 1_024 * 1_024
    static let maximumNestingDepth = 128
    static let maximumValueCount = 1_000_000

    indirect enum Value: Equatable, Sendable {
        case string(String)
        case array([Value])
        case dictionary([String: Value])

        var string: String? {
            guard case let .string(value) = self else { return nil }
            return value
        }

        var array: [Value]? {
            guard case let .array(value) = self else { return nil }
            return value
        }

        var dictionary: [String: Value]? {
            guard case let .dictionary(value) = self else { return nil }
            return value
        }
    }

    enum Token: Equatable {
        case word(String)
        case leftBrace
        case rightBrace
        case leftParenthesis
        case rightParenthesis
        case equals
        case semicolon
        case comma
    }

    struct Syntax {
        struct Entry {
            var range: Range<Int>
            var value: Syntax
        }
        struct Element {
            var range: Range<Int>
            var hasComma: Bool
            var value: Syntax
        }
        var value: Value
        // Offsets count Unicode scalars in the original text, not UTF-16 units.
        var range: Range<Int>
        var entries: [String: Entry] = [:]
        var elements: [Element] = []
    }

    struct Parser {
        private var lexer: Lexer
        private var lookahead: (Token, Range<Int>)?
        private var currentRange = 0..<0
        private var valueCount = 0

        init(data: Data) throws {
            guard !data.isEmpty, data.count <= OpenStep.maximumDocumentBytes,
                  let text = String(data: data, encoding: .utf8)
            else {
                throw Hub.Error.invalidProject("project.pbxproj is empty, oversized, or not UTF-8")
            }
            lexer = Lexer(text: text)
        }

        mutating func parse() throws -> Value { try parseSyntax().value }

        mutating func parseSyntax() throws -> Syntax {
            let result = try parseValue(depth: 0)
            guard try next() == nil else {
                throw Hub.Error.invalidProject("project.pbxproj has trailing tokens")
            }
            return result
        }

        private mutating func parseValue(depth: Int) throws -> Syntax {
            guard depth <= OpenStep.maximumNestingDepth else {
                throw Hub.Error.invalidProject("project.pbxproj nesting is too deep")
            }
            valueCount += 1
            guard valueCount <= OpenStep.maximumValueCount else {
                throw Hub.Error.invalidProject("project.pbxproj contains too many values")
            }
            guard let token = try next() else {
                throw Hub.Error.invalidProject("project.pbxproj ended inside a value")
            }
            switch token {
            case let .word(value):
                return .init(value: .string(value), range: currentRange)
            case .leftBrace:
                return try parseDictionary(depth: depth + 1, start: currentRange.lowerBound)
            case .leftParenthesis:
                return try parseArray(depth: depth + 1, start: currentRange.lowerBound)
            default:
                throw Hub.Error.invalidProject("project.pbxproj contains an unexpected token")
            }
        }

        private mutating func parseDictionary(depth: Int, start: Int) throws -> Syntax {
            var entries: [String: Syntax.Entry] = [:]
            while true {
                guard let token = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside a dictionary")
                }
                if token == .rightBrace {
                    return .init(value: .dictionary(entries.mapValues { $0.value.value }),
                                 range: start..<currentRange.upperBound, entries: entries)
                }
                let keyStart = currentRange.lowerBound
                guard case let .word(key) = token else {
                    throw Hub.Error.invalidProject("project.pbxproj has a malformed dictionary key")
                }
                guard entries[key] == nil else {
                    throw Hub.Error.invalidProject("project.pbxproj repeats dictionary key \(String(reflecting: key)) at scalar \(keyStart)")
                }
                guard try next() == .equals else {
                    throw Hub.Error.invalidProject("project.pbxproj dictionary key \(String(reflecting: key)) lacks '='")
                }
                let value = try parseValue(depth: depth)
                guard try next() == .semicolon else {
                    throw Hub.Error.invalidProject("project.pbxproj dictionary entry \(String(reflecting: key)) lacks ';'")
                }
                entries[key] = .init(range: keyStart..<currentRange.upperBound, value: value)
            }
        }

        private mutating func parseArray(depth: Int, start: Int) throws -> Syntax {
            var elements: [Syntax.Element] = []
            while true {
                guard let token = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside an array")
                }
                if token == .rightParenthesis {
                    return .init(value: .array(elements.map { $0.value.value }),
                                 range: start..<currentRange.upperBound, elements: elements)
                }
                lookahead = (token, currentRange)
                let value = try parseValue(depth: depth)
                guard let separator = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside an array")
                }
                switch separator {
                case .comma:
                    elements.append(.init(range: value.range.lowerBound..<currentRange.upperBound,
                                          hasComma: true, value: value))
                case .rightParenthesis:
                    elements.append(.init(range: value.range, hasComma: false, value: value))
                    return .init(value: .array(elements.map { $0.value.value }),
                                 range: start..<currentRange.upperBound, elements: elements)
                default:
                    throw Hub.Error.invalidProject("project.pbxproj array is malformed")
                }
            }
        }

        private mutating func next() throws -> Token? {
            if let lookahead {
                self.lookahead = nil
                currentRange = lookahead.1
                return lookahead.0
            }
            let result = try lexer.next()
            currentRange = lexer.tokenRange
            return result
        }
    }

    struct Lexer {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private(set) var tokenRange = 0..<0

        init(text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func next() throws -> Token? {
            try skipTrivia()
            guard index < scalars.count else { return nil }
            let start = index
            defer { tokenRange = start..<index }
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "{": return .leftBrace
            case "}": return .rightBrace
            case "(": return .leftParenthesis
            case ")": return .rightParenthesis
            case "=": return .equals
            case ";": return .semicolon
            case ",": return .comma
            case "\"": return .word(try quotedWord())
            default:
                index -= 1
                return .word(try bareWord())
            }
        }

        private mutating func skipTrivia() throws {
            while index < scalars.count {
                if CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                    index += 1
                    continue
                }
                guard scalars[index] == "/", index + 1 < scalars.count else { return }
                if scalars[index + 1] == "/" {
                    index += 2
                    while index < scalars.count,
                          !CharacterSet.newlines.contains(scalars[index]) {
                        index += 1
                    }
                    continue
                }
                if scalars[index + 1] == "*" {
                    index += 2
                    var closed = false
                    while index + 1 < scalars.count {
                        if scalars[index] == "*", scalars[index + 1] == "/" {
                            index += 2
                            closed = true
                            break
                        }
                        index += 1
                    }
                    guard closed else {
                        throw Hub.Error.invalidProject("project.pbxproj has an unterminated comment")
                    }
                    continue
                }
                return
            }
        }

        private mutating func quotedWord() throws -> String {
            let start = index - 1
            var hasEscape = false
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" {
                    if !hasEscape {
                        return String(String.UnicodeScalarView(scalars[(start + 1)..<(index - 1)]))
                    }
                    // Foundation owns OpenStep escape semantics, including octal
                    // and UTF-16 \U escapes. Never silently change a project's value.
                    let literal = String(String.UnicodeScalarView(scalars[start..<index]))
                    let decoded = try PropertyListSerialization.propertyList(
                        from: Data(("(" + literal + ")").utf8), options: [], format: nil
                    ) as? [String]
                    guard let value = decoded?.first else {
                        throw Hub.Error.invalidProject("project.pbxproj has an invalid string escape")
                    }
                    return value
                }
                if scalar == "\\" {
                    hasEscape = true
                    guard index < scalars.count else { break }
                    index += 1
                }
            }
            throw Hub.Error.invalidProject("project.pbxproj has an unterminated string")
        }

        private mutating func bareWord() throws -> String {
            let start = index
            while index < scalars.count {
                let scalar = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || "{}()=;,".unicodeScalars.contains(scalar) {
                    break
                }
                if scalar == "/", index + 1 < scalars.count,
                   scalars[index + 1] == "/" || scalars[index + 1] == "*" {
                    break
                }
                index += 1
            }
            guard index > start else {
                throw Hub.Error.invalidProject("project.pbxproj has an invalid bare token")
            }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }
    }
}
}
