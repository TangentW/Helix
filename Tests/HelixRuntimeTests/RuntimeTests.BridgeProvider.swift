import Foundation
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
        let shellFactoryCalls = Counter()
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
                shellFactoryCalls.increment()
                return try Verification.ShellInterface(
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
        #expect(shellFactoryCalls.value == 1)
    }

    @Test("Provider fails closed on malformed metadata and mixed interfaces")
    func rejectsInvalidGraph() throws {
        var invalid = makeDescriptor()
        invalid.architecture = "arm64e"
        #expect(throws: Runtime.BridgeProviderError.invalidDescriptor) {
            try invalid.validate()
        }

        invalid = makeDescriptor()
        invalid.nativeCapabilityManifest.capabilities.append(.nativeImportsV1)
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
        let bundleID = "dev.helix.fixture"
        let buildNumber = "1"
        let namespace: Core.ShellNamespaceID = .derive(
            bundleID: bundleID,
            buildNumber: buildNumber,
            seed: "fixture"
        )
        let interfaceHash = Core.Digest.sha256("fixture-interface")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "fixture-swift"
        )
        let manifest = Core.NativeCapability.Manifest(
            identity: .init(
                bundleID: bundleID,
                buildNumber: buildNumber,
                shellNamespaceID: namespace,
                shellInterfaceHash: interfaceHash,
                targetTriple: "arm64-apple-ios15.0-simulator",
                minimumOSVersion: .init(15, 0, 0),
                xcodeBuild: "18A1",
                sdkBuild: "22A1",
                compatibility: compatibility
            ),
            capabilities: [.baselineV1],
            entries: []
        )
        return Runtime.BridgeDescriptor(
            bundleID: bundleID,
            buildNumber: buildNumber,
            shellNamespaceID: namespace,
            shellInterfaceHash: interfaceHash,
            minimumOSVersion: .init(15, 0, 0),
            compatibility: compatibility,
            capabilities: [.baselineV1],
            nativeCapabilityManifest: manifest,
            platform: .iOSSimulator,
            architecture: "arm64",
            xcodeBuild: "18A1",
            sdkBuild: "22A1",
            liveReloadIndexHash: .sha256("reload-index")
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int { lock.withLock { storage } }

        func increment() {
            lock.withLock { storage += 1 }
        }
    }
}
}
