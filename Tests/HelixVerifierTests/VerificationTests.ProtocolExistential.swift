import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC protocol existential verifier")
struct ProtocolExistentialVerifier {
    private let firstKey = Bytecode.LocalTypeKey(rawValue: "Fixture.First")
    private let secondKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Second")

    @Test("A closed dispatch validates every concrete target ABI")
    func acceptsClosedDispatch() throws {
        let fixture = dispatchFixture()

        let image = try verify(fixture)

        #expect(image.module.functions.count == 3)
    }

    @Test("Sequential async rejects dynamic existential dispatch")
    func rejectsAsyncExistentialDispatch() throws {
        var fixture = dispatchFixture()
        fixture.effects = .init(isAsync: true)
        for index in fixture.functions.indices {
            fixture.functions[index].effects = fixture.effects
        }

        try expectInvalid(
            fixture,
            reason: "async existential dispatch is outside the sequential async contract"
        )
    }

    @Test("Checked protocol casts admit an empty closed set")
    func acceptsEmptyCheckedCastSet() throws {
        var fixture = dispatchFixture()
        fixture.functions[0].registerTypes = [.any, .optional(.any)]
        fixture.functions[0].resultType = .optional(.any)
        fixture.functions[0].blocks[0].instructions = [
            .checkedCastExistential(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                acceptedTypes: .init(types: [])
            ),
            .returnValue(.init(rawValue: 1)),
        ]
        fixture.resultType = .optional(.any)

        _ = try verify(fixture)
    }

    @Test("Protocol cast sets reject duplicates and unknown types")
    func rejectsMalformedCastSets() throws {
        var duplicate = castFixture(
            acceptedTypes: [.local(firstKey), .local(firstKey)]
        )
        try expectInvalid(
            duplicate,
            reason: "protocol existential type set is oversized, duplicate, or invalid"
        )

        duplicate = castFixture(
            acceptedTypes: [.local(.init(rawValue: "Fixture.Unknown"))]
        )
        try expectInvalid(
            duplicate,
            reason: "protocol existential type set is oversized, duplicate, or invalid"
        )
    }

