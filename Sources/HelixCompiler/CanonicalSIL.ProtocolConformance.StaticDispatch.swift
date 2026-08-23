import Foundation

extension CanonicalSIL.ProtocolConformance {
enum StaticDispatch {
    struct WitnessReference {
        var result: String
        var conformingType: String
        var requirement: String
        var requirementType: String
        var functionType: String
    }

    private struct Target {
        var symbol: String
        var functionType: String
        var witnessFunctionType: String
        var conformingType: String
        var conformerGenericArguments: [String]
        var sourceGenericParameterCount: Int
        var genericParameterCount: Int
    }

    /// File-wide witness and function evidence is immutable. Index it once;
    /// only the concrete type environment varies when NativeImport metadata is
    /// injected for a compilation.
    struct Inventory: Sendable {
        fileprivate let conformances: CanonicalSIL.ProtocolConformance
            .Environment
        fileprivate let functionsBySymbol: [String: [CanonicalSIL.Function]]

        init(
            conformances: CanonicalSIL.ProtocolConformance.Environment,
            availableFunctions: [CanonicalSIL.Function]
        ) {
            self.conformances = conformances
            functionsBySymbol = availableFunctions.reduce(
                into: [String: [CanonicalSIL.Function]]()
            ) { result, function in
                result[function.mangledName, default: []].append(function)
            }
        }
    }

    struct Rewriter: Sendable {
        private let conformances: CanonicalSIL.ProtocolConformance.Environment
        private let typeEnvironment: CanonicalSIL.TypeEnvironment
        private let functionsBySymbol: [String: [CanonicalSIL.Function]]

        init(
            conformances: CanonicalSIL.ProtocolConformance.Environment,
            availableFunctions: [CanonicalSIL.Function],
            typeEnvironment: CanonicalSIL.TypeEnvironment = .empty
        ) {
            self.init(
                inventory: .init(
                    conformances: conformances,
                    availableFunctions: availableFunctions
                ),
                typeEnvironment: typeEnvironment
            )
        }

        init(
            inventory: Inventory,
            typeEnvironment: CanonicalSIL.TypeEnvironment
        ) {
            conformances = inventory.conformances
            self.typeEnvironment = typeEnvironment
            functionsBySymbol = inventory.functionsBySymbol
        }

        func rewrite(
            _ function: CanonicalSIL.Function,
            moduleName: String? = nil
        ) -> CanonicalSIL.Function {
            StaticDispatch.rewrite(
                function,
                moduleName: moduleName ?? CanonicalSIL.SymbolIdentity.moduleName(
                    of: function.mangledName
                ),
                conformances: conformances,
                typeEnvironment: typeEnvironment,
                functionsBySymbol: functionsBySymbol
            )
        }
    }

    /// Replaces only closed, unambiguous witness lookups with their exact SIL
    /// thunk. A conditional conformance is admitted only after all of its
    /// concrete requirements are proven. Dynamic, incomplete, or textually
    /// ambiguous evidence remains as `witness_method` and fails closed if it
    /// becomes reachable.
    static func rewrite(
        _ function: CanonicalSIL.Function,
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        availableFunctions: [CanonicalSIL.Function],
        typeEnvironment: CanonicalSIL.TypeEnvironment = .empty
    ) -> CanonicalSIL.Function {
        Rewriter(
            conformances: conformances,
            availableFunctions: availableFunctions,
            typeEnvironment: typeEnvironment
        ).rewrite(function)
    }

