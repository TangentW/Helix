import Foundation
import HelixCore
import HelixDevProtocol
@testable import HelixDevRuntime
import HelixLiveReloadAPI
import Testing

extension DevRuntimeTests {
@Suite("Device Dev connection bootstrap")
struct DevConnectionBootstrap {
    @Test("Runtime polling outlives the LLDB installer deadline")
    func debuggerHandoffTiming() {
        let timing = DevProtocol.DebuggerHandoffTiming.self
        #expect(
            DevRuntime.DebuggerHandoff.defaultIntervalNanoseconds
                == timing.pollIntervalNanoseconds
        )
        #expect(
            DevRuntime.DebuggerHandoff.defaultMaximumAttempts
                == timing.runtimeMaximumAttempts
        )

        let runtimeWindow =
            UInt64(timing.runtimeMaximumAttempts - 1) * timing.pollIntervalNanoseconds
        let installerWindow = UInt64(timing.installerTimeoutSeconds) * 1_000_000_000
        #expect(runtimeWindow > installerWindow)
    }

    @Test("Debugger handoff accepts only a complete session-marked snapshot")
    func debuggerHandoffReadiness() async {
        let sessionID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let source = HandoffEnvironmentSource([
            [:],
            [
                "HLX_DEV_SESSION_ID": sessionID,
                "HLX_DEV_HANDOFF_READY": "stale-session",
            ],
            [
                "HLX_DEV_SESSION_ID": sessionID,
                "HLX_DEV_HANDOFF_READY": sessionID,
            ],
        ])
        let environment = await DevRuntime.DebuggerHandoff.waitForEnvironment(
            maximumAttempts: 3,
            intervalNanoseconds: 1,
            environment: { source.next() }
        )
        #expect(environment?["HLX_DEV_SESSION_ID"] == sessionID)

        let partial = await DevRuntime.DebuggerHandoff.waitForEnvironment(
            maximumAttempts: 1,
            intervalNanoseconds: 0,
            environment: {
                [
                    "HLX_DEV_SESSION_ID": sessionID,
                    "HLX_DEV_HANDOFF_READY": "different-session",
                ]
            }
        )
        #expect(partial == nil)
    }

    @Test("Debugger handoff cancellation ends the bounded wait")
    func debuggerHandoffCancellation() async {
        let task = Task {
            await DevRuntime.DebuggerHandoff.waitForEnvironment(
                maximumAttempts: 1_000,
                intervalNanoseconds: 1_000_000_000,
                environment: { [:] }
            )
        }
        await Task.yield()
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("Absent launch variables disable the Dev connection cleanly")
    func absentEnvironment() throws {
        #expect(try DevConnection.Configuration.load(environment: [:]) == nil)
    }

    @Test("Simulator and device launch environments select deterministic endpoints")
    func endpointSelection() throws {
        let sessionID = UUID()
        let secret = Data(repeating: 0x3c, count: 32)
        var environment = baseEnvironment(sessionID: sessionID, secret: secret)
        environment["HLX_DEV_HOST"] = "127.0.0.1"
        environment["HLX_DEV_PORT"] = "54321"
        let simulator = try #require(
            try DevConnection.Configuration.load(environment: environment)
        )
        #expect(simulator.sessionID == sessionID)
        #expect(simulator.sessionSecret == secret)
        #expect(simulator.endpoint == .direct(host: "127.0.0.1", port: 54_321))

        environment.removeValue(forKey: "HLX_DEV_HOST")
        environment.removeValue(forKey: "HLX_DEV_PORT")
        let device = try #require(
            try DevConnection.Configuration.load(environment: environment)
        )
        #expect(device.endpoint == .bonjour(serviceName: "Helix-12345678"))
    }

    @Test("Partial, stale, and malformed launch credentials fail closed")
    func rejectsMalformedEnvironment() throws {
        let sessionID = UUID()
        var environment = baseEnvironment(
            sessionID: sessionID,
            secret: Data(repeating: 0x7a, count: 32)
        )
        environment.removeValue(forKey: "HLX_DEV_SPKI_SHA256")
        #expect(throws: DevConnection.Error.invalidEnvironment) {
            _ = try DevConnection.Configuration.load(environment: environment)
        }

        environment = baseEnvironment(
            sessionID: sessionID,
            secret: Data(repeating: 0x7a, count: 32)
        )
        environment["HLX_DEV_PROTOCOL_VERSION"] = "1"
        #expect(throws: DevConnection.Error.protocolVersionMismatch) {
            _ = try DevConnection.Configuration.load(environment: environment)
        }

        environment = baseEnvironment(
            sessionID: sessionID,
            secret: Data(repeating: 0x7a, count: 32)
        )
        environment["HLX_DEV_HOST"] = "127.0.0.1"
        #expect(throws: DevConnection.Error.invalidEnvironment) {
            _ = try DevConnection.Configuration.load(environment: environment)
        }
    }

    @Test("Reconnect policy is bounded and ordered")
    func reconnectPolicyValidation() throws {
        try DevConnection.ReconnectPolicy().validate()
        #expect(throws: DevConnection.Error.invalidEnvironment) {
            try DevConnection.ReconnectPolicy(
                initialDelayNanoseconds: 2,
                maximumDelayNanoseconds: 1
            ).validate()
        }
    }

    @Test("Identity factory combines frozen build values with measured process facts")
    func makesBoundProcessIdentity() throws {
        let sessionID = UUID()
        let connection = try makeConnection(sessionID: sessionID)
        let build = try makeBuildContract()
        let executableUUID = UUID()
        let process = try DevRuntime.ProcessIdentity(
            bundleID: build.bundleID,
            executableUUID: executableUUID,
            processID: 42,
            platform: build.platform,
            architecture: build.architecture,
            operatingSystemBuild: "25G91"
        )

        let identity = try DevRuntime.IdentityFactory().make(
            connection: connection,
            build: build,
            process: process,
            supportedBackends: [.nativeDynamicReplacement, .hlbc],
            nativeChainingProbePassed: true
        )

        #expect(identity.sessionID == sessionID)
        #expect(identity.bundleID == build.bundleID)
        #expect(identity.executableUUID == executableUUID)
        #expect(identity.processID == 42)
        #expect(identity.operatingSystemBuild == "25G91")
        #expect(identity.xcodeBuild == build.xcodeBuild)
        #expect(identity.swiftCompilerFingerprint == build.swiftCompilerFingerprint)
        #expect(identity.liveReloadIndexHash == build.liveReloadIndexHash)
        #expect(identity.supportedBackends == [.hlbc, .nativeDynamicReplacement])
        #expect(identity.nativeChainingProbePassed)
    }

    @Test("Identity factory rejects stale launch and process dimensions independently")
    func rejectsStaleProcessIdentity() throws {
        let sessionID = UUID()
        let connection = try makeConnection(sessionID: sessionID)
        let build = try makeBuildContract()
        let process = try DevRuntime.ProcessIdentity(
            bundleID: build.bundleID,
            executableUUID: UUID(),
            processID: 73,
            platform: build.platform,
            architecture: build.architecture,
            operatingSystemBuild: "25G91"
        )
        let factory = DevRuntime.IdentityFactory()

        var staleBundle = process
        staleBundle.bundleID = "dev.helix.stale"
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("bundle ID")) {
            _ = try factory.make(
                connection: connection,
                build: build,
                process: staleBundle,
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: false
            )
        }

        var stalePlatform = process
        stalePlatform.platform = .iOS
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("platform")) {
            _ = try factory.make(
                connection: connection,
                build: build,
                process: stalePlatform,
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: false
            )
        }

        var staleArchitecture = process
        staleArchitecture.architecture = "x86_64"
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("architecture")) {
            _ = try factory.make(
                connection: connection,
                build: build,
                process: staleArchitecture,
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: false
            )
        }
    }

    @Test("Identity factory rejects overlapping Helix package products")
    func rejectsDuplicateRuntimeImages() throws {
        let connection = try makeConnection(sessionID: UUID())
        var build = try makeBuildContract()
        build.runtimeImageIdentity = .init()
        let process = try DevRuntime.ProcessIdentity(
            bundleID: build.bundleID,
            executableUUID: UUID(),
            processID: 74,
            platform: build.platform,
            architecture: build.architecture,
            operatingSystemBuild: "25G91"
        )

        #expect(throws: DevRuntime.BootstrapError.duplicateRuntimeImages) {
            _ = try DevRuntime.IdentityFactory().make(
                connection: connection,
                build: build,
                process: process,
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: false
            )
        }
    }

    @Test("Build, process, and backend validation fail closed")
    func rejectsInvalidBootstrapInputs() throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(throws: DevRuntime.BootstrapError.invalidBuildContract) {
            _ = try DevRuntime.BuildContract(
                bundleID: "",
                platform: .iOSSimulator,
                architecture: "arm64",
                xcodeBuild: "17F113",
                swiftCompilerFingerprint: "swift-6.3.3-fixture",
                liveReloadIndexHash: .sha256("reload-index")
            )
        }
        #expect(throws: DevRuntime.BootstrapError.invalidProcessIdentity) {
            _ = try DevRuntime.ProcessIdentity(
                bundleID: "dev.helix.host",
                executableUUID: zero,
                processID: 0,
                platform: .iOSSimulator,
                architecture: "arm64",
                operatingSystemBuild: "25G91"
            )
        }

        let sessionID = UUID()
        #expect(throws: DevProtocol.Error.self) {
            _ = try DevRuntime.IdentityFactory().make(
                connection: makeConnection(sessionID: sessionID),
                build: makeBuildContract(),
                process: DevRuntime.ProcessIdentity(
                    bundleID: "dev.helix.host",
                    executableUUID: UUID(),
                    processID: 99,
                    platform: .iOSSimulator,
                    architecture: "arm64",
                    operatingSystemBuild: "25G91"
                ),
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: true
            )
        }
    }

    private func baseEnvironment(
        sessionID: UUID,
        secret: Data
    ) -> [String: String] {
        [
            "HLX_DEV_PROTOCOL_VERSION": String(
                DevProtocol.SessionIdentity.currentProtocolVersion
            ),
            "HLX_DEV_SESSION_ID": sessionID.uuidString,
            "HLX_DEV_SERVICE_NAME": "Helix-12345678",
            "HLX_DEV_SPKI_SHA256": Core.Digest.sha256("certificate").hex,
            "HLX_DEV_SESSION_SECRET": secret.map {
                String(format: "%02x", $0)
            }.joined(),
        ]
    }

    private func makeConnection(sessionID: UUID) throws -> DevConnection.Configuration {
        try .init(
            protocolVersion: DevProtocol.SessionIdentity.currentProtocolVersion,
            sessionID: sessionID,
            endpoint: .direct(host: "127.0.0.1", port: 54_321),
            expectedSPKIHash: .sha256("certificate"),
            sessionSecret: Data(repeating: 0x4a, count: 32)
        )
    }

    private func makeBuildContract() throws -> DevRuntime.BuildContract {
        try .init(
            bundleID: "dev.helix.host",
            platform: .iOSSimulator,
            architecture: "arm64",
            xcodeBuild: "17F113",
            swiftCompilerFingerprint: "swift-6.3.3-fixture",
            liveReloadIndexHash: .sha256("reload-index")
        )
    }

    private final class HandoffEnvironmentSource: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[String: String]]

        init(_ snapshots: [[String: String]]) {
            self.snapshots = snapshots
        }

        func next() -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            guard snapshots.count > 1 else { return snapshots.first ?? [:] }
            return snapshots.removeFirst()
        }
    }
}
}
