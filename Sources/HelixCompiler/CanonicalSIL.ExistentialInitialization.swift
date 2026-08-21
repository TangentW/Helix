import Foundation

extension CanonicalSIL {
/// Inventories concrete writes into `init_existential_addr` projections before
/// instruction emission. Canonical SIL may initialize one projection on
/// mutually exclusive blocks; lowering needs to retain the projection until
/// its final textual write while routing the runtime values through SSA edges.
enum ExistentialInitialization {
    struct Plan: Equatable, Sendable {
        fileprivate var finalWriteLines: [String: Int]

        func hasWrite(
            to projection: String,
            after line: Int
        ) -> Bool {
            guard let final = finalWriteLines[projection] else { return false }
            return final > line
        }
    }

    static func analyze(body: String) throws -> Plan {
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map {
            CanonicalSIL.DebugMetadata.strippingMetadata(from: String($0))
                .trimmingCharacters(in: .whitespaces)
        }
        let projectionPattern = try NSRegularExpression(
            pattern: #"^(%[0-9]+) = init_existential_addr %[0-9]+, \$.+$"#
        )
        let componentPattern = try NSRegularExpression(
            pattern: #"^(%[0-9]+) = tuple_element_addr (%[0-9]+), [0-9]+$"#
        )
        let storePattern = try NSRegularExpression(
            pattern: #"^store %[0-9]+ to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
        )
        let copyPattern = try NSRegularExpression(
            pattern: #"^copy_addr(?: \[take\])? %[0-9]+ to (?:\[(?:init|assign)\] )?(%[0-9]+)$"#
        )
        let valuePattern = try NSRegularExpression(pattern: #"%[0-9]+"#)

        let projections = Set(
            lines.compactMap { capture(projectionPattern, in: $0, at: 1) }
        )
        var projectionByComponent: [String: String] = [:]
        for line in lines {
            guard let component = capture(componentPattern, in: line, at: 1),
                  let projection = capture(componentPattern, in: line, at: 2),
                  projections.contains(projection)
            else { continue }
            guard projectionByComponent.updateValue(
                projection,
                forKey: component
            ) == nil else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "existential tuple component is projected more than once"
                )
            }
        }

        var finalWriteLines: [String: Int] = [:]
        for (lineIndex, line) in lines.enumerated() {
            if let destination = capture(storePattern, in: line, at: 1)
                ?? capture(copyPattern, in: line, at: 1) {
                let projection = projections.contains(destination)
                    ? destination : projectionByComponent[destination]
                if let projection {
                    finalWriteLines[projection] = lineIndex
                }
            }

            if (line.contains(" = apply ") || line.hasPrefix("apply ")),
               line.contains("@out") {
                for token in captures(valuePattern, in: line) {
                    let appliedProjection = projections.contains(token)
                        ? token : projectionByComponent[token]
                    if let appliedProjection {
                        finalWriteLines[appliedProjection] = lineIndex
                    }
                }
            }
        }
        return .init(finalWriteLines: finalWriteLines)
    }

    private static func capture(
        _ expression: NSRegularExpression,
        in text: String,
        at index: Int
    ) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > index,
              let captureRange = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    private static func captures(
        _ expression: NSRegularExpression,
        in text: String
    ) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
}
