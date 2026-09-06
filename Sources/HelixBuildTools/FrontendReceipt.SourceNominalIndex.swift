import Foundation

extension FrontendReceipt.Adapter {
    /// USRs identify declarations; a spelling is only a lookup in a source scope.
    struct SourceNominalIndex {
        private var global: [String: SourceNominal] = [:]
        private var scoped: [String: [String: SourceNominal]] = [:]

        init(_ nominals: [SourceNominal]) {
            for nominal in nominals {
                if nominal.isFileScoped {
                    scoped[nominal.sourceFileLogicalID, default: [:]][nominal.canonicalName] = nominal
                } else {
                    global[nominal.canonicalName] = nominal
                }
            }
        }

        func resolve(_ name: String, in source: String) -> SourceNominal? {
            scoped[source]?[name] ?? global[name]
        }
    }

    static func sourceNominalSpelling(_ compilerName: String) -> String {
        // This is only a source spelling. Declaration equality still uses USR
        // and lookup is constrained to the declaring source file.
        compilerName.replacingOccurrences(
            of: #"\(([\p{L}\p{N}_]+) in _[0-9A-Fa-f]+\)"#,
            with: "$1", options: .regularExpression
        )
    }

    static func insertSourceNominal(
        _ nominal: SourceNominal,
        into declarations: inout [String: SourceNominal]
    ) throws {
        guard !nominal.declarationIdentity.isEmpty else {
            throw FrontendReceipt.Error.malformedAST(
                "source nominal has no declaration USR: \(sourceNominalEvidence(nominal))"
            )
        }
        if let existing = declarations[nominal.declarationIdentity], existing != nominal {
            throw FrontendReceipt.Error.malformedAST(
                "source nominal USR \(nominal.declarationIdentity) has conflicting declarations: "
                + [existing, nominal].map(sourceNominalEvidence).sorted().joined(separator: "; ")
            )
        }
        declarations[nominal.declarationIdentity] = nominal
    }

    private static func sourceNominalEvidence(_ value: SourceNominal) -> String {
        "USR=\(value.declarationIdentity), name=\(value.canonicalName), "
        + "source=\(value.sourceFileLogicalID), UTF-8 offset=\(value.declarationOffset.map(String.init) ?? "unknown"), "
        + "kind=\(value.kind), fileScoped=\(value.isFileScoped), ambiguousName=\(value.hasAmbiguousName), "
        + "fileScopeNameable=\(value.isFileScopeNameable), availabilityConstrained=\(value.isAvailabilityConstrained)"
    }

    static func resolveSourceNominalNames(_ nominals: [SourceNominal]) throws -> [SourceNominal] {
        let byName = Dictionary(grouping: nominals, by: \.canonicalName)
        var ambiguousNames = Set<String>()
        for (name, values) in byName where values.count > 1 {
            guard values.allSatisfy(\.isFileScoped),
                  Set(values.map(\.sourceFileLogicalID)).count == values.count
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "source nominal \(name) has conflicting declarations: "
                    + values.map(sourceNominalEvidence).sorted().joined(separator: "; ")
                )
            }
            ambiguousNames.insert(name)
        }
        return nominals.map { value in
            var nominal = value
            var name = nominal.canonicalName
            while true {
                if ambiguousNames.contains(name) {
                    // SIL's declaration summary omits private discriminators.
                    // Never freeze a layout selected only by that lossy spelling.
                    nominal.hasAmbiguousName = true
                    break
                }
                guard let separator = name.lastIndex(of: ".") else { break }
                name = String(name[..<separator])
            }
            return nominal
        }.sorted {
            ($0.canonicalName, $0.sourceFileLogicalID, $0.declarationIdentity)
                < ($1.canonicalName, $1.sourceFileLogicalID, $1.declarationIdentity)
        }
    }
}
