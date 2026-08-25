import Foundation
import HelixCore

extension CanonicalSIL {
/// Removes Swift's pinned synchronous MainActor executor assertion after the
/// function has acquired a verifier-visible MainActor effect. The VM enforces
/// the same condition before entering roots and native callbacks, so retaining
/// the compiler runtime scaffold would duplicate policy with opaque executor
/// values that are deliberately not representable in HLBC.
enum MainActorExecutorCheck {
    private struct Component {
        var removed: Set<Int>
        var replacement: (index: Int, line: String)?
        var values: Set<String>
        var actor: String
        var excludedBlocks: Set<String>
    }

    static func normalizedBody(
        _ body: String,
        effects: Core.Effects
    ) throws -> String {
        let rawLines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let lines = rawLines.map(semanticLine)
        let metatypes = lines.indices.filter {
            lines[$0].range(
                of: #"^%[0-9]+ = metatype \$@thick MainActor\.Type$"#,
                options: .regularExpression
            ) != nil
        }
        guard !metatypes.isEmpty else { return body }
        guard effects.requiresMainActor else {
            throw unsupported(
                line: metatypes[0] + 1,
                reason: "a nonisolated function contains a MainActor executor assertion"
            )
        }
        guard metatypes.count == 1 else {
            throw unsupported(
                line: metatypes[1] + 1,
                reason: "a function contains multiple MainActor executor assertions"
            )
        }

        var removed = Set<Int>()
        var replacements: [Int: String] = [:]
        var excludedBlocks = Set<String>()
        for metatype in metatypes {
            let component = try component(
                metatypeIndex: metatype,
                lines: lines
            )
            removed.formUnion(component.removed)
            excludedBlocks.formUnion(component.excludedBlocks)
            if let replacement = component.replacement {
                guard replacements.updateValue(
                    replacement.line,
                    forKey: replacement.index
                ) == nil else {
                    throw unsupported(
                        line: replacement.index + 1,
                        reason: "overlapping MainActor executor assertions"
                    )
                }
            }
            let releaseLines = lines.indices.filter {
                [
                    "strong_release \(component.actor)",
                    "release_value \(component.actor)",
                    "destroy_value \(component.actor)",
                ].contains(lines[$0])
            }
            guard releaseLines.count == 1 else {
                throw unsupported(
                    line: metatype + 1,
                    reason: "MainActor assertion ownership has no unique release"
                )
            }
            removed.insert(releaseLines[0])
            var values = component.values
            values.insert(component.actor)
            try requireNoUses(
                of: values,
                outside: removed,
                replacements: Set(replacements.keys),
                lines: lines
            )
        }
        try requireNoReferences(
            to: excludedBlocks,
            outside: removed,
            replacements: Set(replacements.keys),
            lines: lines
        )

        return rawLines.indices.map { index in
            if let replacement = replacements[index] { return replacement }
            return removed.contains(index) ? "" : rawLines[index]
        }.joined(separator: "\n")
    }

    private static func component(
        metatypeIndex: Int,
        lines: [String]
    ) throws -> Component {
        guard let metatype = resultValue(in: lines[metatypeIndex]),
              let actorApply = uniqueIndex(in: lines, matching: { line in
                  line.range(
                      of: #"^%[0-9]+ = apply %[0-9]+\(%[0-9]+\) : \$@convention\(method\).+@thick MainActor\.Type.+@owned MainActor$"#,
                      options: .regularExpression
                  ) != nil && orderedSSAValues(in: line)?.last == metatype
              }),
              let actor = resultValue(in: lines[actorApply]),
              let applyValues = orderedSSAValues(in: lines[actorApply]),
              applyValues.count == 3,
              let getterDefinition = uniqueDefinition(
                  of: applyValues[1],
                  in: lines
              ),
              lines[getterDefinition].hasPrefix(
                  "\(applyValues[1]) = function_ref @$sScM6sharedScMvgZ :"
              ),
              let executorDefinition = uniqueIndex(
                  in: lines,
                  matching: {
                      $0.range(
                          of: #"^%[0-9]+ = extract_executor %[0-9]+$"#,
                          options: .regularExpression
                      ) != nil && orderedSSAValues(in: $0)?.last == actor
                  }
              ),
              let executor = resultValue(in: lines[executorDefinition])
        else {
            throw unsupported(
                line: metatypeIndex + 1,
                reason: "MainActor executor assertion does not use the pinned shared actor ABI"
            )
        }

        var baseRemoved: Set<Int> = [
            metatypeIndex, getterDefinition, actorApply, executorDefinition,
        ]
        var values: Set<String> = [
            metatype, applyValues[1], actor, executor,
        ]

        if let direct = try directCheck(
            executor: executor,
            lines: lines
        ) {
            baseRemoved.formUnion(direct.removed)
            values.formUnion(direct.values)
            return .init(
                removed: baseRemoved,
                replacement: nil,
                values: values,
                actor: actor,
                excludedBlocks: []
            )
        }
        let branching = try branchingCheck(
            executor: executor,
            lines: lines
        )
        baseRemoved.formUnion(branching.removed)
        values.formUnion(branching.values)
        return .init(
            removed: baseRemoved,
            replacement: branching.replacement,
            values: values,
            actor: actor,
            excludedBlocks: branching.excludedBlocks
        )
    }

