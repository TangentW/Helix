import Foundation
import HelixCompiler

extension BuildPerformance {
public final class Recorder: @unchecked Sendable {
    private struct StageAccumulator {
        var invocationCount: UInt64 = 0
        var durationMicroseconds: UInt64 = 0
    }

    private struct SubprocessKey: Hashable {
        var kind: SwiftFrontend.InvocationKind
        var executableName: String
    }

    private struct SubprocessAccumulator {
        var invocationCount: UInt64 = 0
        var failureCount: UInt64 = 0
        var durationMicroseconds: UInt64 = 0
        var standardOutputBytes: UInt64 = 0
        var standardErrorBytes: UInt64 = 0
    }

    private struct State {
        var stages: [String: StageAccumulator] = [:]
        var subprocesses: [SubprocessKey: SubprocessAccumulator] = [:]
        var counters: [String: UInt64] = [:]
        var artifacts: [String: UInt64] = [:]
    }

    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private let startedAt: UInt64
    private var state = State()

    public init(
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        now = monotonicNanoseconds
        startedAt = monotonicNanoseconds()
    }

    public var subprocessObserver: SwiftFrontend.InvocationObserver {
        { [weak self] metric in self?.record(metric) }
    }

    public func measure<Value>(
        _ name: String,
        _ operation: () throws -> Value
    ) rethrows -> Value {
        let start = now()
        defer { recordStage(name, elapsedSince: start) }
        return try operation()
    }

    public func measure<Value>(
        _ name: String,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let start = now()
        defer { recordStage(name, elapsedSince: start) }
        return try await operation()
    }

    public func setCounter(_ name: String, value: UInt64) {
        lock.withLock { state.counters[name] = value }
    }

    public func incrementCounter(_ name: String, by value: UInt64 = 1) {
        lock.withLock {
            state.counters[name] = Self.adding(state.counters[name] ?? 0, value)
        }
    }

    public func recordArtifact(relativePath: String, byteCount: UInt64) {
        lock.withLock { state.artifacts[relativePath] = byteCount }
    }

    public func merge(_ trace: BuildPerformance.Trace) {
        lock.withLock {
            for stage in trace.stages {
                var value = state.stages[stage.name] ?? .init()
                value.invocationCount = Self.adding(
                    value.invocationCount,
                    stage.invocationCount
                )
                value.durationMicroseconds = Self.adding(
                    value.durationMicroseconds,
                    stage.durationMicroseconds
                )
                state.stages[stage.name] = value
            }
            for subprocess in trace.subprocesses {
                let key = SubprocessKey(
                    kind: subprocess.kind,
                    executableName: subprocess.executableName
                )
                var value = state.subprocesses[key] ?? .init()
                value.invocationCount = Self.adding(
                    value.invocationCount,
                    subprocess.invocationCount
                )
                value.failureCount = Self.adding(
                    value.failureCount,
                    subprocess.failureCount
                )
                value.durationMicroseconds = Self.adding(
                    value.durationMicroseconds,
                    subprocess.durationMicroseconds
                )
                value.standardOutputBytes = Self.adding(
                    value.standardOutputBytes,
                    subprocess.standardOutputBytes
                )
                value.standardErrorBytes = Self.adding(
                    value.standardErrorBytes,
                    subprocess.standardErrorBytes
                )
                state.subprocesses[key] = value
            }
            for counter in trace.counters {
                state.counters[counter.name] = Self.adding(
                    state.counters[counter.name] ?? 0,
                    counter.value
                )
            }
            for artifact in trace.artifacts {
                state.artifacts[artifact.relativePath] = artifact.byteCount
            }
        }
    }

    public func trace() -> BuildPerformance.Trace {
        lock.withLock {
            BuildPerformance.Trace(
                stages: state.stages.map {
                    .init(
                        name: $0.key,
                        invocationCount: $0.value.invocationCount,
                        durationMicroseconds: $0.value.durationMicroseconds
                    )
                }.sorted { $0.name < $1.name },
                subprocesses: state.subprocesses.map {
                    .init(
                        kind: $0.key.kind,
                        executableName: $0.key.executableName,
                        invocationCount: $0.value.invocationCount,
                        failureCount: $0.value.failureCount,
                        durationMicroseconds: $0.value.durationMicroseconds,
                        standardOutputBytes: $0.value.standardOutputBytes,
                        standardErrorBytes: $0.value.standardErrorBytes
                    )
                }.sorted {
                    ($0.kind.rawValue, $0.executableName)
                        < ($1.kind.rawValue, $1.executableName)
                },
                counters: state.counters.map {
                    .init(name: $0.key, value: $0.value)
                }.sorted { $0.name < $1.name },
                artifacts: state.artifacts.map {
                    .init(relativePath: $0.key, byteCount: $0.value)
                }.sorted { $0.relativePath < $1.relativePath }
            )
        }
    }

    public func report(
        operation: BuildPerformance.Operation,
        workflow: BuildPerformance.Workflow,
        outcome: BuildPerformance.Outcome
    ) throws -> BuildPerformance.Report {
        try .init(
            operation: operation,
            workflow: workflow,
            outcome: outcome,
            totalDurationMicroseconds: Self.microseconds(now() &- startedAt),
            trace: trace()
        )
    }

    private func record(_ metric: SwiftFrontend.InvocationMetric) {
        lock.withLock {
            let key = SubprocessKey(
                kind: metric.kind,
                executableName: metric.executableName
            )
            var value = state.subprocesses[key] ?? .init()
            value.invocationCount = Self.adding(value.invocationCount, 1)
            if metric.terminationStatus.map({ $0 != 0 }) ?? true {
                value.failureCount = Self.adding(value.failureCount, 1)
            }
            value.durationMicroseconds = Self.adding(
                value.durationMicroseconds,
                metric.durationMicroseconds
            )
            value.standardOutputBytes = Self.adding(
                value.standardOutputBytes,
                metric.standardOutputBytes
            )
            value.standardErrorBytes = Self.adding(
                value.standardErrorBytes,
                metric.standardErrorBytes
            )
            state.subprocesses[key] = value
        }
    }

    private func recordStage(_ name: String, elapsedSince start: UInt64) {
        let duration = Self.microseconds(now() &- start)
        lock.withLock {
            var value = state.stages[name] ?? .init()
            value.invocationCount = Self.adding(value.invocationCount, 1)
            value.durationMicroseconds = Self.adding(
                value.durationMicroseconds,
                duration
            )
            state.stages[name] = value
        }
    }

    private static func microseconds(_ nanoseconds: UInt64) -> UInt64 {
        nanoseconds / 1_000
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
}
