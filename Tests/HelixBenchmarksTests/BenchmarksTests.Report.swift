import Foundation
import HelixBenchmarks
import HelixCore
import Testing

enum BenchmarksTests {}

extension BenchmarksTests {
@MainActor
@Suite("Performance report and harness")
struct ReportTests {
    @Test("Nearest-rank statistics preserve batch evidence")
    func statistics() throws {
        let result = try Benchmarks.Statistics.summarize(
            batchDurationsNanoseconds: [100, 20, 40, 60, 80],
            iterationsPerSample: 10
        )
        #expect(result.minimumNanosecondsPerOperation == 2)
        #expect(result.meanNanosecondsPerOperation == 6)
        #expect(result.p50NanosecondsPerOperation == 6)
        #expect(result.p95NanosecondsPerOperation == 10)
        #expect(result.p99NanosecondsPerOperation == 10)
    }

    @Test("Invalid iteration counts fail before measurement")
    func invalidConfiguration() {
        let configuration = Benchmarks.Configuration(iterationsPerSample: 0)
        #expect(throws: Benchmarks.Error.self) {
            try configuration.validate()
        }
    }

    @Test("Quick harness exercises every scenario and emits canonical JSON")
    func quickHarness() throws {
        let configuration = Benchmarks.Configuration(
            warmupIterations: 1,
            iterationsPerSample: 8,
            sampleCount: 2,
            verificationIterationsPerSample: 2,
            verificationSampleCount: 2
        )
        let report = try deterministicRunner().run(configuration: configuration)

        #expect(report.schemaVersion == Benchmarks.Report.currentSchemaVersion)
        #expect(report.generatedAt == "1970-01-01T00:00:00Z")
        #expect(report.scenarios.map(\.name) == Benchmarks.ScenarioName.allCases)
        #expect(report.scenarios.allSatisfy { $0.batchDurationsNanoseconds.count == 2 })
        #expect(
            report.scenarios
                .filter { $0.category == .hotPath }
                .allSatisfy { $0.p50RelativeToDirectSwift != nil }
        )
        let encoded = try Core.CanonicalJSON.encode(report)
        let decoded = try JSONDecoder().decode(Benchmarks.Report.self, from: encoded)
        #expect(decoded == report)
        #expect(try Core.CanonicalJSON.encode(decoded) == encoded)
    }

    @Test("Regression evaluation is deterministic and rejects incomparable runs")
    func regressionEvaluation() throws {
        let baseline = try quickReport()
        #expect(
            try Benchmarks.RegressionEvaluator.evaluate(
                candidate: baseline,
                against: baseline
            ).passed
        )

        var candidate = baseline
        let index = try #require(
            candidate.scenarios.firstIndex { $0.name == .bridgeHLBCPatch }
        )
        let baselineRatio = try #require(
            baseline.scenarios[index].p50RelativeToDirectSwift
        )
        candidate.scenarios[index].statistics.p50NanosecondsPerOperation *= 2
        candidate.scenarios[index].statistics.p95NanosecondsPerOperation *= 2
        candidate.scenarios[index].p50RelativeToDirectSwift = baselineRatio * 2
        let policy = Benchmarks.RegressionPolicy(
            maximumP50Regression: 0.10,
            maximumP95Regression: 0.10,
            maximumP50RelativeToDirectSwift: [
                .bridgeHLBCPatch: baselineRatio * 1.5,
            ]
        )
        let evaluation = try Benchmarks.RegressionEvaluator.evaluate(
            candidate: candidate,
            against: baseline,
            policy: policy
        )
        #expect(!evaluation.passed)
        #expect(evaluation.violations.count == 3)
        #expect(
            Set(evaluation.violations.map(\.metric)) == [
                .p50NanosecondsPerOperation,
                .p95NanosecondsPerOperation,
                .p50RelativeToDirectSwift,
            ]
        )
        let encodedPolicy = try Core.CanonicalJSON.encode(policy)
        #expect(
            try JSONDecoder().decode(
                Benchmarks.RegressionPolicy.self,
                from: encodedPolicy
            ) == policy
        )

        var differentArchitecture = baseline
        differentArchitecture.environment.architecture = "incomparable"
        #expect(throws: Benchmarks.Error.incomparableReports("architectures differ")) {
            try Benchmarks.RegressionEvaluator.evaluate(
                candidate: differentArchitecture,
                against: baseline
            )
        }

        var differentConfiguration = baseline
        differentConfiguration.configuration.iterationsPerSample += 1
        #expect(
            throws: Benchmarks.Error.incomparableReports(
                "benchmark configurations differ"
            )
        ) {
            try Benchmarks.RegressionEvaluator.evaluate(
                candidate: differentConfiguration,
                against: baseline
            )
        }

        var incomplete = baseline
        incomplete.scenarios.removeLast()
        #expect(
            throws: Benchmarks.Error.incomparableReports(
                "report does not contain the complete schema scenario set"
            )
        ) {
            try Benchmarks.RegressionEvaluator.evaluate(
                candidate: incomplete,
                against: baseline
            )
        }
    }

    private func quickReport() throws -> Benchmarks.Report {
        try deterministicRunner().run(
            configuration: .init(
                warmupIterations: 1,
                iterationsPerSample: 8,
                sampleCount: 2,
                verificationIterationsPerSample: 2,
                verificationSampleCount: 2
            )
        )
    }

    private func deterministicRunner() -> Benchmarks.Runner {
        var timestamp: UInt64 = 0
        return Benchmarks.Runner(
            now: { Date(timeIntervalSince1970: 0) },
            swiftVersionProvider: { "Swift test toolchain" },
            monotonicNanoseconds: {
                defer { timestamp &+= 1_000 }
                return timestamp
            }
        )
    }
}
}
