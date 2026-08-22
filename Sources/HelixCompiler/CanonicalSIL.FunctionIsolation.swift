import Foundation

extension CanonicalSIL {
/// Source-level isolation retained by canonical SIL outside the lowered
/// function type. This metadata is authoritative for compiler-generated
/// closure bodies, whose `@convention(thin)` type does not encode a global
/// actor.
public enum FunctionIsolation: Hashable, Sendable {
    case unspecified
    case nonisolated
    case actorInstance(String?)
    case globalActor(String)
    case unknown(String)

    enum LoweredTypeAnnotation: Equatable, Sendable {
        case none
        case mainActor
        case unsupported(String)
    }

    var isMainActor: Bool {
        guard case let .globalActor(name) = self else { return false }
        return name == "MainActor" || name == "Swift.MainActor"
    }

    /// Interprets actor annotations only from an outer function type's
    /// attribute prefix. Callers must exclude the parameter tuple so a nested
    /// callback's actor does not become authority for the enclosing function.
    static func loweredTypeAnnotation(
        in outerAttributePrefix: String
    ) -> LoweredTypeAnnotation {
        if outerAttributePrefix.range(
            of: #"@isolated\s*\([^)]*\)"#,
            options: .regularExpression
        ) != nil {
            return .unsupported("isolated(any)")
        }
        let pattern = #"@[A-Za-z_][A-Za-z0-9_.]*Actor\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else { return .unsupported("invalid actor annotation parser") }
        let range = NSRange(
            outerAttributePrefix.startIndex..<outerAttributePrefix.endIndex,
            in: outerAttributePrefix
        )
        let names = expression.matches(
            in: outerAttributePrefix,
            range: range
        ).compactMap { match -> String? in
            guard let valueRange = Range(match.range, in: outerAttributePrefix)
            else { return nil }
            return String(outerAttributePrefix[valueRange].dropFirst())
        }
        guard !names.isEmpty else { return .none }
        guard names.allSatisfy({
            $0 == "MainActor" || $0 == "Swift.MainActor"
        }) else {
            return .unsupported(names.joined(separator: ", "))
        }
        return .mainActor
    }

    static func parse(comment raw: String) -> Self? {
        let comment = raw.trimmingCharacters(in: .whitespaces)
        let prefix = "// Isolation:"
        guard comment.hasPrefix(prefix) else { return nil }
        let value = comment.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
        if value == "unspecified" { return .unspecified }
        if value == "nonisolated" { return .nonisolated }
        if value.hasPrefix("global_actor.") {
            guard let marker = value.range(of: "type:") else {
                return .unknown(value)
            }
            let actor = value[marker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            return actor.isEmpty ? .unknown(value) : .globalActor(actor)
        }
        if value.hasPrefix("actor_instance.") {
            let name = value.range(of: "name:").map {
                value[$0.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            return .actorInstance(name.flatMap { $0.isEmpty ? nil : $0 })
        }
        return .unknown(value)
    }
}
}
