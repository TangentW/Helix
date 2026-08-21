import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM address and call-convention execution")
struct AddressExecution {
    @Test("Borrowed mutable cells alias only an active modify address")
    func executesBorrowedMutableCellLifetime() throws {
        let first = VM.Value.integer(try int(1))
        let second = VM.Value.integer(try int(2))
        let replacement = VM.Value.integer(try int(3))
        let tupleType = Bytecode.ValueType.tuple([.int64, .int64])
        let cell = VM.MemoryCell(
            .tuple([first, second]),
            storageShape: .tuple([.leaf, .leaf])
        )
        let base = VM.Address(cell: cell, pointee: tupleType)

        let read = try base.begin(.read)
        #expect(throws: VM.RuntimeTrap.addressWriteRequiresModifyAccess) {
            try VM.MutableCell(borrowing: read)
        }
        try read.end()

        let modify = try base.begin(.modify)
        let borrowed = try VM.MutableCell(borrowing: modify)
            .projected(field: 1, pointee: .int64)
        #expect(try borrowed.read() == second)
        try borrowed.store(replacement, mode: .assign)
        #expect(try modify.read() == .tuple([first, replacement]))

        try modify.end()
        #expect(throws: VM.RuntimeTrap.inactiveAddressAccess) {
            try borrowed.read()
        }
        #expect(throws: VM.RuntimeTrap.inactiveAddressAccess) {
            try borrowed.store(second, mode: .assign)
        }
    }

    @Test("Empty aggregate storage still requires explicit initialization")
    func requiresEmptyAggregateInitialization() throws {
        let cell = VM.MemoryCell(storageShape: .leaf)

        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.directRead()
        }
        try cell.directStore(.tuple([]), mode: .initialize)
        #expect(try cell.directTake() == .tuple([]))
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.directRead()
        }
    }

    @Test("Replace stores and conditional destroy cover dynamic storage state")
    func executesDynamicStorageTransitions() throws {
        let first = VM.Value.integer(try int(1))
        let second = VM.Value.integer(try int(2))
        let replacement = VM.Value.integer(try int(3))
        let cell = VM.MemoryCell(
            storageShape: .tuple([.leaf, .leaf])
        )

        try cell.unscopedStore(
            first,
            path: [0],
            mode: .initialize
        )
        try cell.unscopedStore(
            second,
            path: [1],
            mode: .replace
        )
        #expect(try cell.directRead() == .tuple([first, second]))

        try cell.unscopedStore(
            replacement,
            path: [0],
            mode: .replace
        )
        #expect(try cell.directRead() == .tuple([replacement, second]))

        try cell.directDestroyIfInitialized()
        try cell.directDestroyIfInitialized()
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.directRead()
        }
    }

    @Test("Projected takes preserve siblings and require modify access")
    func executesProjectedTake() throws {
        let first = VM.Value.integer(try int(1))
        let second = VM.Value.integer(try int(2))
        let replacement = VM.Value.integer(try int(3))
        let cell = VM.MemoryCell(
            .tuple([first, second]),
            storageShape: .tuple([.leaf, .leaf])
        )

        let read = try cell.begin(path: [0], kind: .read)
        #expect(throws: VM.RuntimeTrap.addressWriteRequiresModifyAccess) {
            try cell.take(path: [0], token: read)
        }
        try cell.end(token: read)

        let modify = try cell.begin(path: [0], kind: .modify)
        #expect(
            try cell.projectedRemovalWork(path: [0], token: modify) == 3
        )
        #expect(try cell.take(path: [0], token: modify) == first)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.take(path: [0], token: modify)
        }
        try cell.end(token: modify)

        #expect(try cell.unscopedRead(path: [1]) == second)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.directRead()
        }
        try cell.unscopedStore(
            replacement,
            path: [0],
            mode: .initialize
        )
        #expect(try cell.directRead() == .tuple([replacement, second]))
    }

    @Test("A failed projected take leaves storage unchanged")
    func keepsProjectedTakeTransactional() throws {
        let first = VM.Value.integer(try int(1))
        let original = VM.Value.tuple([first])
        let cell = VM.MemoryCell(
            original,
            storageShape: .tuple([.leaf, .leaf])
        )
        let modify = try cell.begin(path: [0], kind: .modify)

        #expect(throws: VM.RuntimeTrap.invalidAddressProjection) {
            try cell.take(path: [0], token: modify)
        }
        try cell.end(token: modify)
        #expect(try cell.directRead() == original)
    }

    @Test("Projected destruction preserves siblings and partial initialization")
    func executesProjectedDestroy() throws {
        let first = VM.Value.integer(try int(1))
        let second = VM.Value.integer(try int(2))
        let cell = VM.MemoryCell(
            storageShape: .tuple([
                .tuple([.leaf, .leaf]),
                .leaf,
            ])
        )
        try cell.unscopedStore(first, path: [0, 0], mode: .initialize)
        try cell.unscopedStore(second, path: [1], mode: .initialize)

        let read = try cell.begin(path: [0], kind: .read)
        #expect(throws: VM.RuntimeTrap.addressWriteRequiresModifyAccess) {
            try cell.destroy(
                path: [0],
                token: read,
                ifInitialized: true
            )
        }
        try cell.end(token: read)

        let modify = try cell.begin(path: [0], kind: .modify)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.destroy(
                path: [0],
                token: modify,
                ifInitialized: false
            )
        }
        try cell.destroy(
            path: [0],
            token: modify,
            ifInitialized: true
        )
        try cell.destroy(
            path: [0],
            token: modify,
            ifInitialized: true
        )
        try cell.end(token: modify)

        #expect(try cell.unscopedRead(path: [1]) == second)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.unscopedRead(path: [0, 0])
        }

        let invalid = try cell.begin(path: [99], kind: .modify)
        #expect(throws: VM.RuntimeTrap.invalidAddressProjection) {
            try cell.destroy(
                path: [99],
                token: invalid,
                ifInitialized: true
            )
        }
        try cell.end(token: invalid)
    }

    @Test("Conditional projected destroy executes through verified bytecode")
    func executesConditionalProjectedDestroyInstruction() throws {
        let tuple = Bytecode.ValueType.tuple([.int64, .int64])
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "conditionalProjectedDestroy",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [
                .int64, .address(tuple), .address(.int64),
                .address(.int64), .address(.int64), .address(.int64),
                .address(.int64), .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 0),
                            bitPattern: 2
                        ),
                        .stackAddress(
                            result: .init(rawValue: 1),
                            slot: .init(rawValue: 0)
                        ),
                        .projectAggregateAddress(
                            result: .init(rawValue: 2),
                            base: .init(rawValue: 1),
                            fieldIndex: 1
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
                        .projectAggregateAddress(
                            result: .init(rawValue: 4),
                            base: .init(rawValue: 1),
                            fieldIndex: 0
                        ),
                        .beginAccess(
                            result: .init(rawValue: 5),
                            address: .init(rawValue: 4),
                            kind: .modify
                        ),
                        .destroyAddressIfInitialized(.init(rawValue: 5)),
                        .endAccess(.init(rawValue: 5)),
                        .beginAccess(
                            result: .init(rawValue: 6),
                            address: .init(rawValue: 2),
                            kind: .modify
                        ),
                        .loadAddress(
                            result: .init(rawValue: 7),
                            address: .init(rawValue: 6),
                            mode: .take
                        ),
                        .endAccess(.init(rawValue: 6)),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ],
            stackSlotTypes: [tuple]
        )
        let image = try verify(
            root: function,
            additionalFunctions: [],
            capabilities: [.baselineV1, .addressValuesV1],
            parameterTypes: [],
            resultType: .int64
        )

        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [],
                budget: .init(
                    limits: .init(
                        instructionFuelPerEntry: 22,
                        maxWallTimeMainThreadMilliseconds: 1_000
                    )
                )
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [],
                budget: .init(
                    limits: .init(
                        instructionFuelPerEntry: 23,
                        maxWallTimeMainThreadMilliseconds: 1_000
                    )
                )
            ) == .returned(.integer(try int(2)))
        )
    }

    @Test("Conditional root destruction respects active access scope shape")
    func enforcesConditionalDestroyExclusivity() throws {
        let first = VM.Value.integer(try int(1))
        let second = VM.Value.integer(try int(2))
        let cell = VM.MemoryCell(
            .tuple([first, second]),
            storageShape: .tuple([.leaf, .leaf])
        )

        let read = try cell.begin(path: [], kind: .read)
        #expect(throws: VM.RuntimeTrap.exclusivityViolation) {
            try cell.directDestroyIfInitialized()
        }
        try cell.end(token: read)

        let child = try cell.begin(path: [0], kind: .modify)
        #expect(throws: VM.RuntimeTrap.exclusivityViolation) {
            try cell.directDestroyIfInitialized()
        }
        try cell.end(token: child)

        let left = try cell.begin(path: [0], kind: .modify)
        let right = try cell.begin(path: [1], kind: .modify)
        #expect(throws: VM.RuntimeTrap.exclusivityViolation) {
            try cell.directDestroyIfInitialized()
        }
        try cell.end(token: right)
        try cell.end(token: left)

        let root = try cell.begin(path: [], kind: .modify)
        try cell.directDestroyIfInitialized()
        try cell.end(token: root)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try cell.directRead()
        }
    }

    @Test("A scalar stack value is mutated through an inout helper")
    func executesScalarInoutMutation() throws {
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "mutateLocal",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
                .int64,
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
                        .constantInteger(result: .init(rawValue: 3), bitPattern: 41),
                        .apply(
                            result: nil,
                            function: .init(rawValue: 1),
                            arguments: [.init(rawValue: 2), .init(rawValue: 3)]
                        ),
                        .endAccess(.init(rawValue: 2)),
                        .loadStack(
                            result: .init(rawValue: 4),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )
        let image = try verify(
            root: root,
            additionalFunctions: [inoutSetter(id: 1)],
            capabilities: [.baselineV1, .addressValuesV1]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.integer(try int(5))]
            ) == .returned(.integer(try int(41)))
        )
    }

    @Test("A projected local-struct field is written back to its root cell")
    func executesProjectedStructMutation() throws {
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
                        .constantInteger(result: .init(rawValue: 6), bitPattern: 73),
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
            capabilities: [.baselineV1, .addressValuesV1, .localNominalsV1],
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
            ]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.integer(try int(5))]
            ) == .returned(.integer(try int(73)))
        )
    }

    @Test("Borrowed calls retain caller ownership while owned calls consume it")
    func executesBorrowedNativeValueCall() throws {
        struct Payload: Hashable, Sendable { var value: Int }

        let typeID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "Fixture.Payload"
        )
        let layout = Core.Digest.sha256("Fixture.Payload.layout.v1")
        let operations = VM.NativeTypeOperations(
            id: typeID,
            canonicalName: "Fixture.Payload",
            kind: .value,
            layoutFingerprint: layout,
            estimatedSize: 8,
            clone: { (value: Payload) in value }
        )
        let descriptor = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Fixture.Payload",
            kind: .value,
            layoutFingerprint: layout,
            isCopyable: true,
            estimatedSize: 8
        )
        let nativeType = Bytecode.ValueType.native(typeID)
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "borrowAndReturn",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: nativeType,
            registerTypes: [nativeType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .apply(
                            result: nil,
                            function: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 0)),
                    ]
                ),
            ]
        )
        func observer(_ convention: Bytecode.ParameterConvention) -> Bytecode.Function {
            .init(
                id: .init(rawValue: 1),
                name: "observe",
                parameterRegisters: [.init(rawValue: 0)],
                parameterConventions: [convention],
                resultType: .void,
                registerTypes: [nativeType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(nil)]
                    ),
                ]
            )
        }
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .borrowCallsV1,
            .nativeTypesV1,
        ]
        let image = try verify(
            root: root,
            additionalFunctions: [observer(.borrowed)],
            capabilities: capabilities,
            parameterTypes: [nativeType],
            resultType: nativeType,
            shellTypes: [descriptor]
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let boxed = try operations.box(Payload(value: 17))

        #expect(
            VM.Interpreter(nativeTypeCatalog: catalog).invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.native(boxed)]
            ) == .returned(.native(boxed))
        )
        #expect(throws: Verification.Error.self) {
            try verify(
                root: root,
                additionalFunctions: [observer(.owned)],
                capabilities: capabilities,
                parameterTypes: [nativeType],
                resultType: nativeType,
                shellTypes: [descriptor]
            )
        }
    }

    private let namespace = Core.ShellNamespaceID.derive(
        bundleID: "dev.helix.vm.address",
        buildNumber: "1",
        seed: "fixture"
    )

    private func int(_ value: Int64) throws -> VM.Integer {
        try .init(signed: value, bitWidth: 64, isSigned: true)
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

    private func verify(
        root: Bytecode.Function,
        additionalFunctions: [Bytecode.Function],
        capabilities: Set<Core.Capability>,
        localTypes: [Bytecode.LocalTypeDefinition] = [],
        parameterTypes: [Bytecode.ValueType] = [.int64],
        resultType: Bytecode.ValueType = .int64,
        shellTypes: [Verification.ResolvedNativeType] = []
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("address-vm-shell")
        let signature = Core.LoweredSignature(
            parameters: parameterTypes.map(\.description),
            result: resultType.description
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func run",
            loweredSignature: signature,
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-address-vm-fixture"
        )
        let module = Bytecode.Module(
            name: "AddressVMFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: .init(maxWallTimeMainThreadMilliseconds: 1_000),
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
                    resultType: resultType
                ),
            ],
            types: shellTypes
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                resourceCeiling: .init(maxWallTimeMainThreadMilliseconds: 1_000)
            )
        )
    }
}
}
