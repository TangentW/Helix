import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
/// Resolves Objective-C property accessors through compiler-authored
/// `#selector` expressions. Swift property names alone cannot prove a custom
/// Objective-C getter or setter such as `setter=markEnabled:`.
enum ObjectiveCSelectorResolver {}
}

extension FrontendReceipt.ObjectiveCSelectorResolver {
    private struct Candidate: Hashable, Sendable {
        var declarationUSR: String
        var accessor: Core.NativeCall.ObjectiveCPropertyAccessor
        var ownerType: String
        var memberName: String
        var importedModules: [String]
    }

    static func resolve(
        operations: [FrontendReceipt.Adapter.ImportedOperation],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        let allCandidates = Array(Set(operations.compactMap(candidate))).sorted {
            ($0.declarationUSR, $0.accessor.rawValue, $0.ownerType, $0.memberName)
                < ($1.declarationUSR, $1.accessor.rawValue,
                   $1.ownerType, $1.memberName)
        }
        // Bound compiler work without turning a large source module into a
        // build failure. Unmeasured accessors retain their exact Swift Adapter.
        let candidates = Array(allCandidates.prefix(4_096))
        guard !candidates.isEmpty else { return operations }

        var selectors: [Candidate: String] = [:]
        var start = 0
        while start < candidates.count {
            let end = min(start + 128, candidates.count)
            let batch = Array(candidates[start..<end])
            selectors.merge(
                try resolveBatch(
                    batch,
                    frontend: frontend,
                    invocation: invocation
                ),
                uniquingKeysWith: { first, _ in first }
            )
            start = end
        }
        return operations.map { operation in
            guard let candidate = candidate(operation),
                  let selector = selectors[candidate],
                  var evidence = operation.objectiveC,
                  let property = evidence.property
            else { return operation }
            evidence.selector = selector
            evidence.selectorIsExact = true
            let dispatch: Core.NativeCall.Dispatch = evidence.dispatchClassName == nil
                ? .instance : .static
            evidence.methodFamily = property.accessor == .getter
                ? FrontendReceipt.ObjectiveCABI.methodFamily(
                    selector: selector,
                    dispatch: dispatch,
                    resultSwiftABIType: evidence.resultSwiftABIType
                ) : .none
            evidence.resultConvention = FrontendReceipt.ObjectiveCABI
                .resultConvention(
                    swiftABIType: evidence.resultSwiftABIType,
                    methodFamily: evidence.methodFamily
                )
            var result = operation
            result.objectiveC = evidence
            return result
        }
    }

    static func unresolvedCandidateCount(
        in operations: [FrontendReceipt.Adapter.ImportedOperation]
    ) -> Int {
        Set(operations.compactMap(candidate)).count
    }

    private static func candidate(
        _ operation: FrontendReceipt.Adapter.ImportedOperation
    ) -> Candidate? {
        guard let evidence = operation.objectiveC,
              !evidence.selectorIsExact,
              let property = evidence.property,
              let owner = escapedNominalType(operation.ownerType),
              let member = Core.SwiftName.escapedIdentifier(operation.baseName)
        else { return nil }
        return .init(
            declarationUSR: evidence.declarationUSR,
            accessor: property.accessor,
            ownerType: owner,
            memberName: member,
            importedModules: Array(Set(operation.importedModules)).sorted()
        )
    }

    private static func resolveBatch(
        _ candidates: [Candidate],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [Candidate: String] {
        do {
            return try measure(
                candidates,
                frontend: frontend,
                invocation: invocation
            )
        } catch let error as SwiftFrontend.Error {
            guard case let .compilationFailed(status, _) = error,
                  status == 1
            else { throw error }
            guard candidates.count > 1 else { return [:] }
            let middle = candidates.count / 2
            var result = try resolveBatch(
                Array(candidates[..<middle]),
                frontend: frontend,
                invocation: invocation
            )
            result.merge(
                try resolveBatch(
                    Array(candidates[middle...]),
                    frontend: frontend,
                    invocation: invocation
                ),
                uniquingKeysWith: { first, _ in first }
            )
            return result
        }
    }

    private static func measure(
        _ candidates: [Candidate],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [Candidate: String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-objective-c-selectors-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent(
            "ObjectiveCSelectors.swift"
        )
        let source = renderSource(candidates)
        let contents = Data(source.utf8)
        guard contents.count <= 2 * 1_024 * 1_024 else {
            throw FrontendReceipt.Error.frontendFailed(
                "Objective-C selector probe source exceeds 2 MiB"
            )
        }
        try contents.write(to: sourceURL, options: .atomic)
        let output = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(output)
        var result: [Candidate: String] = [:]
        for document in documents {
            guard let items = document["items"] as? [Any] else { continue }
            for value in items {
                guard let item = value as? FrontendReceipt.TypedAST.Object,
                      item["_kind"] as? String == "func_decl",
                      let name = FrontendReceipt.Adapter().baseName(in: item),
                      name.hasPrefix("helixObjectiveCSelectorProbe"),
                      let index = Int(name.dropFirst(
                          "helixObjectiveCSelectorProbe".count
                      )),
                      candidates.indices.contains(index)
                else { continue }
                let candidate = candidates[index]
                let matches = FrontendReceipt.ObjectiveCABI
                    .propertySelectors(in: item).filter {
                        $0.declarationUSR == candidate.declarationUSR
                            && $0.accessor == candidate.accessor
                    }
                if matches.count == 1, let selector = matches.first?.selector {
                    result[candidate] = selector
                }
            }
        }
        return result
    }

    private static func renderSource(_ candidates: [Candidate]) -> String {
        let imports = Set(candidates.flatMap(\.importedModules)).sorted().map {
            "import \($0)"
        }
        let probes = candidates.enumerated().map { index, candidate in
            "private func helixObjectiveCSelectorProbe\(index)() {\n"
                + "    _ = #selector(\(candidate.accessor.rawValue): "
                + "\(candidate.ownerType).\(candidate.memberName))\n}"
        }
        return (imports + [""] + probes + [""]).joined(separator: "\n")
    }

    private static func escapedNominalType(_ value: String) -> String? {
        guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(value) else {
            return nil
        }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty else { return nil }
        let escaped = components.compactMap {
            Core.SwiftName.escapedIdentifier(String($0))
        }
        return escaped.count == components.count
            ? escaped.joined(separator: ".") : nil
    }
}
