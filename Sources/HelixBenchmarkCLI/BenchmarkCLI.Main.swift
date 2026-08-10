import Darwin
import Foundation
import HelixBenchmarks
import HelixCore

extension BenchmarkCLI {
@main
enum Main {
    static func main() {
        do {
            guard let options = try BenchmarkCLI.Options.parse(
                Array(CommandLine.arguments.dropFirst())
            ) else {
                print(help)
                return
            }
            let report = try Benchmarks.Runner().run(configuration: options.configuration)
            var data = try Core.CanonicalJSON.encode(report)
            data.append(0x0A)
            if let output = options.output {
                try data.write(to: output, options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(2)
        }
    }

    private static let help = """
    Usage: helix-benchmark [options]

      --warmup N                  Warmup operations per scenario (default: 1000)
      --iterations N              Hot-path operations per sample (default: 10000)
      --samples N                 Hot-path sample count (default: 12)
      --verification-iterations N Decode/verify operations per sample (default: 100)
      --verification-samples N    Decode/verify sample count (default: 10)
      --output PATH               Write canonical JSON to PATH instead of stdout
      -h, --help                  Show this help

    Run this executable with `swift run -c release helix-benchmark` when recording
    qualification evidence. Debug results are intended only for harness validation.
    """
}
}
