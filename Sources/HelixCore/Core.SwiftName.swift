import Foundation

extension Core {
public enum SwiftName {}
}

extension Core.SwiftName {
    public static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }

    /// Normalizes the identifier spelling emitted by compiler ASTs. Swift
    /// surrounds keyword-shaped declaration names with one pair of backticks.
    public static func normalizedIdentifier(_ value: String) -> String? {
        if isIdentifier(value) { return value }
        guard value.first == "`", value.last == "`", value.count > 2 else {
            return nil
        }
        let unescaped = String(value.dropFirst().dropLast())
        return isIdentifier(unescaped) ? unescaped : nil
    }

    /// Accepts the ASCII operator grammar used by Swift and Apple SDK APIs.
    /// Comment delimiters are excluded because this spelling is emitted into
    /// generated source inside an operator-reference expression.
    public static func isOperator(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 64,
              !value.contains("//"),
              !value.contains("/*"),
              !value.contains("*/")
        else { return false }
        let scalars = value.unicodeScalars
        let allowed = CharacterSet(charactersIn: "/=-+!*%<>&|^?~.")
        guard scalars.allSatisfy(allowed.contains) else { return false }
        return !value.contains(".") || value.first == "."
    }
}
