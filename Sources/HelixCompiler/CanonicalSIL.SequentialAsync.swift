import Foundation
import HelixCore

extension CanonicalSIL {
/// Normalizes the pinned Swift executor scaffolding around a sequential async
/// function. Suspension remains represented by exact direct `apply` and
/// `try_apply` instructions; task creation and async function values stay out
/// of the v1 execution model.
enum SequentialAsync {
    private static let concurrentInstructionMarkers = [
        "async_continuation", "await_async_continuation",
        "create_async_task", "createAsyncTask", "task_future_wait",
        "async_let", "asyncLet", "task_group", "taskGroup",
        "swift_asyncLet_", "swift_task_",
    ]

    private static let excludedConcurrencyTypeSpellings = [
        "Task<", "TaskGroup<", "ThrowingTaskGroup<", "TaskLocal<",
        "UnsafeCurrentTask", "CheckedContinuation<", "UnsafeContinuation<",
        "AsyncStream<", "AsyncThrowingStream<", "AsyncSequence",
        "AsyncIteratorProtocol",
    ]

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
        try validateSequentialInstructions(lines)
        let removed = try executorScaffolding(
            in: lines,
            requiresMainActor: effects.requiresMainActor
        )

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

    private static func validateSequentialInstructions(
        _ lines: [String]
    ) throws {
        for (index, line) in lines.enumerated() where !line.isEmpty {
            if containsConcurrentRuntimePrimitive(line) {
                throw unsupported(
                    line: index + 1,
                    reason: "task, async-let, task-group, continuation, and async-sequence primitives are outside sequential async"
                )
            }
            if line.contains("@async"), !isExactDirectAsyncCallLine(line) {
                throw unsupported(
                    line: index + 1,
                    reason: "async function and closure values are not supported"
                )
            }
        }
    }

    /// The canonical optimizer represents an awaited statically known callee
    /// as an ordinary direct apply whose function type carries `@async`.
    private static func isExactDirectAsyncCallLine(_ line: String) -> Bool {
        if line.range(
            of: #"^%[0-9]+ = function_ref @[^ ]+ : \$.+@async(?:\s|\()"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return line.range(
            of: #"^(?:(?:%[0-9]+) = )?(?:apply|try_apply) %[0-9]+(?:<.+>)?\(.*\) : \$.+@async(?:\s|\()"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsConcurrentRuntimePrimitive(
        _ line: String
    ) -> Bool {
        if concurrentInstructionMarkers.contains(where: line.contains) {
            return true
        }

        // These concrete standard-library spellings cover the source-level
        // concurrency facilities deliberately excluded from v1. Exact direct
        // app/native/image callees remain governed by their frozen bindings.
        return excludedConcurrencyTypeSpellings.contains(where: line.contains)
    }

    private static func executorScaffolding(
        in lines: [String],
        requiresMainActor: Bool
    ) throws -> Set<Int> {
        let hops = lines.indices.filter {
            lines[$0].hasPrefix("hop_to_executor ")
        }
        guard !hops.isEmpty else { return [] }

        var removed = Set<Int>()
        var scaffoldValues = Set<String>()
        var ownedMainActors = Set<String>()
        var borrowedMainActors = Set<String>()

        for hopIndex in hops {
            guard let hopOperand = capture(
                pattern: #"^hop_to_executor (%[0-9]+)$"#,
                in: lines[hopIndex]
            )?.first else {
                throw unsupported(
                    line: hopIndex + 1,
                    reason: "unknown executor-hop shape"
                )
            }

            if let definition = uniqueDefinition(of: hopOperand, in: lines),
               lines[definition].hasPrefix(
                   "\(hopOperand) = enum $Optional<any Actor>, #Optional.none!enumelt"
               ) {
                guard !requiresMainActor else {
                    throw unsupported(
                        line: hopIndex + 1,
                        reason: "a MainActor function cannot resume on the nonisolated executor"
                    )
                }
                removed.formUnion([definition, hopIndex])
                scaffoldValues.insert(hopOperand)
                continue
            }

            guard requiresMainActor else {
                throw unsupported(
                    line: hopIndex + 1,
                    reason: "custom actor and global-actor executor hops are not supported"
                )
            }
            let component = try mainActorComponent(
                hopIndex: hopIndex,
                hopOperand: hopOperand,
                lines: lines
            )
            removed.formUnion(component.lines)
            scaffoldValues.formUnion(component.values)
            ownedMainActors.insert(component.actor)
            if let borrowed = component.borrowed {
                borrowedMainActors.insert(borrowed)
            }
        }

        for index in lines.indices {
            if ownedMainActors.contains(where: { actor in
                lines[index] == "destroy_value \(actor)"
                    || lines[index] == "strong_release \(actor)"
            }) {
                removed.insert(index)
            }
            if borrowedMainActors.contains(where: { borrowed in
                lines[index] == "end_borrow \(borrowed)"
            }) {
                removed.insert(index)
            }
        }
        for actor in ownedMainActors {
            guard removed.contains(where: {
                lines[$0] == "destroy_value \(actor)"
                    || lines[$0] == "strong_release \(actor)"
            }) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "MainActor executor ownership has no matching release"
                )
            }
        }
        for borrowed in borrowedMainActors {
            guard removed.contains(where: {
                lines[$0] == "end_borrow \(borrowed)"
            }) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "MainActor executor borrow has no matching end_borrow"
                )
            }
        }

        try requireNoUses(
            of: scaffoldValues,
            outside: removed,
            lines: lines
        )
        return removed
    }

    private struct MainActorComponent {
        var lines: Set<Int>
        var values: Set<String>
        var actor: String
        var borrowed: String?
    }

    private static func mainActorComponent(
        hopIndex: Int,
        hopOperand: String,
        lines: [String]
    ) throws -> MainActorComponent {
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
                reason: "only the pinned MainActor.shared executor shape is supported"
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
        removed.formUnion([
            actorDefinition, getterDefinition, metatypeDefinition,
        ])
        var values: Set<String> = [hopOperand, actor, getter, metatype]
        if let borrowed { values.insert(borrowed) }
        return .init(
            lines: removed,
            values: values,
            actor: actor,
            borrowed: borrowed
        )
    }

    private static func uniqueDefinition(
        of value: String,
        in lines: [String]
    ) -> Int? {
        let matches = lines.indices.filter {
            lines[$0].hasPrefix("\(value) = ")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func requireNoUses(
        of values: Set<String>,
        outside removed: Set<Int>,
        lines: [String]
    ) throws {
        for index in lines.indices where !removed.contains(index) {
            let tokens = ssaValues(in: lines[index])
            if let value = values.first(where: { tokens.contains($0) }) {
                throw unsupported(
                    line: index + 1,
                    reason: "executor scaffold value \(value) escapes into the patch body"
                )
            }
        }
    }

    private static func containsAsyncConvention(_ type: String) -> Bool {
        type.range(
            of: #"(?:^|\s)@async(?:\s|$)"#,
            options: .regularExpression
        ) != nil
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
        guard let regex = try? NSRegularExpression(pattern: #"%[0-9]+"#)
        else { return [] }
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
            text: "sequential async profile: \(reason)"
        )
    }
}
}