    private static func rewrite(
        _ function: CanonicalSIL.Function,
        moduleName: String?,
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        functionsBySymbol: [String: [CanonicalSIL.Function]]
    ) -> CanonicalSIL.Function {
        guard !CanonicalSIL.GenericFunction.isGeneric(
            loweredType: function.loweredType
        ), function.body.contains("witness_method"),
           let moduleName else { return function }

        let lines = function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var targetByValue: [String: Target] = [:]

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let reference = witnessReference(in: line),
               let target = target(
                   for: reference,
                   moduleName: moduleName,
                   conformances: conformances,
                   typeEnvironment: typeEnvironment,
                   functionsBySymbol: functionsBySymbol
               ) {
                targetByValue[reference.result] = target
                continue
            }
            if let alias = functionReferenceAlias(in: line),
               let target = targetByValue[alias.source] {
                targetByValue[alias.result] = target
            }
        }
        guard !targetByValue.isEmpty else { return function }

        var rewritten = function
        rewritten.body = lines.map { rawLine in
            let indentation = String(rawLine.prefix(while: \.isWhitespace))
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let reference = witnessReference(in: line),
               let target = targetByValue[reference.result] {
                return indentation + reference.result
                    + " = function_ref @" + target.symbol
                    + " : $" + target.functionType
            }
            guard let replacement = rewriteApplication(
                line,
                targetByValue: targetByValue
            ) else { return rawLine }
            return indentation + replacement
        }.joined(separator: "\n")
        return rewritten
    }

    static func isWitnessThunk(
        _ function: CanonicalSIL.Function
    ) -> Bool {
        function.loweredType.contains("@convention(witness_method:")
    }

    private static func target(
        for reference: WitnessReference,
        moduleName: String,
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        functionsBySymbol: [String: [CanonicalSIL.Function]]
    ) -> Target? {
        let records = conformances.specializedRecords(
            conformingType: reference.conformingType
        ).filter { specialized in
            let record = specialized.record
            guard record.isComplete,
                  record.moduleName == moduleName,
                  requirement(
                    reference.requirement,
                    belongsTo: record
                  )
            else {
                return false
            }
            guard let rawClause = record.genericClause else { return true }
            guard let clause = try? CanonicalSIL.GenericSignature
                .standaloneClause(rawClause),
                  (try? CanonicalSIL.GenericSignature.resolve(
                    clause,
                    bindings: specialized.bindings,
                    conformances: conformances,
                    typeEnvironment: typeEnvironment
                  )) != nil
            else { return false }
            return true
        }
        let witnesses = records.flatMap { specialized in
            specialized.record.witnesses.compactMap {
                witness -> (CanonicalSIL.ProtocolConformance.Witness, [String])? in
                guard witness.requirement == reference.requirement
                    && (equivalentType(
                            witness.loweredType,
                            reference.requirementType
                        ) || equivalentType(
                            specializingSelf(
                                in: witness.loweredType,
                                as: reference.conformingType
                            ),
                            reference.requirementType
                        ))
                else { return nil }
                return (witness, specialized.genericArguments)
            }
        }
        guard witnesses.count == 1,
              let symbol = witnesses[0].0.symbol,
              let candidates = functionsBySymbol[symbol],
              candidates.count == 1,
              let target = candidates.first,
              !target.isExternalDefinition,
              isWitnessThunk(target)
        else { return nil }
        let genericParameterCount = CanonicalSIL.GenericFunction
            .parameterCount(loweredType: target.loweredType) ?? 0
        let sourceGenericParameterCount = CanonicalSIL.GenericFunction
            .parameterCount(loweredType: reference.functionType) ?? 0
        return .init(
            symbol: symbol,
            functionType: target.loweredType,
            witnessFunctionType: reference.functionType,
            conformingType: reference.conformingType,
            conformerGenericArguments: witnesses[0].1,
            sourceGenericParameterCount: sourceGenericParameterCount,
            genericParameterCount: genericParameterCount
        )
    }

    private static func requirement(
        _ requirement: String,
        belongsTo record: CanonicalSIL.ProtocolConformance.Record
    ) -> Bool {
        let protocolName = record.protocolName
            .trimmingCharacters(in: .whitespaces)
        guard !protocolName.isEmpty else { return false }
        var prefixes = [protocolName]
        if !protocolName.hasPrefix(record.moduleName + ".") {
            prefixes.append(record.moduleName + "." + protocolName)
        }
        return prefixes.contains { requirement.hasPrefix($0 + ".") }
    }

