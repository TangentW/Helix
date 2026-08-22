extension CanonicalSIL {
/// Structural helpers for canonical SIL function-type spellings.
enum FunctionTypeSyntax {
    /// Finds the result arrow of the outer function, ignoring arrows nested
    /// inside parameter, generic, collection, and result function types.
    static func outerArrow(in text: String) -> Range<String.Index>? {
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "-" where parenthesisDepth == 0
                    && angleDepth == 0
                    && bracketDepth == 0:
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ">" {
                    return index..<text.index(after: next)
                }
            default:
                break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    static func matchingOpeningParenthesis(
        for close: String.Index,
        in text: String
    ) -> String.Index? {
        guard text.indices.contains(close), text[close] == ")" else {
            return nil
        }
        var depth = 0
        var index = close
        while true {
            switch text[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            guard depth >= 0, index > text.startIndex else { return nil }
            index = text.index(before: index)
        }
    }
}
}
