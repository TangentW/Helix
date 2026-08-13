import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

enum VerificationTests {}

extension VerificationTests {
@Suite("HLBC semantic verifier")
struct SemanticVerifier {
    @Test("A valid typed entry is accepted")
    func acceptsValidEntry() throws {
        let fixture = try makeFixture()
        let verified = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(verified.module == fixture.module)
        #expect(verified.function(entry: .init(rawValue: 0))?.name == "identity")
    }

    @Test("Shell signatures reject nested patch-local values at construction")
    func rejectsLocalValuesInShellSignatures() throws {
        let fixture = try makeFixture()
        let index = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[index])
        entry.parameterTypes = [
            .optional(.array(.local(.init(rawValue: "Fixture.Local")))),
        ]

        #expect(
            throws: Verification.Error.invalidShellInterface(
                "patch-local nominal, Error, address, and closure values cannot appear in entry 0 signature"
            )
        ) {
            try Verification.ShellInterface(
                interfaceHash: fixture.shell.interfaceHash,
                compatibility: fixture.shell.compatibility,
                capabilities: fixture.shell.capabilities,
                entries: [entry]
            )
        }

        var mutatedShell = fixture.shell
        mutatedShell.entries[index]?.resultType = .error
        #expect(
            throws: Verification.Error.invalidShellInterface(
                "patch-local nominal, Error, address, and closure values cannot appear in entry 0 signature"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: mutatedShell,
                policy: fixture.policy
            )
        }
    }

    @Test("A module for another Shell is rejected")
    func rejectsWrongShell() throws {
        let fixture = try makeFixture()
        var module = fixture.module
        module.shellInterfaceHash = .sha256("another-shell")

        #expect(throws: Verification.Error.shellInterfaceHashMismatch) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Use-before-definition is rejected before execution")
    func rejectsUndefinedRegister() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [.returnValue(.init(rawValue: 1))]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A malformed later callee is rejected without crashing its caller verification")
    func rejectsMalformedLaterCallee() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "malformedCallee",
                parameterRegisters: [.init(rawValue: 99)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 99)],
                        instructions: [.returnValue(.init(rawValue: 99))]
                    ),
                ]
            )
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "callee 1 has a parameter register outside its type table"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A block without a terminator is rejected")
    func rejectsMissingTerminator() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [.constantInteger(result: .init(rawValue: 1), value: 1)]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Floating arithmetic requires one matching Float width")
    func rejectsMismatchedFloatingOperands() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 32))
            function.registerTypes.append(.float(bitWidth: 64))
            function.registerTypes.append(.float(bitWidth: 32))
            function.blocks[0].instructions = [
                .constantFloat(result: .init(rawValue: 1), value: 1),
                .constantFloat(result: .init(rawValue: 2), value: 2),
                .floatingBinary(
                    result: .init(rawValue: 3),
                    operation: .add,
                    lhs: .init(rawValue: 1),
                    rhs: .init(rawValue: 2)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "floating binary operands and result must use one float type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Numeric conversions reject forged widths and signedness")
    func rejectsInvalidNumericConversions() throws {
        let invalidExtension = try makeFixture { function in
            function.registerTypes.append(.integer(bitWidth: 8, signed: true))
            function.blocks[0].instructions = [
                .integerConvert(
                    result: .init(rawValue: 1),
                    operation: .signExtend,
                    value: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "sign extension requires a signed input and wider result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidExtension.module),
                shell: invalidExtension.shell,
                policy: invalidExtension.policy
            )
        }

        let invalidSignedness = try makeFixture { function in
            function.registerTypes.append(.float(bitWidth: 64))
            function.blocks[0].instructions = [
                .floatingConvert(
                    result: .init(rawValue: 1),
                    operation: .unsignedIntegerToFloat,
                    value: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "unsigned integer-to-float conversion requires an unsigned integer"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(invalidSignedness.module),
                shell: invalidSignedness.shell,
                policy: invalidSignedness.policy
            )
        }
    }

    @Test("String instructions require their exact operand and result types")
    func rejectsMismatchedStringInstructionTypes() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.string, .string])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "Helix"),
                .stringCount(result: .init(rawValue: 2), string: .init(rawValue: 1)),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.insert(.stringsV1)
        fixture.shell.capabilities.insert(.stringsV1)
        fixture.policy.acceptedCapabilities.insert(.stringsV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "string_count needs a String operand and Int64 result"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("String value types cannot be smuggled in without the String capability")
    func rejectsUndeclaredStringCapability() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "Helix"),
                .returnValue(.init(rawValue: 0)),
            ]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array construction cannot smuggle an element of another type")
    func rejectsMismatchedArrayElement() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.array(.int64), .string])
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 2), value: "not an Int"),
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 2)]
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "make_array elements must match its Array element type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array update cannot forge an index or replacement element type")
    func rejectsMismatchedArrayUpdate() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.int64), .bool, .string, .array(.int64),
            ])
            function.blocks[0].instructions = [
                .makeArray(
                    result: .init(rawValue: 1),
                    elements: [.init(rawValue: 0)]
                ),
                .constantBool(result: .init(rawValue: 2), value: true),
                .constantString(result: .init(rawValue: 3), value: "wrong"),
                .arrayUpdate(
                    result: .init(rawValue: 4),
                    array: .init(rawValue: 1),
                    index: .init(rawValue: 2),
                    value: .init(rawValue: 3)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "array_update types do not match Array.Element and Int index"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Array value types require the collection capability")
    func rejectsUndeclaredArrayCapability() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.array(.int64))
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary keys are restricted to frozen scalar Hashable types")
    func rejectsUnsupportedDictionaryKey() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(
                .dictionary(key: .float(bitWidth: 64), value: .int64)
            )
        }
        fixture.module.capabilities.insert(.collectionsV1)
        fixture.shell.capabilities.insert(.collectionsV1)
        fixture.policy.acceptedCapabilities.insert(.collectionsV1)

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Dictionary iteration requires an initialized verified index slot")
    func rejectsUninitializedDictionaryIterator() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [
                .array(.tuple([.string, .int64])),
                .dictionary(key: .string, value: .int64),
                .optional(.tuple([.string, .int64])),
            ])
            function.stackSlotTypes = [.int64]
            function.blocks[0].instructions = [
                .makeArray(result: .init(rawValue: 1), elements: []),
                .makeDictionary(result: .init(rawValue: 2), pairs: .init(rawValue: 1)),
                .dictionaryNext(
                    result: .init(rawValue: 3),
                    dictionary: .init(rawValue: 2),
                    indexSlot: .init(rawValue: 0)
                ),
                .returnValue(.init(rawValue: 0)),
            ]
        }
        fixture.module.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.shell.capabilities.formUnion([.collectionsV1, .stringsV1])
        fixture.policy.acceptedCapabilities.formUnion([.collectionsV1, .stringsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "dictionary_next uses an uninitialized index slot"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A duplicate SSA definition is rejected")
    func rejectsDuplicateDefinition() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .constantInteger(result: .init(rawValue: 1), value: 1),
                .constantInteger(result: .init(rawValue: 1), value: 2),
                .returnValue(.init(rawValue: 1)),
            ]
        }

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Capabilities are intersected with runtime policy")
    func rejectsDeniedCapability() throws {
        let fixture = try makeFixture()
        var module = fixture.module
        module.capabilities.insert(.stringsV1)

        #expect(throws: Verification.Error.capabilityDenied(.stringsV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Capabilities unknown to this Runtime are rejected even if policy lists them")
    func rejectsUnsupportedCapability() throws {
        var fixture = try makeFixture()
        let future: Core.Capability = "future-execution-99"
        fixture.module.capabilities.insert(future)
        fixture.shell.capabilities.insert(future)
        fixture.policy.acceptedCapabilities.insert(future)

        #expect(throws: Verification.Error.unsupportedCapability(future)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Source maps must reference an existing instruction and valid location")
    func rejectsInvalidSourceMap() throws {
        var fixture = try makeFixture()
        fixture.module.sourceMap = [
            .init(
                functionID: .init(rawValue: 0),
                blockID: .init(rawValue: 0),
                instructionOffset: 1,
                location: .init(file: "Sources/Fixture.swift", line: 1, column: 1)
            ),
        ]

        #expect(throws: Verification.Error.invalidSourceMap("instruction offset is outside 0.bb0")) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("copy_value cannot copy a noncopyable frozen native type")
    func rejectsCopyOfNoncopyableNativeType() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnly"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.blocks[0].instructions = [
                .copyValue(result: .init(rawValue: 1), source: .init(rawValue: 0)),
                .destroyValue(.init(rawValue: 0)),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnly",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnly.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(throws: Verification.Error.self) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A borrowed copyable Native reference can be copied into owned storage")
    func acceptsCopyOfBorrowedNativeReference() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterConventions = [.borrowed]
            function.registerTypes = [.native(typeID), .native(typeID), .int64]
            function.blocks[0].instructions = [
                .copyValue(result: .init(rawValue: 1), source: .init(rawValue: 0)),
                .destroyValue(.init(rawValue: 1)),
                .constantInteger(result: .init(rawValue: 2), value: 7),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        fixture.module.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.policy.acceptedCapabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID)]
        fixture.shell.entries[entryIndex] = entry

        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(image.module.functions[0].parameterConventions == [.borrowed])
    }

    @Test("Owned native values may remain live across Optional control flow")
    func acceptsOwnedValueCarriedAcrossOptionalSwitch() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterRegisters = [
                .init(rawValue: 0),
                .init(rawValue: 1),
            ]
            function.parameterConventions = [.owned, .owned]
            function.registerTypes = [
                .native(typeID),
                .optional(.int64),
                .int64,
                .int64,
            ]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .switchOptional(
                            optional: .init(rawValue: 1),
                            someTarget: .init(rawValue: 1),
                            noneTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 2)],
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .constantInteger(result: .init(rawValue: 3), value: 0),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID), .optional(.int64)]
        fixture.shell.entries[entryIndex] = entry

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Owned-value states must agree at a CFG merge")
    func rejectsMismatchedOwnershipAtMerge() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        var fixture = try makeFixture { function in
            function.parameterRegisters = [
                .init(rawValue: 0),
                .init(rawValue: 1),
            ]
            function.parameterConventions = [.owned, .owned]
            function.registerTypes = [.native(typeID), .bool]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .conditionalBranch(
                            condition: .init(rawValue: 1),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .destroyValue(.init(rawValue: 0)),
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [
                        .trap(.explicit("merge should be unreachable")),
                    ]
                ),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )
        let entryIndex = Core.EntryIndex(rawValue: 0)
        var entry = try #require(fixture.shell.entries[entryIndex])
        entry.parameterTypes = [.native(typeID), .bool]
        fixture.shell.entries[entryIndex] = entry

        #expect(
            throws: Verification.Error.invalidBlock(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                reason: "incoming owned-value states disagree"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Linear call arguments transfer ownership instead of minting an alias")
    func rejectsUseAfterLinearCallTransfer() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnly"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .destroyValue(.init(rawValue: 0)),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "forwardMoveOnly",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .native(typeID),
                registerTypes: [.native(typeID)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnly",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnly.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "instruction uses a consumed owned value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Stack initialization state must agree at a CFG merge")
    func rejectsMismatchedStackStateAtMerge() throws {
        let fixture = try makeFixture { function in
            function.registerTypes.append(.bool)
            function.stackSlotTypes = [.int64]
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantBool(result: .init(rawValue: 1), value: true),
                        .conditionalBranch(
                            condition: .init(rawValue: 1),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .branch(target: .init(rawValue: 3), arguments: []),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [.branch(target: .init(rawValue: 3), arguments: [])]
                ),
                .init(
                    id: .init(rawValue: 3),
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        }

        #expect(
            throws: Verification.Error.invalidBlock(
                function: .init(rawValue: 0),
                block: .init(rawValue: 3),
                reason: "incoming stack-slot initialization states disagree"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("throw_error requires both a throwing effect and capability")
    func rejectsThrowFromNonthrowingFunction() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.string)
            function.blocks[0].instructions = [
                .constantString(result: .init(rawValue: 1), value: "failure"),
                .throwError(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.shell.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.policy.acceptedCapabilities.formUnion([.stringsV1, .untypedThrowsV1])

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "throw_error requires a throwing function and untyped-throws capability"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("switch_optional requires one wrapped payload only on its some edge")
    func rejectsMalformedOptionalSwitchTargets() throws {
        var fixture = try makeFixture { function in
            function.parameterRegisters = [.init(rawValue: 0)]
            function.resultType = .int64
            function.registerTypes = [.optional(.int64), .int64, .int64]
            function.entryBlock = .init(rawValue: 0)
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .switchOptional(
                            optional: .init(rawValue: 0),
                            someTarget: .init(rawValue: 1),
                            noneTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), value: 1),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 2), value: 0),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        }
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.optional(.int64)],
            resultType: .int64,
            effects: entry.effects
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "switch_optional some target must accept the wrapped value"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A noncopyable native value cannot be copied out of a stack slot")
    func rejectsStackCopyOfNoncopyableNativeType() throws {
        let typeID = Core.TypeID.derive(
            namespace: Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.MoveOnlyStackValue"
        )
        var fixture = try makeFixture { function in
            function.resultType = .native(typeID)
            function.registerTypes = [.native(typeID), .native(typeID)]
            function.stackSlotTypes = [.native(typeID)]
            function.blocks[0].instructions = [
                .storeStack(
                    slot: .init(rawValue: 0),
                    source: .init(rawValue: 0),
                    mode: .initialize
                ),
                .loadStack(
                    result: .init(rawValue: 1),
                    slot: .init(rawValue: 0),
                    mode: .copy
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        fixture.module.capabilities.insert(.nativeTypesV1)
        fixture.shell.capabilities.insert(.nativeTypesV1)
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.MoveOnlyStackValue",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.MoveOnlyStackValue.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        let entry = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[entry.index] = .init(
            index: entry.index,
            key: entry.key,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            effects: entry.effects
        )
        fixture.policy.acceptedCapabilities.insert(.nativeTypesV1)

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "load_stack.copy requires a copyable slot type"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Call effects must be contained by the caller declaration")
    func rejectsUnreportedEntrySideEffects() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .entryApply(
                    result: .init(rawValue: 1),
                    entry: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        let root = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[.init(rawValue: 1)] = .init(
            index: .init(rawValue: 1),
            key: root.key,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(hasExternalSideEffects: true)
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "entry_apply calls an externally side-effecting operation from a pure function"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("try_apply accepts handled throws and rejects malformed error edges")
    func validatesTryApplyControlFlow() throws {
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.int64, .string])
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .entryTryApply(
                            entry: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)],
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 1)],
                    instructions: [.returnValue(.init(rawValue: 1))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 2)],
                    instructions: [
                        .destroyValue(.init(rawValue: 2)),
                        .returnValue(.init(rawValue: 0)),
                    ]
                ),
            ]
        }
        let root = try #require(fixture.shell.entries[.init(rawValue: 0)])
        fixture.shell.entries[.init(rawValue: 1)] = .init(
            index: .init(rawValue: 1),
            key: root.key,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(mayThrow: true)
        )
        fixture.module.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.shell.capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        fixture.policy.acceptedCapabilities.formUnion([.stringsV1, .untypedThrowsV1])

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        fixture.module.functions[0].registerTypes[2] = .int64
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "try_apply error target must accept one untyped String error"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Local nominal tables and enum control flow fail closed")
    func validatesLocalNominalContracts() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Payload")
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.local(key), .int64])
            function.blocks = [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeEnum(
                            result: .init(rawValue: 1),
                            caseIndex: 0,
                            payload: .init(rawValue: 0)
                        ),
                        .switchEnum(
                            enumeration: .init(rawValue: 1),
                            cases: [
                                .init(caseIndex: 0, target: .init(rawValue: 1)),
                            ],
                            defaultTarget: nil
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 2)],
                    instructions: [.returnValue(.init(rawValue: 2))]
                ),
            ]
        }
        fixture.module.localTypes = [
            .init(
                key: key,
                kind: .enumeration(
                    cases: [.init(name: "value", payloadType: .int64)]
                )
            ),
        ]
        fixture.module.capabilities.insert(.localNominalsV1)
        fixture.shell.capabilities.insert(.localNominalsV1)
        fixture.policy.acceptedCapabilities.insert(.localNominalsV1)

        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        var wrongPayload = fixture.module
        wrongPayload.localTypes[0].kind = .enumeration(
            cases: [.init(name: "value", payloadType: .bool)]
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_enum payload does not match the local enum case"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongPayload),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var nonexhaustive = fixture.module
        nonexhaustive.localTypes[0].kind = .enumeration(
            cases: [
                .init(name: "value", payloadType: .int64),
                .init(name: "none"),
            ]
        )
        nonexhaustive.functions[0].blocks[0].instructions[1] = .switchEnum(
            enumeration: .init(rawValue: 1),
            cases: [.init(caseIndex: 0, target: .init(rawValue: 1))],
            defaultTarget: nil
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "switch_enum without a default must be exhaustive"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nonexhaustive),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var nativeMember = fixture.module
        nativeMember.localTypes[0].kind = .enumeration(
            cases: [
                .init(
                    name: "value",
                    payloadType: .native(.init(rawValue: .sha256("forged-local-native")))
                ),
            ]
        )
        #expect(
            throws: Verification.Error.invalidModule(
                "HLBC local types cannot contain native values"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nativeMember),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var recursive = fixture.module
        recursive.localTypes[0].kind = .enumeration(
            cases: [.init(name: "next", payloadType: .local(key))]
        )
        #expect(
            throws: Verification.Error.invalidModule(
                "local type graph is recursive at \(key); "
                    + "recursive HLBC local values are unsupported"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(recursive),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }

        var existentialMember = fixture.module
        existentialMember.localTypes[0].kind = .enumeration(
            cases: [.init(name: "wrapped", payloadType: .error)]
        )
        existentialMember.capabilities.insert(.structuredErrorsV1)
        fixture.shell.capabilities.insert(.structuredErrorsV1)
        fixture.policy.acceptedCapabilities.insert(.structuredErrorsV1)
        #expect(
            throws: Verification.Error.invalidModule(
                "HLBC local types cannot contain Error existential values"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(existentialMember),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("A nonescaping closure body with copyable captures is accepted")
    func acceptsClosureContract() throws {
        var fixture = try makeClosureFixture()
        fixture.module.functions[1].parameterConventions = [.borrowed, .borrowed]
        fixture.module.capabilities.insert(.borrowCallsV1)
        fixture.shell.capabilities.insert(.borrowCallsV1)
        fixture.policy.acceptedCapabilities.insert(.borrowCallsV1)

        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )

        #expect(image.module.functions[1].kind == .closureBody)
        #expect(image.module.capabilities.contains(.closureValuesV1))
    }

    @Test("Borrowed closure parameters cannot hide linear Native ownership")
    func rejectsBorrowedLinearClosureParameter() throws {
        var fixture = try makeClosureFixture()
        let typeID = Core.TypeID.derive(
            namespace: .derive(
                bundleID: "dev.helix.verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "Fixture.Reference"
        )
        let signature = Bytecode.ClosureSignature(
            parameters: [.native(typeID)],
            result: .int64
        )
        fixture.module.functions[0].registerTypes[1] = .closure(signature)
        fixture.module.functions[1].registerTypes[0] = .native(typeID)
        fixture.module.functions[1].parameterConventions = [.borrowed, .borrowed]
        fixture.module.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.capabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.policy.acceptedCapabilities.formUnion([.borrowCallsV1, .nativeTypesV1])
        fixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout"),
            isCopyable: true,
            estimatedSize: 8
        )

        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "HLBC borrowed closure parameters cannot require linear ownership"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Closure construction requires an exact closure-body contract")
    func rejectsMalformedClosureBodyContract() throws {
        var wrongKind = try makeClosureFixture()
        wrongKind.module.functions[1].kind = .ordinary
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "make_closure target must be a closure body"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongKind.module),
                shell: wrongKind.shell,
                policy: wrongKind.policy
            )
        }

        var wrongCapture = try makeClosureFixture()
        wrongCapture.module.functions[1].registerTypes[1] = .bool
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure body parameters must equal invocation parameters followed by captures"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(wrongCapture.module),
                shell: wrongCapture.shell,
                policy: wrongCapture.policy
            )
        }
    }

    @Test("Closure bodies require dynamic calls and internal closure returns require capability")
    func validatesClosureEscapeAndDirectCall() throws {
        var directCall = try makeClosureFixture()
        directCall.module.functions[0].blocks[0].instructions = [
            .apply(
                result: .init(rawValue: 2),
                function: .init(rawValue: 1),
                arguments: [.init(rawValue: 0), .init(rawValue: 0)]
            ),
            .returnValue(.init(rawValue: 2)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "closure bodies must be invoked through closure_apply"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(directCall.module),
                shell: directCall.shell,
                policy: directCall.policy
            )
        }

        var escaping = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(parameters: [.int64], result: .int64)
        escaping.module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "escapingClosure",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .closure(signature),
                registerTypes: [.int64, .closure(signature)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .makeClosure(
                                result: .init(rawValue: 1),
                                function: .init(rawValue: 1),
                                captures: [.init(rawValue: 0)]
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        )
        #expect(
            throws: Verification.Error.capabilityDenied(.escapingClosureValuesV1)
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(escaping.module),
                shell: escaping.shell,
                policy: escaping.policy
            )
        }
        escaping.module.capabilities.insert(.escapingClosureValuesV1)
        escaping.shell.capabilities.insert(.escapingClosureValuesV1)
        escaping.policy.acceptedCapabilities.insert(.escapingClosureValuesV1)
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(escaping.module),
            shell: escaping.shell,
            policy: escaping.policy
        )
        #expect(image.module.functions[2].resultType == .closure(signature))
    }

    @Test("A closure may capture another closure only with escaping capability")
    func validatesNestedClosureCaptureCapability() throws {
        var fixture = try makeClosureFixture()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            result: .int64
        )
        fixture.module.functions[0].registerTypes.append(contentsOf: [
            .closure(signature),
            .int64,
        ])
        fixture.module.functions[0].blocks[0].instructions = [
            .makeClosure(
                result: .init(rawValue: 1),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            .makeClosure(
                result: .init(rawValue: 3),
                function: .init(rawValue: 2),
                captures: [.init(rawValue: 1)]
            ),
            .closureApply(
                result: .init(rawValue: 4),
                closure: .init(rawValue: 3),
                arguments: [.init(rawValue: 0)]
            ),
            .returnValue(.init(rawValue: 4)),
        ]
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "nestedClosureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .int64,
                registerTypes: [.int64, .closure(signature), .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [
                            .closureApply(
                                result: .init(rawValue: 2),
                                closure: .init(rawValue: 1),
                                arguments: [.init(rawValue: 0)]
                            ),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
        )

        #expect(
            throws: Verification.Error.capabilityDenied(
                .escapingClosureValuesV1
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
        fixture.module.capabilities.insert(.escapingClosureValuesV1)
        fixture.shell.capabilities.insert(.escapingClosureValuesV1)
        fixture.policy.acceptedCapabilities.insert(.escapingClosureValuesV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    @Test("Compiler-generated specializations cannot become Shell entries")
    func rejectsSpecializationEntry() throws {
        var fixture = try makeFixture()
        fixture.module.functions[0].kind = .concreteSpecialization
        fixture.module.capabilities.insert(.compilerSpecializationsV1)
        fixture.shell.capabilities.insert(.compilerSpecializationsV1)
        fixture.policy.acceptedCapabilities.insert(.compilerSpecializationsV1)

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "closure bodies and compiler specializations cannot be patch entries"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    @Test("Async effects are entry-only, capability-gated, and cannot be called synchronously")
    func verifiesAsyncLeafContract() throws {
        var accepted = try makeFixture()
        accepted.module.functions[0].effects.isAsync = true
        accepted.module.capabilities.insert(.asyncLeafEntriesV1)
        accepted.shell.entries[.init(rawValue: 0)]?.effects.isAsync = true
        accepted.shell.capabilities.insert(.asyncLeafEntriesV1)
        accepted.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(accepted.module),
            shell: accepted.shell,
            policy: accepted.policy
        )

        var missingCapability = accepted
        missingCapability.module.capabilities.remove(.asyncLeafEntriesV1)
        #expect(throws: Verification.Error.capabilityDenied(.asyncLeafEntriesV1)) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(missingCapability.module),
                shell: missingCapability.shell,
                policy: missingCapability.policy
            )
        }

        var helper = try makeFixture { function in
            function.registerTypes.append(.int64)
            function.blocks[0].instructions = [
                .apply(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 1)),
            ]
        }
        helper.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "async helper",
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
                ],
                effects: .init(isAsync: true)
            )
        )
        helper.module.capabilities.insert(.asyncLeafEntriesV1)
        helper.shell.capabilities.insert(.asyncLeafEntriesV1)
        helper.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "hlbc_apply calls an async entry without a suspension contract"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(helper.module),
                shell: helper.shell,
                policy: helper.policy
            )
        }
    }

    @Test("Async closure signatures remain outside the non-suspending entry capability")
    func rejectsAsyncClosureSignature() throws {
        var fixture = try makeClosureFixture()
        fixture.module.functions[0].registerTypes[1] = .closure(
            .init(parameters: [.int64], result: .int64, effects: .init(isAsync: true))
        )
        fixture.module.capabilities.insert(.asyncLeafEntriesV1)
        fixture.shell.capabilities.insert(.asyncLeafEntriesV1)
        fixture.policy.acceptedCapabilities.insert(.asyncLeafEntriesV1)

        #expect(
            throws: Verification.Error.invalidFunction(
                function: .init(rawValue: 0),
                reason: "throwing or async closures require a future suspension-aware closure contract"
            )
        ) {
            try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(fixture.module),
                shell: fixture.shell,
                policy: fixture.policy
            )
        }
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private func makeFixture(
        mutate: ((inout Bytecode.Function) -> Void)? = nil
    ) throws -> Fixture {
        let shellHash = Core.Digest.sha256("verifier-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier",
            buildNumber: "1",
            seed: "fixture"
        )
        let lowered = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_: Int) -> Int",
            loweredSignature: lowered,
            role: .function
        )
        var function = Bytecode.Function(
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
        mutate?(&function)
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-verifier-fixture"
        )
        let module = Bytecode.Module(
            name: "VerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            functions: [function],
            entries: [.init(entryIndex: .init(rawValue: 0), functionKey: key, functionID: function.id)]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        return Fixture(module: module, shell: shell, policy: .init())
    }

    private func makeClosureFixture() throws -> Fixture {
        let signature = Bytecode.ClosureSignature(parameters: [.int64], result: .int64)
        var fixture = try makeFixture { function in
            function.registerTypes.append(contentsOf: [.closure(signature), .int64])
            function.blocks[0].instructions = [
                .makeClosure(
                    result: .init(rawValue: 1),
                    function: .init(rawValue: 1),
                    captures: [.init(rawValue: 0)]
                ),
                .closureApply(
                    result: .init(rawValue: 2),
                    closure: .init(rawValue: 1),
                    arguments: [.init(rawValue: 0)]
                ),
                .returnValue(.init(rawValue: 2)),
            ]
        }
        fixture.module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "closureBody",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .int64,
                registerTypes: [.int64, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )
        fixture.module.capabilities.insert(.closureValuesV1)
        fixture.shell.capabilities.insert(.closureValuesV1)
        fixture.policy.acceptedCapabilities.insert(.closureValuesV1)
        return fixture
    }
}
}
