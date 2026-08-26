import Foundation

extension FrontendReceipt {
/// A lightweight, conservative import-declaration scanner used only to scope
/// compiler-input fingerprints. The compiler AST remains authoritative.
public enum SourceImports {}
}

extension FrontendReceipt.SourceImports {
enum ValidationError: Swift.Error, Equatable, Sendable {
    case compilerImportMismatch
    case sourceChanged
}

public struct Result: Equatable, Sendable {
    public var modules: [String]
    public var isComplete: Bool

    public init(modules: [String], isComplete: Bool) {
        self.modules = Array(Set(modules)).sorted()
        self.isComplete = isComplete
    }

    /// Compiler AST module paths can include a declaration suffix. Dependency
    /// search is rooted in the first module-path component.
    public func covers(compilerModules: [String]) -> Bool {
        let scanned = Set(modules)
        return compilerModules.allSatisfy {
            guard let root = $0.split(separator: ".").first else { return false }
            return scanned.contains(String(root))
        }
    }
}

public static func scan(sources: [FrontendReceipt.Source]) throws -> Result {
    var contents: [Data] = []
    contents.reserveCapacity(sources.count)
    for source in sources.sorted(by: { $0.logicalPath < $1.logicalPath }) {
        let url = source.url.resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= 64 * 1_024 * 1_024
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "source is missing, non-regular, or too large: \(url.path)"
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size, String(data: data, encoding: .utf8) != nil else {
            throw FrontendReceipt.Error.invalidRequest(
                "source changed while reading or is not UTF-8: \(url.path)"
            )
        }
        contents.append(data)
    }
    return scan(contents: contents)
}

static func scan(contents: [Data]) -> Result {
    var modules = Set<String>()
    var complete = true
    for contents in contents {
        var lexer = Lexer(bytes: Array(contents))
        while let token = lexer.next() {
            guard case let .identifier(value, escaped) = token,
                  value == "import", !escaped
            else { continue }
            guard var next = lexer.next() else {
                complete = false
                break
            }
            if case let .identifier(kind, false) = next,
               declarationKinds.contains(kind) {
                guard let scoped = lexer.next() else {
                    complete = false
                    break
                }
                next = scoped
            }
            guard case let .identifier(module, _) = next,
                  isModuleIdentifier(module)
            else {
                // `import` may legally be used as an argument label when
                // escaped only. An unescaped non-declaration is invalid Swift,
                // so refusing the cache is safer than guessing.
                complete = false
                continue
            }
            modules.insert(module)
            if modules.count > 4_096 {
                complete = false
                break
            }
        }
        complete = complete && lexer.isComplete
    }
    return .init(modules: Array(modules), isComplete: complete)
}

private static let declarationKinds: Set<String> = [
    "typealias", "struct", "class", "enum", "protocol", "let", "var",
    "func", "operator", "macro",
]

private static func isModuleIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 1_024 else { return false }
    return !value.unicodeScalars.contains { scalar in
        scalar.value == 0 || scalar.properties.isWhitespace
            || "/\\:".unicodeScalars.contains(scalar)
    }
}

private enum Token {
    case identifier(String, escaped: Bool)
    case punctuation(UInt8)
}

private struct Lexer {
    var bytes: [UInt8]
    var index = 0
    var isComplete = true

