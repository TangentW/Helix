import Darwin
import Foundation
import HelixCore
import HelixDevProtocol

/// Process-level lifecycle and debugger handoff for an Xcode-owned Dev Session.
public enum DevProcess {}

extension DevProcess {
public struct BootstrapDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var target: DevSession.LaunchTarget
    public var environment: [String: String]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        target: DevSession.LaunchTarget,
        environment: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.environment = environment
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DevProcess.Error.invalidDocument("unsupported bootstrap schema")
        }
        let common: Set<String> = [
            "HLX_DEV_PROTOCOL_VERSION", "HLX_DEV_SESSION_ID",
            "HLX_DEV_SERVICE_NAME", "HLX_DEV_SPKI_SHA256",
            "HLX_DEV_SESSION_SECRET",
        ]
        let expected = target == .simulator
            ? common.union(["HLX_DEV_HOST", "HLX_DEV_PORT"])
            : common
        guard Set(environment.keys) == expected,
              environment.values.allSatisfy(Self.isSafeLLDBValue),
              let versionText = environment["HLX_DEV_PROTOCOL_VERSION"],
              let version = UInt16(versionText), version > 0,
              let sessionText = environment["HLX_DEV_SESSION_ID"],
              UUID(uuidString: sessionText) != nil,
              let service = environment["HLX_DEV_SERVICE_NAME"],
              !service.isEmpty, service.utf8.count <= 63,
              let pin = environment["HLX_DEV_SPKI_SHA256"],
              (try? Core.Digest(hex: pin)) != nil,
              let secret = environment["HLX_DEV_SESSION_SECRET"],
              Self.isHex(secret, byteCount: 32)
        else {
            throw DevProcess.Error.invalidDocument(
                "bootstrap environment is incomplete or malformed"
            )
        }
        if target == .simulator {
            guard environment["HLX_DEV_HOST"] == "127.0.0.1",
                  let portText = environment["HLX_DEV_PORT"],
                  let port = UInt16(portText), port > 0
            else {
                throw DevProcess.Error.invalidDocument(
                    "simulator bootstrap endpoint is invalid"
                )
            }
        }
    }

    public func sessionID() throws -> UUID {
        try validate()
        guard let value = environment["HLX_DEV_SESSION_ID"],
              let sessionID = UUID(uuidString: value)
        else {
            throw DevProcess.Error.invalidDocument("missing session ID")
        }
        return sessionID
    }

    private static func isSafeLLDBValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || [45, 46, 58, 95].contains($0)
        }
    }

    private static func isHex(_ value: String, byteCount: Int) -> Bool {
        value.utf8.count == byteCount * 2 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct State: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var processID: Int32
    public var sessionID: UUID
    public var configurationSHA256: Core.Digest
    public var executablePath: String
    public var logPath: String
    public var lldbInitPath: String
    public var lifecycleLockPath: String
    public var startedAtUnixSeconds: UInt64

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        processID: Int32,
        sessionID: UUID,
        configurationSHA256: Core.Digest,
        executablePath: String,
        logPath: String,
        lldbInitPath: String,
        lifecycleLockPath: String,
        startedAtUnixSeconds: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.sessionID = sessionID
        self.configurationSHA256 = configurationSHA256
        self.executablePath = executablePath
        self.logPath = logPath
        self.lldbInitPath = lldbInitPath
        self.lifecycleLockPath = lifecycleLockPath
        self.startedAtUnixSeconds = startedAtUnixSeconds
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              processID > 1,
              startedAtUnixSeconds > 0,
              [executablePath, logPath, lldbInitPath, lifecycleLockPath].allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 16 * 1_024
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              })
        else {
            throw DevProcess.Error.invalidDocument("invalid Dev process state")
        }
    }
}

/// Identity written into the locked daemon file. A stop request must match
/// this record before it may signal a PID, which closes the stale-PID reuse
/// window without depending on process-list string matching.
public struct LifetimeOwner: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var processID: Int32
    public var sessionID: UUID
    public var configurationSHA256: Core.Digest
    public var executablePath: String

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        processID: Int32,
        sessionID: UUID,
        configurationSHA256: Core.Digest,
        executablePath: String
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.sessionID = sessionID
        self.configurationSHA256 = configurationSHA256
        self.executablePath = executablePath
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              processID > 1,
              executablePath.hasPrefix("/"),
              executablePath.utf8.count <= 16 * 1_024,
              !executablePath.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw DevProcess.Error.invalidDocument("invalid Dev lifecycle owner")
        }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDocument(String)
    case insecureFile(String)
    case processLaunchFailed(String)
    case processExited(Int32)
    case startupTimedOut
    case lifecycleConflict
    case stopTimedOut

    public var description: String {
        switch self {
        case let .invalidDocument(reason): "invalid Dev process document: \(reason)"
        case let .insecureFile(path): "Dev process file is insecure: \(path)"
        case let .processLaunchFailed(reason): "cannot launch Dev process: \(reason)"
        case let .processExited(status): "Dev process exited during startup with status \(status)"
        case .startupTimedOut: "Dev process did not publish bootstrap data before the timeout"
        case .lifecycleConflict: "another process owns the Dev lifecycle lock"
        case .stopTimedOut: "Dev process did not stop before the timeout"
        }
    }
}

