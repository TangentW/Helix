import Foundation
import HelixCore
import Testing
@testable import HelixPatch

extension PatchTests {
@Suite("Patch metadata")
struct Metadata {
    @Test func moduleUsesV1Format() {
        #expect(PatchPackage.Metadata.version.major == 1)
    }

    @Test("Patch Runtime derives one exact target and least-privilege policy")
    func runtimeBuildContract() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.patch-runtime",
            buildNumber: "7",
            seed: "patch-runtime-test"
        )
        let interfaceHash = Core.Digest.sha256("shell")
        let callKey = Core.NativeCall.Key(rawValue: .sha256("fixture-native-call"))
        let contract = try PatchRuntime.BuildContract(
            bundleID: "dev.helix.patch-runtime",
            buildNumber: "7",
            shellNamespaceID: namespace,
            shellInterfaceHash: interfaceHash,
            minimumOSVersion: .init(15),
            compatibility: .init(
                runtime: .init(1),
                bytecode: .init(1, 9),
                interfaceArchive: .init(2, 3),
                compilerFingerprint: "test-toolchain"
            ),
            capabilities: [.baselineV1, .nativeImportsV1],
            nativeCallKeys: [callKey]
        )
        let process = try PatchRuntime.ProcessIdentity(
            bundleID: "dev.helix.patch-runtime",
            marketingVersion: "1.2.3",
            executableUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            architecture: "arm64",
            platform: .iOSSimulator,
            operatingSystemVersion: .init(18)
        )
        let target = try contract.targetContext(
            process: process,
            installationID: "installation-1"
        )
        #expect(target.machOUUID == process.executableUUID)
        #expect(target.shellInterfaceHash == interfaceHash)
        #expect(contract.runtimePolicy().allowedNativeCalls == [callKey])
        #expect(contract.runtimePolicy().productionChannelEnabled)
        #expect(throws: PatchRuntime.Error.invalidBuildContract) {
            try PatchRuntime.BuildContract(
                bundleID: contract.bundleID,
                buildNumber: contract.buildNumber,
                shellNamespaceID: contract.shellNamespaceID,
                shellInterfaceHash: contract.shellInterfaceHash,
                minimumOSVersion: contract.minimumOSVersion,
                compatibility: contract.compatibility,
                capabilities: [.baselineV1],
                nativeCallKeys: [callKey]
            )
        }
        #expect(throws: PatchRuntime.Error.invalidProcessIdentity(
            "required field is missing"
        )) {
            _ = try PatchRuntime.ProcessIdentity(
                bundleID: "dev.helix.patch-runtime",
                marketingVersion: "development",
                executableUUID: process.executableUUID,
                architecture: "arm64",
                platform: .iOSSimulator,
                operatingSystemVersion: .init(18)
            )
        }
    }
}
}
