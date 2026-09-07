import Foundation
import HelixCompiler

extension FrontendReceipt.Adapter {
    /// Mapping needs verified functions, even if another SIL component failed.
    func validateSILSourceMappings(
        documents: [FrontendReceipt.TypedAST.Object], sourcesByPhysicalPath: [String: SourceState],
        functions: [CanonicalSIL.Function], compilerURL: URL, performance: BuildPerformance.Recorder
    ) throws {
        var selection = try FrontendReceipt.DeclarationSelection(documents: documents,
            sourcesByPhysicalPath: sourcesByPhysicalPath, options: nil)
        _ = try analyzeSILSourceMappings(selection: &selection, sourcesByPhysicalPath: sourcesByPhysicalPath,
            functions: functions, compilerURL: compilerURL, performance: performance, stage: "canonical SIL")
    }

    func analyzeSILSourceMappings(
        selection: inout FrontendReceipt.DeclarationSelection,
        sourcesByPhysicalPath: [String: SourceState], functions: [CanonicalSIL.Function],
        compilerURL: URL, performance: BuildPerformance.Recorder, stage: String
    ) throws -> FrontendReceipt.SILFunctionResolver {
        let resolver = try FrontendReceipt.SILFunctionResolver(functions: functions)
            .resolvingSourceMappings(members: selection.members,
                using: .init(compilerURL: compilerURL, invocationObserver: performance.subprocessObserver))
        var failures = Set<String>()
        for member in selection.members {
            let item = member.item
            do {
                try Task.checkCancellation()
                switch item["_kind"] as? String {
                case "func_decl":
                    let function = try resolver.function(for: item, source: member.source, baseName: baseName(in: item))
                    if function == nil, item["implicit"] as? Bool != true, item["body"] is FrontendReceipt.TypedAST.Object,
                       let declaration = member.declaration, item["usr"] as? String == declaration.key.usr {
                        throw FrontendReceipt.Error.missingSILFunction("\(declaration.key.usr) in \(declaration.key.logicalPath) at \(String(describing: declaration.location))")
                    }
                case "accessor_decl":
                    _ = try resolver.function(for: item, source: member.source)
                case "closure_expr":
                    // An inlined closure can have no separate SIL function.
                    // Ambiguous surviving functions are not such evidence.
                    _ = try resolver.function(forClosure: item, source: member.source)
                default: break
                }
            } catch {
                guard FrontendReceipt.DeclarationSelection.isMappingFailure(error) else { throw error }
                let evidence = "\(stage): \(error)"
                if selection.failurePolicy == .excludeUnresolved, let declaration = member.declaration {
                    selection.exclude(declaration, reason: evidence)
                } else {
                    failures.insert(evidence)
                }
            }
        }
        guard failures.isEmpty else {
            throw FrontendReceipt.Error.invalidRequest("AST/SIL mapping failures:\n" + failures.sorted().joined(separator: "\n"))
        }
        return resolver
    }
}
