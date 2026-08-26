import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("Stable native-call verification")
struct NativeCall {
    @Test("Policy diagnostics identify the Swift call site and stable key")
    func diagnosticContext() throws {
        let fixture = try makeFixture()
        var deniedPolicy = fixture.policy
        deniedPolicy.allowedNativeCalls = []
        let context = Verification.NativeCallContext(
            key: fixture.requirement.key,
            location: fixture.location
        )

        #expect(throws: Verification.Error.nativeCallDenied(context)) {
            try Verification.Engine().verify(
                bytes: fixture.bytes,
                shell: fixture.shell,
                policy: deniedPolicy
            )
        }
        #expect(
            Verification.Error.nativeCallDenied(context).description
                == "runtime policy denies Sources/Patch.swift:42:13: native call "
                    + fixture.requirement.key.description
        )

        let missingShell = try Verification.ShellInterface(
            interfaceHash: fixture.shell.interfaceHash,
            compatibility: fixture.shell.compatibility,
            capabilities: fixture.shell.capabilities,
            entries: Array(fixture.shell.entries.values)
        )
        #expect(throws: Verification.Error.unknownNativeCall(context)) {
            try Verification.Engine().verify(
                bytes: fixture.bytes,
                shell: missingShell,
                policy: fixture.policy
            )
        }
    }

    @Test("Descriptor and key tampering fail at the signed boundary")
    func rejectsTampering() throws {
        let fixture = try makeFixture()

        var descriptorTamper = fixture.module
        descriptorTamper.imports[0].descriptor.target.entryPoint =
            "Fixture.alternate(_:)"
        #expect(throws: Verification.Error.nativeCallDescriptorMismatch(
            .init(key: fixture.requirement.key, location: fixture.location)
        )) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(descriptorTamper),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var keyTamper = fixture.module
        let forged = Core.NativeCall.Key(rawValue: .sha256("forged-native-call"))
        keyTamper.imports[0].key = forged
        var forgedPolicy = fixture.policy
        forgedPolicy.allowedNativeCalls = [forged]
        #expect(throws: Verification.Error.nativeCallDescriptorMismatch(
            .init(key: forged, location: fixture.location)
        )) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(keyTamper),
                shell: fixture.shell,
                policy: forgedPolicy
            )
        }
    }

    @Test("Compact slots cannot duplicate one stable native call")
    func rejectsDuplicateStableKeys() throws {
        let fixture = try makeFixture()
        let second = try nativeImport(
            id: .init(rawValue: 1),
            canonicalCallee: "Fixture.other(_:)"
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: fixture.shell.interfaceHash,
            compatibility: fixture.shell.compatibility,
            capabilities: fixture.shell.capabilities,
            entries: Array(fixture.shell.entries.values),
            imports: [fixture.shellImport, second.shell]
        )
        var module = fixture.module
        var duplicate = fixture.requirement
        duplicate.id = second.requirement.id
        module.imports.append(duplicate)
        #expect(throws: Verification.Error.duplicateNativeCall(
            .init(key: fixture.requirement.key)
        )) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(module),
                shell: shell,
                policy: fixture.policy
            )
        }

        var duplicateSlot = second.shell
        duplicateSlot.key = fixture.shellImport.key
        duplicateSlot.descriptor = fixture.shellImport.descriptor
        duplicateSlot.contract = fixture.shellImport.contract
        #expect(throws: Verification.Error.invalidShellInterface(
            "native call keys must be unique across compact import slots"
        )) {
            try Verification.ShellInterface(
                interfaceHash: fixture.shell.interfaceHash,
                compatibility: fixture.shell.compatibility,
                capabilities: fixture.shell.capabilities,
                entries: Array(fixture.shell.entries.values),
                imports: [fixture.shellImport, duplicateSlot]
            )
        }
    }

    private struct Fixture {
        var bytes: Data
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var shellImport: Verification.ResolvedNativeImport
        var policy: Core.RuntimePolicy
        var requirement: Bytecode.ImportRequirement
        var location: Core.SourceLocation
    }

    private func makeFixture() throws -> Fixture {
        let native = try nativeImport(
            id: .init(rawValue: 0),
            canonicalCallee: "Fixture.increment(_:)"
        )
        let shellHash = Core.Digest.sha256("stable-native-call-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "stable-native-call-verifier"
        )
        let location = Core.SourceLocation(
            file: "Sources/Patch.swift",
            line: 42,
            column: 13
        )
        let entryKey = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.stable-native-call",
                buildNumber: "1",
                seed: "verifier-fixture"
            ),
            module: "StableNativeCallFixture",
            sourceFileLogicalID: location.file,
            canonicalDeclaration: "func root(_ value: Int)",
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Void"
            ),
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "root",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .void,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeApply(
                            result: nil,
                            importID: native.requirement.id,
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
        let module = Bytecode.Module(
            name: "StableNativeCallFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: [.baselineV1, .nativeImportsV1],
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: entryKey,
                    functionID: function.id
                ),
            ],
            imports: [native.requirement],
            sourceMap: [
                .init(
                    functionID: function.id,
                    blockID: .init(rawValue: 0),
                    instructionOffset: 0,
                    location: location
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: module.capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: entryKey,
                    parameterTypes: [.int64],
                    parameterConventions: [.owned],
                    resultType: .void
                ),
            ],
            imports: [native.shell]
        )
        let policy = Core.RuntimePolicy(
            acceptedCapabilities: module.capabilities,
            allowedNativeCalls: [native.requirement.key]
        )
        return .init(
            bytes: try Bytecode.Encoder.encode(module),
            module: module,
            shell: shell,
            shellImport: native.shell,
            policy: policy,
            requirement: native.requirement,
            location: location
        )
    }

    private func nativeImport(
        id: Core.NativeImportID,
        canonicalCallee: String
    ) throws -> (
        requirement: Bytecode.ImportRequirement,
        shell: Verification.ResolvedNativeImport
    ) {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: canonicalCallee,
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: contract
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        return (
            .init(
                id: id,
                key: key,
                descriptor: descriptor,
                contract: contract
            ),
            .init(
                id: id,
                key: key,
                descriptor: descriptor,
                parameterTypes: [.int64],
                resultType: .void,
                contract: contract
            )
        )
    }
}
}
