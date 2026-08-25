import Foundation

extension NativeGeneration {
public enum BodyExtractionError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidUTF8
    case anchorNotFound
    case ambiguousAnchor
    case unterminatedBody

    public var description: String {
        switch self {
        case .invalidUTF8: "saved Swift source is not valid UTF-8"
        case .anchorNotFound: "the indexed declaration header changed or disappeared"
        case .ambiguousAnchor: "the indexed declaration header is not unique in its source file"
        case .unterminatedBody: "the Swift declaration body is not lexically complete"
        }
    }
}

public struct ExtractedBody: Hashable, Sendable {
    public var sourceRange: Range<Int>
    public var contents: String

    public init(sourceRange: Range<Int>, contents: String) {
        self.sourceRange = sourceRange
        self.contents = contents
    }
}

/// Extracts the source body following an indexed declaration header. Braces in
/// comments, strings, interpolation, and regular-expression literals do not
/// participate in declaration balancing.
public struct BodyExtractor: Sendable {
    public init() {}

    public func extract(from source: Data, declarationAnchor: String) throws -> String {
        try extractRegion(from: source, declarationAnchor: declarationAnchor).contents
    }

    public func extractRegion(
        from source: Data,
        declarationAnchor: String
    ) throws -> NativeGeneration.ExtractedBody {
        guard String(data: source, encoding: .utf8) != nil else {
            throw NativeGeneration.BodyExtractionError.invalidUTF8
        }
        let anchor = Data(declarationAnchor.utf8)
        guard !anchor.isEmpty, anchor.last == UInt8(ascii: "{") else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        guard let first = source.range(of: anchor) else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        guard source.range(of: anchor, in: first.upperBound..<source.endIndex) == nil else {
            throw NativeGeneration.BodyExtractionError.ambiguousAnchor
        }
        var scanner = Scanner(bytes: Array(source), index: first.upperBound, braceDepth: 1)
        let end = try scanner.scanBodyEnd()
        guard let body = String(data: source[first.upperBound..<end], encoding: .utf8) else {
            throw NativeGeneration.BodyExtractionError.invalidUTF8
        }
        return .init(sourceRange: first.upperBound..<end, contents: body)
    }

    public func extract(
        from source: Data,
        declarationAnchor: String,
        declarationOccurrence: UInt32
    ) throws -> String {
        try extractRegion(
            from: source,
            declarationAnchor: declarationAnchor,
            declarationOccurrence: declarationOccurrence
        ).contents
    }

    public func extractRegion(
        from source: Data,
        declarationAnchor: String,
        declarationOccurrence: UInt32
    ) throws -> NativeGeneration.ExtractedBody {
        guard String(data: source, encoding: .utf8) != nil else {
            throw NativeGeneration.BodyExtractionError.invalidUTF8
        }
        let anchor = Data(declarationAnchor.utf8)
        guard !anchor.isEmpty, anchor.last == UInt8(ascii: "{") else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        var lowerBound = source.startIndex
        var selected: Range<Data.Index>?
        for _ in 0...declarationOccurrence {
            guard let match = source.range(
                of: anchor,
                options: [],
                in: lowerBound..<source.endIndex
            ) else {
                throw NativeGeneration.BodyExtractionError.anchorNotFound
            }
            selected = match
            lowerBound = match.upperBound
        }
        guard let selected else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        var scanner = Scanner(bytes: Array(source), index: selected.upperBound, braceDepth: 1)
        let end = try scanner.scanBodyEnd()
        guard let body = String(data: source[selected.upperBound..<end], encoding: .utf8) else {
            throw NativeGeneration.BodyExtractionError.invalidUTF8
        }
        return .init(sourceRange: selected.upperBound..<end, contents: body)
    }
}
}

private struct Scanner {
    let bytes: [UInt8]
    var index: Int
    var braceDepth: Int

