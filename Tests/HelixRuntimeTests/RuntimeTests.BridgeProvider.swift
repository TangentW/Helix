import HelixCore
@testable import HelixRuntime
import HelixVerifier
import Testing

extension RuntimeTests {
@Suite("Linked Bridge provider")
struct BridgeProvider {
    @Test("Provider validates one coherent runtime and Shell identity")
    func coherentGraph() throws {
        let descriptor = makeDescriptor()
        let provider = Runtime.BridgeProvider(
            descriptor: descriptor,
            makeRuntime: { registry, observer in
                Runtime.Engine(
                    registry: registry,
                    originals: try Runtime.OriginalCatalog([]),
                    shellInterfaceHash: descriptor.shellInterfaceHash,
                    observer: observer
                )
            },
            makeShellInterface: {
                try Verification.ShellInterface(
                    interfaceHash: descriptor.shellInterfaceHash,
                    compatibility: descriptor.compatibility
                )
            },
            install: { _ in }
        )

        let runtime = try provider.makeRuntime()
        let shell = try provider.makeShellInterface()
        try provider.install(on: runtime)
        #expect(runtime.shellInterfaceHash == descriptor.shellInterfaceHash)
        #expect(shell.interfaceHash == descriptor.shellInterfaceHash)
    }

    @Test("Provider fails closed on malformed metadata and mixed interfaces")
    func rejectsInvalidGraph() throws {
        var invalid = makeDescriptor()
        invalid.architecture = "arm64e"
        #expect(throws: Runtime.BridgeProviderError.invalidDescriptor) {
            try invalid.validate()
        }

        let descriptor = makeDescriptor()
        let provider = Runtime.BridgeProvider(
            descriptor: descriptor,
            makeRuntime: { _, _ in
                Runtime.Engine(
                    originals: try Runtime.OriginalCatalog([]),
                    shellInterfaceHash: .sha256("different")
                )
            },
            makeShellInterface: {
                try Verification.ShellInterface(
                    interfaceHash: descriptor.shellInterfaceHash,
                    compatibility: descriptor.compatibility
                )
            },
            install: { _ in }
        )
        #expect(throws: Runtime.BridgeProviderError.interfaceMismatch) {
            try provider.makeRuntime()
        }
    }

    private func makeDescriptor() -> Runtime.BridgeDescriptor {
        Runtime.BridgeDescriptor(
            bundleID: "dev.helix.fixture",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.fixture",
                buildNumber: "1",
                seed: "fixture"
            ),
            shellInterfaceHash: .sha256("fixture-interface"),
            minimumOSVersion: .init(15, 0, 0),
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "fixture-swift"
            ),
            capabilities: [.baselineV1],
            nativeImportIDs: [],
            platform: .iOSSimulator,
            architecture: "arm64",
            xcodeBuild: "18A1",
            liveReloadIndexHash: .sha256("reload-index")
        )
    }
}
}
