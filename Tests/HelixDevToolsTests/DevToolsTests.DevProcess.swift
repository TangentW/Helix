import Darwin
import Foundation
import HelixCore
import HelixDevProtocol
import Testing
@testable import HelixDevTools

extension DevToolsTests {
@Suite("Xcode Dev process supervision")
struct DevProcessSupervision {
    @Test("Simulator mock delivery stages one bounded package inside the App container")
    func simulatorPatchStaging() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-simulator-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let container = directory.appendingPathComponent("Container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Patch.hlxp")
        let bytes = Data("mock signed package bytes".utf8)
        try bytes.write(to: package)
        let stager = PatchDelivery.SimulatorStager { bundleID in
            #expect(bundleID == "dev.helix.demo")
            return container
        }
        let destination = try stager.stage(
            packageURL: package,
            bundleID: "dev.helix.demo",
            relativeInboxPath: "Documents/HelixMockInbox/Patch.hlxp"
        )
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(throws: PatchDelivery.Error.self) {
            try stager.stage(
                packageURL: package,
                bundleID: "dev.helix.demo",
                relativeInboxPath: "../Patch.hlxp"
            )
        }
    }

    @Test("Bootstrap, LLDB, and process state documents are canonical and secret-scoped")
    func documentContract() throws {
        let document = bootstrapDocument()
        let bytes = try DevProcess.BootstrapCodec.encode(document)
        #expect(try DevProcess.BootstrapCodec.decode(bytes) == document)
        let lldb = try DevProcess.LLDBWriter().render(document)
        #expect(lldb.contains("settings set target.env-vars"))
        #expect(lldb.contains("script exec("))
        #expect(lldb.contains("def _helix_install(debugger, command):"))
        #expect(lldb.contains("target.FindFunctions(\"helix_dev_runtime_handoff_probe\")"))
        #expect(lldb.contains("stop_error = process.Stop()"))
        #expect(lldb.contains("debugger.GetCommandInterpreter().HandleCommand("))
        #expect(lldb.contains("return result.Succeeded()"))
        #expect(lldb.contains("continue_error = process.Continue()"))
        #expect(lldb.contains("name=\"HelixLLDBHandoff\""))
        #expect(lldb.contains(
            "time.monotonic() + "
                + "\(DevProtocol.DebuggerHandoffTiming.installerTimeoutSeconds).0"
        ))
        #expect(lldb.contains("HLX_DEV_SESSION_SECRET="))
        #expect(!lldb.contains("export "))
        #expect(lldb.contains("(int)setenv"))
        #expect(lldb.components(separatedBy: "expression -l c --").count - 1 == 1)

        let stop = try #require(lldb.range(of: "stop_error = process.Stop()"))
        let inject = try #require(lldb.range(
            of: "injected = _helix_inject(debugger, command)"
        ))
        let resume = try #require(lldb.range(
            of: "continue_error = process.Continue()"
        ))
        #expect(stop.upperBound < inject.lowerBound)
        #expect(inject.upperBound < resume.lowerBound)
        #expect(!lldb.contains("BreakpointCreateByName"))
        #expect(!lldb.contains("SetCommandLineCommands"))

        let installerStart = try #require(lldb.range(of: "_helix_command = "))
        let installer = lldb[installerStart.lowerBound...]
        let readyRange = try #require(installer.range(of: "HLX_DEV_HANDOFF_READY"))
        for (key, value) in document.environment {
            let keyRange = try #require(installer.range(of: key))
            #expect(keyRange.upperBound < readyRange.lowerBound)
            #expect(installer[keyRange.upperBound...].contains(value))
        }
        #expect(installer[readyRange.upperBound...].contains(
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ))
        #expect(!installer[readyRange.upperBound...].contains("setenv"))

        var unsafe = document
        unsafe.environment["HLX_DEV_SERVICE_NAME"] = "unsafe'value"
        #expect(throws: DevProcess.Error.self) {
            try DevProcess.LLDBWriter().render(unsafe)
        }

        let state = DevProcess.State(
            processID: 42,
            sessionID: try document.sessionID(),
            configurationSHA256: .sha256("configuration"),
            executablePath: "/tmp/helix",
            logPath: "/tmp/session/Daemon.log",
            lldbInitPath: "/tmp/session/Helix.lldbinit",
            lifecycleLockPath: "/tmp/session/Daemon.lock",
            startedAtUnixSeconds: 1
        )
        let stateBytes = try DevProcess.StateCodec.encode(state)
        #expect(try DevProcess.StateCodec.decode(stateBytes) == state)
        #expect(!String(decoding: stateBytes, as: UTF8.self).contains(
            document.environment["HLX_DEV_SESSION_SECRET"]!
        ))

        var nonCanonical = bytes
        nonCanonical.append(UInt8(ascii: "\n"))
        #expect(throws: DevProcess.Error.self) {
            try DevProcess.BootstrapCodec.decode(nonCanonical)
        }
    }

    @Test("Private handoff files and lifecycle locks reject broad or concurrent access")
    func privateFilesAndLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-dev-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrapURL = directory.appendingPathComponent("Bootstrap.private.json")
        try DevProcess.BootstrapCodec.write(bootstrapDocument(), to: bootstrapURL)
        var information = Darwin.stat()
        #expect(lstat(bootstrapURL.path, &information) == 0)
        #expect(information.st_mode & 0o777 == 0o600)

        let lockURL = directory.appendingPathComponent("Daemon.lock")
        let first = try DevProcess.LifetimeLock(url: lockURL)
        #expect(try DevProcess.LifetimeLock.isHeld(at: lockURL))
        let owner = DevProcess.LifetimeOwner(
            processID: 42,
            sessionID: try bootstrapDocument().sessionID(),
            configurationSHA256: .sha256("configuration"),
            executablePath: "/tmp/helix"
        )
        try first.publish(owner: owner)
        #expect(try DevProcess.LifetimeLock.owner(at: lockURL) == owner)
        #expect(throws: DevProcess.Error.lifecycleConflict) {
            try DevProcess.LifetimeLock(url: lockURL)
        }

        let lldbURL = directory.appendingPathComponent("Helix.lldbinit")
        let stateURL = directory.appendingPathComponent("Session.json")
        try DevProcess.SecureFile.write(Data("private init".utf8), to: lldbURL)
        try DevProcess.SecureFile.write(Data("private state".utf8), to: stateURL)
        let artifacts = try DevProcess.SupervisedArtifacts(
            bootstrapURL: bootstrapURL,
            lifecycleLockURL: lockURL
        )
        #expect(artifacts.directoryURL == directory.resolvingSymlinksInPath())

        let aliasURL = directory.deletingLastPathComponent().appendingPathComponent(
            "helix-dev-process-alias-(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: directory
        )
        defer { try? FileManager.default.removeItem(at: aliasURL) }
        let aliasedArtifacts = try DevProcess.SupervisedArtifacts(
            bootstrapURL: aliasURL.appendingPathComponent("Bootstrap.private.json"),
            lifecycleLockURL: aliasURL.appendingPathComponent("Daemon.lock")
        )
        #expect(aliasedArtifacts.directoryURL == artifacts.directoryURL)
        try aliasedArtifacts.cleanupPrivateHandoff()
        #expect(!FileManager.default.fileExists(atPath: bootstrapURL.path))
        #expect(!FileManager.default.fileExists(atPath: lldbURL.path))
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
        #expect(throws: DevProcess.Error.self) {
            _ = try DevProcess.SupervisedArtifacts(
                bootstrapURL: bootstrapURL,
                lifecycleLockURL: directory.deletingLastPathComponent()
                    .appendingPathComponent("Daemon.lock")
            )
        }

        first.unlock()
        #expect(try !DevProcess.LifetimeLock.isHeld(at: lockURL))

        #expect(chmod(lockURL.path, 0o644) == 0)
        #expect(throws: DevProcess.Error.insecureFile(lockURL.path)) {
            try DevProcess.LifetimeLock(url: lockURL)
        }
    }

    private func bootstrapDocument() -> DevProcess.BootstrapDocument {
        .init(
            target: .simulator,
            environment: [
                "HLX_DEV_PROTOCOL_VERSION": "1",
                "HLX_DEV_SESSION_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "HLX_DEV_SERVICE_NAME": "Helix-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "HLX_DEV_SPKI_SHA256": String(repeating: "a", count: 64),
                "HLX_DEV_SESSION_SECRET": String(repeating: "b", count: 64),
                "HLX_DEV_HOST": "127.0.0.1",
                "HLX_DEV_PORT": "49152",
            ]
        )
    }
}
}
