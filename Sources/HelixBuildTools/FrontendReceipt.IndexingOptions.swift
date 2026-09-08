import Foundation
import HelixCompiler

extension FrontendReceipt {
public enum DeclarationFailurePolicy: String, Codable, Hashable, Sendable {
    case strict
    /// Excludes a source declaration when its AST/SIL mapping cannot be proven,
    /// or its entire source file when compiler-backed ownership is unavailable.
    /// Compiler, source, type, ABI and Catalog validation remain mandatory.
    case excludeUnresolved
}

/// Selects Helix declaration discovery without changing Swift compilation inputs.
public struct IndexingOptions: Codable, Hashable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public var failurePolicy: DeclarationFailurePolicy

    public init(include: [String] = ["**"], exclude: [String] = [],
                failurePolicy: DeclarationFailurePolicy = .strict) {
        self.include = include
        self.exclude = exclude
        self.failurePolicy = failurePolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        include = try values.decodeIfPresent([String].self, forKey: .include) ?? ["**"]
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
        failurePolicy = try values.decodeIfPresent(DeclarationFailurePolicy.self, forKey: .failurePolicy) ?? .strict
    }

    public func includes(logicalPath: String) -> Bool {
        PatchConfiguration.Module(include: include, exclude: exclude).includes(logicalPath: logicalPath)
    }

    public func validate() throws {
        guard !include.isEmpty, (include + exclude).allSatisfy({
            !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\\")
                && !$0.split(separator: "/").contains("..") && !$0.utf8.contains(0)
        }) else {
            throw FrontendReceipt.Error.invalidRequest("indexing patterns must be nonempty relative paths without traversal: include=\(include), exclude=\(exclude)")
        }
    }
}
}
