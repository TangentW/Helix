import Foundation

extension FrontendReceipt {
/// Selectable diagnostic roots. Their necessary compiler/input checks are
/// included automatically; only `receipt` validates the complete receipt.
public enum DiagnosticStage: String, Codable, CaseIterable, Sendable {
    case typedAST = "typed-ast"
    case identitySIL = "identity-sil"
    case semanticSIL = "semantic-sil"
    case sourceNominals = "source-nominals"
    case importedTypes = "imported-types"
    case sourceMappings = "source-mappings"
    case importedOperations = "imported-operations"
    case catalogs
    case receipt

    var roots: [String] {
        switch self {
        case .typedAST: ["frontend.typed_ast"]
        case .identitySIL: ["frontend.identity_sil"]
        case .semanticSIL: ["frontend.semantic_sil"]
        case .sourceNominals: ["frontend.discover_source_nominals"]
        case .importedTypes: ["frontend.discover_imported_types"]
        case .sourceMappings: ["frontend.identity_sil.ast_mapping", "frontend.semantic_sil.ast_mapping"]
        case .importedOperations: ["frontend.discover_imported_operations"]
        case .catalogs: ["frontend.resolve_native_api_catalogs"]
        case .receipt: ["frontend.receipt"]
        }
    }
}

enum DiagnosticPlan {
    static let dependencies: [String: [String]] = {
        let compiler = ["frontend.validate_request", "frontend.load_sources", "frontend.toolchain_identity"]
        let nominals = ["frontend.typed_ast", "frontend.demangle_types", "frontend.load_sources"]
        var graph: [String: [String]] = [
            "frontend.validate_request": [],
            "frontend.load_sources": ["frontend.validate_request"],
            "frontend.toolchain_identity": ["frontend.validate_request"],
            "frontend.typed_ast": compiler,
            "frontend.demangle_types": ["frontend.typed_ast"],
            "frontend.resolve_calling_surface": ["frontend.validate_request"],
            "frontend.discover_source_nominals": nominals,
            "frontend.discover_imported_types": nominals,
            "frontend.discover_imported_operations": nominals + ["frontend.semantic_sil"],
            "frontend.resolve_native_api_catalogs": ["frontend.typed_ast", "frontend.toolchain_identity"],
            "frontend.merge_imported_types": ["frontend.discover_imported_types", "frontend.discover_imported_operations", "frontend.resolve_native_api_catalogs"],
            "frontend.receipt": ["frontend.identity_sil", "frontend.semantic_sil", "frontend.resolve_calling_surface",
                "frontend.discover_source_nominals", "frontend.merge_imported_types",
                "frontend.identity_sil.ast_mapping", "frontend.semantic_sil.ast_mapping"],
        ]
        for prefix in ["frontend.identity_sil", "frontend.semantic_sil"] {
            graph[prefix] = compiler
            graph[prefix + ".function_locations"] = [prefix]
            graph[prefix + ".ast_mapping"] = ["frontend.typed_ast", "frontend.load_sources", prefix + ".function_locations"]
        }
        return graph
    }()

    static func requiredStages(_ selection: [DiagnosticStage]) -> Set<String> {
        var required = Set<String>()
        var pending = selection.flatMap(\.roots)
        while let stage = pending.popLast() {
            guard required.insert(stage).inserted else { continue }
            pending += dependencies[stage, default: []]
        }
        return required
    }
}

struct DiagnosticSelectionComplete: Swift.Error {}
}
