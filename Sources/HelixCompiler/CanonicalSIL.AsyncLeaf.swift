import Foundation
import HelixCore

extension CanonicalSIL {
/// Qualifies Swift async entries whose HLVM segment cannot suspend. The exact
/// Swift wrapper retains the async ABI and executor hop; this normalizer removes
/// only the pinned compiler's matching prologue before ordinary SIL lowering.
enum AsyncLeaf {
    static func normalizedBody(
        of function: CanonicalSIL.Function,
        effects: Core.Effects
    ) throws -> String {
        guard effects.isAsync else { return function.body }
        guard containsAsyncConvention(function.loweredType) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "an async archive entry has a synchronous SIL convention"
            )
        }

        let rawLines = function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let lines = rawLines.map(semanticLine)

        for (index, line) in lines.enumerated() where !line.isEmpty {
            if line.contains("@async") {
                throw unsupported(
                    line: index + 1,
                    reason: "async calls and async closure values can suspend"
                )
            }
            if containsSuspensionPrimitive(line) {
                throw unsupported(
                    line: index + 1,
                    reason: "async continuation and task primitives are not part of the leaf profile"
                )
            }
        }

        let hops = lines.indices.filter { lines[$0].hasPrefix("hop_to_executor ") }
        guard hops.count == 1 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "an async leaf must contain exactly one compiler executor prologue"
            )
        }
        let hopIndex = hops[0]
        guard let hopOperand = capture(
            pattern: #"^hop_to_executor (%[0-9]+)$"#,
            in: lines[hopIndex]
        )?.first else {
            throw unsupported(line: hopIndex + 1, reason: "unknown executor-hop shape")
        }

        let removed = if effects.requiresMainActor {
            try mainActorPrologue(
                hopIndex: hopIndex,
                hopOperand: hopOperand,
                lines: lines
            )
        } else {
            try nonisolatedPrologue(
                hopIndex: hopIndex,
                hopOperand: hopOperand,
                lines: lines
            )
        }

        var normalized = rawLines
        for index in removed { normalized[index] = "" }
        return normalized.joined(separator: "\n")
    }

    static func validate(
        _ function: CanonicalSIL.Function,
        effects: Core.Effects
    ) throws {
        _ = try normalizedBody(of: function, effects: effects)
    }

    private static func nonisolatedPrologue(
        hopIndex: Int,
        hopOperand: String,
        lines: [String]
    ) throws -> Set<Int> {
        guard let definition = uniqueDefinition(of: hopOperand, in: lines),
              lines[definition].hasPrefix(
                "\(hopOperand) = enum $Optional<any Actor>, #Optional.none!enumelt"
              )
        else {
            throw unsupported(
                line: hopIndex + 1,
                reason: "only the nonisolated Optional.none executor prologue is supported"
            )
        }
        let removed: Set<Int> = [definition, hopIndex]
        try requireNoUses(of: [hopOperand], outside: removed, lines: lines)
        return removed
    }

    private static func mainActorPrologue(
        hopIndex: Int,
        hopOperand: String,
        lines: [String]
    ) throws -> Set<Int> {
        var removed: Set<Int> = [hopIndex]
        var actor = hopOperand
        var borrowed: String?

        if let definition = uniqueDefinition(of: hopOperand, in: lines),
           let source = capture(
               pattern: #"^%[0-9]+ = begin_borrow (%[0-9]+)$"#,
               in: lines[definition]
           )?.first {
            borrowed = hopOperand
            actor = source
            removed.insert(definition)
        }

        guard let actorDefinition = uniqueDefinition(of: actor, in: lines),
              let apply = capture(
                  pattern: #"^%[0-9]+ = apply (%[0-9]+)\((%[0-9]+)\) : \$@convention\(method\).+MainActor$"#,
                  in: lines[actorDefinition]
              ),
              apply.count == 2
        else {
            throw unsupported(
                line: hopIndex + 1,
                reason: "only the pinned MainActor.shared executor prologue is supported"
            )
        }
        let getter = apply[0]
        let metatype = apply[1]
        guard let getterDefinition = uniqueDefinition(of: getter, in: lines),
              lines[getterDefinition].hasPrefix(
                "\(getter) = function_ref @$sScM6sharedScMvgZ :"
              ),
              let metatypeDefinition = uniqueDefinition(of: metatype, in: lines),
              lines[metatypeDefinition]
                == "\(metatype) = metatype $@thick MainActor.Type"
        else {
            throw unsupported(
                line: hopIndex + 1,
                reason: "MainActor executor identity does not match the pinned Swift ABI"
            )
        }
        removed.formUnion([actorDefinition, getterDefinition, metatypeDefinition])

        for index in lines.indices {
            if let borrowed, lines[index] == "end_borrow \(borrowed)" {
                removed.insert(index)
            }
            if lines[index] == "destroy_value \(actor)"
                || lines[index] == "strong_release \(actor)" {
                removed.insert(index)
            }
        }
        guard removed.contains(where: {
            lines[$0] == "destroy_value \(actor)" || lines[$0] == "strong_release \(actor)"
        }) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "MainActor executor ownership has no matching release"
            )
        }
        if let borrowed,
           !removed.contains(where: { lines[$0] == "end_borrow \(borrowed)" }) {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "MainActor executor borrow has no matching end_borrow"
            )
        }

        try requireNoUses(
            of: [hopOperand, actor, getter, metatype],
            outside: removed,
            lines: lines
        )
        return removed
    }

    private static func uniqueDefinition(
        of value: String,
        in lines: [String]
    ) -> Int? {
        let matches = lines.indices.filter { lines[$0].hasPrefix("\(value) = ") }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func requireNoUses(
        of values: [String],
        outside removed: Set<Int>,
        lines: [String]
    ) throws {
        for index in lines.indices where !removed.contains(index) {
            let tokens = ssaValues(in: lines[index])
            if let value = values.first(where: { tokens.contains($0) }) {
                throw unsupported(
                    line: index + 1,
                    reason: "executor prologue value \(value) escapes into the patch body"
                )
            }
        }
    }

    private static func containsAsyncConvention(_ type: String) -> Bool {
        type.range(of: #"(?:^|\s)@async(?:\s|$)"#, options: .regularExpression) != nil
    }

    private static func containsSuspensionPrimitive(_ line: String) -> Bool {
        [
            "async_continuation", "create_async_task", "createAsyncTask",
            "task_future_wait", "swift_task_",
        ].contains(where: line.contains)
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

    private static func ssaValues(in line: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"%[0-9]+"#) else {
            return []
        }
        let range = NSRange(line.startIndex..., in: line)
        return Set(regex.matches(in: line, range: range).compactMap { match in
            Range(match.range, in: line).map { String(line[$0]) }
        })
    }

    private static func capture(pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..., in: line)
              ),
              match.range == NSRange(line.startIndex..., in: line)
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
    }

    private static func unsupported(
        line: Int,
        reason: String
    ) -> CanonicalSIL.LoweringError {
        .unsupportedInstruction(
            line: line,
            text: "async leaf profile: \(reason)"
        )
    }
}
}
