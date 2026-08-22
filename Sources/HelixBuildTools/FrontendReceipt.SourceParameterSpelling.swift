import Foundation

extension FrontendReceipt {
/// Recovers compiler-validated parameter type spellings from a declaration's
/// exact source range. The typed AST remains ABI authority; source text is used
/// only to retain Swift overlay names that the JSON AST may canonicalize to an
/// unavailable Objective-C runtime name.
enum SourceParameterSpelling {
    static func types(in rawParameterList: String) -> [String]? {
        let bytes = Array(rawParameterList.utf8)
        guard bytes.count <= 512 * 1_024,
              let bounds = trimmedBounds(in: bytes),
              bytes[bounds.lowerBound] == UInt8(ascii: "("),
              bytes[bounds.upperBound - 1] == UInt8(ascii: ")")
        else { return nil }

        let body = (bounds.lowerBound + 1)..<(bounds.upperBound - 1)
        if body.isEmpty
            || bytes[body].allSatisfy(isASCIIWhitespace) {
            return []
        }
        guard let parameterRanges = splitTopLevel(
            bytes,
            in: body,
            separator: UInt8(ascii: ",")
        ) else { return nil }

        let result = parameterRanges.compactMap { range -> String? in
            guard let defaultValue = firstTopLevelDelimiter(
                UInt8(ascii: "="),
                in: bytes,
                range: range
            ) else {
                return parameterType(in: bytes, range: range)
            }
            return parameterType(
                in: bytes,
                range: range.lowerBound..<defaultValue
            )
        }
        return result.count == parameterRanges.count ? result : nil
    }

    private static func parameterType(
        in bytes: [UInt8],
        range: Range<Int>
    ) -> String? {
        guard let colon = firstTopLevelDelimiter(
            UInt8(ascii: ":"),
            in: bytes,
            range: range
        ), firstTopLevelDelimiter(
            UInt8(ascii: ":"),
            in: bytes,
            range: (colon + 1)..<range.upperBound
        ) == nil,
              let typeBounds = trimmedBounds(
                  in: bytes,
                  range: (colon + 1)..<range.upperBound
              )
        else { return nil }

        let type = String(
            decoding: bytes[typeBounds],
            as: UTF8.self
        )
        return FrontendReceipt.SwiftTypeSpelling.isGeneratedType(type)
            ? type : nil
    }

    private static func splitTopLevel(
        _ bytes: [UInt8],
        in range: Range<Int>,
        separator: UInt8
    ) -> [Range<Int>]? {
        guard let delimiters = scan(
            bytes,
            in: range,
            matching: separator
        ) else { return nil }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        for delimiter in delimiters {
            guard let bounds = trimmedBounds(
                in: bytes,
                range: start..<delimiter
            ) else { return nil }
            result.append(bounds)
            start = delimiter + 1
        }
        guard let tail = trimmedBounds(
            in: bytes,
            range: start..<range.upperBound
        ) else { return nil }
        result.append(tail)
        return result
    }

    private static func firstTopLevelDelimiter(
        _ delimiter: UInt8,
        in bytes: [UInt8],
        range: Range<Int>
    ) -> Int? {
        scan(bytes, in: range, matching: delimiter)?.first
    }

    /// Scans declaration syntax rather than expressions. Strings and nested
    /// comments are skipped so commas or colons in default values cannot alter
    /// the recovered parameter-to-AST alignment. Interpolated strings fail
    /// closed because their embedded Swift requires a full lexer.
    private static func scan(
        _ bytes: [UInt8],
        in range: Range<Int>,
        matching delimiter: UInt8
    ) -> [Int]? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            return nil
        }
        var matches: [Int] = []
        var parentheses = 0
        var brackets = 0
        var braces = 0
        var angles = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringPounds: Int?
        var multilineString = false
        var cursor = range.lowerBound