    mutating func scanBodyEnd() throws -> Int {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"):
                braceDepth += 1
                index += 1
            case UInt8(ascii: "}"):
                braceDepth -= 1
                if braceDepth == 0 { return index }
                index += 1
            case UInt8(ascii: "/") where matches("//"):
                skipLineComment()
            case UInt8(ascii: "/") where matches("/*"):
                try skipBlockComment()
            case UInt8(ascii: "\""):
                try skipString(hashCount: precedingHashes(at: index))
            case UInt8(ascii: "/") where precedingHashes(at: index) > 0:
                try skipRegex(hashCount: precedingHashes(at: index))
            case UInt8(ascii: "/") where beginsBareRegex():
                try skipRegex(hashCount: 0)
            default:
                index += 1
            }
        }
        throw NativeGeneration.BodyExtractionError.unterminatedBody
    }

    private func matches(_ text: StaticString, at offset: Int = 0) -> Bool {
        let expected = Array(String(describing: text).utf8)
        let start = index + offset
        guard start >= 0, start + expected.count <= bytes.count else { return false }
        return Array(bytes[start..<(start + expected.count)]) == expected
    }

    private func precedingHashes(at position: Int) -> Int {
        var cursor = position
        while cursor > 0, bytes[cursor - 1] == UInt8(ascii: "#") { cursor -= 1 }
        return position - cursor
    }

    private mutating func skipLineComment() {
        index += 2
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
    }

    private mutating func skipBlockComment() throws {
        index += 2
        var depth = 1
        while index < bytes.count {
            if matches("/*") {
                depth += 1
                index += 2
            } else if matches("*/") {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                index += 1
            }
        }
        throw NativeGeneration.BodyExtractionError.unterminatedBody
    }

    private mutating func skipString(hashCount: Int) throws {
        let multiline = matches("\"\"\"")
        index += multiline ? 3 : 1
        while index < bytes.count {
            if isStringTerminator(multiline: multiline, hashCount: hashCount) {
                index += (multiline ? 3 : 1) + hashCount
                return
            }
            if isInterpolationStart(hashCount: hashCount) {
                index += 2 + hashCount
                try skipInterpolation()
                continue
            }
            if hashCount == 0, bytes[index] == UInt8(ascii: "\\") {
                index = min(bytes.count, index + 2)
            } else {
                index += 1
            }
        }
        throw NativeGeneration.BodyExtractionError.unterminatedBody
    }

    private func isStringTerminator(multiline: Bool, hashCount: Int) -> Bool {
        let quotes = multiline ? 3 : 1
        guard index + quotes + hashCount <= bytes.count else { return false }
        guard bytes[index..<(index + quotes)].allSatisfy({ $0 == UInt8(ascii: "\"") }) else {
            return false
        }
        return bytes[(index + quotes)..<(index + quotes + hashCount)]
            .allSatisfy { $0 == UInt8(ascii: "#") }
    }

    private func isInterpolationStart(hashCount: Int) -> Bool {
        guard index + hashCount + 2 <= bytes.count,
              bytes[index] == UInt8(ascii: "\\")
        else { return false }
        let hashes = bytes[(index + 1)..<(index + 1 + hashCount)]
        return hashes.allSatisfy { $0 == UInt8(ascii: "#") }
            && bytes[index + 1 + hashCount] == UInt8(ascii: "(")
    }

    private mutating func skipInterpolation() throws {
        var parentheses = 1
        while index < bytes.count {
            if matches("//") {
                skipLineComment()
            } else if matches("/*") {
                try skipBlockComment()
            } else if bytes[index] == UInt8(ascii: "\"") {
                try skipString(hashCount: precedingHashes(at: index))
            } else if bytes[index] == UInt8(ascii: "(") {
                parentheses += 1
                index += 1
            } else if bytes[index] == UInt8(ascii: ")") {
                parentheses -= 1
                index += 1
                if parentheses == 0 { return }
            } else {
                index += 1
            }
        }
        throw NativeGeneration.BodyExtractionError.unterminatedBody
    }

    private func beginsBareRegex() -> Bool {
        guard index + 1 < bytes.count,
              bytes[index + 1] != UInt8(ascii: "/"),
              bytes[index + 1] != UInt8(ascii: "*"),
              !isWhitespace(bytes[index + 1])
        else { return false }
        var cursor = index
        while cursor > 0, isWhitespace(bytes[cursor - 1]) { cursor -= 1 }
        guard cursor > 0 else { return true }
        return "=(:,![{;?\n".utf8.contains(bytes[cursor - 1])
    }

    private mutating func skipRegex(hashCount: Int) throws {
        index += 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                index = min(bytes.count, index + 2)
                continue
            }
            if bytes[index] == UInt8(ascii: "/"),
               index + 1 + hashCount <= bytes.count,
               bytes[(index + 1)..<(index + 1 + hashCount)]
                .allSatisfy({ $0 == UInt8(ascii: "#") })
            {
                index += 1 + hashCount
                return
            }
            index += 1
        }
        throw NativeGeneration.BodyExtractionError.unterminatedBody
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }
}
