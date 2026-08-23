import Foundation
import HelixCore

extension CanonicalSIL {
enum GenericFunction {
    struct Specialization: Hashable, Sendable {
        var arguments: [String]
        var concreteLoweredType: String
    }

    struct Materialized: Sendable {
        var descriptor: Specialization
        var function: CanonicalSIL.Function
    }

    enum SpecializationError: Error, Equatable, Sendable,
        CustomStringConvertible {
        case malformedSignature(String)
        case invalidArguments(String)

        var description: String {
            switch self {
            case let .malformedSignature(reason):
                "generic function signature is malformed: \(reason)"
            case let .invalidArguments(reason):
                "generic function specialization is invalid: \(reason)"
            }
        }
    }

    static func isGeneric(loweredType: String) -> Bool {
        (try? genericClause(in: loweredType)) != nil
    }

    static func parameterCount(loweredType: String) -> Int? {
        try? genericClause(in: loweredType).parameters.count
    }

    static func arguments(in raw: String) throws -> [String] {
        let values: [String]
        do {
            values = try CanonicalSIL.GenericSignature.splitTopLevel(raw)
        } catch let error as CanonicalSIL.GenericSignature.ParseError {
            throw SpecializationError.invalidArguments(error.description)
        }
        guard !values.isEmpty else {
            throw SpecializationError.invalidArguments(
                "the call supplies no concrete type arguments"
            )
        }
        for value in values {
            guard !value.isEmpty else {
                throw SpecializationError.invalidArguments(
                    "the call contains an empty type argument"
                )
            }
            guard value.range(
                of: #"(?<![A-Za-z0-9_τ])τ_[0-9]+_[0-9]+(?![A-Za-z0-9_])"#,
                options: .regularExpression
            ) == nil else {
                throw SpecializationError.invalidArguments(
                    "the call retains an unresolved archetype \(value)"
                )
            }
            guard value != "_", value.range(
                of: #"(?:^|[^A-Za-z0-9_])repeat\s+each(?:$|[^A-Za-z0-9_])"#,
                options: .regularExpression
            ) == nil else {
                throw SpecializationError.invalidArguments(
                    "the call contains an unresolved type placeholder or pack \(value)"
                )
            }
        }
        return values
    }

    static func appliedArguments(
        to value: String,
        in line: String
    ) -> String? {
        guard let marker = line.range(of: value + "<") else {
            return nil
        }
        let open = line.index(before: marker.upperBound)
        guard let close = matchingClose(
            for: open,
            open: "<",
            close: ">",
            in: line,
            ignoresFunctionArrow: true
        ) else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    static func specialize(
        _ function: CanonicalSIL.Function,
        arguments rawArguments: String,
        conformances: CanonicalSIL.ProtocolConformance.Environment? = nil,
        typeEnvironment: CanonicalSIL.TypeEnvironment? = nil
    ) throws -> Materialized {
        let clause = try genericClause(in: function.loweredType)
        let arguments = try arguments(in: rawArguments)
        guard clause.parameters.count == arguments.count else {
            throw SpecializationError.invalidArguments(
                "the declaration has \(clause.parameters.count) type parameters "
                    + "but the call supplies \(arguments.count)"
            )
        }

        let typeWithoutClause = String(
            function.loweredType[..<clause.range.lowerBound]
        ) + String(function.loweredType[clause.range.upperBound...])
        var substitutions = Dictionary(
            uniqueKeysWithValues: zip(clause.parameters, arguments).map {
                ($0.0, $0.1)
            }
        )
        if !clause.requirements.isEmpty {
            guard let conformances, let typeEnvironment else {
                throw SpecializationError.invalidArguments(
                    "its generic requirements have no concrete conformance environment"
                )
            }
            do {
                guard let signature = try CanonicalSIL.GenericSignature
                    .functionSignature(in: function.loweredType) else {
                    throw SpecializationError.malformedSignature(
                        "it is not a generic SIL function type"
                    )
                }
                substitutions = try CanonicalSIL.GenericSignature.resolve(
                    signature,
                    arguments: arguments,
                    conformances: conformances,
                    typeEnvironment: typeEnvironment
                ).substitutions
            } catch let error as CanonicalSIL.GenericSignature.ParseError {
                throw SpecializationError.malformedSignature(error.description)
            } catch let error as CanonicalSIL.GenericSignature.ResolutionError {
                throw SpecializationError.invalidArguments(error.description)
            }
        }
        let concreteType: String
        let concreteBody: String
        do {
            concreteType = try CanonicalSIL.GenericSignature.substituting(
                substitutions,
                in: typeWithoutClause
            )
            concreteBody = try CanonicalSIL.GenericSignature.substituting(
                substitutions,
                in: function.body
            )
        } catch let error as CanonicalSIL.GenericSignature.ParseError {
            throw SpecializationError.malformedSignature(error.description)
        }
        for parameter in clause.parameters {
            let typeRetainsParameter = try CanonicalSIL.GenericSignature
                .containsAny(of: [parameter], in: concreteType)
            let bodyRetainsParameter = try CanonicalSIL.GenericSignature
                .containsAny(of: [parameter], in: concreteBody)
            guard !typeRetainsParameter, !bodyRetainsParameter
            else {
                throw SpecializationError.invalidArguments(
                    "the concrete body retains generic parameter \(parameter)"
                )
            }
        }

        let descriptor = Specialization(
            arguments: arguments,
            concreteLoweredType: concreteType
        )
        let symbol = syntheticSymbol(
            for: function.mangledName,
            originalLoweredType: function.loweredType,
            arguments: arguments
        )
        return .init(
            descriptor: descriptor,
            function: .init(
                mangledName: symbol,
                loweredType: concreteType,
                body: concreteBody,
                isolation: function.isolation,
                declarationLocation: function.declarationLocation,
                debugLineLocations: function.debugLineLocations,
                isExternalDefinition: function.isExternalDefinition
            )
        )
    }

    static func validatesCallType(
        _ appliedLoweredType: String,
        against referenceLoweredType: String
    ) -> Bool {
        appliedLoweredType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == referenceLoweredType
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Clause {
        var range: Range<String.Index>
        var parameters: [String]
        var requirements: [CanonicalSIL.GenericSignature.Requirement]
    }

    private static func genericClause(in raw: String) throws -> Clause {
        do {
            guard let signature = try CanonicalSIL.GenericSignature
                .functionSignature(in: raw) else {
                throw SpecializationError.malformedSignature(
                    "it is not a generic SIL function type"
                )
            }
            return .init(
                range: signature.range,
                parameters: signature.parameters,
                requirements: signature.requirements
            )
        } catch let error as CanonicalSIL.GenericSignature.ParseError {
            throw SpecializationError.malformedSignature(error.description)
        }
    }

    private static func matchingClose(
        for openIndex: String.Index,
        open: Character,
        close: Character,
        in text: String,
        ignoresFunctionArrow: Bool = false
    ) -> String.Index? {
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            if text[index] == open {
                depth += 1
            } else if text[index] == close {
                let previous = index > text.startIndex
                    ? text[text.index(before: index)] : nil
                if !ignoresFunctionArrow || previous != "-" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            guard depth >= 0 else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func syntheticSymbol(
        for baseSymbol: String,
        originalLoweredType: String,
        arguments: [String]
    ) -> String {
        var hasher = Core.StableHasher(domain: "HLX.GenericSpecialization.v1")
        hasher.append(baseSymbol)
        hasher.append(originalLoweredType)
        hasher.append(UInt64(arguments.count))
        for argument in arguments { hasher.append(argument) }
        return "$hlx_generic_specialization_\(hasher.finalize().hex)"
    }
}
}
