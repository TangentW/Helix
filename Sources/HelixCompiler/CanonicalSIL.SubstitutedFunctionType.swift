import Foundation

extension CanonicalSIL {
enum SubstitutedFunctionType {
    /// Rewrites SIL's fully concrete `@substituted ... for ...` function
    /// spelling into the ordinary lowered function type understood by the
    /// portable type system. Archetypes are accepted only when every one has
    /// an exact concrete substitution; partially specialized functions remain
    /// outside the image contract.
    static func specialize(_ raw: String) throws -> String {
        var result = raw
        while let marker = topLevelSubstitutionMarker(in: result) {
            let genericOpen = result[marker.upperBound...].firstIndex(of: "<")
            guard let genericOpen,
                  let genericClose = matchingClosingAngle(
                    for: genericOpen,
                    in: result
                  )
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has an invalid archetype list"
                )
            }

            let trimmedEnd = result[..<result.endIndex].lastIndex {
                !$0.isWhitespace
            }
            guard let trimmedEnd, result[trimmedEnd] == ">",
                  let substitutionOpen = matchingOpeningAngle(
                    for: trimmedEnd,
                    in: result
                  )
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has no concrete substitution list"
                )
            }
            guard let beforeSubstitutionsEnd = result[..<substitutionOpen]
                .lastIndex(where: { !$0.isWhitespace })
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has no trailing for-clause"
                )
            }
            let afterFor = result.index(after: beforeSubstitutionsEnd)
            guard result.distance(
                from: result.startIndex,
                to: afterFor
            ) >= " for".count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has no trailing for-clause"
                )
            }
            let forStart = result.index(
                afterFor,
                offsetBy: -" for".count
            )
            guard result[forStart..<afterFor] == " for" else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has no trailing for-clause"
                )
            }
            guard genericClose < forStart else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type has an empty function body"
                )
            }

            guard let archetypes = splitTopLevel(
                String(result[result.index(after: genericOpen)..<genericClose])
            ), let substitutions = splitTopLevel(
                String(result[result.index(after: substitutionOpen)..<trimmedEnd])
            ), !archetypes.isEmpty,
                  archetypes.count == substitutions.count,
                  archetypes.allSatisfy(isArchetype),
                  substitutions.allSatisfy({
                    !$0.isEmpty && !containsArchetypeSpelling(in: $0)
                  })
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type does not have a one-to-one concrete substitution"
                )
            }

            var body = String(result[result.index(after: genericClose)..<forStart])
                .trimmingCharacters(in: .whitespaces)
            for (archetype, substitution) in zip(archetypes, substitutions)
                .sorted(by: { $0.0.count > $1.0.count }) {
                body = try replacingArchetype(
                    archetype,
                    with: substitution,
                    in: body
                )
            }
            guard !containsArchetype(from: archetypes, in: body) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "substituted function type retains an unspecialized archetype"
                )
            }

            let prefix = result[..<marker.lowerBound]
            let suffix = result[result.index(after: trimmedEnd)...]
            result = String(prefix) + body + String(suffix)
        }
        return result
    }

    private static func topLevelSubstitutionMarker(
        in text: String
    ) -> Range<String.Index>? {
        let marker = "@substituted "
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            if parenthesisDepth == 0,
               angleDepth == 0,
               bracketDepth == 0,
               text[index...].hasPrefix(marker) {
                return index..<text.index(index, offsetBy: marker.count)
            }
            switch text[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isArchetype(_ raw: String) -> Bool {
        raw.range(
            of: #"^τ_[0-9]+_[0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsArchetypeSpelling(in raw: String) -> Bool {
        raw.range(
            of: #"(?<![A-Za-z0-9_τ])τ_[0-9]+_[0-9]+(?![A-Za-z0-9_])"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsArchetype(
        from archetypes: [String],
        in body: String
    ) -> Bool {
        archetypes.contains { archetype in
            body.range(
                of: tokenPattern(archetype),
                options: .regularExpression
            ) != nil
        }
    }

    private static func replacingArchetype(
        _ archetype: String,
        with substitution: String,
        in body: String
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: tokenPattern(archetype))
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return expression.stringByReplacingMatches(
            in: body,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: substitution)
        )
    }

    private static func tokenPattern(_ archetype: String) -> String {
        #"(?<![A-Za-z0-9_τ])"#
            + NSRegularExpression.escapedPattern(for: archetype)
            + #"(?![A-Za-z0-9_])"#
    }

    private static func matchingClosingAngle(
        for open: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "<":
                depth += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            default:
                break
            }
            guard depth >= 0 else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingOpeningAngle(
        for close: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var index = close
        while true {
            switch text[index] {
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depth += 1 }
            case "<":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            guard depth >= 0, index > text.startIndex else { return nil }
            index = text.index(before: index)
        }
    }

    private static func splitTopLevel(_ raw: String) -> [String]? {
        var result: [String] = []
        var start = raw.startIndex
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "," where parenthesisDepth == 0
                    && angleDepth == 0
                    && bracketDepth == 0:
                result.append(
                    String(raw[start..<index])
                        .trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            default:
                break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
        }
        guard parenthesisDepth == 0,
              angleDepth == 0,
              bracketDepth == 0
        else { return nil }
        result.append(
            String(raw[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result
    }
}
}
