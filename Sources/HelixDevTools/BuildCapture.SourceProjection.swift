import Foundation

extension BuildCapture {
/// Produces a self-contained frontend job for an explicitly selected subset of
/// a normalized Xcode source set. This keeps integration-owned scheduling
/// sources out of later analysis without weakening source-membership checks.
public struct SourceProjection: Sendable {
    public init() {}

    public func project(
        _ job: BuildCapture.NormalizedFrontendJob,
        onto sourcePaths: [String],
        workingDirectory: URL
    ) throws -> BuildCapture.CapturedFrontendJob {
        let workingDirectory = workingDirectory.standardizedFileURL
        guard workingDirectory.isFileURL,
              workingDirectory.path.hasPrefix("/")
        else {
            throw BuildCapture.Error.malformedCommand(
                "source projection requires an absolute working directory"
            )
        }
        let captured = Set(job.sourcePaths)
        let selected = Set(sourcePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        guard !selected.isEmpty,
              selected.count == sourcePaths.count,
              selected.isSubset(of: captured)
        else {
            throw BuildCapture.Error.malformedCommand(
                "projected sources must be a unique, nonempty subset of the captured job"
            )
        }

        var arguments: [String] = []
        var index = 0
        while index < job.arguments.count {
            let argument = job.arguments[index]
            if argument == "-primary-file" {
                guard index + 1 < job.arguments.count else {
                    throw BuildCapture.Error.missingArgument(argument)
                }
                let source = job.arguments[index + 1]
                let absoluteSource = absolute(source, relativeTo: workingDirectory)
                if selected.contains(absoluteSource) {
                    arguments.append(contentsOf: [argument, source])
                }
                index += 2
                continue
            }
            let absoluteArgument = absolute(argument, relativeTo: workingDirectory)
            if captured.contains(absoluteArgument),
               !selected.contains(absoluteArgument)
            {
                index += 1
                continue
            }
            arguments.append(argument)
            index += 1
        }

        let projected = BuildCapture.CapturedFrontendJob(
            executable: job.executable,
            arguments: arguments,
            sourceLine: "projected Xcode Swift compiler capture"
        )
        let verified = try BuildCapture.FrontendJobNormalizer().normalize(
            projected,
            workingDirectory: workingDirectory
        )
        guard Set(verified.sourcePaths) == selected else {
            throw BuildCapture.Error.malformedCommand(
                "projected frontend job does not exactly preserve the selected sources"
            )
        }
        return projected
    }

    private func absolute(_ path: String, relativeTo directory: URL) -> String {
        guard !path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }
}
}