public enum BootstrapCodec {
    public static func encode(_ document: DevProcess.BootstrapDocument) throws -> Data {
        try document.validate()
        return try Core.CanonicalJSON.encode(document)
    }

    public static func decode(_ data: Data) throws -> DevProcess.BootstrapDocument {
        guard data.count <= 64 * 1_024 else {
            throw DevProcess.Error.invalidDocument("bootstrap exceeds 64 KiB")
        }
        let document: DevProcess.BootstrapDocument
        do {
            document = try JSONDecoder().decode(Self.Document.self, from: data)
        } catch {
            throw DevProcess.Error.invalidDocument("bootstrap JSON decoding failed")
        }
        guard try Core.CanonicalJSON.encode(document) == data else {
            throw DevProcess.Error.invalidDocument("bootstrap JSON is not canonical")
        }
        try document.validate()
        return document
    }

    public static func write(
        _ document: DevProcess.BootstrapDocument,
        to url: URL
    ) throws {
        try DevProcess.SecureFile.write(try encode(document), to: url)
    }

    private typealias Document = DevProcess.BootstrapDocument
}

public enum StateCodec {
    public static func encode(_ state: DevProcess.State) throws -> Data {
        try state.validate()
        return try Core.CanonicalJSON.encode(state)
    }

    public static func decode(_ data: Data) throws -> DevProcess.State {
        guard data.count <= 64 * 1_024 else {
            throw DevProcess.Error.invalidDocument("state exceeds 64 KiB")
        }
        let state: DevProcess.State
        do {
            state = try JSONDecoder().decode(DevProcess.State.self, from: data)
        } catch {
            throw DevProcess.Error.invalidDocument("state JSON decoding failed")
        }
        guard try Core.CanonicalJSON.encode(state) == data else {
            throw DevProcess.Error.invalidDocument("state JSON is not canonical")
        }
        try state.validate()
        return state
    }

    public static func write(_ state: DevProcess.State, to url: URL) throws {
        try DevProcess.SecureFile.write(try encode(state), to: url)
    }
}

public enum LifetimeOwnerCodec {
    public static func encode(_ owner: DevProcess.LifetimeOwner) throws -> Data {
        try owner.validate()
        return try Core.CanonicalJSON.encode(owner)
    }

    public static func decode(_ data: Data) throws -> DevProcess.LifetimeOwner {
        guard data.count <= 64 * 1_024 else {
            throw DevProcess.Error.invalidDocument("lifecycle owner exceeds 64 KiB")
        }
        let owner: DevProcess.LifetimeOwner
        do {
            owner = try JSONDecoder().decode(DevProcess.LifetimeOwner.self, from: data)
        } catch {
            throw DevProcess.Error.invalidDocument("lifecycle owner JSON decoding failed")
        }
        guard try Core.CanonicalJSON.encode(owner) == data else {
            throw DevProcess.Error.invalidDocument("lifecycle owner JSON is not canonical")
        }
        try owner.validate()
        return owner
    }
}

public struct LLDBWriter: Sendable {
    private static let handoffReadyEnvironmentName = "HLX_DEV_HANDOFF_READY"
    private static let runtimeProbeSymbol = "helix_dev_runtime_handoff_probe"
    private static let installerTimeoutSeconds =
        DevProtocol.DebuggerHandoffTiming.installerTimeoutSeconds

    public init() {}