        while cursor < range.upperBound {
            let byte = bytes[cursor]
            let next = cursor + 1 < range.upperBound
                ? bytes[cursor + 1] : nil

            if inLineComment {
                if byte == UInt8(ascii: "\n") { inLineComment = false }
                cursor += 1
                continue
            }
            if blockCommentDepth > 0 {
                if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                    blockCommentDepth += 1
                    cursor += 2
                } else if byte == UInt8(ascii: "*"), next == UInt8(ascii: "/") {
                    blockCommentDepth -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
                continue
            }
            if let pounds = stringPounds {
                let quoteCount = multilineString ? 3 : 1
                if byte == UInt8(ascii: "\\"),
                   interpolationStarts(
                       in: bytes,
                       at: cursor,
                       pounds: pounds,
                       upperBound: range.upperBound
                   ) {
                    return nil
                }
                if pounds == 0, byte == UInt8(ascii: "\\") {
                    cursor += min(2, range.upperBound - cursor)
                    continue
                }
                if hasStringTerminator(
                    in: bytes,
                    at: cursor,
                    quotes: quoteCount,
                    pounds: pounds,
                    upperBound: range.upperBound
                ) {
                    cursor += quoteCount + pounds
                    stringPounds = nil
                    multilineString = false
                } else {
                    cursor += 1
                }
                continue
            }

            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                inLineComment = true
                cursor += 2
                continue
            }
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                blockCommentDepth = 1
                cursor += 2
                continue
            }
            if let opening = stringOpening(
                in: bytes,
                at: cursor,
                upperBound: range.upperBound
            ) {
                stringPounds = opening.pounds
                multilineString = opening.quotes == 3
                cursor += opening.pounds + opening.quotes
                continue
            }

            switch byte {
            case UInt8(ascii: "("): parentheses += 1
            case UInt8(ascii: ")"): parentheses -= 1
            case UInt8(ascii: "["): brackets += 1
            case UInt8(ascii: "]"): brackets -= 1
            case UInt8(ascii: "{"): braces += 1
            case UInt8(ascii: "}"): braces -= 1
            case UInt8(ascii: "<"): angles += 1
            case UInt8(ascii: ">"):
                let previous = cursor > range.lowerBound
                    ? bytes[cursor - 1] : nil
                if previous != UInt8(ascii: "-") { angles -= 1 }
            default: break
            }
            guard parentheses >= 0, brackets >= 0, braces >= 0,
                  angles >= 0
            else { return nil }
            if byte == delimiter,
               parentheses == 0, brackets == 0, braces == 0, angles == 0 {
                matches.append(cursor)
            }
            cursor += 1
        }
        guard blockCommentDepth == 0, !inLineComment,
              stringPounds == nil,
              parentheses == 0, brackets == 0, braces == 0, angles == 0
        else { return nil }
        return matches
    }

    private static func stringOpening(
        in bytes: [UInt8],
        at offset: Int,
        upperBound: Int
    ) -> (pounds: Int, quotes: Int)? {
        var cursor = offset
        while cursor < upperBound, bytes[cursor] == UInt8(ascii: "#") {
            cursor += 1
        }
        guard cursor < upperBound, bytes[cursor] == UInt8(ascii: "\"") else {
            return nil
        }
        let quoteCount = cursor + 2 < upperBound
                && bytes[cursor + 1] == UInt8(ascii: "\"")
                && bytes[cursor + 2] == UInt8(ascii: "\"")
            ? 3 : 1
        return (cursor - offset, quoteCount)
    }

    private static func hasStringTerminator(
        in bytes: [UInt8],
        at offset: Int,
        quotes: Int,
        pounds: Int,
        upperBound: Int
    ) -> Bool {
        guard offset + quotes + pounds <= upperBound else { return false }
        for index in 0..<quotes
        where bytes[offset + index] != UInt8(ascii: "\"") {
            return false
        }
        for index in 0..<pounds
        where bytes[offset + quotes + index] != UInt8(ascii: "#") {
            return false
        }
        return true
    }

    private static func interpolationStarts(
        in bytes: [UInt8],
        at offset: Int,
        pounds: Int,
        upperBound: Int
    ) -> Bool {
        guard offset + pounds + 1 < upperBound,
              bytes[offset] == UInt8(ascii: "\\")
        else { return false }
        for index in 0..<pounds
        where bytes[offset + 1 + index] != UInt8(ascii: "#") {
            return false
        }
        return bytes[offset + 1 + pounds] == UInt8(ascii: "(")
    }

    private static func trimmedBounds(in bytes: [UInt8]) -> Range<Int>? {
        trimmedBounds(in: bytes, range: bytes.indices)
    }

    private static func trimmedBounds(
        in bytes: [UInt8],
        range: Range<Int>
    ) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isASCIIWhitespace(bytes[lower]) { lower += 1 }
        while upper > lower, isASCIIWhitespace(bytes[upper - 1]) { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }
}
}
