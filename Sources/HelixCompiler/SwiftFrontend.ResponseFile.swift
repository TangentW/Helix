import Foundation

extension SwiftFrontend {
enum ResponseFile {
    // Stay below both NSConcreteTask's argv count limit and the OS byte limit.
    static func isRequired(for arguments: [String]) -> Bool {
        arguments.count > 3_000
            || arguments.reduce(0, { $0 + $1.utf8.count + 1 }) > 128 * 1_024
    }

    static func render(_ arguments: [String]) throws -> String {
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw SwiftFrontend.Error.launchFailed("compiler argument contains NUL")
        }
        // Swift/LLVM response files use shell-style quoting, not JSON escapes.
        // Quoting every token also preserves empty strings and literal quotes.
        return arguments.map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: "\n") + "\n"
    }
}
}
