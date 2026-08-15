import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC Set verification")
struct SetSemantics {
    @Test("VM Hashable classification is bounded and fail-closed")
    func boundsRecursiveHashableTypes() throws {
        var type = Bytecode.ValueType.int64
        for _ in 0..<64 { type = .optional(type) }

        #expect(!type.isVMHashable)
        #expect(!Bytecode.ValueType.tuple([.int64]).isVMHashable)
        #expect(
            Bytecode.ValueType.dictionary(
                key: .array(.string),
                value: .set(.optional(.int64))
            ).isVMHashable
        )

        let fixture = try makeFixture()
        #expect(
            throws: Verification.Error.invalidShellInterface(
                "type nesting in entry 0 exceeds 32 levels"
            )
        ) {
            _ = try shell(
                compatibility: fixture.module.compatibility,
                hash: fixture.module.shellInterfaceHash,
                capabilities: fixture.module.capabilities,
                parameterType: type
            )
        }
    }

    @Test("A well-typed Set construction and iterator owns its cursor")
    func acceptsValidSetProgram() throws {
        _ = try verify(makeFixture())
    }

    @Test("Set construction requires matching hashable element types")
    func rejectsInvalidSetConstruction() throws {
        var mismatch = try makeFixture()
        mismatch.module.functions[0].registerTypes[1] = .set(
            .integer(bitWidth: 32, signed: true)
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_set needs Array<T> or Set<T> and a matching Set<T> result"
            )
        ) {
            try verify(mismatch)
        }

        var unsupported = try makeFixture()
        let tuple = Bytecode.ValueType.tuple([.int64])
        unsupported.module.functions[0].registerTypes[0] = .array(tuple)
        unsupported.module.functions[0].registerTypes[1] = .set(tuple)
        unsupported.shell = try shell(
            compatibility: unsupported.module.compatibility,
            hash: unsupported.module.shellInterfaceHash,
            capabilities: unsupported.module.capabilities,
            parameterType: .array(tuple)
        )
        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "Set element lacks VM-defined Hashable semantics"
            )
        ) {
            try verify(unsupported)
        }

        var invalidPop = try makeFixture()
        invalidPop.module.functions[0].registerTypes[4] = .bool
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "set_pop_first results must match Set.Element"
            )
        ) {
            try verify(invalidPop)
        }
    }

    @Test("Set operations are capability-gated and iterator cursors are initialized")
    func rejectsMissingCapabilityOrCursor() throws {
        var missingCapability = try makeFixture()
        missingCapability.module.capabilities.remove(.collectionsV1)
        missingCapability.module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "scalarEntry",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .optional(.int64),
            registerTypes: [.int64, .optional(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeOptionalSome(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        missingCapability.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "setCount",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.set(.int64), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .setCount(
                                result: .init(rawValue: 1),
                                set: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        missingCapability.shell = try shell(
            compatibility: missingCapability.module.compatibility,
            hash: missingCapability.module.shellInterfaceHash,
            capabilities: missingCapability.module.capabilities,
            parameterType: .int64
        )
        #expect(throws: Verification.Error.capabilityDenied(.collectionsV1)) {
            try verify(missingCapability)
        }

        var uninitialized = try makeFixture()
        uninitialized.module.functions[0].blocks[0].instructions.remove(at: 3)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "stack storage $0 is used before initialization"
            )
        ) {
            try verify(uninitialized)
        }
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private func makeFixture() throws -> Fixture {
        let array = Bytecode.ValueType.array(.int64)
        let set = Bytecode.ValueType.set(.int64)
        let optional = Bytecode.ValueType.optional(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "setIterator",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: optional,
            registerTypes: [array, set, .int64, optional, optional, set],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeSet(
                            result: .init(rawValue: 1),
                            source: .init(rawValue: 0)
                        ),
                        .setPopFirst(
                            elementResult: .init(rawValue: 4),
                            setResult: .init(rawValue: 5),
                            set: .init(rawValue: 1)
                        ),
                        .constantInteger(result: .init(rawValue: 2), value: 0),
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 2),
                            mode: .initialize
                        ),
                        .setNext(
                            result: .init(rawValue: 3),
                            set: .init(rawValue: 5),
                            indexSlot: .init(rawValue: 0)
                        ),
                        .destroyStack(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "set-verifier-fixture"
        )
        let hash = Core.Digest.sha256("set-verifier-shell")
        let capabilities: Set<Core.Capability> = [.baselineV1, .collectionsV1]
        let module = Bytecode.Module(
            name: "SetVerifierFixture",
            shellInterfaceHash: hash,
            compatibility: compatibility,
            capabilities: capabilities,
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: try functionKey(),
                    functionID: function.id
                ),
            ]
        )
        return .init(
            module: module,
            shell: try shell(
                compatibility: compatibility,
                hash: hash,
                capabilities: capabilities,
                parameterType: array
            ),
            policy: .init(acceptedCapabilities: capabilities)
        )
    }

    private func shell(
        compatibility: Core.Compatibility,
        hash: Core.Digest,
        capabilities: Set<Core.Capability>,
        parameterType: Bytecode.ValueType
    ) throws -> Verification.ShellInterface {
        try .init(
            interfaceHash: hash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: try functionKey(),
                    parameterTypes: [parameterType],
                    resultType: .optional(.int64)
                ),
            ]
        )
    }

    private func functionKey() throws -> Core.FunctionKey {
        try .derive(
            namespace: .derive(
                bundleID: "dev.helix.verifier.set",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Set.swift",
            canonicalDeclaration: "func setIterator(_: [Int]) -> Int?",
            loweredSignature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Optional<Swift.Int>"
            ),
            role: .function
        )
    }

    private func verify(_ fixture: Fixture) throws -> Verification.Image {
        try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }
}
}