    private static func equivalentType(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func specializingSelf(
        in type: String,
        as conformingType: String
    ) -> String {
        guard let expression = selfTokenExpression else { return type }
        let template = NSRegularExpression.escapedTemplate(
            for: conformingType
        )
        return expression.stringByReplacingMatches(
            in: type,
            range: NSRange(type.startIndex..<type.endIndex, in: type),
            withTemplate: template
        )
    }

    private static let selfTokenExpression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_τ])Self(?![A-Za-z0-9_])"#
    )

    static func witnessReference(
        in line: String
    ) -> WitnessReference? {
        guard let assignment = line.range(of: " = witness_method $"),
              line[..<assignment.lowerBound].first == "%"
        else { return nil }
        let result = String(line[..<assignment.lowerBound])
        let body = line[assignment.upperBound...]
        guard let requirementMarker = topLevelRange(of: ", #", in: body)
        else { return nil }
        let conformingType = body[..<requirementMarker.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let declarationAndType = body[requirementMarker.upperBound...]
        guard let functionMarker = declarationAndType.range(
            of: " : $",
            options: .backwards
        ) else { return nil }
        let declaration = declarationAndType[..<functionMarker.lowerBound]
        let functionType = declarationAndType[functionMarker.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard let requirementSeparator = topLevelIndex(
            of: ":",
            in: declaration
        ) else { return nil }
        let requirement = declaration[..<requirementSeparator]
            .trimmingCharacters(in: .whitespaces)
        let requirementType = declaration[
            declaration.index(after: requirementSeparator)...
        ].trimmingCharacters(in: .whitespaces)
        // An opened existential appends its dynamic value operand after the
        // requirement type. It must never be mistaken for closed dispatch.
        guard topLevelIndex(of: ",", in: requirementType) == nil,
              !conformingType.isEmpty,
              !requirement.isEmpty,
              !requirementType.isEmpty,
              !functionType.isEmpty
        else { return nil }
        return .init(
            result: result,
            conformingType: conformingType,
            requirement: requirement,
            requirementType: requirementType,
            functionType: functionType
        )
    }

    private static func functionReferenceAlias(
        in line: String
    ) -> (result: String, source: String)? {
        for marker in [
            " = begin_borrow ",
            " = copy_value ",
            " = move_value ",
        ] {
            guard let range = line.range(of: marker) else { continue }
            let result = line[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let suffix = line[range.upperBound...]
            guard result.first == "%",
                  let source = silValue(in: suffix)
            else { return nil }
            return (String(result), source)
        }
        return nil
    }

    private static func rewriteApplication(
        _ line: String,
        targetByValue: [String: Target]
    ) -> String? {
        let markers = [
            "try_apply ",
            "begin_apply ",
            "partial_apply ",
            "apply ",
        ]
        guard let operation = markers.compactMap({ marker -> Range<String.Index>? in
            line.range(of: marker)
        }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let suffix = line[operation.upperBound...]
        guard let tokenStart = suffix.firstIndex(of: "%") else { return nil }
        let digitsStart = line.index(after: tokenStart)
        let digits = line[digitsStart...].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let tokenEnd = line.index(digitsStart, offsetBy: digits.count)
        let token = String(line[tokenStart..<tokenEnd])
        guard let target = targetByValue[token] else { return nil }

        let originalType = "$" + target.witnessFunctionType
        guard let typeRange = line.range(
            of: originalType,
            options: .backwards
        ) else { return nil }
        var calleeEnd = tokenEnd
        var sourceArguments: [String] = []
        if calleeEnd < line.endIndex, line[calleeEnd] == "<" {
            guard let close = matchingClose(
                in: line,
                from: calleeEnd,
                open: "<",
                close: ">"
            ) else { return nil }
            guard let parsed = try? CanonicalSIL.GenericFunction.arguments(
                in: String(line[line.index(after: calleeEnd)..<close])
            ) else { return nil }
            sourceArguments = parsed
            calleeEnd = line.index(after: close)
        }
        guard sourceArguments.count == target.sourceGenericParameterCount else {
            return nil
        }
        if let selfArgument = sourceArguments.first,
           !CanonicalSIL.GenericSignature.equivalentType(
            selfArgument,
            target.conformingType
           ) {
            return nil
        }
        let targetArguments = target.conformerGenericArguments
            + Array(sourceArguments.dropFirst())
        guard targetArguments.count == target.genericParameterCount else {
            return nil
        }
        let rewrittenCallee = token + (targetArguments.isEmpty ? "" : "<"
            + targetArguments.joined(separator: ", ") + ">")

        var result = line
        result.replaceSubrange(
            typeRange,
            with: "$" + target.functionType
        )
        guard let rewrittenToken = result.range(
            of: String(line[tokenStart..<calleeEnd]),
            range: result.index(
                result.startIndex,
                offsetBy: line.distance(
                    from: line.startIndex,
                    to: tokenStart
                )
            )..<result.endIndex
        ) else { return nil }
        result.replaceSubrange(rewrittenToken, with: rewrittenCallee)
        return result
    }

    private static func silValue(in text: Substring) -> String? {
        guard let start = text.firstIndex(of: "%") else { return nil }
        let digitsStart = text.index(after: start)
        let digits = text[digitsStart...].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let end = text.index(digitsStart, offsetBy: digits.count)
        return String(text[start..<end])
    }

    private static func topLevelRange<T: StringProtocol>(
        of marker: String,
        in text: T
    ) -> Range<T.Index>? {
        var state = DelimiterState()
        var index = text.startIndex
        while index < text.endIndex {
            if state.isTopLevel, text[index...].hasPrefix(marker) {
                return index..<text.index(index, offsetBy: marker.count)
            }
            guard state.consume(
                text[index],
                previous: previousCharacter(index, in: text)
            )
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func topLevelIndex<T: StringProtocol>(
        of marker: Character,
        in text: T
    ) -> T.Index? {
        var state = DelimiterState()
        var index = text.startIndex
        while index < text.endIndex {
            if state.isTopLevel, text[index] == marker { return index }
            guard state.consume(
                text[index],
                previous: previousCharacter(index, in: text)
            )
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingClose(
        in text: String,
        from openIndex: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var isQuoted = false
        var isEscaped = false
        var index = openIndex
        while index < text.endIndex {
            let character = text[index]
            if isQuoted {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isQuoted = false
                }
            } else if character == "\"" {
                isQuoted = true
            } else if character == open {
                depth += 1
            } else if character == close {
                let previous = previousCharacter(index, in: text)
                if close != ">" || previous != "-" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            guard depth >= 0 else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func previousCharacter<T: StringProtocol>(
        _ index: T.Index,
        in text: T
    ) -> Character? {
        index > text.startIndex ? text[text.index(before: index)] : nil
    }

    private struct DelimiterState {
        var parentheses = 0
        var angles = 0
        var brackets = 0
        var isQuoted = false
        var isEscaped = false

        var isTopLevel: Bool {
            !isQuoted && parentheses == 0 && angles == 0 && brackets == 0
        }

        mutating func consume(
            _ character: Character,
            previous: Character?
        ) -> Bool {
            if isQuoted {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isQuoted = false
                }
                return true
            }
            if character == "\"" {
                isQuoted = true
            } else {
                switch character {
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "<": angles += 1
                case ">":
                    if previous != "-" { angles -= 1 }
                case "[": brackets += 1
                case "]": brackets -= 1
                default: break
                }
            }
            return parentheses >= 0 && angles >= 0 && brackets >= 0
        }
    }
}
}
