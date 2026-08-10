import Darwin
import Foundation
import HelixCore

extension DevProcess {
public struct StartRequest: Sendable {
    public var executableURL: URL
    public var configurationURL: URL
    public var stateURL: URL
    public var logURL: URL
    public var lldbInitURL: URL
    public var target: DevSession.LaunchTarget
    public var startupTimeoutMilliseconds: UInt32

    public init(
        executableURL: URL,
        configurationURL: URL,
        stateURL: URL,
        logURL: URL,
        lldbInitURL: URL,
        target: DevSession.LaunchTarget,
        startupTimeoutMilliseconds: UInt32 = 15_000
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.stateURL = stateURL
        self.logURL = logURL
        self.lldbInitURL = lldbInitURL
        self.target = target
        self.startupTimeoutMilliseconds = startupTimeoutMilliseconds
    }
}

public struct Supervisor: Sendable {
    public init() {}

    @discardableResult
    public func start(_ request: DevProcess.StartRequest) throws -> DevProcess.State {
        try validate(request)
        try stop(stateURL: request.stateURL, allowMissing: true)
        let directory = request.stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bootstrapURL = directory.appendingPathComponent("Bootstrap.private.json")
        let lockURL = directory.appendingPathComponent("Daemon.lock")
        if try DevProcess.LifetimeLock.isHeld(at: lockURL) {
            throw DevProcess.Error.lifecycleConflict
        }
        for url in [bootstrapURL, request.stateURL, request.lldbInitURL] {
            try DevProcess.SecureFile.removeRegularFileIfPresent(url)
        }

        let logHandle = try openPrivateLog(request.logURL)
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = [
            "dev", "run",
            "--config", request.configurationURL.path,
            "--bootstrap", bootstrapURL.path,
            "--target", request.target.rawValue,
            "--lifecycle-lock", lockURL.path,
        ]
        process.currentDirectoryURL = request.configurationURL.deletingLastPathComponent()
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
            try logHandle.close()
        } catch {
            try? logHandle.close()
            throw DevProcess.Error.processLaunchFailed(String(describing: error))
        }

