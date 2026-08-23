import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC address and exclusivity verifier")
struct AddressSemantics {
    @Test("Local class references are recursive leaves, but cannot impersonate Error values")
    func validatesLocalClassDefinitions() throws {
        let node = Bytecode.LocalTypeKey(rawValue: "Fixture.Node")
        let definition = Bytecode.LocalTypeDefinition(
            key: node,
            kind: .class(
                fields: [
                    .init(name: "value", type: .int64),
                    .init(name: "next", type: .optional(.local(node))),
                ],
                hostedSuperclass: nil,
                hostedMethods: []
            )
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .localNominalsV1,
            .localClassesV1,
        ]

        _ = try verify(localTypes: [definition], capabilities: capabilities)

        var invalid = definition
        invalid.conformsToError = true
        #expect(throws: Verification.Error.self) {
            try verify(localTypes: [invalid], capabilities: capabilities)
        }
    }

    @Test("A projected local-struct address can be mutated by an inout helper")
    func acceptsProjectedInoutCall() throws {
        let counter = Bytecode.LocalTypeKey(rawValue: "Fixture.Counter")
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "mutateCounter",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64,
                .bool,
                .local(counter),
                .address(.local(counter)),
                .address(.local(counter)),
                .address(.int64),
                .int64,
                .local(counter),
                .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantBool(result: .init(rawValue: 1), value: true),
                        .makeStruct(
                            result: .init(rawValue: 2),
                            fields: [.init(rawValue: 0), .init(rawValue: 1)]
                        ),
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 2),
                            mode: .initialize
                        ),
                        .stackAddress(
                            result: .init(rawValue: 3),
                            slot: .init(rawValue: 0)
                        ),
                        .beginAccess(
                            result: .init(rawValue: 4),
                            address: .init(rawValue: 3),
                            kind: .modify
                        ),
                        .projectAggregateAddress(
                            result: .init(rawValue: 5),
                            base: .init(rawValue: 4),
                            fieldIndex: 0
                        ),
                        .constantInteger(result: .init(rawValue: 6), bitPattern: 41),
                        .apply(
                            result: nil,
                            function: .init(rawValue: 1),
                            arguments: [.init(rawValue: 5), .init(rawValue: 6)]
                        ),
                        .endAccess(.init(rawValue: 4)),
                        .loadStack(
                            result: .init(rawValue: 7),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .structExtract(
                            result: .init(rawValue: 8),
                            structure: .init(rawValue: 7),
                            fieldIndex: 0
                        ),
                        .returnValue(.init(rawValue: 8)),
                    ]
                ),
            ],
            stackSlotTypes: [.local(counter)]
        )
        let image = try verify(
            root: root,
            additionalFunctions: [inoutSetter(id: 1)],
            localTypes: [
                .init(
                    key: counter,
                    kind: .structure(
                        fields: [
                            .init(name: "value", type: .int64),
                            .init(name: "enabled", type: .bool),
                        ]
                    )
                ),
            ],
            capabilities: [.baselineV1, .addressValuesV1, .localNominalsV1]
        )

        #expect(image.module.functions.count == 2)
    }

    @Test("Dynamic inout closure calls preserve access across both try edges")
    func acceptsThrowingInoutClosureCall() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.address(.int64)],
            parameterConventions: [.inout],
            result: .void,
            effects: .init(mayThrow: true)
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "invokeInoutClosure",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
                .closure(signature),
                .string,
                .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .stackAddress(
                            result: .init(rawValue: 1),
                            slot: .init(rawValue: 0)
                        ),
                        .beginAccess(
                            result: .init(rawValue: 2),
                            address: .init(rawValue: 1),
                            kind: .modify
                        ),
                        .makeClosure(
                            result: .init(rawValue: 3),
                            function: .init(rawValue: 1),
                            captures: []
                        ),
                        .closureTryApply(
                            closure: .init(rawValue: 3),
                            arguments: [.init(rawValue: 2)],
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .endAccess(.init(rawValue: 2)),
                        .loadStack(
                            result: .init(rawValue: 5),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .returnValue(.init(rawValue: 5)),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [
                        .endAccess(.init(rawValue: 2)),
                        .destroyStack(.init(rawValue: 0)),
                        .trap(.explicit("unexpected callback error")),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )
        let callback = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "mutatingCallback",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.inout],
            resultType: .void,
            registerTypes: [.address(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: 41
                        ),
                        .storeAddress(
                            address: .init(rawValue: 0),
                            source: .init(rawValue: 1),
                            mode: .assign
                        ),
                        .returnValue(nil),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )

        _ = try verify(
            root: root,
            additionalFunctions: [callback],
            capabilities: [
                .baselineV1,
                .addressValuesV1,
                .closureValuesV1,
                .stringsV1,
                .untypedThrowsV1,
            ]
        )

        var directCallback = callback
        directCallback.id = .init(rawValue: 2)
        directCallback.kind = .ordinary
        var directRoot = root
        directRoot.blocks[0].instructions = Array(
            directRoot.blocks[0].instructions.prefix(3)
        ) + [
            .tryApply(
                function: directCallback.id,
                arguments: [.init(rawValue: 2)],
                normalTarget: .init(rawValue: 1),
                errorTarget: .init(rawValue: 2)
            ),
        ]
        _ = try verify(
            root: directRoot,
            additionalFunctions: [directCallback],
            capabilities: [
                .baselineV1,
                .addressValuesV1,
                .closureValuesV1,
                .stringsV1,
                .untypedThrowsV1,
            ]
        )

        var malformedRoot = root
        malformedRoot.registerTypes[3] = .closure(
            .init(
                parameters: [.address(.int64)],
                parameterConventions: [.owned],
                result: .void,
                effects: .init(mayThrow: true)
            )
        )
        #expect(throws: Verification.Error.self) {
            try verify(
                root: malformedRoot,
                additionalFunctions: [callback],
                capabilities: [
                    .baselineV1,
                    .addressValuesV1,
                    .closureValuesV1,
                    .stringsV1,
                    .untypedThrowsV1,
                ]
            )
        }

        var readOnlyRoot = root
        readOnlyRoot.blocks[0].instructions[2] = .beginAccess(
            result: .init(rawValue: 2),
            address: .init(rawValue: 1),
            kind: .read
        )
        #expect(throws: Verification.Error.self) {
            try verify(
                root: readOnlyRoot,
                additionalFunctions: [callback],
                capabilities: [
                    .baselineV1,
                    .addressValuesV1,
                    .closureValuesV1,
                    .stringsV1,
                    .untypedThrowsV1,
                ]
            )
        }
    }

    @Test("Borrowed inout cells remain inside lexical closure and access scopes")
    func validatesBorrowedInoutClosureLifetime() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let closureType = Bytecode.ValueType.closure(signature)
        let body = Bytecode.Function(
            id: .init(rawValue: 2),
            name: "borrowedInoutBody",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .void,
            registerTypes: [.mutableCell(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .loadMutableCell(
                            result: .init(rawValue: 1),
                            cell: .init(rawValue: 0)
                        ),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
        func function(
            lifetime: Bytecode.ClosureLifetime,
            closesClosureBeforeAccess: Bool,
            accessKind: Bytecode.AccessKind = .modify
        ) -> Bytecode.Function {
            let close: [Bytecode.Instruction] = closesClosureBeforeAccess
                ? [
                    .endClosureScope(closure: .init(rawValue: 4)),
                    .endAccess(.init(rawValue: 2)),
                ]
                : [
                    .endAccess(.init(rawValue: 2)),
                    .endClosureScope(closure: .init(rawValue: 4)),
                ]
            return .init(
                id: .init(rawValue: 1),
                name: "borrowedInoutCapture",
                parameterRegisters: [],
                resultType: .void,
                registerTypes: [
                    .int64,
                    .address(.int64),
                    .address(.int64),
                    .mutableCell(.int64),
                    closureType,
                ],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 0),
                                bitPattern: 1
                            ),
                            .storeStack(
                                slot: .init(rawValue: 0),
                                source: .init(rawValue: 0),
                                mode: .initialize
                            ),
                            .stackAddress(
                                result: .init(rawValue: 1),
                                slot: .init(rawValue: 0)
                            ),
                            .beginAccess(
                                result: .init(rawValue: 2),
                                address: .init(rawValue: 1),
                                kind: accessKind
                            ),
                            .borrowMutableCell(
                                result: .init(rawValue: 3),
                                address: .init(rawValue: 2)
                            ),
                            .makeClosure(
                                result: .init(rawValue: 4),
                                function: body.id,
                                captures: [.init(rawValue: 3)],
                                lifetime: lifetime
                            ),
                        ] + (lifetime == .lexical ? close : [
                            .endAccess(.init(rawValue: 2)),
                        ]) + [
                            .destroyStack(.init(rawValue: 0)),
                            .returnValue(nil),
                        ]
                    ),
                ],
                stackSlotTypes: [.int64]
            )
        }
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .addressValuesV1,
            .closureValuesV1,
            .mutableCapturesV1,
        ]

        _ = try verify(
            additionalFunctions: [
                function(
                    lifetime: .lexical,
                    closesClosureBeforeAccess: true
                ),
                body,
            ],
            capabilities: capabilities
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 5,
                reason: "a borrowed mutable cell may only enter a lexical closure"
            )
        ) {
            try verify(
                additionalFunctions: [
                    function(
                        lifetime: .invocation,
                        closesClosureBeforeAccess: true
                    ),
                    body,
                ],
                capabilities: capabilities
            )
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 7,
                reason: "address access scope is not active on this path"
            )
        ) {
            try verify(
                additionalFunctions: [
                    function(
                        lifetime: .lexical,
                        closesClosureBeforeAccess: false
                    ),
                    body,
                ],
                capabilities: capabilities
            )
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 4,
                reason: "write requires a modify access"
            )
        ) {
            try verify(
                additionalFunctions: [
                    function(
                        lifetime: .lexical,
                        closesClosureBeforeAccess: true,
                        accessKind: .read
                    ),
                    body,
                ],
                capabilities: capabilities
            )
        }
    }

    @Test("Address types cannot nest, escape as results, or use copy_value")
    func rejectsAddressShapeAndOwnershipMisuse() throws {
        let nested = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "nestedAddress",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [.address(.address(.int64))],
            entryBlock: .init(rawValue: 0),
            blocks: [.init(id: .init(rawValue: 0), instructions: [.returnValue(nil)])]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [nested])
        }

        let returned = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "returnAddress",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.inout],
            resultType: .address(.int64),
            registerTypes: [.address(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [returned])
        }

        let copied = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "copyAddress",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.inout],
            resultType: .void,
            registerTypes: [.address(.int64), .address(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .copyValue(
                            result: .init(rawValue: 1),
                            source: .init(rawValue: 0)
                        ),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [copied])
        }
    }

    @Test("Address operations require a live scope with sufficient permission")
    func rejectsInvalidAccessScopes() throws {
        let unscoped = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .loadAddress(
                    result: .init(rawValue: 3),
                    address: .init(rawValue: 1),
                    mode: .copy
                ),
                .destroyStack(.init(rawValue: 0)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [unscoped])
        }

        let readWrite = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .read
                ),
                .storeAddress(
                    address: .init(rawValue: 2),
                    source: .init(rawValue: 0),
                    mode: .assign
                ),
                .endAccess(.init(rawValue: 2)),
                .destroyStack(.init(rawValue: 0)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [readWrite])
        }

        let useAfterEnd = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .read
                ),
                .endAccess(.init(rawValue: 2)),
                .loadAddress(
                    result: .init(rawValue: 3),
                    address: .init(rawValue: 2),
                    mode: .copy
                ),
                .destroyStack(.init(rawValue: 0)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [useAfterEnd])
        }

        let missingEnd = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .modify
                ),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [missingEnd])
        }
    }

    @Test("Projected takes require local modify access and consume only one field")
    func verifiesProjectedTake() throws {
        let tuple = Bytecode.ValueType.tuple([.int64, .int64])

        func projectedTake(
            id: UInt32,
            accessKind: Bytecode.AccessKind
        ) -> Bytecode.Function {
            .init(
                id: .init(rawValue: id),
                name: "projectedTake",
                parameterRegisters: [],
                resultType: .void,
                registerTypes: [
                    .int64, .int64, tuple, .address(tuple),
                    .address(.int64), .address(.int64), .int64,
                    .address(.int64), .address(.int64), .int64,
                ],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 0),
                                bitPattern: 1
                            ),
                            .constantInteger(
                                result: .init(rawValue: 1),
                                bitPattern: 2
                            ),
                            .makeTuple(
                                result: .init(rawValue: 2),
                                elements: [
                                    .init(rawValue: 0), .init(rawValue: 1),
                                ]
                            ),
                            .storeStack(
                                slot: .init(rawValue: 0),
                                source: .init(rawValue: 2),
                                mode: .initialize
                            ),
                            .stackAddress(
                                result: .init(rawValue: 3),
                                slot: .init(rawValue: 0)
                            ),
                            .projectAggregateAddress(
                                result: .init(rawValue: 4),
                                base: .init(rawValue: 3),
                                fieldIndex: 0
                            ),
                            .beginAccess(
                                result: .init(rawValue: 5),
                                address: .init(rawValue: 4),
                                kind: accessKind
                            ),
                            .loadAddress(
                                result: .init(rawValue: 6),
                                address: .init(rawValue: 5),
                                mode: .take
                            ),
                            .endAccess(.init(rawValue: 5)),
                            .projectAggregateAddress(
                                result: .init(rawValue: 7),
                                base: .init(rawValue: 3),
                                fieldIndex: 1
                            ),
                            .beginAccess(
                                result: .init(rawValue: 8),
                                address: .init(rawValue: 7),
                                kind: .modify
                            ),
                            .loadAddress(
                                result: .init(rawValue: 9),
                                address: .init(rawValue: 8),
                                mode: .take
                            ),
                            .endAccess(.init(rawValue: 8)),
                            .returnValue(nil),
                        ]
                    ),
                ],
                stackSlotTypes: [tuple]
            )
        }

        _ = try verify(
            additionalFunctions: [
                projectedTake(id: 1, accessKind: .modify),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(
                additionalFunctions: [
                    projectedTake(id: 1, accessKind: .read),
                ]
            )
        }

        let callerOwnedTake = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "callerOwnedTake",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.inout],
            resultType: .void,
            registerTypes: [.address(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .loadAddress(
                            result: .init(rawValue: 1),
                            address: .init(rawValue: 0),
                            mode: .take
                        ),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [callerOwnedTake])
        }
    }

    @Test("Projected destroy requires local modify access and exact initialization")
    func verifiesProjectedDestroy() throws {
        let tuple = Bytecode.ValueType.tuple([.int64, .int64])

        func projectedDestroy(
            id: UInt32,
            accessKind: Bytecode.AccessKind,
            conditional: Bool
        ) -> Bytecode.Function {
            let destroy: Bytecode.Instruction = conditional
                ? .destroyAddressIfInitialized(.init(rawValue: 4))
                : .destroyAddress(.init(rawValue: 4))
            return .init(
                id: .init(rawValue: id),
                name: "projectedDestroy",
                parameterRegisters: [],
                resultType: .void,
                registerTypes: [
                    .int64, .address(tuple), .address(.int64),
                    .address(.int64), .address(.int64),
                ],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 0),
                                bitPattern: 1
                            ),
                            .stackAddress(
                                result: .init(rawValue: 1),
                                slot: .init(rawValue: 0)
                            ),
                            .projectAggregateAddress(
                                result: .init(rawValue: 2),
                                base: .init(rawValue: 1),
                                fieldIndex: 0
                            ),
                            .beginAccess(
                                result: .init(rawValue: 3),
                                address: .init(rawValue: 2),
                                kind: .modify
                            ),
                            .storeAddress(
                                address: .init(rawValue: 3),
                                source: .init(rawValue: 0),
                                mode: .initialize
                            ),
                            .endAccess(.init(rawValue: 3)),
                            .beginAccess(
                                result: .init(rawValue: 4),
                                address: .init(rawValue: 2),
                                kind: accessKind
                            ),
                            destroy,
                            .endAccess(.init(rawValue: 4)),
                            .returnValue(nil),
                        ]
                    ),
                ],
                stackSlotTypes: [tuple]
            )
        }

        _ = try verify(
            additionalFunctions: [
                projectedDestroy(
                    id: 1,
                    accessKind: .modify,
                    conditional: false
                ),
            ]
        )
        _ = try verify(
            additionalFunctions: [
                projectedDestroy(
                    id: 1,
                    accessKind: .modify,
                    conditional: true
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(
                additionalFunctions: [
                    projectedDestroy(
                        id: 1,
                        accessKind: .read,
                        conditional: true
                    ),
                ]
            )
        }

        let callerOwned = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "callerOwnedDestroy",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.inout],
            resultType: .void,
            registerTypes: [.address(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .destroyAddressIfInitialized(.init(rawValue: 0)),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [callerOwned])
        }

        let definitelyUninitialized = projectedDestroy(
            id: 1,
            accessKind: .modify,
            conditional: false
        )
        var invalidBlocks = definitelyUninitialized.blocks
        invalidBlocks[0].instructions.remove(at: 4)
        let invalid = Bytecode.Function(
            id: definitelyUninitialized.id,
            name: definitelyUninitialized.name,
            parameterRegisters: definitelyUninitialized.parameterRegisters,
            parameterConventions: definitelyUninitialized.parameterConventions,
            resultType: definitelyUninitialized.resultType,
            registerTypes: definitelyUninitialized.registerTypes,
            entryBlock: definitelyUninitialized.entryBlock,
            blocks: invalidBlocks,
            stackSlotTypes: definitelyUninitialized.stackSlotTypes
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [invalid])
        }
    }

    @Test("An access scope may cross a checked branch and terminate on its trap edge")
    func acceptsAccessAcrossCheckedBranch() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "checkedMutation",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
                .bool,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .stackAddress(
                            result: .init(rawValue: 1),
                            slot: .init(rawValue: 0)
                        ),
                        .beginAccess(
                            result: .init(rawValue: 2),
                            address: .init(rawValue: 1),
                            kind: .modify
                        ),
                        .constantBool(result: .init(rawValue: 3), value: false),
                        .conditionalBranch(
                            condition: .init(rawValue: 3),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [.trap(.integerOverflow)]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .storeAddress(
                            address: .init(rawValue: 2),
                            source: .init(rawValue: 0),
                            mode: .assign
                        ),
                        .endAccess(.init(rawValue: 2)),
                        .destroyStack(.init(rawValue: 0)),
                        .returnValue(nil),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )

        _ = try verify(additionalFunctions: [function])
    }

    @Test("Exclusive accesses reject overlap and aliased inout arguments")
    func rejectsExclusiveAccessViolations() throws {
        let overlapping = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .modify
                ),
                .beginAccess(
                    result: .init(rawValue: 4),
                    address: .init(rawValue: 1),
                    kind: .read
                ),
                .trap(.explicit("fixture")),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [overlapping])
        }

        let aliasing = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .modify
                ),
                .apply(
                    result: nil,
                    function: .init(rawValue: 2),
                    arguments: [.init(rawValue: 2), .init(rawValue: 2)]
                ),
                .endAccess(.init(rawValue: 2)),
                .destroyStack(.init(rawValue: 0)),
                .returnValue(nil),
            ]
        )
        let twoInout = Bytecode.Function(
            id: .init(rawValue: 2),
            name: "twoInout",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            parameterConventions: [.inout, .inout],
            resultType: .void,
            registerTypes: [.address(.int64), .address(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [.returnValue(nil)]
                ),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [aliasing, twoInout])
        }
    }

    @Test("Conditional root destroy admits only its unique root modify scope")
    func validatesConditionalDestroyAccessScope() throws {
        let rootRead = addressFunction(
            id: 1,
            instructions: initializedPrefix + [
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .read
                ),
                .destroyStackIfInitialized(.init(rawValue: 0)),
                .endAccess(.init(rawValue: 2)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [rootRead])
        }

        let tuple = Bytecode.ValueType.tuple([.int64, .int64])
        func fixture(
            name: String,
            instructions: [Bytecode.Instruction],
            registerTypes: [Bytecode.ValueType]
        ) -> Bytecode.Function {
            .init(
                id: .init(rawValue: 1),
                name: name,
                parameterRegisters: [],
                resultType: .void,
                registerTypes: registerTypes,
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: instructions
                    ),
                ],
                stackSlotTypes: [tuple]
            )
        }
        let prefix: [Bytecode.Instruction] = [
            .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
            .makeTuple(
                result: .init(rawValue: 1),
                elements: [.init(rawValue: 0), .init(rawValue: 0)]
            ),
            .storeStack(
                slot: .init(rawValue: 0),
                source: .init(rawValue: 1),
                mode: .initialize
            ),
            .stackAddress(
                result: .init(rawValue: 2),
                slot: .init(rawValue: 0)
            ),
        ]
        let rootModify = fixture(
            name: "conditionalDestroyRootModify",
            instructions: prefix + [
                .beginAccess(
                    result: .init(rawValue: 3),
                    address: .init(rawValue: 2),
                    kind: .modify
                ),
                .destroyStackIfInitialized(.init(rawValue: 0)),
                .endAccess(.init(rawValue: 3)),
                .returnValue(nil),
            ],
            registerTypes: [
                .int64, tuple, .address(tuple), .address(tuple),
            ]
        )
        _ = try verify(additionalFunctions: [rootModify])

        let childModify = fixture(
            name: "conditionalDestroyChildModify",
            instructions: prefix + [
                .projectAggregateAddress(
                    result: .init(rawValue: 3),
                    base: .init(rawValue: 2),
                    fieldIndex: 0
                ),
                .beginAccess(
                    result: .init(rawValue: 4),
                    address: .init(rawValue: 3),
                    kind: .modify
                ),
                .destroyStackIfInitialized(.init(rawValue: 0)),
                .endAccess(.init(rawValue: 4)),
                .returnValue(nil),
            ],
            registerTypes: [
                .int64, tuple, .address(tuple),
                .address(.int64), .address(.int64),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [childModify])
        }

        let disjointChildren = fixture(
            name: "conditionalDestroyDisjointChildren",
            instructions: prefix + [
                .projectAggregateAddress(
                    result: .init(rawValue: 3),
                    base: .init(rawValue: 2),
                    fieldIndex: 0
                ),
                .projectAggregateAddress(
                    result: .init(rawValue: 4),
                    base: .init(rawValue: 2),
                    fieldIndex: 1
                ),
                .beginAccess(
                    result: .init(rawValue: 5),
                    address: .init(rawValue: 3),
                    kind: .modify
                ),
                .beginAccess(
                    result: .init(rawValue: 6),
                    address: .init(rawValue: 4),
                    kind: .modify
                ),
                .destroyStackIfInitialized(.init(rawValue: 0)),
                .endAccess(.init(rawValue: 6)),
                .endAccess(.init(rawValue: 5)),
                .returnValue(nil),
            ],
            registerTypes: [
                .int64, tuple, .address(tuple),
                .address(.int64), .address(.int64),
                .address(.int64), .address(.int64),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [disjointChildren])
        }
    }

    @Test("Address loads and assignments require initialized storage")
    func rejectsUninitializedAddressStorage() throws {
        let load = addressFunction(
            id: 1,
            instructions: [
                .stackAddress(
                    result: .init(rawValue: 1),
                    slot: .init(rawValue: 0)
                ),
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .read
                ),
                .loadAddress(
                    result: .init(rawValue: 3),
                    address: .init(rawValue: 2),
                    mode: .copy
                ),
                .endAccess(.init(rawValue: 2)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [load])
        }

        let store = addressFunction(
            id: 1,
            instructions: [
                .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
                .stackAddress(
                    result: .init(rawValue: 1),
                    slot: .init(rawValue: 0)
                ),
                .beginAccess(
                    result: .init(rawValue: 2),
                    address: .init(rawValue: 1),
                    kind: .modify
                ),
                .storeAddress(
                    address: .init(rawValue: 2),
                    source: .init(rawValue: 0),
                    mode: .assign
                ),
                .endAccess(.init(rawValue: 2)),
                .returnValue(nil),
            ]
        )
        #expect(throws: Verification.Error.self) {
            try verify(additionalFunctions: [store])
        }
    }

    @Test("A partially initialized aggregate stack slot cannot be loaded")
    func rejectsPartiallyInitializedAggregateLoad() throws {
        let tuple = Bytecode.ValueType.tuple([.int64, .int64])
        let function = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "partialTuple",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [
                .int64,
                .address(tuple),
                .address(tuple),
                .address(.int64),
                tuple,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
                        .stackAddress(
                            result: .init(rawValue: 1),
                            slot: .init(rawValue: 0)
                        ),
                        .beginAccess(
                            result: .init(rawValue: 2),
                            address: .init(rawValue: 1),
                            kind: .modify
                        ),
                        .projectAggregateAddress(
                            result: .init(rawValue: 3),
                            base: .init(rawValue: 2),
                            fieldIndex: 0
                        ),
                        .storeAddress(
                            address: .init(rawValue: 3),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .endAccess(.init(rawValue: 2)),
                        .loadStack(
                            result: .init(rawValue: 4),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .returnValue(nil),
                    ]
                ),
            ],
            stackSlotTypes: [tuple]
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 1),
                block: .init(rawValue: 0),
                offset: 6,
                reason: "stack storage $0 is used before initialization"
            )
        ) {
            try verify(additionalFunctions: [function])
        }
    }

    private var initializedPrefix: [Bytecode.Instruction] {
        [
            .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
            .storeStack(
                slot: .init(rawValue: 0),
                source: .init(rawValue: 0),
                mode: .initialize
            ),
            .stackAddress(
                result: .init(rawValue: 1),
                slot: .init(rawValue: 0)
            ),
        ]
    }

    private func addressFunction(
        id: UInt32,
        instructions: [Bytecode.Instruction]
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: id),
            name: "addressFixture",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
                .int64,
                .address(.int64),
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [.init(id: .init(rawValue: 0), instructions: instructions)],
            stackSlotTypes: [.int64]
        )
    }

    private func inoutSetter(id: UInt32) -> Bytecode.Function {
        .init(
            id: .init(rawValue: id),
            name: "setInout",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            parameterConventions: [.inout, .owned],
            resultType: .void,
            registerTypes: [.address(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .storeAddress(
                            address: .init(rawValue: 0),
                            source: .init(rawValue: 1),
                            mode: .assign
                        ),
                        .returnValue(nil),
                    ]
                ),
            ]
        )
    }

    @discardableResult
    private func verify(
        root: Bytecode.Function? = nil,
        additionalFunctions: [Bytecode.Function] = [],
        localTypes: [Bytecode.LocalTypeDefinition] = [],
        capabilities: Set<Core.Capability> = [.baselineV1, .addressValuesV1]
    ) throws -> Verification.Image {
        let root = root ?? identityRoot()
        let shellHash = Core.Digest.sha256("address-verifier-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier.address",
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
            canonicalDeclaration: "func run(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-address-verifier-fixture"
        )
        let module = Bytecode.Module(
            name: "AddressVerifierFixture",
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
                    parameterTypes: [.int64],
                    parameterConventions: root.parameterConventions,
                    resultType: .int64
                ),
            ]
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
    }

    private func identityRoot() -> Bytecode.Function {
        .init(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
    }
}
}
