import Foundation

extension Benchmarks {
@MainActor
public struct Runner {
    private struct Scenario {
        var name: Benchmarks.ScenarioName
        var category: Benchmarks.ScenarioCategory
        var iterations: Int
        var samples: Int
        var warmup: Int
        var operation: (Int) throws -> UInt64
        var expected: (Int) -> UInt64
    }

    private let now: () -> Date
    private let monotonicNanoseconds: () -> UInt64
    private let swiftVersionProvider: () throws -> String

    public init(
        now: @escaping () -> Date = Date.init,
        swiftVersionProvider: (() throws -> String)? = nil
    ) {
        self.now = now
        self.monotonicNanoseconds = { DispatchTime.now().uptimeNanoseconds }
        self.swiftVersionProvider = swiftVersionProvider ?? Self.installedSwiftVersion
    }

    package init(
        now: @escaping () -> Date,
        swiftVersionProvider: @escaping () throws -> String,
        monotonicNanoseconds: @escaping () -> UInt64
    ) {
        self.now = now
        self.monotonicNanoseconds = monotonicNanoseconds
        self.swiftVersionProvider = swiftVersionProvider
    }

    public func run(configuration: Benchmarks.Configuration = .init()) throws -> Benchmarks.Report {
        try configuration.validate()
        let fixture = try Benchmarks.Fixture()
        let hotIterations = configuration.iterationsPerSample
        let verificationIterations = configuration.verificationIterationsPerSample
        let verificationExpected = UInt64(fixture.image.imageHash.bytes[0])
        let scenarios = [
            Scenario(
                name: .directSwift,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: Benchmarks.Fixture.directTransform(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .bridgeOriginalFastPath,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokeOriginalBridge(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .runtimeOriginalCatalog,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokeOriginalRuntime(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .verifiedImageInvocation,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokeImage(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .uiNativeImportInvocation,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokeUINativeImport(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .closureImageInvocation,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokeClosureImage(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .bridgeHLBCPatch,
                category: .hotPath,
                iterations: hotIterations,
                samples: configuration.sampleCount,
                warmup: configuration.warmupIterations,
                operation: { index in
                    UInt64(bitPattern: try fixture.invokePatchedBridge(
                        Benchmarks.Fixture.input(for: index)
                    ))
                },
                expected: Self.expectedTransform
            ),
            Scenario(
                name: .decodeAndVerify,
                category: .artifactPreparation,
                iterations: verificationIterations,
                samples: configuration.verificationSampleCount,
                warmup: min(configuration.warmupIterations, 10),
                operation: { _ in try fixture.verifyImageHashByte() },
                expected: { _ in verificationExpected }
            ),
        ]

        var results = try scenarios.map(measure)
        guard let directP50 = results.first(where: { $0.name == .directSwift })?
            .statistics.p50NanosecondsPerOperation,
              directP50 > 0
        else {
            throw Benchmarks.Error.unexpectedResult(
                scenario: .directSwift,
                detail: "the monotonic clock did not advance"
            )
        }
        for index in results.indices where results[index].category == .hotPath {
            results[index].p50RelativeToDirectSwift =
                results[index].statistics.p50NanosecondsPerOperation / directP50
        }

        return Benchmarks.Report(
            generatedAt: Self.timestamp(now()),
            environment: try environment(),
            configuration: configuration,
            scenarios: results
        )
    }

    private func measure(_ scenario: Scenario) throws -> Benchmarks.ScenarioResult {
        if scenario.warmup > 0 {
            let warmupChecksum = try Self.checksum(
                iterations: scenario.warmup,
                operation: scenario.operation
            )
            let expected = Self.checksum(
                iterations: scenario.warmup,
                operation: scenario.expected
            )
            guard warmupChecksum == expected else {
                throw Benchmarks.Error.unexpectedResult(
                    scenario: scenario.name,
                    detail: "warmup checksum \(warmupChecksum) != \(expected)"
                )
            }
        }

        let expected = Self.checksum(
            iterations: scenario.iterations,
            operation: scenario.expected
        )
        var durations: [UInt64] = []
        var reportChecksum: UInt64 = 0
        durations.reserveCapacity(scenario.samples)
        for sample in 0..<scenario.samples {
            let start = monotonicNanoseconds()
            let measured = try Self.checksum(
                iterations: scenario.iterations,
                operation: scenario.operation
            )
            let end = monotonicNanoseconds()
            guard measured == expected else {
                throw Benchmarks.Error.unexpectedResult(
                    scenario: scenario.name,
                    detail: "sample checksum \(measured) != \(expected)"
                )
            }
            durations.append(end &- start)
            reportChecksum &+= measured &+ UInt64(sample)
        }
        return try Benchmarks.ScenarioResult(
            name: scenario.name,
            category: scenario.category,
            iterationsPerSample: scenario.iterations,
            batchDurationsNanoseconds: durations,
            checksum: reportChecksum,
            statistics: .summarize(
                batchDurationsNanoseconds: durations,
                iterationsPerSample: scenario.iterations
            )
        )
    }

    private func environment() throws -> Benchmarks.Environment {
        let process = ProcessInfo.processInfo
        #if DEBUG
        let optimization = "debug"
        #else
        let optimization = "release"
        #endif
        return Benchmarks.Environment(
            operatingSystem: process.operatingSystemVersionString,
            architecture: Self.architecture,
            processorCount: process.processorCount,
            activeProcessorCount: process.activeProcessorCount,
            physicalMemoryBytes: process.physicalMemory,
            swiftVersion: try swiftVersionProvider(),
            optimization: optimization
        )
    }

    private static func checksum(
        iterations: Int,
        operation: (Int) throws -> UInt64
    ) rethrows -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<iterations {
            result &+= try operation(index)
        }
        return result
    }

    private static func expectedTransform(_ index: Int) -> UInt64 {
        UInt64(bitPattern: Benchmarks.Fixture.input(for: index) + 27)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func installedSwiftVersion() throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw Benchmarks.Error.compilerVersionUnavailable(String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Benchmarks.Error.compilerVersionUnavailable(
                String(decoding: data, as: UTF8.self)
            )
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
}
