import Foundation

extension FrontendReceipt {
/// Qualifies nominal tokens only inside a frontend-validated function
/// signature. Generated dynamic replacements live outside the declaration's
/// original lexical namespace, so relative nested type names must be made
/// explicit without reconstructing or normalizing the rest of the signature.
enum SourceFunctionSpelling {
    static func replacingNominalAliases(
        in declaration: String,
        parameterUTF8Range: Range<Int>,
        aliases: [String: String]
    ) -> String? {
        guard !aliases.isEmpty else { return declaration }
        var bytes = Array(declaration.utf8)
        guard bytes.count <= 512 * 1_024,
              parameterUTF8Range.lowerBound >= 0,
              parameterUTF8Range.upperBound <= bytes.count,
              parameterUTF8Range.lowerBound < parameterUTF8Range.upperBound
        else { return nil }

        let rawParameters = String(
            decoding: bytes[parameterUTF8Range],
            as: UTF8.self
        )
        guard let rewrittenParameters = FrontendReceipt.SourceParameterSpelling
            .replacingNominalAliases(
                in: rawParameters,
                aliases: aliases
            )
        else { return nil }
        let rewrittenParameterBytes = Array(rewrittenParameters.utf8)
        bytes.replaceSubrange(
            parameterUTF8Range,
            with: rewrittenParameterBytes
        )

        let suffixStart = parameterUTF8Range.lowerBound
            + rewrittenParameterBytes.count
        guard let arrow = firstTopLevelArrow(in: bytes, from: suffixStart)
        else {
            return String(bytes: bytes, encoding: .utf8)
        }
        let resultUpperBound = firstTopLevelWhere(
            in: bytes,
            from: arrow.upperBound
        ) ?? bytes.count
        guard let resultRange = trimmedBounds(
            in: bytes,
            range: arrow.upperBound..<resultUpperBound
        ) else { return nil }
        let rawResult = String(decoding: bytes[resultRange], as: UTF8.self)
        let rewrittenResult = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(in: rawResult, aliases: aliases)
        guard rewrittenResult.utf8.count <= 64 * 1_024,
              !rewrittenResult.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        bytes.replaceSubrange(resultRange, with: rewrittenResult.utf8)
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func firstTopLevelArrow(
        in bytes: [UInt8],
        from lowerBound: Int
    ) -> Range<Int>? {
        var depth = DelimiterDepth()
        var cursor = lowerBound
        while cursor + 1 < bytes.count {
            if depth.isTopLevel,
               bytes[cursor] == UInt8(ascii: "-"),
               bytes[cursor + 1] == UInt8(ascii: ">") {
                return cursor..<(cursor + 2)
            }
            guard depth.consume(bytes[cursor]) else { return nil }
            cursor += 1
        }
        return nil
    }

    private static func firstTopLevelWhere(
        in bytes: [UInt8],
        from lowerBound: Int
    ) -> Int? {
        let keyword = Array("where".utf8)
        var depth = DelimiterDepth()
        var cursor = lowerBound
        while cursor < bytes.count {
            if depth.isTopLevel,
               cursor + keyword.count <= bytes.count,
               Array(bytes[cursor..<(cursor + keyword.count)]) == keyword,
               cursor > 0, isWhitespace(bytes[cursor - 1]),
               cursor + keyword.count < bytes.count,
               isWhitespace(bytes[cursor + keyword.count]) {
                return cursor
            }
            if bytes[cursor] == UInt8(ascii: "-"),
               cursor + 1 < bytes.count,
               bytes[cursor + 1] == UInt8(ascii: ">") {
                cursor += 2
                continue
            }
            guard depth.consume(bytes[cursor]) else { return nil }
            cursor += 1
        }
        return nil
    }

    private static func trimmedBounds(
        in bytes: [UInt8],
        range: Range<Int>
    ) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isWhitespace(bytes[lower]) { lower += 1 }
        while upper > lower, isWhitespace(bytes[upper - 1]) { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    private struct DelimiterDepth {
        var parentheses = 0
        var brackets = 0
        var angles = 0

        var isTopLevel: Bool {
            parentheses == 0 && brackets == 0 && angles == 0
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "("): parentheses += 1
            case UInt8(ascii: ")"): parentheses -= 1
            case UInt8(ascii: "["): brackets += 1
            case UInt8(ascii: "]"): brackets -= 1
            case UInt8(ascii: "<"): angles += 1
            case UInt8(ascii: ">"): angles -= 1
            default: break
            }
            return parentheses >= 0 && brackets >= 0 && angles >= 0
        }
    }
}
}