    public func render(_ document: DevProcess.BootstrapDocument) throws -> String {
        try document.validate()
        guard let handoffReadyValue = document.environment["HLX_DEV_SESSION_ID"] else {
            throw DevProcess.Error.invalidDocument("missing handoff session ID")
        }
        let environment = document.environment.sorted { $0.key < $1.key }
        let assignments = environment.map {
            "\"\($0.key)=\($0.value)\""
        }.joined(separator: " ")
        let installer = Self.renderPythonInstaller(
            environment: environment,
            handoffReadyValue: handoffReadyValue
        )
        return """
        # Generated by Helix. Contains an ephemeral credential; do not commit.
        # target.env-vars covers LLDB-owned launches. Xcode may source this file
        # before the real App target exists and discard dummy-target state.
        # The bounded Python installer therefore pauses the real process and
        # injects the complete environment directly. The final ready marker
        # commits that handoff atomically to Helix.
        settings set target.env-vars \(assignments)
        script exec(\(Self.pythonLiteral(installer)))

        """
    }

    private static func renderPythonInstaller(
        environment: [(key: String, value: String)],
        handoffReadyValue: String
    ) -> String {
        let handoffEnvironment = environment + [(
            key: handoffReadyEnvironmentName,
            value: handoffReadyValue,
        )]
        let injection = handoffEnvironment.map {
            "((int)setenv(\"\($0.key)\", \"\($0.value)\", 1) == 0)"
        }.joined(separator: " && ")
        let command = "expression -l c -- (void)(\(injection))"
        return """
        import lldb
        import threading
        import time

        def _helix_inject(debugger, command):
            result = lldb.SBCommandReturnObject()
            debugger.GetCommandInterpreter().HandleCommand(
                command,
                result,
                False,
            )
            return result.Succeeded()

        def _helix_install(debugger, command):
            deadline = time.monotonic() + \(installerTimeoutSeconds).0
            while time.monotonic() < deadline:
                for index in range(debugger.GetNumTargets()):
                    target = debugger.GetTargetAtIndex(index)
                    process = target.GetProcess()
                    if (
                        not target.IsValid()
                        or not process.IsValid()
                        or process.GetState() != lldb.eStateRunning
                        or target.FindFunctions("\(runtimeProbeSymbol)").GetSize() == 0
                    ):
                        continue
                    stop_error = process.Stop()
                    if stop_error.Fail():
                        continue
                    injected = False
                    try:
                        injected = _helix_inject(debugger, command)
                    finally:
                        continue_error = process.Continue()
                    if continue_error.Fail():
                        print("error: Helix LLDB handoff could not resume the App process")
                        return
                    if injected:
                        return
                time.sleep(0.05)
            print("warning: Helix LLDB handoff timed out before credentials were injected")

        def _helix_install_safely(debugger, command):
            try:
                _helix_install(debugger, command)
            except Exception:
                print("error: Helix LLDB handoff could not inject launch credentials")

        _helix_command = \(pythonLiteral(command))
        threading.Thread(
            target=_helix_install_safely,
            args=(lldb.debugger, _helix_command),
            name="HelixLLDBHandoff",
            daemon=True,
        ).start()
        """
    }

    private static func pythonLiteral(_ value: String) -> String {
        var literal = "'"
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09: literal += "\\t"
            case 0x0A: literal += "\\n"
            case 0x0D: literal += "\\r"
            case 0x27: literal += "\\'"
            case 0x5C: literal += "\\\\"
            default: literal.append(contentsOf: String(scalar))
            }
        }
        literal.append("'")
        return literal
    }

    public func write(
        _ document: DevProcess.BootstrapDocument,
        to url: URL
    ) throws {
        try DevProcess.SecureFile.write(Data(render(document).utf8), to: url)
    }
}

enum SecureFile {
    static func write(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL, destination.path != "/" else {
            throw DevProcess.Error.insecureFile(destination.path)
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(
            ".helix-private-\(UUID().uuidString)"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DevProcess.Error.insecureFile(temporary.path)
        }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let baseAddress = buffer.baseAddress else {
                    throw DevProcess.Error.insecureFile(temporary.path)
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else {
                    throw DevProcess.Error.insecureFile(temporary.path)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw DevProcess.Error.insecureFile(temporary.path)
        }
        do {
            if rename(temporary.path, destination.path) != 0 {
                throw DevProcess.Error.insecureFile(destination.path)
            }
            succeeded = true
        } catch {
            throw error
        }
    }

    static func removeRegularFileIfPresent(_ url: URL) throws {
        var information = Darwin.stat()
        if lstat(url.path, &information) != 0 {
            if errno == ENOENT { return }
            throw DevProcess.Error.insecureFile(url.path)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid()
        else {
            throw DevProcess.Error.insecureFile(url.path)
        }
        guard Darwin.unlink(url.path) == 0 else {
            throw DevProcess.Error.insecureFile(url.path)
        }
    }
}
}
