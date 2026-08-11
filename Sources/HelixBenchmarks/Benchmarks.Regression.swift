import Foundation

extension Benchmarks {
public struct RegressionPolicy: Codable, Equatable, Sendable {
    /// Maximum candidate increase over baseline p50, expressed as a fraction.
    public var maximumP50Regression: Double
    /// Maximum candidate increase over baseline p95, expressed as a fraction.
    public var maximumP95Regression: Double
    /// Optional same-run overhead ceilings for selected hot-path scenarios.
    public var maximumP50RelativeToDirectSwift: [Benchmarks.ScenarioName: Double]
    /// Whether candidate and baseline must use the exact same Swift toolchain.
    public var requiresSameSwiftVersion: Bool

    public init(
        maximumP50Regression: Double = 0.20,
        maximumP95Regression: Double = 0.25,
        maximumP50RelativeToDirectSwift: [Benchmarks.ScenarioName: Double] = [:],
        requiresSameSwiftVersion: Bool = true
    ) {
        self.maximumP50Regression = maximumP50Regression
        self.maximumP95Regression = maximumP95Regression
        self.maximumP50RelativeToDirectSwift = maximumP50RelativeToDirectSwift
        self.requiresSameSwiftVersion = requiresSameSwiftVersion
    }

    public func validate() throws {
        guard maximumP50Regression.isFinite, maximumP50Regression >= 0,
              maximumP95Regression.isFinite, maximumP95Regression >= 0,
              maximumP50RelativeToDirectSwift.values.allSatisfy({
                  $0.isFinite && $0 > 0
              })
        else {
            throw Benchmarks.Error.invalidConfiguration(
                "regression tolerances must be finite and nonnegative; overhead ceilings must be positive"
            )
        }
    }
}

public enum RegressionMetric: String, Codable, Equatable, Sendable {
    case p50NanosecondsPerOperation = "p50_ns_per_operation"
    case p95NanosecondsPerOperation = "p95_ns_per_operation"
    case p50RelativeToDirectSwift = "p50_relative_to_direct_swift"
}

public struct RegressionViolation: Codable, Equatable, Sendable {
    public var scenario: Benchmarks.ScenarioName
    public var metric: Benchmarks.RegressionMetric
    public var baselineValue: Double?
    public var candidateValue: Double
    public var maximumAllowedValue: Double

    public init(
        scenario: Benchmarks.ScenarioName,
        metric: Benchmarks.RegressionMetric,
        baselineValue: Double?,
        candidateValue: Double,
        maximumAllowedValue: Double
    ) {
        self.scenario = scenario
        self.metric = metric
        self.baselineValue = baselineValue
        self.candidateValue = candidateValue
        self.maximumAllowedValue = maximumAllowedValue
    }
}

public struct RegressionEvaluation: Codable, Equatable, Sendable {
    public var passed: Bool
    public var violations: [Benchmarks.RegressionViolation]

    public init(violations: [Benchmarks.RegressionViolation]) {
        self.violations = violations
        passed = violations.isEmpty
    }
}

public enum RegressionEvaluator {
    public static func evaluate(
        candidate: Benchmarks.Report,
        against baseline: Benchmarks.Report,
        policy: Benchmarks.RegressionPolicy = .init()
    ) throws -> Benchmarks.RegressionEvaluation {
        try policy.validate()
        try validateComparable(candidate: candidate, baseline: baseline, policy: policy)
        let candidateByName = try indexed(candidate)
        let baselineByName = try indexed(baseline)
        guard Set(candidateByName.keys) == Set(baselineByName.keys) else {
            throw Benchmarks.Error.incomparableReports(
                "candidate and baseline scenario sets differ"
            )
        }

        var violations: [Benchmarks.RegressionViolation] = []
        for name in Benchmarks.ScenarioName.allCases {
            guard let candidateResult = candidateByName[name],
                  let baselineResult = baselineByName[name]
            else { continue }
            try validate(result: candidateResult, report: "candidate")
            try validate(result: baselineResult, report: "baseline")
            appendViolation(
                scenario: name,
                metric: .p50NanosecondsPerOperation,
                baseline: baselineResult.statistics.p50NanosecondsPerOperation,
                candidate: candidateResult.statistics.p50NanosecondsPerOperation,
                tolerance: policy.maximumP50Regression,
                to: &violations
            )
            appendViolation(
                scenario: name,
                metric: .p95NanosecondsPerOperation,
                baseline: baselineResult.statistics.p95NanosecondsPerOperation,
                candidate: candidateResult.statistics.p95NanosecondsPerOperation,
                tolerance: policy.maximumP95Regression,
                to: &violations
            )
            if let ceiling = policy.maximumP50RelativeToDirectSwift[name] {
                guard let ratio = candidateResult.p50RelativeToDirectSwift else {
                    throw Benchmarks.Error.incomparableReports(
                        "candidate scenario \(name.rawValue) has no direct-Swift ratio"
                    )
                }
                if ratio > ceiling {
                    violations.append(
                        .init(
                            scenario: name,
                            metric: .p50RelativeToDirectSwift,
                            baselineValue: baselineResult.p50RelativeToDirectSwift,
                            candidateValue: ratio,
                            maximumAllowedValue: ceiling
                        )
                    )
                }
            }
        }
        return .init(violations: violations)
    }

