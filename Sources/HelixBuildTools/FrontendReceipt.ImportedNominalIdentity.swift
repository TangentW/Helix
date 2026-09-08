import Foundation

extension FrontendReceipt {
/// Spelling equivalence is considered only inside an already proven ABI group.
/// A shared suffix across different module-qualified names is never identity.
enum ImportedNominalIdentity {
    /// These compiler spellings describe an unbound type expression, not a
    /// concrete nominal. Do not discard unrelated Unicode identifier tokens.
    static func isConcreteSpelling(_ spelling: String) -> Bool {
        if spelling.contains("@opened(") || spelling.contains("<<error type>>")
            || spelling.contains("(unknown context at ") { return false }
        let tokens = spelling.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        return !tokens.contains { token in
            if token == "Self" { return true }
            guard token.hasPrefix("τ_") else { return false }
            let indices = token.dropFirst(2).split(separator: "_", omittingEmptySubsequences: false)
            return indices.count == 2 && indices.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
    }

    static func overlaySpelling(
        canonicalName: String,
        uses: [Adapter.ImportedNativeType]
    ) throws -> String? {
        let modules = moduleRoots(in: uses)
        let runtimes = Set(uses.compactMap(\.objectiveCRuntimeName))
        guard runtimes.count <= 1 else {
            throw conflict("imported nominal \(canonicalName) has conflicting Objective-C runtime identities", uses: uses)
        }
        // Clang's flat ABI name is not a competing Swift overlay. Its qualified
        // spelling is equivalent only when the runtime identity is proven and
        // the prefix is an observed module or the compiler's Clang namespace.
        let runtime = runtimes.first
        let hasReferenceEvidence = uses.allSatisfy { $0.kind == .reference && $0.representation == .reference }
        let runtimeModules = modules.union(["__C", "__ObjC"])
        let spellings = Set(uses.map(\.swiftType)).filter { spelling in
            if spelling == canonicalName { return false }
            guard let runtime, hasReferenceEvidence
            else { return true }
            if spelling == runtime { return false }
            guard let separator = spelling.firstIndex(of: "."),
                  runtimeModules.contains(String(spelling[..<separator]))
            else { return true }
            return String(spelling[spelling.index(after: separator)...]) != runtime
        }
        guard !spellings.isEmpty else {
            return uses.contains { $0.swiftType != canonicalName } ? canonicalName : nil
        }
        if spellings.count == 1 { return spellings.first }
        // Strip exactly one observed module qualifier. Nested nominal scopes
        // and qualifications inside generic arguments must remain intact.
        let candidates = spellings.filter { spelling in
            guard let separator = spelling.firstIndex(of: "."),
                  modules.contains(String(spelling[..<separator])) else { return false }
            let relative = String(spelling[spelling.index(after: separator)...])
            return spellings.isSubset(of: [spelling, relative])
        }
        guard candidates.count == 1 else {
            throw conflict(
                "imported nominal \(canonicalName) has ambiguous Swift overlay identities",
                uses: uses
            )
        }
        return candidates.first
    }

    static func moduleRoots(in uses: [Adapter.ImportedNativeType]) -> Set<String> {
        let modules: [String] = uses.flatMap { use -> [String] in
            use.importedModules + [use.objectiveCModuleName, use.nativeModuleName].compactMap { $0 }
        }
        return Set(modules.compactMap { $0.split(separator: ".").first.map(String.init) })
    }

    static func conflict(
        _ reason: String,
        uses: [Adapter.ImportedNativeType]
    ) -> FrontendReceipt.Error {
        var examples: [String: String] = [:]
        for use in uses {
            let location = use.sourceLocation.map {
                "\($0.file):\($0.line):\($0.column)"
            } ?? use.sourceFileLogicalID
            let fact = "Swift=\(String(reflecting: use.swiftType)), canonical=\(String(reflecting: use.canonicalName)), "
                + "imports=\(Array(Set(use.importedModules)).sorted()), "
                + "declaringModule=\(use.objectiveCModuleName ?? "unproven"), "
                + "catalogModule=\(use.nativeModuleName ?? "none"), "
                + "runtime=\(use.objectiveCRuntimeName ?? "unproven"), "
                + "representation=\(use.kind.rawValue)/\(use.representation.rawValue), "
                + "MainActor=\(use.requiresMainActor)/\(use.isolationEvidence.rawValue), "
                + "aliases=\(Array(Set(use.aliases)).sorted())"
            // Keep every distinct conflicting fact, with one deterministic
            // example instead of thousands of repeated source uses.
            examples[fact] = min(examples[fact] ?? location, location)
        }
        let facts = examples.map { fact, location in
            fact + ", source=\(String(reflecting: location))"
        }.sorted()
        return .invalidRequest(reason + ":\n  " + facts.joined(separator: "\n  "))
    }
}
}
