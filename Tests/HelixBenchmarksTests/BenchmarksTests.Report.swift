import Foundation
import HelixBenchmarks
import HelixCore
import Testing

enum BenchmarksTests {}

extension BenchmarksTests {
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
        let report = try Benchmarks.Runner(
            now: { Date(timeIntervalSince1970: 0) },
            swiftVersionProvider: { "Swift test toolchain" }
        ).run(configuration: configuration)

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
}
}