    private static func validateComparable(
        candidate: Benchmarks.Report,
        baseline: Benchmarks.Report,
        policy: Benchmarks.RegressionPolicy
    ) throws {
        guard candidate.schemaVersion == Benchmarks.Report.currentSchemaVersion,
              baseline.schemaVersion == Benchmarks.Report.currentSchemaVersion
        else {
            throw Benchmarks.Error.incomparableReports(
                "candidate and baseline must use report schema \(Benchmarks.Report.currentSchemaVersion)"
            )
        }
        guard candidate.environment.architecture == baseline.environment.architecture else {
            throw Benchmarks.Error.incomparableReports("architectures differ")
        }
        guard candidate.environment.operatingSystem == baseline.environment.operatingSystem else {
            throw Benchmarks.Error.incomparableReports("operating systems differ")
        }
        guard candidate.environment.processorCount == baseline.environment.processorCount,
              candidate.environment.activeProcessorCount
                == baseline.environment.activeProcessorCount,
              candidate.environment.physicalMemoryBytes
                == baseline.environment.physicalMemoryBytes
        else {
            throw Benchmarks.Error.incomparableReports("host hardware profiles differ")
        }
        guard candidate.environment.optimization == baseline.environment.optimization else {
            throw Benchmarks.Error.incomparableReports("optimization modes differ")
        }
        guard !policy.requiresSameSwiftVersion
                || candidate.environment.swiftVersion == baseline.environment.swiftVersion
        else {
            throw Benchmarks.Error.incomparableReports("Swift toolchains differ")
        }
        guard candidate.configuration == baseline.configuration else {
            throw Benchmarks.Error.incomparableReports("benchmark configurations differ")
        }
    }

    private static func indexed(
        _ report: Benchmarks.Report
    ) throws -> [Benchmarks.ScenarioName: Benchmarks.ScenarioResult] {
        let pairs = report.scenarios.map { ($0.name, $0) }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw Benchmarks.Error.incomparableReports("report contains duplicate scenarios")
        }
        guard Set(pairs.map(\.0)) == Set(Benchmarks.ScenarioName.allCases) else {
            throw Benchmarks.Error.incomparableReports(
                "report does not contain the complete schema scenario set"
            )
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    private static func validate(
        result: Benchmarks.ScenarioResult,
        report: String
    ) throws {
        let values = [
            result.statistics.p50NanosecondsPerOperation,
            result.statistics.p95NanosecondsPerOperation,
        ]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              result.p50RelativeToDirectSwift.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw Benchmarks.Error.incomparableReports(
                "\(report) scenario \(result.name.rawValue) contains nonpositive or nonfinite metrics"
            )
        }
    }

    private static func appendViolation(
        scenario: Benchmarks.ScenarioName,
        metric: Benchmarks.RegressionMetric,
        baseline: Double,
        candidate: Double,
        tolerance: Double,
        to violations: inout [Benchmarks.RegressionViolation]
    ) {
        let maximum = baseline * (1 + tolerance)
        guard candidate > maximum else { return }
        violations.append(
            .init(
                scenario: scenario,
                metric: metric,
                baselineValue: baseline,
                candidateValue: candidate,
                maximumAllowedValue: maximum
            )
        )
    }
}
}