    private static func directCheck(
        executor: String,
        lines: [String]
    ) throws -> (removed: Set<Int>, values: Set<String>)? {
        let references = lines.indices.filter {
            lines[$0].range(
                of: #"^%[0-9]+ = function_ref @\$ss22_checkExpectedExecutor[^ ]* :"#,
                options: .regularExpression
            ) != nil
        }
        guard !references.isEmpty else { return nil }
        guard references.count == 1,
              let function = resultValue(in: lines[references[0]]),
              let apply = uniqueIndex(in: lines, matching: { line in
                  line.hasPrefix("apply \(function)(")
                      || line.range(
                          of: #"^%[0-9]+ = apply \#(NSRegularExpression.escapedPattern(for: function))\("#,
                          options: .regularExpression
                      ) != nil
              }),
              let arguments = appliedArguments(
                  function: function,
                  in: lines[apply]
              ),
              arguments.count == 5,
              arguments.last == executor
        else {
            throw unsupported(
                line: references[0] + 1,
                reason: "unknown _checkExpectedExecutor ABI"
            )
        }
        let diagnostics = try diagnosticDefinitions(
            Array(arguments.dropLast()),
            lines: lines,
            line: apply + 1
        )
        return (
            Set([references[0], apply] + diagnostics.indices),
            Set([function] + arguments + diagnostics.values)
        )
    }

    private static func branchingCheck(
        executor: String,
        lines: [String]
    ) throws -> (
        removed: Set<Int>,
        replacement: (index: Int, line: String),
        values: Set<String>,
        excludedBlocks: Set<String>
    ) {
        guard let currentReference = uniqueIndex(
            in: lines,
            matching: {
                $0.range(
                    of: #"^%[0-9]+ = function_ref @swift_task_isCurrentExecutor :"#,
                    options: .regularExpression
                ) != nil
            }
        ), let currentFunction = resultValue(in: lines[currentReference]),
           let currentApply = uniqueIndex(in: lines, matching: { line in
               appliedArguments(function: currentFunction, in: line)
                   == [executor]
           }), let currentResult = resultValue(in: lines[currentApply]),
           let extract = uniqueIndex(in: lines, matching: { line in
               line.hasSuffix("struct_extract \(currentResult), #Bool._value")
           }), let condition = resultValue(in: lines[extract]),
           let branch = uniqueIndex(in: lines, matching: { line in
               line.hasPrefix("cond_br \(condition), ")
           }), let targets = capture(
               pattern: #"^cond_br %[0-9]+, (bb[0-9]+), (bb[0-9]+)$"#,
               in: lines[branch]
           ), targets.count == 2,
           let successLabel = uniqueBlockLabel(targets[0], in: lines),
           let failureLabel = uniqueBlockLabel(targets[1], in: lines),
           let successBranch = nextSemanticIndex(after: successLabel, in: lines),
           let join = capture(
               pattern: #"^br (bb[0-9]+)$"#,
               in: lines[successBranch]
           )?.first,
           let reportReference = nextSemanticIndex(
               after: failureLabel,
               in: lines
           ), lines[reportReference].range(
               of: #"^%[0-9]+ = function_ref @swift_task_reportUnexpectedExecutor :"#,
               options: .regularExpression
           ) != nil,
           let reportFunction = resultValue(in: lines[reportReference]),
           let reportApply = nextSemanticIndex(
               after: reportReference,
               in: lines
           ), let reportArguments = appliedArguments(
               function: reportFunction,
               in: lines[reportApply]
           ), reportArguments.count == 5,
           reportArguments.last == executor,
           let failureBranch = nextSemanticIndex(
               after: reportApply,
               in: lines
           ), lines[failureBranch] == "br \(join)"
        else {
            throw unsupported(
                line: currentReferenceOrFirstExecutorUse(
                    executor,
                    lines: lines
                ) + 1,
                reason: "unknown swift_task MainActor assertion control flow"
            )
        }
        let diagnostics = try diagnosticDefinitions(
            Array(reportArguments.dropLast()),
            lines: lines,
            line: reportApply + 1
        )
        let removed = Set([
            currentReference, currentApply, extract, branch,
            successLabel, successBranch, failureLabel,
            reportReference, reportApply, failureBranch,
        ] + diagnostics.indices)
        return (
            removed,
            (branch, "  br \(join)"),
            Set(
                [
                    currentFunction, currentResult, condition,
                    reportFunction, executor,
                ] + reportArguments + diagnostics.values
            ),
            Set(targets)
        )
    }

