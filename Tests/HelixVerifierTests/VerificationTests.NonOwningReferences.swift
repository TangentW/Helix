import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC non-owning reference verification")
struct NonOwningReferences {
    @Test("Non-owning storage is capability gated even when unused")
    func requiresCapabilityForUnusedStorage() throws {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let storage = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.local(owner))
        )
        let fixture = try makeFixture(
            storageType: storage,
            capabilities: [.baselineV1, .localNominalsV1, .localClassesV1],
            localTypes: [localClass(owner)]
        )

        #expect(
            throws: Verification.Error.capabilityDenied(
                .nonOwningReferencesV1
            )
        ) {
            try verify(fixture)
        }
    }

    @Test("Non-owning storage cannot enter stack-slot layout")
    func rejectsStackSlotStorage() throws {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let storage = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.local(owner))
        )
        let fixture = try makeFixture(
            storageType: .int64,
            capabilities: localCapabilities,
            localTypes: [localClass(owner)],
            stackSlotTypes: [storage]
        )

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "non-owning reference storage cannot be stored in stack slots"
            )
        ) {
            try verify(fixture)
        }
    }

    @Test("Weak storage requires an Optional strong value")
    func rejectsNonoptionalWeakStorage() throws {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let fixture = try makeFixture(
            storageType: .nonOwningReference(
                kind: .weak,
                pointee: .local(owner)
            ),
            capabilities: localCapabilities,
            localTypes: [localClass(owner)]
        )

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "weak references must load an Optional value"
            )
        ) {
            try verify(fixture)
        }
    }

    @Test("Unused storage still requires a concrete class referent")
    func rejectsUnusedLocalValueStorage() throws {
        let value = Bytecode.LocalTypeKey(rawValue: "Fixture.Value")
        let fixture = try makeFixture(
            storageType: .nonOwningReference(
                kind: .weak,
                pointee: .optional(.local(value))
            ),
            capabilities: localCapabilities,
            localTypes: [
                .init(key: value, kind: .structure(fields: [])),
            ]
        )

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "non-owning reference pointee must be a local or native class"
            )
        ) {
            try verify(fixture)
        }
    }

    @Test("Native value TypeOps cannot back non-owning storage")
    func rejectsNativeValueStorage() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.NativeValue"))
        let capabilities = Set<Core.Capability>([
            .baselineV1, .nativeTypesV1, .nonOwningReferencesV1,
        ])
        let nativeType = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Fixture.NativeValue",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.NativeValue.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let fixture = try makeFixture(
            storageType: .nonOwningReference(
                kind: .weak,
                pointee: .optional(.native(typeID))
            ),
            capabilities: capabilities,
            nativeTypes: [nativeType]
        )

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "non-owning reference pointee must be a local or native class"
            )
        ) {
            try verify(fixture)
        }
    }

    @Test("Non-owning instructions require an exactly matching strong value")
    func rejectsMismatchedInitializer() throws {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let storage = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.local(owner))
        )
        let fixture = try makeFixture(
            storageType: storage,
            capabilities: localCapabilities,
            localTypes: [localClass(owner)],
            instructions: [
                .makeNonOwningReference(
                    result: .init(rawValue: 1),
                    initialValue: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_nonowning_reference requires a matching class reference pointee"
            )
        ) {
            try verify(fixture)
        }
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private var localCapabilities: Set<Core.Capability> {
        [
            .baselineV1,
            .localNominalsV1,
            .localClassesV1,
            .nonOwningReferencesV1,
        ]
    }

    private func localClass(
        _ key: Bytecode.LocalTypeKey
    ) -> Bytecode.LocalTypeDefinition {
        .init(
            key: key,
            kind: .class(
                fields: [],
                hostedSuperclass: nil,
                hostedMethods: []
            )
        )
    }

    private func makeFixture(
        storageType: Bytecode.ValueType,
        capabilities: Set<Core.Capability>,
        localTypes: [Bytecode.LocalTypeDefinition] = [],
        nativeTypes: [Verification.ResolvedNativeType] = [],
        stackSlotTypes: [Bytecode.ValueType] = [],
        instructions: [Bytecode.Instruction]? = nil
    ) throws -> Fixture {
        let shellHash = Core.Digest.sha256("non-owning-verifier-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier.non-owning",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "non-owning-verifier-fixture"
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, storageType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: instructions
                        ?? [.returnValue(.init(rawValue: 0))]
                ),
            ],
            stackSlotTypes: stackSlotTypes
        )
        let module = Bytecode.Module(
            name: "NonOwningVerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            localTypes: localTypes,
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: function.id
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: [.int64],
                    parameterConventions: function.parameterConventions,
                    resultType: .int64
                ),
            ],
            types: nativeTypes
        )
        return .init(
            module: module,
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
    }

    private func verify(_ fixture: Fixture) throws {
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }
}
}
