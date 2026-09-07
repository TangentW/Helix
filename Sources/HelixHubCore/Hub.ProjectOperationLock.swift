#if os(macOS)
import Darwin
import Foundation

extension Hub {
/// Locks the stable project directory inode, since PBX publication replaces the
/// file inode. This coordinates Helix operations without a generated lock file.
final class ProjectOperationLock {
    private var descriptor: Int32

    init(projectURL: URL) throws {
        guard projectURL.isFileURL, projectURL.pathExtension.lowercased() == "xcodeproj" else {
            throw Hub.Error.integrationConflict("project lock requires a local .xcodeproj directory: \(projectURL)")
        }
        let url = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else {
            throw Hub.Error.integrationConflict("cannot open project lock at \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let reason = String(cString: strerror(errno))
            close(opened)
            throw Hub.Error.integrationConflict("another operation holds or prevents the project lock at \(url.path): \(reason)")
        }
        descriptor = opened
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}
}
#endif
