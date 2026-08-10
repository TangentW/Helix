import Foundation
import HelixBenchmarks

enum BenchmarkCLI {}

extension BenchmarkCLI {
struct Options {
    var configuration = Benchmarks.Configuration()
    var output: URL?

    static func parse(_ arguments: [String]) throws -> Self? {
        if arguments.contains("--help") || arguments.contains("-h") { return nil }
        var options = Self()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw Benchmarks.Error.invalidConfiguration("\(option) requires a value")
                }
                index += 1
                return arguments[index]
            }
            switch option {
            case "--warmup":
                options.configuration.warmupIterations = try integer(value(), option: option)
            case "--iterations":
                options.configuration.iterationsPerSample = try integer(value(), option: option)
            case "--samples":
                options.configuration.sampleCount = try integer(value(), option: option)
            case "--verification-iterations":
                options.configuration.verificationIterationsPerSample = try integer(
                    value(), option: option
                )
            case "--verification-samples":
                options.configuration.verificationSampleCount = try integer(
                    value(), option: option
                )
            case "--output":
                options.output = URL(fileURLWithPath: try value())
            default:
                throw Benchmarks.Error.invalidConfiguration("unknown option \(option)")
            }
            index += 1
        }
        try options.configuration.validate()
        return options
    }

    private static func integer(_ value: String, option: String) throws -> Int {
        guard let result = Int(value) else {
            throw Benchmarks.Error.invalidConfiguration("\(option) expects an integer")
        }
        return result
    }
}
}
