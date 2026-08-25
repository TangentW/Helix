import Foundation
import HelixCore
import HelixDevProtocol
@testable import HelixDevRuntime
import HelixLiveReloadAPI
import Testing

extension DevRuntimeTests {
@Suite("Helix Hub App connection")
struct DevConnectionBootstrap {
    @Test("Launch policy is determined only by debugger attachment")
    func launchModeResolution() {
        #expect(DevRuntime.LaunchMode.resolve(debuggerAttached: true) == .automaticXcode)
        #expect(DevRuntime.LaunchMode.resolve(debuggerAttached: false) == .manual)
    }

    @Test("Hub contract and pairing configuration never disclose invitations")
    func redactsPairingMaterial() throws {
        let code = try Pairing.Code("a7kp")
        let contract = try makeHubContract(automaticPairingCode: code)
        let configuration = try DevConnection.Configuration(
            hubContract: contract,
            pairingCode: code
        )

        #expect(contract.automaticPairingCode == code)
        #expect(contract.description.contains(code.rawValue) == false)
        #expect(configuration.description.contains(code.rawValue) == false)
        #expect(configuration.expectedSPKIHash == contract.expectedSPKIHash)
        #expect(configuration.pairingCode == code)

        var reflected = ""
        dump(contract, to: &reflected)
        dump(configuration, to: &reflected)
        #expect(reflected.contains(code.rawValue) == false)
    }

    @Test("Hub contract rejects a different protocol generation")
    func rejectsProtocolMismatch() {
        #expect(throws: DevConnection.Error.protocolVersionMismatch) {
            _ = try DevRuntime.HubContract(
                protocolVersion: DevProtocol.Metadata.currentProtocolVersion + 1,
                expectedSPKIHash: .sha256("host")
            )
        }
    }

    @Test("Pairing codes normalize case and reject ambiguous input")
    func validatesPairingCode() throws {
        #expect(try Pairing.Code(" a7kp\n").rawValue == "A7KP")
        #expect(throws: DevProtocol.Error.invalidPairingCode) {
            _ = try Pairing.Code("AIL0")
        }
        #expect(throws: DevProtocol.Error.invalidPairingCode) {
            _ = try Pairing.Code("ABC")
        }
    }

    @Test("Reconnect policy bounds discovery, TLS, pairing, and retry delays")
    func reconnectPolicyValidation() throws {
        try DevConnection.ReconnectPolicy().validate()
        #expect(throws: DevConnection.Error.invalidConfiguration) {
            try DevConnection.ReconnectPolicy(
                initialDelayNanoseconds: 2,
                maximumDelayNanoseconds: 1
            ).validate()
        }
        #expect(throws: DevConnection.Error.invalidConfiguration) {
            try DevConnection.ReconnectPolicy(
                pairingTimeoutNanoseconds: 0
            ).validate()
        }
    }

    @Test("Bootstrap options fail before discovery when backend or cache is invalid")
    func validatesBootstrapOptions() throws {
        #expect(throws: DevProtocol.Error.self) {
            try DevRuntime.Bootstrap.Options(
                supportedBackends: [.hlbc],
                nativeChainingProbePassed: true
            ).validate()
        }
        #expect(throws: DevActivation.ConfigurationError.invalidCacheDirectory) {
            try DevRuntime.Bootstrap.Options(
                cacheDirectory: URL(string: "https://example.invalid/cache")
            ).validate()
        }
        try DevRuntime.Bootstrap.Options(
            isEnabled: true,
            supportedBackends: [.hlbc]
        ).validate()
        let explicitNative = DevRuntime.Bootstrap.Options(
            supportedBackends: [.hlbc, .nativeDynamicReplacement]
        )
        #expect(!explicitNative.nativeChainingProbePassed)
        try explicitNative.validate()
    }

    @Test("Identity construction waits for the granted Shell ID")
    func makesPeerThenSessionIdentity() throws {
        let build = try makeBuildContract()
        let executableUUID = UUID()
        let process = try makeProcess(
            build: build,
            executableUUID: executableUUID,
            processID: 42
        )
        let factory = DevRuntime.IdentityFactory()
        let peer = try factory.makePeer(
            build: build,
            process: process,
            supportedBackends: [.nativeDynamicReplacement, .hlbc]
        )

        #expect(peer.build.bundleID == build.bundleID)
        #expect(peer.build.executableUUID == executableUUID)
        #expect(peer.processID == 42)
        #expect(peer.supportedBackends == [.hlbc, .nativeDynamicReplacement])

        let shellID = DevProtocol.ShellID(rawValue: UUID())
        let session = try factory.makeSession(
            shellID: shellID,
            peer: peer,
            nativeChainingProbePassed: true
        )
        #expect(session.sessionID == shellID.rawValue)
        #expect(session.matchesBuild(of: session))
        #expect(session.nativeChainingProbePassed)
    }

    @Test("Peer identity rejects stale process dimensions independently")
    func rejectsStaleProcessIdentity() throws {
        let build = try makeBuildContract()
        let process = try makeProcess(build: build)
        let factory = DevRuntime.IdentityFactory()

        var staleBundle = process
        staleBundle.bundleID = "dev.helix.stale"
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("bundle ID")) {
            _ = try factory.makePeer(
                build: build,
                process: staleBundle,
                supportedBackends: [.hlbc]
            )
        }

        var stalePlatform = process
        stalePlatform.platform = .iOS
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("platform")) {
            _ = try factory.makePeer(
                build: build,
                process: stalePlatform,
                supportedBackends: [.hlbc]
            )
        }

        var staleArchitecture = process
        staleArchitecture.architecture = "x86_64"
        #expect(throws: DevRuntime.BootstrapError.buildMismatch("architecture")) {
            _ = try factory.makePeer(
                build: build,
                process: staleArchitecture,
                supportedBackends: [.hlbc]
            )
        }
    }

    @Test("Identity factory rejects overlapping Helix package products")
    func rejectsDuplicateRuntimeImages() throws {
        var build = try makeBuildContract()
        build.runtimeImageIdentity = .init()
        let process = try makeProcess(build: build)

        #expect(throws: DevRuntime.BootstrapError.duplicateRuntimeImages) {
            _ = try DevRuntime.IdentityFactory().makePeer(
                build: build,
                process: process,
                supportedBackends: [.hlbc]
            )
        }
    }

    @Test("Native probe state cannot be claimed by an HLBC-only peer")
    func rejectsUnsupportedNativeProbe() throws {
        let build = try makeBuildContract()
        let peer = try DevRuntime.IdentityFactory().makePeer(
            build: build,
            process: makeProcess(build: build),
            supportedBackends: [.hlbc]
        )
        #expect(throws: DevProtocol.Error.self) {
            _ = try DevRuntime.IdentityFactory().makeSession(
                shellID: .init(rawValue: UUID()),
                peer: peer,
                nativeChainingProbePassed: true
            )
        }
    }

    @Test("Build and process placeholders fail closed")
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
    }

    private func makeHubContract(
        automaticPairingCode: Pairing.Code? = nil
    ) throws -> DevRuntime.HubContract {
        try .init(
            expectedSPKIHash: .sha256("persistent-host-identity"),
            automaticPairingCode: automaticPairingCode
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

    private func makeProcess(
        build: DevRuntime.BuildContract,
        executableUUID: UUID = UUID(),
        processID: Int32 = 73
    ) throws -> DevRuntime.ProcessIdentity {
        try .init(
            bundleID: build.bundleID,
            executableUUID: executableUUID,
            processID: processID,
            platform: build.platform,
            architecture: build.architecture,
            operatingSystemBuild: "25G91"
        )
    }
}
}
