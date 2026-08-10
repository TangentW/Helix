import Foundation

public enum Benchmarks {}

extension Benchmarks {
public struct Configuration: Codable, Equatable, Sendable {
    public var warmupIterations: Int
    public var iterationsPerSample: Int
    public var sampleCount: Int
    public var verificationIterationsPerSample: Int
    public var verificationSampleCount: Int

    public init(
        warmupIterations: Int = 1_000,
        iterationsPerSample: Int = 10_000,
        sampleCount: Int = 12,
        verificationIterationsPerSample: Int = 100,
        verificationSampleCount: Int = 10
    ) {
        self.warmupIterations = warmupIterations
        self.iterationsPerSample = iterationsPerSample
        self.sampleCount = sampleCount
        self.verificationIterationsPerSample = verificationIterationsPerSample
        self.verificationSampleCount = verificationSampleCount
    }

    public func validate() throws {
        guard warmupIterations >= 0 else {
            throw Benchmarks.Error.invalidConfiguration("warmup iterations cannot be negative")
        }
        guard iterationsPerSample > 0, sampleCount > 0 else {
            throw Benchmarks.Error.invalidConfiguration(
                "hot-path iterations and sample count must be positive"
            )
        }
        guard verificationIterationsPerSample > 0, verificationSampleCount > 0 else {
            throw Benchmarks.Error.invalidConfiguration(
                "verification iterations and sample count must be positive"
            )
        }
    }
}

public enum ScenarioName: String, Codable, CaseIterable, Sendable {
    case directSwift = "direct_swift"
    case bridgeOriginalFastPath = "bridge_original_fast_path"
    case runtimeOriginalCatalog = "runtime_original_catalog"
    case verifiedImageInvocation = "hlvm_verified_image_invocation"
    case closureImageInvocation = "hlvm_closure_invocation"
    case bridgeHLBCPatch = "bridge_hlbc_patch"
    case decodeAndVerify = "hlbc_decode_and_verify"
}

public enum ScenarioCategory: String, Codable, Sendable {
    case hotPath = "hot_path"
    case artifactPreparation = "artifact_preparation"
}

public struct Statistics: Codable, Equatable, Sendable {
    public var minimumNanosecondsPerOperation: Double
    public var meanNanosecondsPerOperation: Double
    public var p50NanosecondsPerOperation: Double
    public var p95NanosecondsPerOperation: Double
    public var p99NanosecondsPerOperation: Double

    public init(
        minimumNanosecondsPerOperation: Double,
        meanNanosecondsPerOperation: Double,
        p50NanosecondsPerOperation: Double,
        p95NanosecondsPerOperation: Double,
        p99NanosecondsPerOperation: Double
    ) {
        self.minimumNanosecondsPerOperation = minimumNanosecondsPerOperation
        self.meanNanosecondsPerOperation = meanNanosecondsPerOperation
        self.p50NanosecondsPerOperation = p50NanosecondsPerOperation
        self.p95NanosecondsPerOperation = p95NanosecondsPerOperation
        self.p99NanosecondsPerOperation = p99NanosecondsPerOperation
    }

    public static func summarize(
        batchDurationsNanoseconds: [UInt64],
        iterationsPerSample: Int
    ) throws -> Self {
        guard !batchDurationsNanoseconds.isEmpty, iterationsPerSample > 0 else {
            throw Benchmarks.Error.invalidConfiguration(
                "statistics require at least one duration and one iteration"
            )
        }
        let divisor = Double(iterationsPerSample)
        let values = batchDurationsNanoseconds.map { Double($0) / divisor }.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        return Self(
            minimumNanosecondsPerOperation: values[0],
            meanNanosecondsPerOperation: mean,
            p50NanosecondsPerOperation: percentile(0.50, values: values),
            p95NanosecondsPerOperation: percentile(0.95, values: values),
            p99NanosecondsPerOperation: percentile(0.99, values: values)
        )
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        // Nearest-rank percentiles keep the report transparent for small sample sets.
        let rank = Int(ceil(percentile * Double(values.count)))
        return values[max(0, min(values.count - 1, rank - 1))]
    }
}

public struct ScenarioResult: Codable, Equatable, Sendable {
    public var name: Benchmarks.ScenarioName
    public var category: Benchmarks.ScenarioCategory
    public var iterationsPerSample: Int
    public var batchDurationsNanoseconds: [UInt64]
    public var checksum: UInt64
    public var statistics: Benchmarks.Statistics
    public var p50RelativeToDirectSwift: Double?

    public init(
        name: Benchmarks.ScenarioName,
        category: Benchmarks.ScenarioCategory,
        iterationsPerSample: Int,
        batchDurationsNanoseconds: [UInt64],
        checksum: UInt64,
        statistics: Benchmarks.Statistics,
        p50RelativeToDirectSwift: Double? = nil
    ) {
        self.name = name
        self.category = category
        self.iterationsPerSample = iterationsPerSample
        self.batchDurationsNanoseconds = batchDurationsNanoseconds
        self.checksum = checksum
        self.statistics = statistics
        self.p50RelativeToDirectSwift = p50RelativeToDirectSwift
    }
}

public struct Environment: Codable, Equatable, Sendable {
    public var operatingSystem: String
    public var architecture: String
    public var processorCount: Int
    public var activeProcessorCount: Int
    public var physicalMemoryBytes: UInt64
    public var swiftVersion: String
    public var optimization: String

    public init(
        operatingSystem: String,
        architecture: String,
        processorCount: Int,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64,
        swiftVersion: String,
        optimization: String
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.swiftVersion = swiftVersion
        self.optimization = optimization
    }
}

public struct Report: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var generatedAt: String
    public var environment: Benchmarks.Environment
    public var configuration: Benchmarks.Configuration
    public var scenarios: [Benchmarks.ScenarioResult]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        generatedAt: String,
        environment: Benchmarks.Environment,
        configuration: Benchmarks.Configuration,
        scenarios: [Benchmarks.ScenarioResult]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.configuration = configuration
        self.scenarios = scenarios
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case unexpectedResult(scenario: Benchmarks.ScenarioName, detail: String)
    case compilerVersionUnavailable(String)

    public var description: String {
        switch self {
        case let .invalidConfiguration(message):
            "invalid benchmark configuration: \(message)"
        case let .unexpectedResult(scenario, detail):
            "benchmark \(scenario.rawValue) produced an unexpected result: \(detail)"
        case let .compilerVersionUnavailable(message):
            "could not determine the Swift compiler version: \(message)"
        }
    }
}
}
