import Foundation

extension CanonicalSIL {
/// Recognizes compiler-only closure reabstraction thunks. Their executable
/// semantics are modeled by surrounding SIL operations, so they must not
/// become independent VM functions.
enum ClosureReabstraction {
    enum CompilerThunkKind: Equatable, Sendable {
        case storageInvoke
        case nonescapingAdapter
    }

    static func compilerThunkKind(
        symbol: String,
        loweredType: String
    ) -> CompilerThunkKind? {
        guard symbol.hasSuffix("TR") else { return nil }
        let type = String(
            loweredType.trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("$")
        )
        if type.range(
            of: #"^@convention\s*\(\s*c\s*\)"#,
            options: .regularExpression
        ) != nil, type.contains("@block_storage ") {
            return .storageInvoke
        }
        return nonescapingAdapterClosureType(in: type) == nil
            ? nil : .nonescapingAdapter
    }

    static func nonescapingAdapterClosureType(
        in raw: String
    ) -> String? {
        let type = String(
            raw.trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("$")
        )
        guard type.range(
            of: #"^@convention\s*\(\s*thin\s*\)"#,
            options: .regularExpression
        ) != nil,
              let arrow = type.range(of: " -> ", options: .backwards)
        else { return nil }
        let outerResult = type[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        let prefix = String(type[..<arrow.lowerBound])
        guard let close = prefix.lastIndex(of: ")"),
              let open = matchingOpeningParenthesis(for: close, in: prefix),
              splitTopLevel(
                String(prefix[prefix.index(after: open)..<close])
              ) == nil
        else { return nil }
        var parameter = String(prefix[prefix.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        for ownership in ["@guaranteed ", "@owned "]
        where parameter.hasPrefix(ownership) {
            parameter.removeFirst(ownership.count)
            parameter = parameter.trimmingCharacters(in: .whitespaces)
        }
        var sawNonescaping = false
        var sawCalleeConvention = false
        var actorAnnotation: String?
        while parameter.hasPrefix("@") {
            if parameter.hasPrefix("@noescape ") {
                parameter.removeFirst("@noescape ".count)
                sawNonescaping = true
            } else if parameter.hasPrefix("@callee_guaranteed ") {
                parameter.removeFirst("@callee_guaranteed ".count)
                sawCalleeConvention = true
            } else if parameter.hasPrefix("@callee_owned ") {
                parameter.removeFirst("@callee_owned ".count)
                sawCalleeConvention = true
            } else if parameter.hasPrefix("@Sendable ") {
                parameter.removeFirst("@Sendable ".count)
            } else if let actor = parameter.range(
                of: #"^@[A-Za-z_][A-Za-z0-9_.]*Actor\b\s*"#,
                options: .regularExpression
            ) {
                let annotation = String(parameter[actor])
                    .trimmingCharacters(in: .whitespaces)
                guard CanonicalSIL.FunctionIsolation.loweredTypeAnnotation(
                    in: annotation
                ) == .mainActor else { return nil }
                actorAnnotation = "@MainActor"
                parameter.removeSubrange(actor)
            } else {
                return nil
            }
            parameter = parameter.trimmingCharacters(in: .whitespaces)
        }
        guard sawNonescaping, sawCalleeConvention,
              let closureArrow = parameter.range(
                of: " -> ",
                options: .backwards
              ),
              parameter[closureArrow.upperBound...]
                .trimmingCharacters(in: .whitespaces) == outerResult
        else { return nil }
        return actorAnnotation.map { "\($0) \(parameter)" } ?? parameter
    }

    private static func matchingOpeningParenthesis(
        for close: String.Index,
        in value: String
    ) -> String.Index? {
        var depth = 0
        var index = close
        while true {
            switch value[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            guard index > value.startIndex else { return nil }
            index = value.index(before: index)
        }
    }

    /// Returns a separator only when the outer tuple contains more than one
    /// parameter. Nested closure and generic commas are ignored.
    private static func splitTopLevel(_ value: String) -> String.Index? {
        var angleDepth = 0
        var parenthesisDepth = 0
        for index in value.indices {
            switch value[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "," where angleDepth == 0 && parenthesisDepth == 0:
                return index
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0 else { return index }
        }
        return angleDepth == 0 && parenthesisDepth == 0 ? nil : value.startIndex
    }
}
}
