import Foundation

extension CanonicalSIL.GenericSignature {
    struct Resolution: Sendable {
        var arguments: [String]
        var substitutions: [String: String]
    }

    enum ResolutionError: Error, Equatable, Sendable,
        CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case let .invalid(reason): reason
            }
        }
    }

    static func resolve(
        _ signature: FunctionSignature,
        arguments: [String],
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> Resolution {
        guard signature.parameters.count == arguments.count else {
            throw ResolutionError.invalid(
                "the declaration has \(signature.parameters.count) type parameters "
                    + "but the call supplies \(arguments.count)"
            )
        }
        let bindings = Dictionary(
            uniqueKeysWithValues: zip(signature.parameters, arguments).map {
                ($0.0, $0.1)
            }
        )
        var visited = Set<ConformanceKey>()
        let substitutions = try solve(
            parameters: signature.parameters,
            requirements: signature.requirements,
            initialBindings: bindings,
            conformances: conformances,
            typeEnvironment: typeEnvironment,
            visited: &visited,
            depth: 0
        )
        return .init(arguments: arguments, substitutions: substitutions)
    }

    static func resolve(
        _ clause: Clause,
        bindings: [String: String],
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> Resolution {
        guard Set(bindings.keys) == Set(clause.parameters) else {
            throw ResolutionError.invalid(
                "generic conformance bindings do not match its parameters"
            )
        }
        var visited = Set<ConformanceKey>()
        let substitutions = try solve(
            parameters: clause.parameters,
            requirements: clause.requirements,
            initialBindings: bindings,
            conformances: conformances,
            typeEnvironment: typeEnvironment,
            visited: &visited,
            depth: 0
        )
        return .init(
            arguments: clause.parameters.compactMap { bindings[$0] },
            substitutions: substitutions
        )
    }

    private struct ConformanceKey: Hashable {
        var concrete: String
        var protocolName: String
    }

    private struct Evidence {
        var associatedTypes: [String: String]
    }

    private static let maximumResolutionPasses = 128
    private static let maximumConformanceDepth = 16

    private static func solve(
        parameters: [String],
        requirements: [Requirement],
        initialBindings: [String: String],
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        visited: inout Set<ConformanceKey>,
        depth: Int
    ) throws -> [String: String] {
        guard parameters.count <= maximumParameterCount,
              requirements.count <= maximumRequirementCount,
              depth <= maximumConformanceDepth
        else {
            throw ResolutionError.invalid(
                "generic signature exceeds concrete-resolution limits"
            )
        }
        var substitutions = initialBindings
        for (parameter, argument) in initialBindings {
            guard CanonicalSIL.GenericSignature.isParameter(parameter),
                  !argument.isEmpty,
                  try !CanonicalSIL.GenericSignature.containsAny(
                    of: parameters,
                    in: argument
                  )
            else {
                throw ResolutionError.invalid(
                    "generic parameter \(parameter) is not bound to a concrete type"
                )
            }
        }

        func resolved(_ raw: String) throws -> String {
            var result = raw
            for _ in 0..<maximumResolutionPasses {
                let next = try CanonicalSIL.GenericSignature.substituting(
                    substitutions,
                    in: result,
                    preservesQuotedSpellings: false
                )
                if next == result { return result }
                result = next
            }
            throw ResolutionError.invalid(
                "generic substitutions do not converge"
            )
        }

        func unresolvedDependentPath(_ raw: String) -> Bool {
            guard substitutions[raw] == nil,
                  let root = raw.split(separator: ".").first.map(String.init),
                  parameters.contains(root)
            else { return false }
            return raw != root
        }

        func bind(_ path: String, to rawValue: String) throws -> Bool {
            let value = try resolved(rawValue)
            guard try !CanonicalSIL.GenericSignature.containsAny(
                of: parameters,
                in: value
            ) else { return false }
            if let existing = substitutions[path] {
                guard CanonicalSIL.GenericSignature.equivalentType(
                    try resolved(existing),
                    value
                ) else {
                    throw ResolutionError.invalid(
                        "generic dependent type \(path) resolves inconsistently"
                    )
                }
                return false
            }
            substitutions[path] = value
            return true
        }

        for _ in 0..<maximumResolutionPasses {
            var changed = false

            for requirement in requirements where requirement.relation == .sameType {
                let left = try resolved(requirement.left)
                let right = try resolved(requirement.right)
                let leftUnresolved = unresolvedDependentPath(requirement.left)
                let rightUnresolved = unresolvedDependentPath(requirement.right)
                if leftUnresolved, !rightUnresolved {
                    changed = try bind(requirement.left, to: right) || changed
                } else if rightUnresolved, !leftUnresolved,
                          isTypePathRequirement(requirement.right) {
                    changed = try bind(requirement.right, to: left) || changed
                } else if !leftUnresolved, !rightUnresolved {
                    guard CanonicalSIL.GenericSignature.equivalentType(
                        left,
                        right
                    ) else {
                        throw ResolutionError.invalid(
                            "same-type requirement \(requirement.left) == "
                                + "\(requirement.right) is not satisfied by "
                                + "\(left) and \(right)"
                        )
                    }
                }
            }

            for requirement in requirements where requirement.relation == .conformance {
                guard !unresolvedDependentPath(requirement.left) else {
                    continue
                }
                let concrete = try resolved(requirement.left)
                guard try !CanonicalSIL.GenericSignature.containsAny(
                    of: parameters,
                    in: concrete
                ) else { continue }
                let constraints = try CanonicalSIL.GenericSignature
                    .splitComposition(requirement.right)
                guard !constraints.isEmpty else {
                    throw ResolutionError.invalid(
                        "generic conformance requirement has no protocol"
                    )
                }
                for constraint in constraints {
                    if normalizedProtocolName(constraint) == "AnyObject" {
                        guard typeEnvironment.isReferenceType(concrete) else {
                            throw ResolutionError.invalid(
                                "\(concrete) does not satisfy the AnyObject constraint"
                            )
                        }
                        continue
                    }
                    let evidence = try conformanceEvidence(
                        concrete: concrete,
                        protocolName: constraint,
                        conformances: conformances,
                        typeEnvironment: typeEnvironment,
                        visited: &visited,
                        depth: depth + 1
                    )
                    for (name, value) in evidence.associatedTypes {
                        let path = requirement.left + "." + name
                        changed = try bind(path, to: value) || changed
                    }
                }
            }

            if !changed { break }
        }

        for requirement in requirements {
            let left = try resolved(requirement.left)
            switch requirement.relation {
            case .sameType:
                guard !unresolvedDependentPath(requirement.left),
                      !unresolvedDependentPath(requirement.right),
                      CanonicalSIL.GenericSignature.equivalentType(
                        left,
                        try resolved(requirement.right)
                      )
                else {
                    throw ResolutionError.invalid(
                        "same-type requirement \(requirement.left) == "
                            + "\(requirement.right) could not be concretely proven"
                    )
                }
            case .conformance:
                guard !unresolvedDependentPath(requirement.left) else {
                    throw ResolutionError.invalid(
                        "conformance subject \(requirement.left) remains dependent"
                    )
                }
                for constraint in try CanonicalSIL.GenericSignature
                    .splitComposition(requirement.right) {
                    if normalizedProtocolName(constraint) == "AnyObject" {
                        guard typeEnvironment.isReferenceType(left) else {
                            throw ResolutionError.invalid(
                                "\(left) does not satisfy the AnyObject constraint"
                            )
                        }
                    } else {
                        _ = try conformanceEvidence(
                            concrete: left,
                            protocolName: constraint,
                            conformances: conformances,
                            typeEnvironment: typeEnvironment,
                            visited: &visited,
                            depth: depth + 1
                        )
                    }
                }
            }
        }
        return substitutions
    }

    private static func conformanceEvidence(
        concrete: String,
        protocolName: String,
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        visited: inout Set<ConformanceKey>,
        depth: Int
    ) throws -> Evidence {
        guard depth <= maximumConformanceDepth else {
            throw ResolutionError.invalid(
                "generic conformance proof is deeper than \(maximumConformanceDepth)"
            )
        }
        let key = ConformanceKey(
            concrete: CanonicalSIL.SwiftTypeIdentity.normalized(concrete),
            protocolName: normalizedProtocolName(protocolName)
        )
        guard visited.insert(key).inserted else {
            throw ResolutionError.invalid(
                "generic conformance proof is recursive for \(concrete): \(protocolName)"
            )
        }
        defer { visited.remove(key) }

        if conformances.isAmbiguousType(concrete) {
            throw ResolutionError.invalid(
                "\(concrete) has ambiguous printed conformance identity for \(protocolName):\n  "
                    + conformances.ambiguityEvidence(for: concrete).joined(separator: "\n  ")
            )
        }
        var proven: [Evidence] = []
        for match in conformances.specializedRecords(
            conformingType: concrete,
            protocolName: protocolName
        ) {
            guard match.record.isComplete else { continue }
            var associatedTypes = match.associatedTypes
            if let rawClause = match.record.genericClause {
                let clause: Clause
                do {
                    clause = try CanonicalSIL.GenericSignature
                        .standaloneClause(rawClause)
                } catch let error as ParseError {
                    throw ResolutionError.invalid(
                        "conditional conformance signature is malformed: "
                            + error.description
                    )
                }
                do {
                    let conformanceSubstitutions = try solve(
                        parameters: clause.parameters,
                        requirements: clause.requirements,
                        initialBindings: match.bindings,
                        conformances: conformances,
                        typeEnvironment: typeEnvironment,
                        visited: &visited,
                        depth: depth
                    )
                    associatedTypes = try Dictionary(
                        uniqueKeysWithValues: match.record.associatedTypes.map {
                            name, value in
                            (
                                name,
                                try CanonicalSIL.GenericSignature.substituting(
                                    conformanceSubstitutions,
                                    in: value,
                                    preservesQuotedSpellings: false
                                )
                            )
                        }
                    )
                } catch {
                    continue
                }
            }
            proven.append(.init(associatedTypes: associatedTypes))
        }
        if proven.isEmpty,
           let associated = typeEnvironment.standardConformanceAssociatedTypes(
               concrete: concrete,
               protocolName: protocolName
           ) {
            proven.append(.init(associatedTypes: associated))
        }
        if proven.isEmpty,
           typeEnvironment.satisfiesSuperclassConstraint(
            concrete: concrete,
            superclass: protocolName
           ) {
            proven.append(.init(associatedTypes: [:]))
        }
        guard proven.count == 1, let evidence = proven.first else {
            let reason = proven.isEmpty ? "has no closed conformance evidence"
                : "has ambiguous conformance evidence"
            throw ResolutionError.invalid(
                "\(concrete) \(reason) for \(protocolName)"
            )
        }
        return evidence
    }

    private static func normalizedProtocolName(_ raw: String) -> String {
        let compact = raw.filter { !$0.isWhitespace }
        return compact.hasPrefix("Swift.")
            ? String(compact.dropFirst("Swift.".count)) : compact
    }

    private static func isTypePathRequirement(_ raw: String) -> Bool {
        raw.range(
            of: #"^(?:[A-Za-z_][A-Za-z0-9_]*|τ_[0-9]+_[0-9]+)(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"#,
            options: .regularExpression
        ) != nil
    }
}
