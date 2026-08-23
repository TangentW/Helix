import Foundation

extension CanonicalSIL.ProtocolConformance {
enum StaticDispatch {
    private struct WitnessReference {
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
    }

    struct Rewriter: Sendable {
        private let recordsByConformingType: [
            String: [CanonicalSIL.ProtocolConformance.Record]
        ]
        private let functionsBySymbol: [String: [CanonicalSIL.Function]]

        init(
            conformances: CanonicalSIL.ProtocolConformance.Environment,
            availableFunctions: [CanonicalSIL.Function]
        ) {
            recordsByConformingType = Dictionary(
                grouping: conformances.records,
                by: \.conformingType
            )
            functionsBySymbol = availableFunctions.reduce(
                into: [String: [CanonicalSIL.Function]]()
            ) { result, function in
                result[function.mangledName, default: []].append(function)
            }
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
                recordsByConformingType: recordsByConformingType,
                functionsBySymbol: functionsBySymbol
            )
        }
    }

    /// Replaces only closed, unambiguous witness lookups with their exact SIL
    /// thunk. Dynamic, conditional, incomplete, or textually ambiguous evidence
    /// remains as `witness_method` and therefore continues to fail closed if it
    /// becomes reachable.
    static func rewrite(
        _ function: CanonicalSIL.Function,
        conformances: CanonicalSIL.ProtocolConformance.Environment,
        availableFunctions: [CanonicalSIL.Function]
    ) -> CanonicalSIL.Function {
        Rewriter(
            conformances: conformances,
            availableFunctions: availableFunctions
        ).rewrite(function)
    }

    private static func rewrite(
        _ function: CanonicalSIL.Function,
        moduleName: String?,
        recordsByConformingType: [
            String: [CanonicalSIL.ProtocolConformance.Record]
        ],
        functionsBySymbol: [String: [CanonicalSIL.Function]]
    ) -> CanonicalSIL.Function {
        guard !CanonicalSIL.GenericFunction.isGeneric(
            loweredType: function.loweredType
        ), let moduleName else { return function }

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
                   recordsByConformingType: recordsByConformingType,
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
        recordsByConformingType: [
            String: [CanonicalSIL.ProtocolConformance.Record]
        ],
        functionsBySymbol: [String: [CanonicalSIL.Function]]
    ) -> Target? {
        let records = recordsByConformingType[
            reference.conformingType,
            default: []
        ].filter {
            $0.genericClause == nil
                && $0.isComplete
                && $0.moduleName == moduleName
        }
        let witnesses = records.flatMap { record in
            record.witnesses.filter {
                $0.requirement == reference.requirement
                    && (equivalentType(
                            $0.loweredType,
                            reference.requirementType
                        ) || equivalentType(
                            specializingSelf(
                                in: $0.loweredType,
                                as: reference.conformingType
                            ),
                            reference.requirementType
                        ))
            }
        }
        guard witnesses.count == 1,
              let symbol = witnesses[0].symbol,
              let candidates = functionsBySymbol[symbol],
              candidates.count == 1,
              let target = candidates.first,
              !target.isExternalDefinition,
              isWitnessThunk(target),
              !CanonicalSIL.GenericFunction.isGeneric(
                  loweredType: target.loweredType
              )
        else { return nil }
        return .init(
            symbol: symbol,
            functionType: target.loweredType,
            witnessFunctionType: reference.functionType
        )
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

    private static func witnessReference(
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
        if calleeEnd < line.endIndex, line[calleeEnd] == "<" {
            guard let close = matchingClose(
                in: line,
                from: calleeEnd,
                open: "<",
                close: ">"
            ) else { return nil }
            calleeEnd = line.index(after: close)
        }

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
        result.replaceSubrange(rewrittenToken, with: token)
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
