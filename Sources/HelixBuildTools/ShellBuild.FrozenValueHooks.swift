import Foundation
import HelixInterface

extension ShellBuild {
/// Renders same-source construction hooks for frozen Shell structs. Keeping
/// these declarations in the defining file lets Swift enforce access control
/// while generated bridge code reconstructs values without inspecting layout.
enum FrozenValueHooks {
    static func render(
        _ records: [InterfaceArchive.FrozenValueTypeRecord],
        moduleName: String
    ) -> String {
        records.sorted(by: { $0.key < $1.key }).compactMap { record in
            guard case let .structure(fields) = record.kind else { return nil }
            let type = escapedType(record.swiftType(moduleName: moduleName))
            let parameters = [
                "__helix_\(record.codecIdentifier): ()",
            ] + fields.enumerated().map { offset, field in
                "field\(offset): \(field.swiftType)"
            }
            let assignments = fields.enumerated().map { offset, field in
                "        self.\(escapedIdentifier(field.name)) = field\(offset)"
            }
            let body = assignments.isEmpty ? "" : "\n" + assignments.joined(separator: "\n") + "\n    "
            return """
            extension \(type) {
                private init(
                    \(parameters.joined(separator: ",\n        "))
                ) {\(body)}
            }
            """
        }.joined(separator: "\n\n")
    }

    private static func escapedType(_ value: String) -> String {
        value.split(separator: ".", omittingEmptySubsequences: false)
            .map { escapedIdentifier(String($0)) }
            .joined(separator: ".")
    }

    private static func escapedIdentifier(_ value: String) -> String {
        keywords.contains(value) ? "`\(value)`" : value
    }

    private static let keywords: Set<String> = [
        "Any", "Self", "actor", "any", "as", "associatedtype", "async", "await",
        "break", "borrowing", "case", "catch", "class", "consuming", "continue",
        "default", "defer", "deinit", "distributed", "do", "each", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
        "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let",
        "macro", "nil", "nonisolated", "open", "operator", "package", "precedencegroup",
        "private", "protocol", "public", "repeat", "return", "rethrows", "self", "sending",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while",
    ]
}
}
