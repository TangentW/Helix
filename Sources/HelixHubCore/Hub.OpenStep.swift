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

    struct Parser {
        private var lexer: Lexer
        private var lookahead: Token?
        private var valueCount = 0

        init(data: Data) throws {
            guard !data.isEmpty, data.count <= OpenStep.maximumDocumentBytes,
                  let text = String(data: data, encoding: .utf8)
            else {
                throw Hub.Error.invalidProject("project.pbxproj is empty, oversized, or not UTF-8")
            }
            lexer = Lexer(text: text)
        }

        mutating func parse() throws -> Value {
            let result = try parseValue(depth: 0)
            guard try next() == nil else {
                throw Hub.Error.invalidProject("project.pbxproj has trailing tokens")
            }
            return result
        }

        private mutating func parseValue(depth: Int) throws -> Value {
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
                return .string(value)
            case .leftBrace:
                return try parseDictionary(depth: depth + 1)
            case .leftParenthesis:
                return try parseArray(depth: depth + 1)
            default:
                throw Hub.Error.invalidProject("project.pbxproj contains an unexpected token")
            }
        }

        private mutating func parseDictionary(depth: Int) throws -> Value {
            var result: [String: Value] = [:]
            while true {
                guard let token = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside a dictionary")
                }
                if token == .rightBrace { return .dictionary(result) }
                guard case let .word(key) = token, result[key] == nil,
                      try next() == .equals
                else {
                    throw Hub.Error.invalidProject(
                        "project.pbxproj has a malformed or duplicate dictionary entry"
                    )
                }
                result[key] = try parseValue(depth: depth)
                guard try next() == .semicolon else {
                    throw Hub.Error.invalidProject("project.pbxproj dictionary entry lacks ';'")
                }
            }
        }

        private mutating func parseArray(depth: Int) throws -> Value {
            var result: [Value] = []
            while true {
                guard let token = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside an array")
                }
                if token == .rightParenthesis { return .array(result) }
                lookahead = token
                result.append(try parseValue(depth: depth))
                guard let separator = try next() else {
                    throw Hub.Error.invalidProject("project.pbxproj ended inside an array")
                }
                switch separator {
                case .comma:
                    continue
                case .rightParenthesis:
                    return .array(result)
                default:
                    throw Hub.Error.invalidProject("project.pbxproj array is malformed")
                }
            }
        }

        private mutating func next() throws -> Token? {
            if let lookahead {
                self.lookahead = nil
                return lookahead
            }
            return try lexer.next()
        }
    }

    struct Lexer {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func next() throws -> Token? {
            try skipTrivia()
            guard index < scalars.count else { return nil }
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
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(result) }
                guard scalar == "\\" else {
                    result.append(scalar)
                    continue
                }
                guard index < scalars.count else {
                    throw Hub.Error.invalidProject("project.pbxproj has an invalid string escape")
                }
                let escaped = scalars[index]
                index += 1
                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default:
                    // Xcode occasionally emits nonstandard escapes. Retaining the
                    // escaped scalar is sufficient for semantic inspection.
                    result.append(escaped)
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