    private static func diagnosticDefinitions(
        _ values: [String],
        lines: [String],
        line: Int
    ) throws -> (indices: [Int], values: [String]) {
        guard values.count == 4 else {
            throw unsupported(
                line: line,
                reason: "MainActor executor diagnostic payload has the wrong arity"
            )
        }
        var indices: [Int] = []
        for (offset, value) in values.enumerated() {
            guard let definition = uniqueDefinition(of: value, in: lines) else {
                throw unsupported(
                    line: line,
                    reason: "MainActor executor diagnostic value has no unique definition"
                )
            }
            let valid: Bool = switch offset {
            case 0:
                lines[definition].hasPrefix("\(value) = string_literal utf8 ")
            case 1, 3:
                lines[definition].hasPrefix(
                    "\(value) = integer_literal $Builtin.Word, "
                )
            case 2:
                lines[definition].hasPrefix(
                    "\(value) = integer_literal $Builtin.Int1, "
                )
            default:
                false
            }
            guard valid else {
                throw unsupported(
                    line: definition + 1,
                    reason: "MainActor executor diagnostic payload changed ABI"
                )
            }
            indices.append(definition)
        }
        return (indices, values)
    }

    private static func appliedArguments(
        function: String,
        in line: String
    ) -> [String]? {
        guard let range = line.range(of: "apply \(function)(") else {
            return nil
        }
        let start = range.upperBound
        guard let close = line[start...].firstIndex(of: ")") else {
            return nil
        }
        let body = line[start..<close]
        if body.isEmpty { return [] }
        let arguments = body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return arguments.allSatisfy(isSSAValue) ? arguments : nil
    }

    private static func currentReferenceOrFirstExecutorUse(
        _ executor: String,
        lines: [String]
    ) -> Int {
        lines.firstIndex { ssaValues(in: $0).contains(executor) } ?? 0
    }

    private static func uniqueBlockLabel(
        _ block: String,
        in lines: [String]
    ) -> Int? {
        let indices = lines.indices.filter { lines[$0] == "\(block):" }
        return indices.count == 1 ? indices[0] : nil
    }

    private static func nextSemanticIndex(
        after index: Int,
        in lines: [String]
    ) -> Int? {
        lines.indices.dropFirst(index + 1).first { !lines[$0].isEmpty }
    }

    private static func uniqueDefinition(
        of value: String,
        in lines: [String]
    ) -> Int? {
        uniqueIndex(in: lines) { $0.hasPrefix("\(value) = ") }
    }

    private static func uniqueIndex(
        in lines: [String],
        matching predicate: (String) -> Bool
    ) -> Int? {
        let indices = lines.indices.filter { predicate(lines[$0]) }
        return indices.count == 1 ? indices[0] : nil
    }

    private static func resultValue(in line: String) -> String? {
        guard let separator = line.range(of: " = ") else { return nil }
        let value = String(line[..<separator.lowerBound])
        return isSSAValue(value) ? value : nil
    }

    private static func orderedSSAValues(in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: #"%[0-9]+"#)
        else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range, in: line).map { String(line[$0]) }
        }
    }

    private static func ssaValues(in line: String) -> Set<String> {
        Set(orderedSSAValues(in: line) ?? [])
    }

    private static func isSSAValue(_ value: String) -> Bool {
        value.range(
            of: #"^%[0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func requireNoUses(
        of values: Set<String>,
        outside removed: Set<Int>,
        replacements: Set<Int>,
        lines: [String]
    ) throws {
        for index in lines.indices
        where !removed.contains(index) && !replacements.contains(index) {
            if let value = values.first(where: {
                ssaValues(in: lines[index]).contains($0)
            }) {
                throw unsupported(
                    line: index + 1,
                    reason: "MainActor assertion value \(value) escapes its compiler scaffold"
                )
            }
        }
    }

    private static func requireNoReferences(
        to blocks: Set<String>,
        outside removed: Set<Int>,
        replacements: Set<Int>,
        lines: [String]
    ) throws {
        guard !blocks.isEmpty else { return }
        for index in lines.indices
        where !removed.contains(index) && !replacements.contains(index) {
            let words = Set(lines[index].split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "_"
            }).map(String.init))
            if let block = blocks.first(where: words.contains) {
                throw unsupported(
                    line: index + 1,
                    reason: "MainActor assertion block \(block) has an external predecessor"
                )
            }
        }
    }

    private static func semanticLine(_ raw: String) -> String {
        let body: Substring
        if let comment = raw.range(of: " //") {
            body = raw[..<comment.lowerBound]
        } else {
            body = raw[...]
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func capture(
        pattern: String,
        in line: String
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..., in: line)
              ), match.range == NSRange(line.startIndex..., in: line)
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map {
                String(line[$0])
            }
        }
    }

    private static func unsupported(
        line: Int,
        reason: String
    ) -> CanonicalSIL.LoweringError {
        .unsupportedInstruction(
            line: line,
            text: "MainActor executor assertion: \(reason)"
        )
    }
}
}
