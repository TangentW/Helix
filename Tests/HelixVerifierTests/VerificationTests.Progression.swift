import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC progression verification")
struct Progression {
    @Test("A well-typed progression owns and closes its Optional cursor slot")
    func acceptsValidProgression() throws {
        _ = try verify(makeFixture())
    }

    @Test("Progression result, cursor, end, and stride types must agree")
    func rejectsMismatchedTypes() throws {
        var cursorMismatch = try makeFixture()
        cursorMismatch.module.functions[0].registerTypes[4] = .optional(
            .integer(bitWidth: 32, signed: true)
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 5,
                reason: "progression_next needs Optional<T> result/cursor and a matching end"
            )
        ) {
            try verify(cursorMismatch)
        }

        var strideMismatch = try makeFixture()
        strideMismatch.module.functions[0].registerTypes[2] = .integer(
            bitWidth: 32,
            signed: true
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 5,
                reason: "progression_next stride does not match the element's Stride type"
            )
        ) {
            try verify(strideMismatch)
        }
    }

    @Test("Progression cursors must be initialized and collection-capability gated")
    func rejectsMissingStateOrCapability() throws {
        var uninitialized = try makeFixture()
        uninitialized.module.functions[0].blocks[0].instructions.remove(at: 4)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "stack storage $0 is used before initialization"
            )
        ) {
            try verify(uninitialized)
        }

        var missingCapability = try makeFixture()
        missingCapability.module.capabilities.remove(.collectionsV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 5,
                reason: "Progression iteration requires swift-collections-1"
            )
        ) {
            try verify(missingCapability)
        }
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private func makeFixture() throws -> Fixture {
        let optional = Bytecode.ValueType.optional(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "progression",
            parameterRegisters: [],
            resultType: optional,
            registerTypes: [.int64, .int64, .int64, optional, optional],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 0), bitPattern: 0),
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 3),
                        .constantInteger(result: .init(rawValue: 2), bitPattern: 1),
                        .makeOptionalSome(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 0)
                        ),
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 3),
                            mode: .initialize
                        ),
                        .progressionNext(
                            result: .init(rawValue: 4),
                            cursorSlot: .init(rawValue: 0),
                            end: .init(rawValue: 1),
                            stride: .init(rawValue: 2),
                            boundary: .exclusive
                        ),
                        .destroyStack(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ],
            stackSlotTypes: [optional]
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "progression-verifier-fixture"
        )
        let shellHash = Core.Digest.sha256("progression-verifier-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier.progression",
            buildNumber: "1",
            seed: "fixture"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Progression.swift",
            canonicalDeclaration: "func progression() -> Int?",
            loweredSignature: .init(parameters: [], result: "Swift.Int?"),
            role: .function
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .collectionsV1,
        ]
        let module = Bytecode.Module(
            name: "ProgressionVerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
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
                    parameterTypes: [],
                    parameterConventions: function.parameterConventions,
                    resultType: optional
                ),
            ]
        )
        return .init(
            module: module,
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
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
