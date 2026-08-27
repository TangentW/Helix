import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Production native capability validation")
struct NativeCapability {
    @Test("Runtime accepts one exact immutable Manifest, Shell, and Registry")
    func acceptsExactAuthority() throws {
        let fixture = try Fixture()
        try fixture.runtime().validateNativeCapabilities(
            against: fixture.manifest,
            shell: fixture.shell()
        )
    }

    @Test("Runtime rejects missing, extra, and identity-drifted registrations")
    func rejectsRegistryDrift() throws {
        let fixture = try Fixture()
        let missing = Runtime.Engine(
            originals: try .init([]),
            shellInterfaceHash: fixture.identity.shellInterfaceHash
        )
        #expect(throws: Runtime.NativeCapabilityError.registryInventoryMismatch) {
            try missing.validateNativeCapabilities(
                against: fixture.manifest,
                shell: fixture.shell()
            )
        }

        let extraInvoker = VM.ClosureNativeInvoker(
            id: .init(rawValue: 1),
            key: .init(rawValue: .sha256("extra-native-call")),
            parameterTypes: [],
            resultType: .int64,
            contract: fixture.contract
        ) { _, _ in
            .returned(.integer(try VM.Integer(
                signed: 2,
                bitWidth: 64,
                isSigned: true
            )))
        }
        let extra = Runtime.Engine(
            originals: try .init([]),
            shellInterfaceHash: fixture.identity.shellInterfaceHash,
            nativeCatalog: try .init([fixture.invoker(), extraInvoker])
        )
        #expect(throws: Runtime.NativeCapabilityError.registryInventoryMismatch) {
            try extra.validateNativeCapabilities(
                against: fixture.manifest,
                shell: fixture.shell()
            )
        }

        let wrongKeyInvoker = VM.ClosureNativeInvoker(
            id: fixture.entry.id,
            key: .init(rawValue: .sha256("wrong-native-call")),
            parameterTypes: [],
            resultType: .int64,
            contract: fixture.contract
        ) { _, _ in
            .returned(.integer(try VM.Integer(
                signed: 1,
                bitWidth: 64,
                isSigned: true
            )))
        }
        let wrongIdentity = Runtime.Engine(
            originals: try .init([]),
            shellInterfaceHash: fixture.identity.shellInterfaceHash,
            nativeCatalog: try .init([wrongKeyInvoker])
        )
        #expect(throws: Runtime.NativeCapabilityError.entryMismatch(
            fixture.entry.key
        )) {
            try wrongIdentity.validateNativeCapabilities(
                against: fixture.manifest,
                shell: fixture.shell()
            )
        }
    }

    @Test("Runtime rejects a Shell that does not publish the signed table")
    func rejectsShellDrift() throws {
        let fixture = try Fixture()
        let shell = try Verification.ShellInterface(
            interfaceHash: fixture.identity.shellInterfaceHash,
            compatibility: fixture.identity.compatibility,
            capabilities: [.baselineV1, .nativeImportsV1]
        )

        #expect(throws: Runtime.NativeCapabilityError.shellMismatch) {
            try fixture.runtime().validateNativeCapabilities(
                against: fixture.manifest,
                shell: shell
            )
        }
    }

    @Test("Device ABI evidence is reused only after successful validation")
    func cachesSuccessfulDeviceEvidence() throws {
        let state = Runtime.NativeCapabilityValidationState()
        let hash = Core.Digest.sha256("device-abi-cache")
        var attempts = 0

        #expect(throws: Runtime.NativeCapabilityError.shellMismatch) {
            try state.validateOnce(for: hash) {
                attempts += 1
                throw Runtime.NativeCapabilityError.shellMismatch
            }
        }
        try state.validateOnce(for: hash) { attempts += 1 }
        try state.validateOnce(for: hash) { attempts += 1 }

        #expect(attempts == 2)
        #expect(throws: Runtime.NativeCapabilityError.manifestIdentityMismatch) {
            try state.validateOnce(for: .sha256("different-device-abi-table")) {
                attempts += 1
            }
        }
        #expect(attempts == 2)
    }
}
}

extension RuntimeTests.NativeCapability {
private struct Fixture {
    let identity: Core.NativeCapability.Identity
    let contract: Core.NativeImportContract
    let entry: Core.NativeCapability.Entry

    init() throws {
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "fixture-swift"
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.native-runtime",
            buildNumber: "1",
            seed: "native-runtime-test"
        )
        identity = .init(
            bundleID: "dev.helix.native-runtime",
            buildNumber: "1",
            shellNamespaceID: namespace,
            shellInterfaceHash: .sha256("native-runtime-shell"),
            targetTriple: "arm64-apple-ios15.0-simulator",
            minimumOSVersion: .init(15),
            xcodeBuild: "18A1",
            sdkBuild: "22A1",
            compatibility: compatibility
        )
        contract = .bounded(
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
            contract: contract
        )
        entry = .init(
            id: .init(rawValue: 0),
            key: try Core.NativeCall.Key.derive(descriptor: descriptor),
            descriptor: descriptor,
            contract: contract
        )
    }

    var manifest: Core.NativeCapability.Manifest {
        .init(
            identity: identity,
            capabilities: [.baselineV1, .nativeImportsV1],
            entries: [entry]
        )
    }

    func invoker() -> VM.ClosureNativeInvoker {
        .init(
            id: entry.id,
            key: entry.key,
            parameterTypes: [],
            resultType: .int64,
            contract: contract
        ) { _, _ in
            .returned(.integer(try VM.Integer(
                signed: 1,
                bitWidth: 64,
                isSigned: true
            )))
        }
    }

    func shell() throws -> Verification.ShellInterface {
        try .init(
            interfaceHash: identity.shellInterfaceHash,
            compatibility: identity.compatibility,
            capabilities: [.baselineV1, .nativeImportsV1],
            imports: [
                .init(
                    id: entry.id,
                    key: entry.key,
                    descriptor: entry.descriptor,
                    parameterTypes: [],
                    resultType: .int64,
                    contract: contract
                ),
            ]
        )
    }

    func runtime() throws -> Runtime.Engine {
        Runtime.Engine(
            originals: try .init([]),
            shellInterfaceHash: identity.shellInterfaceHash,
            nativeCatalog: try .init([invoker()])
        )
    }
}
}
