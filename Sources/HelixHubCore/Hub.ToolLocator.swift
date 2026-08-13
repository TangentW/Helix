#if os(macOS)
import Foundation

extension Hub {
/// Locates the command-line build tool shipped beside a Helix frontend.
///
/// The release app carries the tool in `Contents/Helpers`; source builds use
/// the sibling SwiftPM product. Xcode receives the resolved absolute path from
/// the running service, so projects do not need a PATH or environment setting.
public struct ToolLocator: Sendable {
    public init() {}

    public func locate() throws -> URL {
        let processURL = Bundle.main.executableURL ?? URL(
            fileURLWithPath: CommandLine.arguments[0],
            relativeTo: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ).absoluteURL
        return try locate(
            bundleURL: Bundle.main.bundleURL,
            processExecutableURL: processURL
        )
    }

    func locate(
        bundleURL: URL,
        processExecutableURL: URL
    ) throws -> URL {
        var candidates: [URL] = []
        if bundleURL.pathExtension.lowercased() == "app" {
            candidates.append(
                bundleURL.appendingPathComponent(
                    "Contents/Helpers/helix",
                    isDirectory: false
                )
            )
        }
        let process = processExecutableURL.standardizedFileURL
        if process.lastPathComponent == "helix" {
            candidates.append(process)
        }
        candidates.append(
            process.deletingLastPathComponent()
                .appendingPathComponent("helix", isDirectory: false)
        )

        var visited: Set<String> = []
        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard visited.insert(url.path).inserted else { continue }
            var isDirectory = ObjCBool(false)
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            )
            guard FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
                (attributes?[.type] as? FileAttributeType) == .typeRegular,
                FileManager.default.isExecutableFile(atPath: url.path)
            else { continue }
            return url
        }
        throw Hub.Error.storageFailure(
            "the Helix build tool is missing from this app or SwiftPM build"
        )
    }
}
}
#endif
