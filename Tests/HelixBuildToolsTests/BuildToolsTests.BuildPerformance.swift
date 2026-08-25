import Foundation
import HelixCompiler
import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Local build performance telemetry")
struct BuildPerformanceTelemetry {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64]

        init(_ values: [UInt64]) {
            self.values = values
        }

        func next() -> UInt64 {
            lock.withLock {
                precondition(!values.isEmpty)
                return values.removeFirst()
            }
        }
    }

    @Test("Recorder aggregates deterministic stages, counters, artifacts, and subprocesses")
    func recordsDeterministicTrace() throws {
        let clock = Clock([0, 1_000, 5_000, 12_000])
        let recorder = BuildPerformance.Recorder(
            monotonicNanoseconds: { clock.next() }
        )
        let value = recorder.measure("prepare.frontend") { 42 }
        #expect(value == 42)
        recorder.setCounter("source_count", value: 2)
        recorder.incrementCounter("source_count", by: 3)
        recorder.recordArtifact(relativePath: "Shell/Bridge.swift", byteCount: 99)
        recorder.subprocessObserver(
            .init(
                kind: .typedAST,
                executableName: "swift-frontend",
                durationMicroseconds: 7,
                terminationStatus: 0,
                standardOutputBytes: 11,
                standardErrorBytes: 0
            )
        )
        recorder.subprocessObserver(
            .init(
                kind: .typedAST,
                executableName: "swift-frontend",
                durationMicroseconds: 13,
                terminationStatus: nil,
                standardOutputBytes: 0,
                standardErrorBytes: 5
            )
        )

        let report = try recorder.report(
            operation: .prepare,
            workflow: .liveReload,
            outcome: .success
        )
        #expect(report.schemaVersion == 1)
        #expect(report.totalDurationMicroseconds == 12)
        #expect(report.trace.stages == [
            .init(
                name: "prepare.frontend",
                invocationCount: 1,
                durationMicroseconds: 4
            ),
        ])
        #expect(report.trace.counters == [
            .init(name: "source_count", value: 5),
        ])
        #expect(report.trace.artifacts == [
            .init(relativePath: "Shell/Bridge.swift", byteCount: 99),
        ])
        #expect(report.trace.subprocesses == [
            .init(
                kind: .typedAST,
                executableName: "swift-frontend",
                invocationCount: 2,
                failureCount: 1,
                durationMicroseconds: 20,
                standardOutputBytes: 11,
                standardErrorBytes: 5
            ),
        ])

        let encoded = try Core.CanonicalJSON.encode(report)
        let decoded = try JSONDecoder().decode(
            BuildPerformance.Report.self,
            from: encoded
        )
        try decoded.validate()
        #expect(try Core.CanonicalJSON.encode(decoded) == encoded)
    }

    @Test("Merged traces are sorted, combined, and saturate counters")
    func mergesTraces() throws {
        let clock = Clock([0, 1_000])
        let recorder = BuildPerformance.Recorder(
            monotonicNanoseconds: { clock.next() }
        )
        recorder.setCounter("z", value: .max)
        recorder.incrementCounter("z")
        recorder.merge(.init(
            stages: [
                .init(name: "b", invocationCount: 2, durationMicroseconds: 3),
                .init(name: "a", invocationCount: 1, durationMicroseconds: 4),
            ],
            subprocesses: [
                .init(
                    kind: .demangle,
                    executableName: "swift-demangle",
                    invocationCount: 2,
                    failureCount: 0,
                    durationMicroseconds: 9,
                    standardOutputBytes: 10,
                    standardErrorBytes: 0
                ),
            ],
            counters: [.init(name: "a", value: 7)],
            artifacts: [.init(relativePath: "z/file", byteCount: 8)]
        ))
        recorder.merge(.init(
            stages: [.init(name: "a", invocationCount: 3, durationMicroseconds: 5)],
            counters: [.init(name: "a", value: 2)],
            artifacts: [.init(relativePath: "z/file", byteCount: 12)]
        ))

        let report = try recorder.report(
            operation: .patch,
            workflow: .hotPatch,
            outcome: .failure
        )
        #expect(report.trace.stages.map(\.name) == ["a", "b"])
        #expect(report.trace.stages[0].invocationCount == 4)
        #expect(report.trace.stages[0].durationMicroseconds == 9)
        #expect(report.trace.counters == [
            .init(name: "a", value: 9),
            .init(name: "z", value: .max),
        ])
        #expect(report.trace.artifacts == [
            .init(relativePath: "z/file", byteCount: 12),
        ])
    }

    @Test("Validation rejects ambiguous records and unsafe artifact paths")
    func rejectsMalformedTrace() {
        let unsorted = BuildPerformance.Trace(stages: [
            .init(name: "b", invocationCount: 1, durationMicroseconds: 0),
            .init(name: "a", invocationCount: 1, durationMicroseconds: 0),
        ])
        #expect(throws: BuildPerformance.Error.self) {
            try unsorted.validate()
        }

        let duplicate = BuildPerformance.Trace(counters: [
            .init(name: "same", value: 1),
            .init(name: "same", value: 2),
        ])
        #expect(throws: BuildPerformance.Error.self) {
            try duplicate.validate()
        }

        for path in ["/absolute", "../escape", "a/../escape", "a/./b", "a//b"] {
            let unsafe = BuildPerformance.Trace(artifacts: [
                .init(relativePath: path, byteCount: 1),
            ])
            #expect(throws: BuildPerformance.Error.self) {
                try unsafe.validate()
            }
        }

        let emptyInvocation = BuildPerformance.Trace(stages: [
            .init(name: "stage", invocationCount: 0, durationMicroseconds: 1),
        ])
        #expect(throws: BuildPerformance.Error.self) {
            try emptyInvocation.validate()
        }
    }

    @Test("Recorder serializes concurrent observations without losing events")
    func recordsConcurrently() throws {
        let recorder = BuildPerformance.Recorder()
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            recorder.incrementCounter("event_count")
            recorder.subprocessObserver(
                .init(
                    kind: .other,
                    executableName: "custom compiler+tool",
                    durationMicroseconds: 1,
                    terminationStatus: 0,
                    standardOutputBytes: 0,
                    standardErrorBytes: 0
                )
            )
        }

        let report = try recorder.report(
            operation: .bridge,
            workflow: .liveReload,
            outcome: .success
        )
        #expect(report.trace.counters == [
            .init(name: "event_count", value: 256),
        ])
        #expect(report.trace.subprocesses.first?.invocationCount == 256)
        #expect(report.trace.subprocesses.first?.failureCount == 0)
    }

    @Test("Frontend launch failures are still observable")
    func observesFrontendLaunchFailure() {
        let recorder = BuildPerformance.Recorder()
        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/missing/helix-swift-frontend"),
            invocationObserver: recorder.subprocessObserver
        )
        #expect(throws: SwiftFrontend.Error.self) {
            _ = try frontend.run(arguments: ["-version"])
        }
        let subprocess = recorder.trace().subprocesses.first
        #expect(subprocess?.kind == .compilerVersion)
        #expect(subprocess?.executableName == "helix-swift-frontend")
        #expect(subprocess?.invocationCount == 1)
        #expect(subprocess?.failureCount == 1)
    }
}
}