        do {
            let bootstrap = try waitForBootstrap(
                at: bootstrapURL,
                process: process,
                timeoutMilliseconds: request.startupTimeoutMilliseconds
            )
            guard try DevProcess.LifetimeLock.isHeld(at: lockURL) else {
                throw DevProcess.Error.processExited(process.terminationStatus)
            }
            let configuration = try readPrivateRegularFile(
                request.configurationURL,
                maximumBytes: 256 * 1_024,
                requirePrivateMode: false
            )
            let configurationHash = Core.Digest.sha256(configuration)
            let executablePath = request.executableURL.resolvingSymlinksInPath().path
            let sessionID = try bootstrap.sessionID()
            let expectedOwner = DevProcess.LifetimeOwner(
                processID: process.processIdentifier,
                sessionID: sessionID,
                configurationSHA256: configurationHash,
                executablePath: executablePath
            )
            guard try DevProcess.LifetimeLock.owner(at: lockURL) == expectedOwner else {
                throw DevProcess.Error.lifecycleConflict
            }
            try DevProcess.LLDBWriter().write(bootstrap, to: request.lldbInitURL)
            let now = Date().timeIntervalSince1970
            guard now >= 1, now <= Double(UInt64.max) else {
                throw DevProcess.Error.invalidDocument("system clock is outside UInt64")
            }
            let state = DevProcess.State(
                processID: process.processIdentifier,
                sessionID: sessionID,
                configurationSHA256: configurationHash,
                executablePath: executablePath,
                logPath: request.logURL.path,
                lldbInitPath: request.lldbInitURL.path,
                lifecycleLockPath: lockURL.path,
                startedAtUnixSeconds: UInt64(now)
            )
            try DevProcess.StateCodec.write(state, to: request.stateURL)
            try DevProcess.SecureFile.removeRegularFileIfPresent(bootstrapURL)
            return state
        } catch {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGTERM) }
            try? DevProcess.SecureFile.removeRegularFileIfPresent(bootstrapURL)
            try? DevProcess.SecureFile.removeRegularFileIfPresent(request.lldbInitURL)
            try? DevProcess.SecureFile.removeRegularFileIfPresent(request.stateURL)
            throw error
        }
    }

    public func stop(stateURL: URL, allowMissing: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            if allowMissing { return }
            throw DevProcess.Error.invalidDocument("Dev process state does not exist")
        }
        let state = try DevProcess.StateCodec.decode(
            readPrivateRegularFile(
                stateURL,
                maximumBytes: 64 * 1_024,
                requirePrivateMode: true
            )
        )
        let directory = stateURL.deletingLastPathComponent().standardizedFileURL
        let lockURL = URL(fileURLWithPath: state.lifecycleLockPath).standardizedFileURL
        let lldbURL = URL(fileURLWithPath: state.lldbInitPath).standardizedFileURL
        let logURL = URL(fileURLWithPath: state.logPath).standardizedFileURL
        guard Self.contains(lockURL, in: directory),
              Self.contains(lldbURL, in: directory),
              Self.contains(logURL, in: directory)
        else {
            throw DevProcess.Error.invalidDocument("state paths escape the session directory")
        }

        if try DevProcess.LifetimeLock.isHeld(at: lockURL) {
            let expectedOwner = DevProcess.LifetimeOwner(
                processID: state.processID,
                sessionID: state.sessionID,
                configurationSHA256: state.configurationSHA256,
                executablePath: state.executablePath
            )
            guard try DevProcess.LifetimeLock.owner(at: lockURL) == expectedOwner else {
                throw DevProcess.Error.lifecycleConflict
            }
            guard Darwin.kill(state.processID, SIGINT) == 0 || errno == ESRCH else {
                throw DevProcess.Error.lifecycleConflict
            }
            if !waitForStop(
                processID: state.processID,
                lockURL: lockURL,
                timeoutMilliseconds: 5_000
            ) {
                _ = Darwin.kill(state.processID, SIGTERM)
                guard waitForStop(
                    processID: state.processID,
                    lockURL: lockURL,
                    timeoutMilliseconds: 3_000
                ) else {
                    throw DevProcess.Error.stopTimedOut
                }
            }
        }
        try DevProcess.SecureFile.removeRegularFileIfPresent(lldbURL)
        try DevProcess.SecureFile.removeRegularFileIfPresent(
            directory.appendingPathComponent("Bootstrap.private.json")
        )
        try DevProcess.SecureFile.removeRegularFileIfPresent(stateURL)
    }

    public func loadState(at url: URL) throws -> DevProcess.State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try DevProcess.StateCodec.decode(
            readPrivateRegularFile(
                url,
                maximumBytes: 64 * 1_024,
                requirePrivateMode: true
            )
        )
    }

    private func validate(_ request: DevProcess.StartRequest) throws {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path),
              FileManager.default.isReadableFile(atPath: request.configurationURL.path),
              (100...60_000).contains(request.startupTimeoutMilliseconds)
        else {
            throw DevProcess.Error.invalidDocument(
                "start request has an invalid executable, configuration, or timeout"
            )
        }
        let directory = request.stateURL.deletingLastPathComponent().standardizedFileURL
        guard [request.logURL, request.lldbInitURL].allSatisfy({
            $0.deletingLastPathComponent().standardizedFileURL.path == directory.path
        }), request.stateURL.pathExtension == "json",
            request.lldbInitURL.pathExtension == "lldbinit",
            request.logURL.pathExtension == "log"
        else {
            throw DevProcess.Error.invalidDocument(
                "state, log, and LLDB files must share one session directory"
            )
        }
    }

    private func waitForBootstrap(
        at url: URL,
        process: Process,
        timeoutMilliseconds: UInt32
    ) throws -> DevProcess.BootstrapDocument {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return try DevProcess.BootstrapCodec.decode(
                    readPrivateRegularFile(
                        url,
                        maximumBytes: 64 * 1_024,
                        requirePrivateMode: true
                    )
                )
            }
            if !process.isRunning {
                process.waitUntilExit()
                throw DevProcess.Error.processExited(process.terminationStatus)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DevProcess.Error.startupTimedOut
    }

    private func waitForStop(
        processID: Int32,
        lockURL: URL,
        timeoutMilliseconds: UInt32
    ) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while Date() < deadline {
            let lockHeld = (try? DevProcess.LifetimeLock.isHeld(at: lockURL)) ?? true
            if !lockHeld || (Darwin.kill(processID, 0) != 0 && errno == ESRCH) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func openPrivateLog(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw DevProcess.Error.insecureFile(url.path) }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            Darwin.close(descriptor)
            throw DevProcess.Error.insecureFile(url.path)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func readPrivateRegularFile(
        _ url: URL,
        maximumBytes: Int,
        requirePrivateMode: Bool
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DevProcess.Error.insecureFile(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              !requirePrivateMode || information.st_mode & 0o177 == 0,
              information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(maximumBytes)
        else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= maximumBytes else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        return data
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
}
