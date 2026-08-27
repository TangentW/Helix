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
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "test-toolchain"
        )
        let nativeContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.nativeValue()",
            signature: .init(parameters: [], result: "Swift.Int"),
            effects: .init(),
            contract: nativeContract
        )
        let callKey = try Core.NativeCall.Key.derive(descriptor: descriptor)
        let manifest = Core.NativeCapability.Manifest(
            identity: .init(
                bundleID: "dev.helix.patch-runtime",
                buildNumber: "7",
                shellNamespaceID: namespace,
                shellInterfaceHash: interfaceHash,
                targetTriple: "arm64-apple-ios15.0-simulator",
                minimumOSVersion: .init(15),
                xcodeBuild: "18A1",
                sdkBuild: "22A1",
                compatibility: compatibility
            ),
            capabilities: [.baselineV1, .nativeImportsV1],
            entries: [
                .init(
                    id: .init(rawValue: 0),
                    key: callKey,
                    descriptor: descriptor,
                    contract: nativeContract
                ),
            ]
        )
        let contract = try PatchRuntime.BuildContract(
            bundleID: "dev.helix.patch-runtime",
            buildNumber: "7",
            shellNamespaceID: namespace,
            shellInterfaceHash: interfaceHash,
            minimumOSVersion: .init(15),
            compatibility: compatibility,
            capabilities: [.baselineV1, .nativeImportsV1],
            nativeCapabilityManifest: manifest
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
        let manifestHash = try manifest.contentHash()
        #expect(target.nativeCapabilityManifestHash == manifestHash)
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
                nativeCapabilityManifest: manifest
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
