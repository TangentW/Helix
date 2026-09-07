import Foundation
import HelixCompiler

extension FrontendReceipt.Adapter {
    /// Diagnosis can validate this mapping with verified function facts even
    /// when an unrelated SIL layout or conformance prevents a complete File.
    func validateSILSourceMappings(
        documents: [FrontendReceipt.TypedAST.Object], sourcesByPhysicalPath: [String: SourceState],
        functions: [CanonicalSIL.Function], compilerURL: URL, performance: BuildPerformance.Recorder
    ) throws {
        let resolver = try FrontendReceipt.SILFunctionResolver(functions: functions)
            .resolvingCollisions(using: .init(compilerURL: compilerURL, invocationObserver: performance.subprocessObserver))
        var failures = Set<String>()
        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[URL(fileURLWithPath: filename).resolvingSymlinksInPath().standardizedFileURL.path]
            else { throw FrontendReceipt.Error.malformedAST("source mapping document is outside the validated source set") }
            var pending = try FrontendReceipt.TypedAST.items(in: document)
            while let value = pending.popLast() {
                if let array = value as? [Any] { pending.append(contentsOf: array); continue }
                guard let item = value as? FrontendReceipt.TypedAST.Object else { continue }
                do {
                    try Task.checkCancellation()
                    switch item["_kind"] as? String {
                    case "func_decl":
                        _ = try resolver.function(for: item, source: source, baseName: baseName(in: item))
                    case "accessor_decl":
                        _ = try resolver.function(for: item, source: source)
                    case "closure_expr":
                        _ = try resolver.function(forClosure: item, source: source)
                    default: break
                    }
                } catch {
                    if error is CancellationError { throw error }
                    failures.insert(String(describing: error))
                }
                for (key, child) in item where key != "decl" {
                    if child is [Any] || child is FrontendReceipt.TypedAST.Object { pending.append(child) }
                }
            }
        }
        guard failures.isEmpty else {
            throw FrontendReceipt.Error.invalidRequest("AST/SIL mapping failures:\n" + failures.sorted().joined(separator: "\n"))
        }
    }
}
