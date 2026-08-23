import Foundation

extension CanonicalSIL {
enum OpaqueResult {
    /// Replaces only frontend opaque-result identities whose physical result
    /// buffer exposes one exact underlying type. The identity remains a
    /// compiler concern; no opaque-type metadata is serialized into HLBC.
    static func concretize(
        _ function: CanonicalSIL.Function
    ) -> CanonicalSIL.Function {
        guard function.loweredType.contains("@_opaqueReturnTypeOf") else {
            return function
        }
        guard let substitution = substitutionClause(in: function.loweredType)
        else {
            return concretizeDirectResult(function) ?? function
        }
        guard let bodyArrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(
                in: substitution.functionBody
              )
        else { return function }

        let rawResult = substitution.functionBody[bodyArrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard let components = resultComponents(rawResult) else {
            return function
        }
        let indirectResults = components.compactMap { component -> String? in
            let spelling = component.trimmingCharacters(in: .whitespaces)
            guard spelling.hasPrefix("@out ") else { return nil }
            return String(spelling.dropFirst("@out ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let outputTypes = entryOutputTypes(
            in: function.body,
            count: indirectResults.count
        ), indirectResults.count == outputTypes.count else {
            return function
        }

        var replacements = substitution.substitutions
        let opaqueResults = replacements.indices.compactMap { index -> (
            substitutionIndex: Int,
            resultIndex: Int,
            identity: (symbol: String, index: UInt32, arguments: [String])
        )? in
            guard let identity = opaqueIdentity(in: replacements[index]),
                  let resultIndex = indirectResults.firstIndex(
                    of: substitution.archetypes[index]
                  )
            else { return nil }
            return (index, resultIndex, identity)
        }.sorted { left, right in
            left.resultIndex < right.resultIndex
        }
        var replacedAny = false
        for (opaqueIndex, candidate) in opaqueResults.enumerated() {
            guard candidate.identity.symbol == function.mangledName,
                  candidate.resultIndex < outputTypes.count,
                  UInt32(exactly: opaqueIndex) == candidate.identity.index,
                  equivalentArguments(
                    candidate.identity.arguments,
                    substitution.outerParameters
                  ),
                  isConcreteUnderlyingType(
                    outputTypes[candidate.resultIndex],
                    outerParameters: substitution.outerParameters
                  )
            else { continue }
            replacements[candidate.substitutionIndex] =
                outputTypes[candidate.resultIndex]
            replacedAny = true
        }
        guard replacedAny,
              !replacements.contains(where: {
                $0.contains("@_opaqueReturnTypeOf")
              })
        else { return function }

        var rewritten = function
        rewritten.loweredType.replaceSubrange(
            substitution.substitutionRange,
            with: "<" + replacements.joined(separator: ", ") + ">"
        )
        return rewritten
    }

    /// Generic opaque declarations spell the opaque identity directly in the
    /// physical `@out` component (and parameterize that identity with the
    /// declaration's outer generics). The entry block still exposes the exact
    /// underlying result buffer, so it is the same compile-time proof as the
    /// `@substituted ... for <opaque>` form above.
    private static func concretizeDirectResult(
        _ function: CanonicalSIL.Function
    ) -> CanonicalSIL.Function? {
        guard let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(
            in: function.loweredType
        ) else { return nil }
        var resultStart = arrow.upperBound
        while resultStart < function.loweredType.endIndex,
              function.loweredType[resultStart].isWhitespace {
            resultStart = function.loweredType.index(after: resultStart)
        }
        var resultEnd = function.loweredType.endIndex
        while resultEnd > resultStart {
            let previous = function.loweredType.index(before: resultEnd)
            guard function.loweredType[previous].isWhitespace else { break }
            resultEnd = previous
        }
        let rawResult = String(function.loweredType[resultStart..<resultEnd])
        guard let components = resultComponents(rawResult) else { return nil }
        let indirectCount = components.lazy.filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("@out ")
        }.count
        guard indirectCount > 0,
              let outputTypes = entryOutputTypes(
                in: function.body,
                count: indirectCount
              ), outputTypes.count == indirectCount
        else { return nil }

        let outerParameters = (try? CanonicalSIL.GenericSignature
            .functionSignature(in: function.loweredType)?.parameters) ?? []
        var rewrittenComponents = components
        var indirectIndex = 0
        var opaqueIndex = 0
        var replacedAny = false
        for index in rewrittenComponents.indices {
            let component = rewrittenComponents[index]
                .trimmingCharacters(in: .whitespaces)
            guard component.hasPrefix("@out ") else { continue }
            let resultType = String(component.dropFirst("@out ".count))
                .trimmingCharacters(in: .whitespaces)
            defer { indirectIndex += 1 }
            guard resultType.contains("@_opaqueReturnTypeOf") else { continue }
            guard let opaque = opaqueIdentity(in: resultType),
                  opaque.symbol == function.mangledName,
                  UInt32(exactly: opaqueIndex) == opaque.index,
                  equivalentArguments(opaque.arguments, outerParameters),
                  outputTypes.indices.contains(indirectIndex),
                  isConcreteUnderlyingType(
                    outputTypes[indirectIndex],
                    outerParameters: outerParameters
                  )
            else { return nil }
            rewrittenComponents[index] = "@out " + outputTypes[indirectIndex]
            replacedAny = true
            opaqueIndex += 1
        }
        guard replacedAny else { return nil }

        let trimmed = rawResult.trimmingCharacters(in: .whitespaces)
        let rewrittenResult: String
        if trimmed.first == "(", trimmed.last == ")" {
            rewrittenResult = "(" + rewrittenComponents.joined(separator: ", ")
                + ")"
        } else {
            guard rewrittenComponents.count == 1,
                  let component = rewrittenComponents.first else { return nil }
            rewrittenResult = component
        }
        guard !rewrittenResult.contains("@_opaqueReturnTypeOf") else {
            return nil
        }
        var rewritten = function
        rewritten.loweredType.replaceSubrange(
            resultStart..<resultEnd,
            with: rewrittenResult
        )
        return rewritten
    }

    private struct SubstitutionClause {
        var archetypes: [String]
        var substitutions: [String]
        var substitutionRange: Range<String.Index>
        var functionBody: String
        var outerParameters: [String]
    }

    private static func substitutionClause(
        in raw: String
    ) -> SubstitutionClause? {
        guard let marker = topLevelRange(of: "@substituted ", in: raw) else {
            return nil
        }
        let archetypeOpen = marker.upperBound
        guard archetypeOpen < raw.endIndex, raw[archetypeOpen] == "<",
              let archetypeClose = matchingClose(
                in: raw,
                from: archetypeOpen,
                open: "<",
                close: ">"
              ), let forRange = topLevelRange(
                of: " for ",
                in: raw,
                startingAt: raw.index(after: archetypeClose)
              )
        else { return nil }
        let substitutionOpen = forRange.upperBound
        guard substitutionOpen < raw.endIndex,
              raw[substitutionOpen] == "<",
              let substitutionClose = matchingClose(
                in: raw,
                from: substitutionOpen,
                open: "<",
                close: ">"
              ), raw[raw.index(after: substitutionClose)...]
                .trimmingCharacters(in: .whitespaces).isEmpty,
              let archetypes = try? CanonicalSIL.GenericSignature
                .splitTopLevel(String(raw[raw.index(
                    after: archetypeOpen
                )..<archetypeClose])),
              let substitutions = try? CanonicalSIL.GenericSignature
                .splitTopLevel(String(raw[raw.index(
                    after: substitutionOpen
                )..<substitutionClose])),
              !archetypes.isEmpty,
              archetypes.count == substitutions.count,
              archetypes.allSatisfy({
                $0.range(
                    of: #"^τ_[0-9]+_[0-9]+$"#,
                    options: .regularExpression
                ) != nil
              })
        else { return nil }
        let outerParameters = (try? CanonicalSIL.GenericSignature
            .functionSignature(in: raw)?.parameters) ?? []
        return .init(
            archetypes: archetypes,
            substitutions: substitutions,
            substitutionRange: substitutionOpen..<raw.index(
                after: substitutionClose
            ),
            functionBody: String(
                raw[raw.index(after: archetypeClose)..<forRange.lowerBound]
            ).trimmingCharacters(in: .whitespaces),
            outerParameters: outerParameters
        )
    }

    private static func entryOutputTypes(
        in body: String,
        count: Int
    ) -> [String]? {
        guard count > 0 else { return [] }
        guard let entry = body.split(separator: "\n").lazy.map({
            CanonicalSIL.DebugMetadata.strippingComment(from: String($0))
                .trimmingCharacters(in: .whitespaces)
        }).first(where: { $0.hasPrefix("bb0(") }),
              entry.hasSuffix("):")
        else { return nil }
        let contents = String(entry.dropFirst("bb0(".count).dropLast(2))
        guard let parameters = try? CanonicalSIL.GenericSignature
            .splitTopLevel(contents)
        else { return nil }
        var result: [String] = []
        guard parameters.count >= count else { return nil }
        for parameter in parameters.prefix(count) {
            guard let marker = parameter.range(of: " : $", options: .backwards)
            else { return nil }
            var type = parameter[marker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard type.first == "*" else { return nil }
            type.removeFirst()
            guard !type.isEmpty else { return nil }
            result.append(type)
        }
        return result
    }

    private static func resultComponents(_ raw: String) -> [String]? {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
        if spelling.first == "(", spelling.last == ")" {
            return try? CanonicalSIL.GenericSignature.splitTopLevel(
                String(spelling.dropFirst().dropLast())
            )
        }
        return [spelling]
    }

    private static func opaqueIdentity(
        in raw: String
    ) -> (symbol: String, index: UInt32, arguments: [String])? {
        let pattern = #"^@_opaqueReturnTypeOf\(\"([^\"]+)\",\s*([0-9]+)\) __(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw)
              ), match.range == NSRange(raw.startIndex..<raw.endIndex, in: raw),
              let symbolRange = Range(match.range(at: 1), in: raw),
              let indexRange = Range(match.range(at: 2), in: raw),
              let suffixRange = Range(match.range(at: 3), in: raw),
              let index = UInt32(raw[indexRange])
        else { return nil }
        let suffix = String(raw[suffixRange])
        let arguments: [String]
        if !suffix.isEmpty {
            guard suffix.first == "<", suffix.last == ">",
                  let close = matchingClose(
                    in: suffix,
                    from: suffix.startIndex,
                    open: "<",
                    close: ">"
                  ), close == suffix.index(before: suffix.endIndex),
                  let parsedArguments = try? CanonicalSIL.GenericSignature
                    .splitTopLevel(String(suffix.dropFirst().dropLast())),
                  !parsedArguments.isEmpty,
                  parsedArguments.allSatisfy({ !$0.isEmpty })
            else { return nil }
            arguments = parsedArguments
        } else {
            arguments = []
        }
        return (String(raw[symbolRange]), index, arguments)
    }

    private static func equivalentArguments(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            CanonicalSIL.GenericSignature.equivalentType($0, $1)
        }
    }

    private static func isConcreteUnderlyingType(
        _ raw: String,
        outerParameters: [String]
    ) -> Bool {
        guard !raw.isEmpty,
              !raw.contains("@_opaqueReturnTypeOf"),
              !raw.contains("@opened(")
        else { return false }
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_τ])τ_[0-9]+_[0-9]+(?![A-Za-z0-9_])"#
        ) else { return false }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let numbered = expression.matches(in: raw, range: range).compactMap {
            match -> String? in
            guard let range = Range(match.range, in: raw) else { return nil }
            return String(raw[range])
        }
        // Outer archetypes may remain here; the ordinary generic specializer
        // resolves them before the body becomes reachable. Any unrelated
        // archetype would require runtime generic metadata and is rejected.
        return numbered.allSatisfy(Set(outerParameters).contains)
    }

    private static func topLevelRange(
        of marker: String,
        in raw: String,
        startingAt start: String.Index? = nil
    ) -> Range<String.Index>? {
        var parentheses = 0
        var angles = 0
        var brackets = 0
        var quoted = false
        var escaped = false
        var index = start ?? raw.startIndex
        while index < raw.endIndex {
            if !quoted, parentheses == 0, angles == 0, brackets == 0,
               raw[index...].hasPrefix(marker) {
                return index..<raw.index(index, offsetBy: marker.count)
            }
            let character = raw[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else {
                switch character {
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "<": angles += 1
                case ">":
                    let previous = index > raw.startIndex
                        ? raw[raw.index(before: index)] : nil
                    if previous != "-" { angles -= 1 }
                case "[": brackets += 1
                case "]": brackets -= 1
                default: break
                }
            }
            guard parentheses >= 0, angles >= 0, brackets >= 0 else {
                return nil
            }
            index = raw.index(after: index)
        }
        return nil
    }

    private static func matchingClose(
        in raw: String,
        from openIndex: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var quoted = false
        var escaped = false
        var index = openIndex
        while index < raw.endIndex {
            let character = raw[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            guard depth >= 0 else { return nil }
            index = raw.index(after: index)
        }
        return nil
    }
}
}