    mutating func next() -> Token? {
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if byte == ascii("/"), peek(1) == ascii("/") {
                skipLineComment()
                continue
            }
            if byte == ascii("/"), peek(1) == ascii("*") {
                if !skipBlockComment() { isComplete = false }
                continue
            }
            if byte == ascii("\"") {
                if !skipString(hashCount: 0) { isComplete = false }
                continue
            }
            if byte == ascii("#"), let literal = extendedLiteral() {
                if literal.kind == .string {
                    if !skipString(hashCount: literal.hashCount) {
                        isComplete = false
                    }
                } else if !skipExtendedRegex(hashCount: literal.hashCount) {
                    isComplete = false
                }
                continue
            }
            if byte == ascii("`") {
                return escapedIdentifier()
            }
            if isIdentifierHead(byte) {
                let start = index
                index += 1
                while index < bytes.count, isIdentifierContinuation(bytes[index]) {
                    index += 1
                }
                guard let value = String(bytes: bytes[start..<index], encoding: .utf8)
                else {
                    isComplete = false
                    continue
                }
                return .identifier(value, escaped: false)
            }
            index += 1
            return .punctuation(byte)
        }
        return nil
    }

    private enum LiteralKind { case string, regex }
    private struct ExtendedLiteral {
        var hashCount: Int
        var kind: LiteralKind
    }

    private func extendedLiteral() -> ExtendedLiteral? {
        var cursor = index
        while cursor < bytes.count, bytes[cursor] == ascii("#") {
            cursor += 1
        }
        let count = cursor - index
        guard count > 0, cursor < bytes.count else { return nil }
        if bytes[cursor] == ascii("\"") {
            return .init(hashCount: count, kind: .string)
        }
        if bytes[cursor] == ascii("/") {
            return .init(hashCount: count, kind: .regex)
        }
        return nil
    }

    private mutating func escapedIdentifier() -> Token? {
        index += 1
        let start = index
        while index < bytes.count, bytes[index] != ascii("`") {
            index += 1
        }
        guard index < bytes.count,
              let value = String(bytes: bytes[start..<index], encoding: .utf8)
        else {
            isComplete = false
            index = bytes.count
            return nil
        }
        index += 1
        return .identifier(value, escaped: true)
    }

    private mutating func skipLineComment() {
        index += 2
        while index < bytes.count, bytes[index] != ascii("\n") { index += 1 }
    }

    private mutating func skipBlockComment() -> Bool {
        index += 2
        var depth = 1
        while index < bytes.count {
            if bytes[index] == ascii("/"), peek(1) == ascii("*") {
                depth += 1
                index += 2
            } else if bytes[index] == ascii("*"), peek(1) == ascii("/") {
                depth -= 1
                index += 2
                if depth == 0 { return true }
            } else {
                index += 1
            }
        }
        return false
    }

    private mutating func skipString(hashCount: Int) -> Bool {
        index += hashCount
        guard index < bytes.count, bytes[index] == ascii("\"") else {
            return false
        }
        let triple = peek(1) == ascii("\"") && peek(2) == ascii("\"")
        index += triple ? 3 : 1
        while index < bytes.count {
            if closesString(hashCount: hashCount, triple: triple) {
                index += (triple ? 3 : 1) + hashCount
                return true
            }
            if beginsInterpolation(hashCount: hashCount) {
                index += 1 + hashCount + 1
                guard skipInterpolation() else { return false }
                continue
            }
            if hashCount == 0, bytes[index] == ascii("\\") {
                index += min(2, bytes.count - index)
            } else {
                index += 1
            }
        }
        return false
    }

    private func closesString(hashCount: Int, triple: Bool) -> Bool {
        let quoteCount = triple ? 3 : 1
        guard matches(repeating: ascii("\""), count: quoteCount, at: index),
              matches(repeating: ascii("#"), count: hashCount, at: index + quoteCount)
        else { return false }
        return true
    }

    private func beginsInterpolation(hashCount: Int) -> Bool {
        guard bytes[index] == ascii("\\"),
              matches(repeating: ascii("#"), count: hashCount, at: index + 1)
        else { return false }
        let open = index + 1 + hashCount
        return open < bytes.count && bytes[open] == ascii("(")
    }

    private mutating func skipInterpolation() -> Bool {
        var depth = 1
        while index < bytes.count {
            if bytes[index] == ascii("/"), peek(1) == ascii("/") {
                skipLineComment()
            } else if bytes[index] == ascii("/"), peek(1) == ascii("*") {
                guard skipBlockComment() else { return false }
            } else if bytes[index] == ascii("\"") {
                guard skipString(hashCount: 0) else { return false }
            } else if bytes[index] == ascii("#"), let literal = extendedLiteral() {
                if literal.kind == .string {
                    guard skipString(hashCount: literal.hashCount) else { return false }
                } else {
                    guard skipExtendedRegex(hashCount: literal.hashCount) else {
                        return false
                    }
                }
            } else if bytes[index] == ascii("(") {
                depth += 1
                index += 1
            } else if bytes[index] == ascii(")") {
                depth -= 1
                index += 1
                if depth == 0 { return true }
            } else {
                index += 1
            }
        }
        return false
    }

    private mutating func skipExtendedRegex(hashCount: Int) -> Bool {
        index += hashCount + 1
        while index < bytes.count {
            if bytes[index] == ascii("/"),
               matches(repeating: ascii("#"), count: hashCount, at: index + 1) {
                index += 1 + hashCount
                return true
            }
            if bytes[index] == ascii("\\") {
                index += min(2, bytes.count - index)
            } else {
                index += 1
            }
        }
        return false
    }

    private func matches(repeating byte: UInt8, count: Int, at start: Int) -> Bool {
        guard count >= 0, start >= 0, start + count <= bytes.count else { return false }
        return bytes[start..<(start + count)].allSatisfy { $0 == byte }
    }

    private func peek(_ distance: Int) -> UInt8? {
        let position = index + distance
        return position < bytes.count ? bytes[position] : nil
    }

    private func ascii(_ value: Character) -> UInt8 {
        value.asciiValue!
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            || byte == 0x0B || byte == 0x0C
    }

    private func isIdentifierHead(_ byte: UInt8) -> Bool {
        byte == ascii("_") || byte >= 0x80
            || (byte >= ascii("A") && byte <= ascii("Z"))
            || (byte >= ascii("a") && byte <= ascii("z"))
    }

    private func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierHead(byte) || (byte >= ascii("0") && byte <= ascii("9"))
    }
}
}
