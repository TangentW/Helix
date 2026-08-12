import Foundation

/// Validates type syntax emitted into generated Swift source. This is a syntax
/// boundary, not a semantic resolver; frozen ValueType checks remain separate.
extension FrontendReceipt {
enum SwiftTypeSpelling {
    static func isGeneratedType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value.utf8.count <= 64 * 1_024
            && isType(value)
    }

    private static func isType(_ value: String) -> Bool {
        if value.hasSuffix("?") {
            return isType(String(value.dropLast()))
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let body = String(value.dropFirst().dropLast())
            guard let components = splitTopLevel(body, separator: ":") else {
                return false
            }
            switch components.count {
            case 1:
                return isType(components[0])
            case 2:
                return isType(components[0]) && isType(components[1])
            default:
                return false
            }
        }
        if value.hasPrefix("("), value.hasSuffix(")") {
            let body = String(value.dropFirst().dropLast())
            guard let components = splitTopLevel(body, separator: ","),
                  components.count >= 2
            else { return false }
            return components.allSatisfy(isType)
        }
        if let open = value.firstIndex(of: "<") {
            guard value.hasSuffix(">"),
                  isModulePath(String(value[..<open]))
            else { return false }
            let body = String(
                value[value.index(after: open)..<value.index(before: value.endIndex)]
            )
            guard let arguments = splitTopLevel(body, separator: ","),
                  !arguments.isEmpty
            else { return false }
            return arguments.allSatisfy(isType)
        }
        return isModulePath(value)
    }

    private static func splitTopLevel(
        _ raw: String,
        separator: Character
    ) -> [String]? {
        var result: [String] = []
        var start = raw.startIndex
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        for index in raw.indices {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">": angleDepth -= 1
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0, bracketDepth >= 0 else {
                return nil
            }
            if raw[index] == separator,
               angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 {
                let component = raw[start..<index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty else { return nil }
                result.append(component)
                start = raw.index(after: index)
            }
        }
        guard angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 else {
            return nil
        }
        let tail = raw[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        result.append(tail)
        return result
    }

    private static func isModulePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".").allSatisfy { component in
            guard let first = component.first, first == "_" || first.isLetter else {
                return false
            }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }
}
}