    @Test("Closed type and dispatch sets enforce their v1 upper bounds")
    func rejectsOversizedClosedSets() throws {
        let count = Bytecode.ExistentialTypeSet.maximumTypeCountV1 + 1
        let types: [Bytecode.DynamicType] = (0..<count).map { index in
            .tuple([
                .init(label: "value\(index)", type: .bool),
                .init(label: "other", type: .bool),
            ])
        }
        var fixture = castFixture(acceptedTypes: types)
        try expectInvalid(
            fixture,
            reason: "protocol existential type set is oversized, duplicate, or invalid"
        )

        let targets = types.map {
            Bytecode.ExistentialDispatchTarget(
                dynamicType: $0,
                function: .init(rawValue: 1)
            )
        }
        fixture = dispatchFixture()
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [],
            dispatch: .init(
                receiverParameterIndex: 0,
                targets: targets
            )
        )
        try expectInvalid(
            fixture,
            reason: "existential dispatch table is empty, oversized, duplicate, or has an invalid receiver"
        )
    }

    @Test("Dispatch tables reject empty, duplicate, and unknown cases")
    func rejectsMalformedDispatchSets() throws {
        var fixture = dispatchFixture()
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [],
            dispatch: .init(receiverParameterIndex: 0, targets: [])
        )
        try expectInvalid(
            fixture,
            reason: "existential dispatch table is empty, oversized, duplicate, or has an invalid receiver"
        )

        fixture = dispatchFixture()
        let first = fixture.dispatch.targets[0]
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [],
            dispatch: .init(
                receiverParameterIndex: 0,
                targets: [first, first]
            )
        )
        try expectInvalid(
            fixture,
            reason: "existential dispatch table is empty, oversized, duplicate, or has an invalid receiver"
        )

        fixture = dispatchFixture()
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [],
            dispatch: .init(
                receiverParameterIndex: 0,
                targets: [
                    .init(
                        dynamicType: .local(
                            .init(rawValue: "Fixture.Unknown")
                        ),
                        function: .init(rawValue: 1)
                    ),
                ]
            )
        )
        try expectInvalid(
            fixture,
            reason: "existential dispatch target must name a known concrete specialization and dynamic type"
        )
    }

    @Test("Dispatch targets must be concrete specializations with one ABI")
    func rejectsInvalidTargetsAndABIs() throws {
        var fixture = dispatchFixture()
        fixture.functions[1].kind = .ordinary
        try expectInvalid(
            fixture,
            reason: "existential dispatch target must name a known concrete specialization and dynamic type"
        )

        fixture = dispatchFixture()
        fixture.functions[2].resultType = .bool
        fixture.functions[2].registerTypes[1] = .bool
        fixture.functions[2].blocks[0].instructions = [
            .constantBool(result: .init(rawValue: 1), value: true),
            .returnValue(.init(rawValue: 1)),
        ]
        try expectInvalid(
            fixture,
            reason: "existential dispatch targets do not share one callable ABI"
        )
    }

    @Test("Owned existential receivers cannot conceal reference ownership")
    func rejectsUnsafeOwnedReceiver() throws {
        let classKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Reference")
        var fixture = dispatchFixture()
        fixture.localTypes.append(
            .init(
                key: classKey,
                kind: .class(
                    fields: [],
                    hostedSuperclass: nil,
                    hostedMethods: []
                )
            )
        )
        fixture.functions[1] = .init(
            id: .init(rawValue: 1),
            name: "referenceWitness",
            kind: .concreteSpecialization,
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.owned],
            resultType: .int64,
            registerTypes: [.local(classKey), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: 1
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        fixture.functions.removeLast()
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [],
            dispatch: .init(
                receiverParameterIndex: 0,
                targets: [
                    .init(
                        dynamicType: .local(classKey),
                        function: .init(rawValue: 1)
                    ),
                ]
            )
        )

        try expectInvalid(
            fixture,
            reason: "existential dispatch receiver is neither borrowed nor one safely copyable concrete target parameter"
        )
    }

    @Test("An owned argument cannot consume its existential receiver source")
    func rejectsOwnedReceiverSourceAlias() throws {
        var fixture = dispatchFixture()
        for index in 1...2 {
            let key = index == 1 ? firstKey : secondKey
            fixture.functions[index] = .init(
                id: .init(rawValue: UInt32(index)),
                name: "witness\(index)",
                kind: .concreteSpecialization,
                parameterRegisters: [
                    .init(rawValue: 0), .init(rawValue: 1),
                ],
                parameterConventions: [.borrowed, .owned],
                resultType: .int64,
                registerTypes: [.local(key), .any, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [
                            .init(rawValue: 0), .init(rawValue: 1),
                        ],
                        instructions: [
                            .destroyValue(.init(rawValue: 1)),
                            .structExtract(
                                result: .init(rawValue: 2),
                                structure: .init(rawValue: 0),
                                fieldIndex: 0
                            ),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
        }
        fixture.functions[0].blocks[0].instructions[0] = .existentialApply(
            result: .init(rawValue: 1),
            existential: .init(rawValue: 0),
            arguments: [.init(rawValue: 0)],
            dispatch: fixture.dispatch
        )

        try expectInvalid(
            fixture,
            reason: "an owned argument aliases the existential receiver source"
        )
    }

    private struct Fixture {
        var functions: [Bytecode.Function]
        var localTypes: [Bytecode.LocalTypeDefinition]
        var dispatch: Bytecode.ExistentialDispatchTable
        var resultType: Bytecode.ValueType = .int64
        var effects: Core.Effects = .init()
    }

    private func dispatchFixture() -> Fixture {
        let dispatch = Bytecode.ExistentialDispatchTable(
            receiverParameterIndex: 0,
            targets: [
                .init(
                    dynamicType: .local(firstKey),
                    function: .init(rawValue: 1)
                ),
                .init(
                    dynamicType: .local(secondKey),
                    function: .init(rawValue: 2)
                ),
            ]
        )
        let caller = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "dispatch",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.any, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .existentialApply(
                            result: .init(rawValue: 1),
                            existential: .init(rawValue: 0),
                            arguments: [],
                            dispatch: dispatch
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        return .init(
            functions: [
                caller,
                witness(id: 1, key: firstKey),
                witness(id: 2, key: secondKey),
            ],
            localTypes: [localStruct(firstKey), localStruct(secondKey)],
            dispatch: dispatch
        )
    }

    private func castFixture(
        acceptedTypes: [Bytecode.DynamicType]
    ) -> Fixture {
        var fixture = dispatchFixture()
        fixture.functions[0].resultType = .optional(.any)
        fixture.functions[0].registerTypes = [.any, .optional(.any)]
        fixture.functions[0].blocks[0].instructions = [
            .checkedCastExistential(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                acceptedTypes: .init(types: acceptedTypes)
            ),
            .returnValue(.init(rawValue: 1)),
        ]
        fixture.resultType = .optional(.any)
        return fixture
    }

    private func witness(
        id: UInt32,
        key: Bytecode.LocalTypeKey
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: id),
            name: "witness\(id)",
            kind: .concreteSpecialization,
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.borrowed],
            resultType: .int64,
            registerTypes: [.local(key), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .structExtract(
                            result: .init(rawValue: 1),
                            structure: .init(rawValue: 0),
                            fieldIndex: 0
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
    }

    private func localStruct(
        _ key: Bytecode.LocalTypeKey
    ) -> Bytecode.LocalTypeDefinition {
        .init(
            key: key,
            kind: .structure(
                fields: [.init(name: "value", type: .int64)]
            )
        )
    }

    private func expectInvalid(
        _ fixture: Fixture,
        reason: String
    ) throws {
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: reason
            )
        ) {
            try verify(fixture)
        }
    }

    private func verify(_ fixture: Fixture) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("protocol-existential-verifier")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-protocol-existential-verifier"
        )
        let key = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.protocol-existential-verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func dispatch(_ value: Any)",
            loweredSignature: .init(
                parameters: ["Swift.Any"],
                result: fixture.resultType.description,
                isAsync: fixture.effects.isAsync
            ),
            role: .function
        )
        var capabilities: Set<Core.Capability> = [
            .baselineV1,
            .anyValuesV1,
            .borrowCallsV1,
            .compilerSpecializationsV1,
            .localNominalsV1,
            .localClassesV1,
        ]
        if fixture.effects.isAsync {
            capabilities.insert(.sequentialAsyncV1)
        }
        let module = Bytecode.Module(
            name: "ProtocolExistentialVerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            localTypes: fixture.localTypes,
            functions: fixture.functions,
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: .init(rawValue: 0)
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
                    parameterTypes: [.any],
                    parameterConventions: [.owned],
                    resultType: fixture.resultType,
                    effects: fixture.effects
                ),
            ]
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
    }
}
}
