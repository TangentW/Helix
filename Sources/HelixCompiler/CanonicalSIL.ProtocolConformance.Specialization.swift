import Foundation

extension CanonicalSIL.ProtocolConformance {
    struct SpecializedRecord: Sendable {
        var record: Record
        var bindings: [String: String]
        var associatedTypes: [String: String]

        var genericArguments: [String] {
            guard let raw = record.genericClause,
                  let clause = try? CanonicalSIL.GenericSignature
                    .standaloneClause(raw)
            else { return [] }
            return clause.parameters.compactMap { bindings[$0] }
        }
    }
}

extension CanonicalSIL.ProtocolConformance.Environment {
    func specializedRecords(
        conformingType: String
    ) -> [CanonicalSIL.ProtocolConformance.SpecializedRecord] {
        specializedRecords(
            conformingType: conformingType,
            protocolName: nil
        )
    }

    func specializedRecords(
        conformingType: String,
        protocolName: String
    ) -> [CanonicalSIL.ProtocolConformance.SpecializedRecord] {
        specializedRecords(
            conformingType: conformingType,
            protocolName: Optional(protocolName)
        )
    }

    private func specializedRecords(
        conformingType: String,
        protocolName: String?
    ) -> [CanonicalSIL.ProtocolConformance.SpecializedRecord] {
        unambiguousRecords.compactMap { record in
            if let protocolName {
                guard protocolNamesEquivalent(
                    protocolName,
                    record.protocolName,
                    moduleName: record.moduleName
                ) else { return nil }
            }

            let bindings: [String: String]
            if let rawClause = record.genericClause {
                guard let clause = try? CanonicalSIL.GenericSignature
                    .standaloneClause(rawClause),
                      let matched = CanonicalSIL.GenericSignature
                        .concreteBindings(
                            template: record.conformingType,
                            concrete: conformingType,
                            parameters: clause.parameters,
                            moduleName: record.moduleName
                        )
                else { return nil }
                bindings = matched
            } else {
                guard concreteTypeNamesEquivalent(
                    conformingType,
                    record.conformingType,
                    moduleName: record.moduleName
                ) else { return nil }
                bindings = [:]
            }

            let associatedTypes: [String: String]
            do {
                associatedTypes = try Dictionary(
                    uniqueKeysWithValues: record.associatedTypes.map {
                        name, value in
                        (
                            name,
                            try CanonicalSIL.GenericSignature.substituting(
                                bindings,
                                in: value,
                                preservesQuotedSpellings: false
                            )
                        )
                    }
                )
            } catch {
                return nil
            }
            return .init(
                record: record,
                bindings: bindings,
                associatedTypes: associatedTypes
            )
        }.sorted { left, right in
            left.record.orderKey < right.record.orderKey
        }
    }

    private func protocolNamesEquivalent(
        _ lhs: String,
        _ rhs: String,
        moduleName: String
    ) -> Bool {
        CanonicalSIL.ProtocolExistential.Identity.namesEquivalent(
            lhs,
            rhs,
            moduleName: moduleName
        )
    }

    private func concreteTypeNamesEquivalent(
        _ lhs: String,
        _ rhs: String,
        moduleName: String
    ) -> Bool {
        let left = CanonicalSIL.SwiftTypeIdentity.normalized(lhs)
        let right = CanonicalSIL.SwiftTypeIdentity.normalized(rhs)
        return left == right
            || left == moduleName + "." + right
            || right == moduleName + "." + left
    }
}
