import Foundation

extension DevProcess {
/// Fixed private-file layout shared by the supervising parent and daemon.
/// Callers provide both independently derived paths so a malformed CLI request
/// cannot redirect cleanup outside the one Xcode session directory.
public struct SupervisedArtifacts: Sendable {
    public let directoryURL: URL

    public init(bootstrapURL: URL, lifecycleLockURL: URL) throws {
        let bootstrap = bootstrapURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let lifecycleLock = lifecycleLockURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directory = bootstrap.deletingLastPathComponent()
        guard bootstrap.isFileURL,
              lifecycleLock.isFileURL,
              bootstrap.lastPathComponent == "Bootstrap.private.json",
              lifecycleLock.lastPathComponent == "Daemon.lock",
              lifecycleLock.deletingLastPathComponent() == directory,
              directory.path.hasPrefix("/"),
              directory.path != "/"
        else {
            throw DevProcess.Error.invalidDocument(
                "supervised artifacts must use one canonical session directory"
            )
        }
        directoryURL = directory
    }

    public func cleanupPrivateHandoff() throws {
        for name in [
            "Bootstrap.private.json",
            "Helix.lldbinit",
            "Session.json",
        ] {
            try DevProcess.SecureFile.removeRegularFileIfPresent(
                directoryURL.appendingPathComponent(name)
            )
        }
    }
}
}
