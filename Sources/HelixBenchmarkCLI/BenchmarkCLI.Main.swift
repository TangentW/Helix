import Darwin
import Foundation
import HelixBenchmarks
import HelixCore

extension BenchmarkCLI {
@main
enum Main {
    @MainActor
    static func main() {
        do {
            guard let options = try BenchmarkCLI.Options.parse(
                Array(CommandLine.arguments.dropFirst())
            ) else {
                print(help)
                return
            }
            // Read gate inputs before writing the candidate so an identical
            // baseline/output path cannot accidentally compare a file to itself.
            let baseline = try options.baseline.map {
                try decode(Benchmarks.Report.self, from: $0)
            }
            let policy = try options.policy.map {
                try decode(Benchmarks.RegressionPolicy.self, from: $0)
            } ?? .init()
            let report = try Benchmarks.Runner().run(configuration: options.configuration)
            var data = try Core.CanonicalJSON.encode(report)
            data.append(0x0A)
            if let output = options.output {
                try data.write(to: output, options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
            }
            if let baseline {
                let evaluation = try Benchmarks.RegressionEvaluator.evaluate(
                    candidate: report,
                    against: baseline,
                    policy: policy
                )
                var evaluationData = try Core.CanonicalJSON.encode(evaluation)
                evaluationData.append(0x0A)
                FileHandle.standardError.write(evaluationData)
                if !evaluation.passed { exit(3) }
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static let help = """
    Usage: helix-benchmark [options]

      --warmup N                  Warmup operations per scenario (default: 1000)
      --iterations N              Hot-path operations per sample (default: 10000)
      --samples N                 Hot-path sample count (default: 12)
      --verification-iterations N Decode/verify operations per sample (default: 100)
      --verification-samples N    Decode/verify sample count (default: 10)
      --output PATH               Write canonical JSON to PATH instead of stdout
      --baseline PATH             Compare the candidate against a prior report
      --policy PATH               Use a RegressionPolicy JSON file with --baseline
      -h, --help                  Show this help

    Run this executable with `swift run -c release helix-benchmark` when recording
    qualification evidence. A failed baseline gate exits with status 3; malformed
    input or execution failures exit with status 2. Debug results are intended only
    for harness validation.
    """
}
}
