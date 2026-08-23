import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM protocol existential execution")
struct ProtocolExistentialExecution {
    private let firstKey = Bytecode.LocalTypeKey(rawValue: "Fixture.First")
    private let secondKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Second")

    @Test("Closed dispatch selects the exact dynamic receiver at any ABI index")
    func dispatchesExactReceiver() throws {
        let fixture = dispatchFixture(includesSecondTarget: true)
        let image = try makeVerified(
            root: fixture.root,
            localTypes: fixture.localTypes,
            additionalFunctions: fixture.targets
        )
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [try boxed(firstKey, value: 11), try integer(99)]
            ) == .returned(try integer(11))
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [try boxed(secondKey, value: 22), try integer(99)]
            ) == .returned(try integer(22))
        )
    }

    @Test("A verified closed table traps a valid but unlisted dynamic type")
    func trapsUnlistedReceiver() throws {
        let fixture = dispatchFixture(includesSecondTarget: false)
        let image = try makeVerified(
            root: fixture.root,
            localTypes: fixture.localTypes,
            additionalFunctions: fixture.targets
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [try boxed(secondKey, value: 22), try integer(0)]
            ) == .trapped(
                .existentialDispatchFailure(actual: .local(secondKey))
            )
        )
    }

    @Test("Protocol casts preserve the erased identity or fail closed")
    func castsClosedExistential() throws {
        let accepted = Bytecode.ExistentialTypeSet(
            types: [.local(firstKey)]
        )
        let checked = castFunction(accepted: accepted, checked: true)
        let checkedImage = try makeVerified(
            root: checked,
            resultType: .optional(.any),
            localTypes: localTypes
        )
        let first = try boxed(firstKey, value: 7)
        let second = try boxed(secondKey, value: 8)
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: checkedImage,
                arguments: [first]
            ) == .returned(.optional(first))
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: checkedImage,
                arguments: [second]
            ) == .returned(.optional(nil))
        )

        let forced = castFunction(accepted: accepted, checked: false)
        let forcedImage = try makeVerified(
            root: forced,
            resultType: .any,
            localTypes: localTypes
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: forcedImage,
                arguments: [first]
            ) == .returned(first)
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: forcedImage,
                arguments: [second]
            ) == .trapped(
                .existentialCastFailure(actual: .local(secondKey))
            )
        )
    }

    @Test("Closed existential lookup work consumes proportional fuel")
    func metersClosedLookupWork() throws {
        let source = try boxed(firstKey, value: 7)
        let limits = Core.ResourceLimits(
            instructionFuelPerEntry: 64,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let small = castFunction(
            accepted: .init(types: [.local(firstKey)]),
            checked: true
        )
        let smallImage = try makeVerified(
            root: small,
            resultType: .optional(.any),
            localTypes: localTypes
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: smallImage,
                arguments: [source],
                budget: .init(limits: limits)
            ) == .returned(.optional(source))
        )

        let additionalTypes: [Bytecode.DynamicType] = (0..<127).map { index in
            .tuple([
                .init(label: "value\(index)", type: .bool),
                .init(label: "other", type: .bool),
            ])
        }
        let large = castFunction(
            accepted: .init(
                types: [.local(firstKey)] + additionalTypes
            ),
            checked: true
        )
        let largeImage = try makeVerified(
            root: large,
            resultType: .optional(.any),
            localTypes: localTypes
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: largeImage,
                arguments: [source],
                budget: .init(limits: limits)
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Protocol cast payload validation consumes traversal fuel")
    func metersProtocolCastPayloadValidation() throws {
        let dynamicType = Bytecode.DynamicType.array(.bool)
        let source = VM.Value.any(.init(
            dynamicType: dynamicType,
            payload: .array(
                Array(repeating: .bool(true), count: 16),
                elementType: .bool
            )
        ))
        let function = castFunction(
            accepted: .init(types: [dynamicType]),
            checked: true
        )
        let image = try makeVerified(
            root: function,
            resultType: .optional(.any),
            localTypes: []
        )
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source],
                budget: .init(limits: .init(
                    instructionFuelPerEntry: 128,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ))
            ) == .returned(.optional(source))
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source],
                budget: .init(limits: .init(
                    instructionFuelPerEntry: 30,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ))
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Throwing witness dispatch reaches both continuations")
    func dispatchesThrowingReceiver() throws {
        let target = throwingWitness()
        let dispatch = Bytecode.ExistentialDispatchTable(
            receiverParameterIndex: 1,
            targets: [
                .init(
                    dynamicType: .local(firstKey),
                    function: target.id
                ),
            ]
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "tryDispatch",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            resultType: .int64,
            registerTypes: [.any, .bool, .int64, .string, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .existentialTryApply(
                            existential: .init(rawValue: 0),
                            arguments: [.init(rawValue: 1)],
                            dispatch: dispatch,
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 2)],
                    instructions: [.returnValue(.init(rawValue: 2))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 3)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 4),
                            bitPattern: UInt64.max
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            root: root,
            localTypes: [localStruct(firstKey)],
            additionalFunctions: [target],
            additionalCapabilities: [.untypedThrowsV1]
        )
        let receiver = try boxed(firstKey, value: 41)
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [receiver, .bool(false)]
            ) == .returned(try integer(41))
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [receiver, .bool(true)]
            ) == .returned(try integer(-1))
        )
    }

    private struct DispatchFixture {
        var root: Bytecode.Function
        var targets: [Bytecode.Function]
        var localTypes: [Bytecode.LocalTypeDefinition]
    }

    private var localTypes: [Bytecode.LocalTypeDefinition] {
        [localStruct(firstKey), localStruct(secondKey)]
    }

    private func dispatchFixture(
        includesSecondTarget: Bool
    ) -> DispatchFixture {
        let first = witness(id: 1, key: firstKey)
        let second = witness(id: 2, key: secondKey)
        var targets = [
            Bytecode.ExistentialDispatchTarget(
                dynamicType: .local(firstKey),
                function: first.id
            ),
        ]
        if includesSecondTarget {
            targets.append(
                .init(
                    dynamicType: .local(secondKey),
                    function: second.id
                )
            )
        }
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "dispatch",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            resultType: .int64,
            registerTypes: [.any, .int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .existentialApply(
                            result: .init(rawValue: 2),
                            existential: .init(rawValue: 0),
                            arguments: [.init(rawValue: 1)],
                            dispatch: .init(
                                receiverParameterIndex: 1,
                                targets: targets
                            )
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        return .init(
            root: root,
            targets: includesSecondTarget ? [first, second] : [first],
            localTypes: localTypes
        )
    }

    private func castFunction(
        accepted: Bytecode.ExistentialTypeSet,
        checked: Bool
    ) -> Bytecode.Function {
        let resultType: Bytecode.ValueType = checked
            ? .optional(.any) : .any
        let instruction: Bytecode.Instruction = checked
            ? .checkedCastExistential(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                acceptedTypes: accepted
            )
            : .forceCastExistential(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                acceptedTypes: accepted
            )
        return .init(
            id: .init(rawValue: 0),
            name: checked ? "checkedProtocolCast" : "forcedProtocolCast",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: resultType,
            registerTypes: [.any, resultType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        instruction,
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
    }

    private func witness(
        id: UInt32,
        key: Bytecode.LocalTypeKey
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: id),
            name: "witness\(id)",
            kind: .concreteSpecialization,
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            parameterConventions: [.owned, .borrowed],
            resultType: .int64,
            registerTypes: [.int64, .local(key), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .structExtract(
                            result: .init(rawValue: 2),
                            structure: .init(rawValue: 1),
                            fieldIndex: 0
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
    }

    private func throwingWitness() -> Bytecode.Function {
        .init(
            id: .init(rawValue: 1),
            name: "throwingWitness",
            kind: .concreteSpecialization,
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            parameterConventions: [.owned, .borrowed],
            resultType: .int64,
            thrownType: .string,
            registerTypes: [
                .bool, .local(firstKey), .int64, .int64, .string,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .structExtract(
                            result: .init(rawValue: 2),
                            structure: .init(rawValue: 1),
                            fieldIndex: 0
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 0),
                            trueTarget: .init(rawValue: 2),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 1),
                            falseArguments: [.init(rawValue: 2)]
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 3)],
                    instructions: [.returnValue(.init(rawValue: 3))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .constantString(
                            result: .init(rawValue: 4),
                            value: "rejected"
                        ),
                        .throwError(.init(rawValue: 4)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
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

    private func boxed(
        _ key: Bytecode.LocalTypeKey,
        value: Int64
    ) throws -> VM.Value {
        let payload = VM.Value.structure(
            type: key,
            fields: [.integer(try .init(
                signed: value,
                bitWidth: 64,
                isSigned: true
            ))]
        )
        return .any(.init(dynamicType: .local(key), payload: payload))
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func makeVerified(
        root: Bytecode.Function,
        resultType: Bytecode.ValueType = .int64,
        localTypes: [Bytecode.LocalTypeDefinition],
        additionalFunctions: [Bytecode.Function] = [],
        additionalCapabilities: Set<Core.Capability> = []
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("vm-protocol-existential-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-vm-protocol-existential"
        )
        let parameterTypes = root.parameterRegisters.compactMap {
            root.type(of: $0)
        }
        let key = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.vm-protocol-existential",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func protocolExistentialFixture()",
            loweredSignature: .init(
                parameters: parameterTypes.map(\.description),
                result: resultType.description
            ),
            role: .function
        )
        let capabilities = Set<Core.Capability>([
            .baselineV1,
            .anyValuesV1,
            .borrowCallsV1,
            .compilerSpecializationsV1,
            .localNominalsV1,
            .stringsV1,
        ]).union(additionalCapabilities)
        let module = Bytecode.Module(
            name: "VMProtocolExistentialFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            localTypes: localTypes,
            functions: [root] + additionalFunctions,
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: root.id
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
                    parameterTypes: parameterTypes,
                    parameterConventions: root.parameterConventions,
                    resultType: resultType,
                    effects: root.effects
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
