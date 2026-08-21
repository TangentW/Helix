import Foundation
import HelixCore
import Testing
@testable import HelixBytecode

@Test("HLBC magic is exactly eight bytes")
func magicWidth() {
    #expect(Bytecode.Format.magic.count == 8)
    #expect(String(decoding: Bytecode.Format.magic.prefix(4), as: UTF8.self) == "HLBC")
}

enum BytecodeTests {}

extension BytecodeTests {
@Suite("HLBC container")
struct Container {
    @Test("A typed CFG survives an encode/decode round trip")
    func roundTrip() throws {
        let module = try makeAddModule()
        let encoded = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(encoded)

        #expect(Array(encoded.prefix(8)) == Bytecode.Format.magic)
        #expect(decoded.module == module)
        #expect(decoded.header.shellInterfaceHash == module.shellInterfaceHash)
        #expect(decoded.sections[.functions] != nil)
        #expect(decoded.sections[.code] != nil)
    }

    @Test("Optional unwrap traps survive the HLBC 1.0 wire format")
    func optionalUnwrapTrapRoundTrip() throws {
        var module = try makeAddModule()
        module.functions[0].blocks[1].instructions = [
            .trap(.optionalUnwrapOfNil),
        ]

        let decoded = try Bytecode.Decoder.decode(
            Bytecode.Encoder.encode(module)
        ).module

        #expect(decoded == module)
        #expect(
            Bytecode.TrapReason.optionalUnwrapOfNil.description
                == "attempted to unwrap a nil Optional"
        )
    }

    @Test("Function stack layout and effects survive the wire format")
    func stackAndEffectsRoundTrip() throws {
        var module = try makeAddModule()
        module.functions[0].stackSlotTypes = [.optional(.string)]
        module.functions[0].effects = .init(mayThrow: true)

        let decoded = try Bytecode.Decoder.decode(Bytecode.Encoder.encode(module)).module

        #expect(decoded.functions[0].stackSlotTypes == [.optional(.string)])
        #expect(decoded.functions[0].effects == .init(mayThrow: true))
        #expect(decoded == module)
    }

    @Test("Dictionary mutation and projection share the current HLBC 1.0 wire format")
    func dictionaryOperationsRoundTrip() throws {
        let dictionary = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        var module = try makeAddModule()
        module.capabilities.formUnion([.collectionsV1, .stringsV1])
        module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "dictionaryOperations",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: dictionary,
            registerTypes: [
                dictionary, .string, .optional(.int64), .optional(.int64),
                dictionary, .array(.string), .array(.int64),
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    instructions: [
                        .dictionarySet(
                            previousValueResult: .init(rawValue: 3),
                            dictionaryResult: .init(rawValue: 4),
                            dictionary: .init(rawValue: 0),
                            key: .init(rawValue: 1),
                            value: .init(rawValue: 2)
                        ),
                        .dictionaryProject(
                            result: .init(rawValue: 5),
                            dictionary: .init(rawValue: 4),
                            projection: .keys
                        ),
                        .dictionaryProject(
                            result: .init(rawValue: 6),
                            dictionary: .init(rawValue: 4),
                            projection: .values
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes).module

        #expect(decoded == module)
        #expect(try Bytecode.Encoder.encode(decoded) == bytes)
    }

    @Test("Text representation primitives share the current HLBC 1.0 wire format")
    func textRepresentationRoundTrip() throws {
        let strings = Bytecode.ValueType.array(.string)
        let resultType = Bytecode.ValueType.tuple([.string, .string])
        var module = try makeAddModule()
        module.capabilities.formUnion([.collectionsV1, .stringsV1])
        module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "textRepresentation",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: resultType,
            registerTypes: [
                .string, strings, .string, strings, .string, .string,
                resultType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    instructions: [
                        .stringCharacters(
                            result: .init(rawValue: 3),
                            string: .init(rawValue: 0)
                        ),
                        .stringJoin(
                            result: .init(rawValue: 4),
                            elements: .init(rawValue: 3),
                            separator: nil,
                            elementKind: .character
                        ),
                        .stringJoin(
                            result: .init(rawValue: 5),
                            elements: .init(rawValue: 1),
                            separator: .init(rawValue: 2),
                            elementKind: .string
                        ),
                        .makeTuple(
                            result: .init(rawValue: 6),
                            elements: [
                                .init(rawValue: 4), .init(rawValue: 5),
                            ]
                        ),
                        .returnValue(.init(rawValue: 6)),
                    ]
                ),
            ]
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes).module
        let disassembly = Bytecode.Disassembler.disassemble(decoded)

        #expect(decoded == module)
        #expect(try Bytecode.Encoder.encode(decoded) == bytes)
        #expect(disassembly.contains("string_characters"))
        #expect(disassembly.contains("string_join.character"))
        #expect(disassembly.contains("string_join.string"))
    }

    @Test("Scalar text primitives share the current HLBC 1.0 wire format")
    func scalarTextRoundTrip() throws {
        let optionalInteger = Bytecode.ValueType.optional(.int64)
        let resultType = Bytecode.ValueType.tuple([
            optionalInteger, .string,
        ])
        var module = try makeAddModule()
        module.capabilities.insert(.stringsV1)
        module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "scalarText",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
                .init(rawValue: 2), .init(rawValue: 3),
            ],
            resultType: resultType,
            registerTypes: [
                .string, .int64, .int64, .bool,
                optionalInteger, .string, resultType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                        .init(rawValue: 2), .init(rawValue: 3),
                    ],
                    instructions: [
                        .scalarFromString(
                            result: .init(rawValue: 4),
                            string: .init(rawValue: 0),
                            radix: .init(rawValue: 2)
                        ),
                        .integerToString(
                            result: .init(rawValue: 5),
                            value: .init(rawValue: 1),
                            radix: .init(rawValue: 2),
                            uppercase: .init(rawValue: 3)
                        ),
                        .makeTuple(
                            result: .init(rawValue: 6),
                            elements: [
                                .init(rawValue: 4), .init(rawValue: 5),
                            ]
                        ),
                        .returnValue(.init(rawValue: 6)),
                    ]
                ),
            ]
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes).module
        let disassembly = Bytecode.Disassembler.disassemble(decoded)

        #expect(decoded == module)
        #expect(try Bytecode.Encoder.encode(decoded) == bytes)
        #expect(disassembly.contains("scalar_from_string"))
        #expect(disassembly.contains("integer_to_string"))
    }

    @Test("Encoding is deterministic")
    func deterministicEncoding() throws {
        let module = try makeAddModule()
        #expect(try Bytecode.Encoder.encode(module) == Bytecode.Encoder.encode(module))
    }

    @Test("Only the current HLBC format is accepted")
    func formatVersionIsExact() throws {
        var bytes = try Bytecode.Encoder.encode(makeAddModule())
        bytes[10] = 1

        #expect(
            throws: Bytecode.CodecError.unsupportedFormat(major: 1, minor: 1)
        ) {
            try Bytecode.Decoder.decode(bytes)
        }

        var incompatible = try makeAddModule()
        incompatible.compatibility.bytecode = .init(1, 1, 0)
        #expect(
            throws: Bytecode.CodecError.invalidHeader(
                "HLBC format 1.0 requires bytecode compatibility 1.0.0, not 1.1.0"
            )
        ) {
            try Bytecode.Encoder.encode(incompatible)
        }
    }

    @Test("HLBC 1.0 canonically carries module-local nominal definitions")
    func localNominalWireFormat() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Mode")
        let auxiliaryKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Auxiliary")
        var module = try makeAddModule()
        module.capabilities.insert(.localNominalsV1)
        module.localTypes = [
            .init(
                key: key,
                kind: .enumeration(
                    cases: [
                        .init(name: "value", payloadType: .int64),
                        .init(name: "none"),
                    ]
                )
            ),
            .init(
                key: auxiliaryKey,
                kind: .structure(fields: [.init(name: "flag", type: .bool)])
            ),
        ]
        module.functions[0].registerTypes.append(.local(key))
        module.functions[0].blocks[0].instructions.insert(
            .makeEnum(
                result: .init(rawValue: 5),
                caseIndex: 0,
                payload: .init(rawValue: 0)
            ),
            at: 0
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        var canonicalModule = module
        canonicalModule.localTypes.sort { $0.key < $1.key }
        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == canonicalModule)
        #expect(try Bytecode.Encoder.encode(module) == Bytecode.Encoder.encode(canonicalModule))
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries local classes and bounded host descriptors")
    func localClassWireFormat() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Controller")
        let superclass = Core.TypeID.derive(
            namespace: .derive(
                bundleID: "dev.helix.fixture",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "UIKit.UIViewController"
        )
        var module = try makeAddModule()
        module.capabilities.formUnion([
            .localNominalsV1,
            .addressValuesV1,
            .localClassesV1,
            .hostedObjectiveCClassesV1,
        ])
        module.localTypes = [
            .init(
                key: key,
                kind: .class(
                    fields: [
                        .init(name: "count", type: .int64),
                        .init(name: "next", type: .optional(.local(key))),
                    ],
                    hostedSuperclass: .init(typeID: superclass),
                    hostedMethods: [
                        .init(
                            selector: "viewDidLoad",
                            functionID: .init(rawValue: 0),
                            abi: .voidNoArguments
                        ),
                    ]
                )
            ),
        ]
        module.functions[0].registerTypes.append(contentsOf: [
            .local(key),
            .address(.int64),
            .native(superclass),
        ])
        module.functions[0].blocks[0].instructions.insert(contentsOf: [
            .allocateObject(result: .init(rawValue: 5)),
            .projectObjectAddress(
                result: .init(rawValue: 6),
                object: .init(rawValue: 5),
                fieldIndex: 0
            ),
            .projectHostedObject(
                result: .init(rawValue: 7),
                object: .init(rawValue: 5)
            ),
            .hostedSuperApply(
                object: .init(rawValue: 5),
                methodIndex: 0,
                arguments: []
            ),
        ], at: 0)

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries address operations and call conventions")
    func addressWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.formUnion([.addressValuesV1, .borrowCallsV1])
        module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "mutateLocal",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.borrowed],
            resultType: .int64,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
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
                        .loadAddress(
                            result: .init(rawValue: 3),
                            address: .init(rawValue: 2),
                            mode: .copy
                        ),
                        .storeAddress(
                            address: .init(rawValue: 2),
                            source: .init(rawValue: 3),
                            mode: .assign
                        ),
                        .endAccess(.init(rawValue: 2)),
                        .destroyStack(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries bounded Array algorithm states")
    func arrayAlgorithmStateWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.insert(.collectionsV1)
        module.functions[0].registerTypes.append(contentsOf: [
            .array(.int64),
            .arrayState(kind: .stableSort, element: .int64),
            .optional(.tuple([.int64, .int64])),
            .bool,
            .array(.int64),
            .array(.int64),
            .arrayState(kind: .split, element: .int64),
            .int64,
            .bool,
            .optional(.int64),
            .array(.array(.int64)),
            .array(.array(.int64)),
            .arrayState(kind: .mutation, element: .int64),
            .int64,
            .array(.int64),
            .array(.int64),
        ])
        module.functions[0].blocks[0].instructions.insert(contentsOf: [
            .makeArray(
                result: .init(rawValue: 5),
                elements: [.init(rawValue: 0)]
            ),
            .makeArraySortState(
                result: .init(rawValue: 6),
                array: .init(rawValue: 5)
            ),
            .arraySortNextComparison(
                result: .init(rawValue: 7),
                state: .init(rawValue: 6)
            ),
            .constantBool(result: .init(rawValue: 8), value: true),
            .arraySortAcceptComparison(
                state: .init(rawValue: 6),
                rightPrecedesLeft: .init(rawValue: 8)
            ),
            .finishArraySort(
                result: .init(rawValue: 9),
                state: .init(rawValue: 6)
            ),
            .arraySorted(
                result: .init(rawValue: 10),
                array: .init(rawValue: 5)
            ),
            .constantInteger(result: .init(rawValue: 12), bitPattern: 1),
            .constantBool(result: .init(rawValue: 13), value: true),
            .makeArraySplitState(
                result: .init(rawValue: 11),
                array: .init(rawValue: 5),
                maxSplits: .init(rawValue: 12),
                omittingEmptySubsequences: .init(rawValue: 13)
            ),
            .arraySplitNextElement(
                result: .init(rawValue: 14),
                state: .init(rawValue: 11)
            ),
            .arraySplitAcceptElement(
                state: .init(rawValue: 11),
                isSeparator: .init(rawValue: 13)
            ),
            .finishArraySplit(
                result: .init(rawValue: 15),
                state: .init(rawValue: 11)
            ),
            .arraySplitSeparator(
                result: .init(rawValue: 16),
                array: .init(rawValue: 5),
                separator: .init(rawValue: 0),
                maxSplits: .init(rawValue: 12),
                omittingEmptySubsequences: .init(rawValue: 13)
            ),
            .makeArrayMutationState(
                result: .init(rawValue: 17),
                array: .init(rawValue: 5)
            ),
            .arrayMutationGet(
                result: .init(rawValue: 18),
                state: .init(rawValue: 17),
                index: .init(rawValue: 0)
            ),
            .arrayMutationSwap(
                state: .init(rawValue: 17),
                lhsIndex: .init(rawValue: 0),
                rhsIndex: .init(rawValue: 0)
            ),
            .finishArrayMutation(
                result: .init(rawValue: 19),
                state: .init(rawValue: 17)
            ),
            .collectionMaterialize(
                result: .init(rawValue: 20),
                collection: .init(rawValue: 5)
            ),
        ], at: 0)

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        let text = Bytecode.Disassembler.disassemble(decoded.module)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
        #expect(text.contains("make_array_sort_state"))
        #expect(text.contains("array_sort_next_comparison"))
        #expect(text.contains("finish_array_sort"))
        #expect(text.contains("array_sorted"))
        #expect(text.contains("make_array_split_state"))
        #expect(text.contains("array_split_next_element"))
        #expect(text.contains("array_split_accept_element"))
        #expect(text.contains("finish_array_split"))
        #expect(text.contains("array_split %5"))
        #expect(text.contains("make_array_mutation_state"))
        #expect(text.contains("array_mutation_get"))
        #expect(text.contains("array_mutation_swap"))
        #expect(text.contains("finish_array_mutation"))
        #expect(text.contains("collection_materialize"))
    }

    @Test("HLBC 1.0 canonically carries Dictionary accumulation state")
    func dictionaryAccumulationStateWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.formUnion([.collectionsV1, .stringsV1])
        module.functions[0].registerTypes.append(contentsOf: [
            .dictionaryState(key: .string, value: .int64),
            .string,
            .optional(.int64),
            .dictionary(key: .string, value: .int64),
            .dictionaryState(key: .string, value: .array(.int64)),
            .dictionary(key: .string, value: .array(.int64)),
        ])
        module.functions[0].blocks[0].instructions.insert(contentsOf: [
            .makeDictionaryBuilder(
                result: .init(rawValue: 5),
                initialValue: nil
            ),
            .constantString(result: .init(rawValue: 6), value: "key"),
            .dictionaryBuilderGet(
                result: .init(rawValue: 7),
                builder: .init(rawValue: 5),
                key: .init(rawValue: 6)
            ),
            .dictionaryBuilderSet(
                builder: .init(rawValue: 5),
                key: .init(rawValue: 6),
                value: .init(rawValue: 0)
            ),
            .finishDictionaryBuilder(
                result: .init(rawValue: 8),
                builder: .init(rawValue: 5)
            ),
            .makeDictionaryBuilder(
                result: .init(rawValue: 9),
                initialValue: nil
            ),
            .dictionaryBuilderAppendArrayElement(
                builder: .init(rawValue: 9),
                key: .init(rawValue: 6),
                element: .init(rawValue: 0)
            ),
            .finishDictionaryBuilder(
                result: .init(rawValue: 10),
                builder: .init(rawValue: 9)
            ),
        ], at: 0)

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        let text = Bytecode.Disassembler.disassemble(decoded.module)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
        #expect(text.contains("make_dictionary_builder"))
        #expect(text.contains("dictionary_builder_get"))
        #expect(text.contains("dictionary_builder_set"))
        #expect(text.contains("dictionary_builder_append_array_element"))
        #expect(text.contains("finish_dictionary_builder"))
    }

    @Test("HLBC 1.0 canonically carries closure values and function kinds")
    func closureWireFormat() throws {
        var module = try makeAddModule()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        module.capabilities.formUnion([
            .closureValuesV1,
            .compilerSpecializationsV1,
        ])
        module.functions[0].registerTypes.append(.closure(signature))
        module.functions[0].registerTypes.append(.int64)
        module.functions[0].blocks[0].instructions.insert(
            .makeClosure(
                result: .init(rawValue: 5),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            at: 0
        )
        module.functions[0].blocks[0].instructions.insert(
            .closureApply(
                result: .init(rawValue: 6),
                closure: .init(rawValue: 5),
                arguments: [.init(rawValue: 1)]
            ),
            at: 1
        )
        module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "closure body",
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
        module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "genericIdentity<Int>",
                kind: .concreteSpecialization,
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
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("Closure descriptions preserve ownership and expose malformed ABI")
    func closureSignatureDescription() {
        var signature = Bytecode.ClosureSignature(
            parameters: [.int64, .string, .bool],
            parameterConventions: [.owned, .borrowed, .inout],
            result: .void
        )
        #expect(
            signature.description
                == "(Int64, @borrowed String, @inout Bool) -> Void"
        )

        signature.parameterConventions.removeLast()
        #expect(
            signature.description
                == "<invalid closure signature: 3 parameters, 2 conventions>"
        )
    }

    @Test("HLBC 1.0 canonically carries the non-suspending async entry ABI")
    func asyncLeafWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.insert(.asyncLeafEntriesV1)
        module.functions[0].effects.isAsync = true

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("Any post-encode mutation invalidates the image hash")
    func corruptionIsRejected() throws {
        var encoded = try Bytecode.Encoder.encode(makeAddModule())
        encoded[encoded.count - 1] ^= 0x01

        #expect(throws: Bytecode.CodecError.imageHashMismatch) {
            try Bytecode.Decoder.decode(encoded)
        }
    }

    @Test("The decoder deterministically rejects a seeded malformed corpus")
    func malformedCorpusIsRejected() throws {
        let canonical = try Bytecode.Encoder.encode(makeAddModule())
        var generator = Generator(seed: 0x484c_4243_4655_5a5a)

        for caseID in 0..<1_000 {
            let candidate = mutate(canonical, caseID: caseID, generator: &generator)
            let first = decodeOutcome(candidate)
            let second = decodeOutcome(candidate)
            #expect(first == second, Comment(rawValue: "non-deterministic case \(caseID)"))
            #expect(!first.wasAccepted, Comment(rawValue: "accepted malformed case \(caseID)"))
        }
    }

    @Test("A hash-consistent but non-canonical JSON section is rejected")
    func nonCanonicalSectionIsRejected() throws {
        let encoded = try Bytecode.Encoder.encode(makeAddModule())
        let rebuilt = try rebuild(encoded) { sections in
            sections[.metadata]?.append(0x20)
        }

        #expect(throws: Bytecode.CodecError.invalidHeader("v1 image is not canonically encoded")) {
            try Bytecode.Decoder.decode(rebuilt)
        }
    }

    @Test("Recognized but undeclared v1 sections are rejected")
    func extraV1SectionIsRejected() throws {
        let encoded = try Bytecode.Encoder.encode(makeAddModule())
        let rebuilt = try rebuild(encoded) { sections in
            sections[.strings] = Data("[]".utf8)
        }

        #expect(throws: Bytecode.CodecError.self) {
            try Bytecode.Decoder.decode(rebuilt)
        }
    }

    @Test("Canonical scalar literals preserve every raw payload bit")
    func specialScalarBitPatternsRoundTrip() throws {
        var module = try makeAddModule()
        module.functions[0].registerTypes.append(contentsOf: [
            .float(bitWidth: 32),
            .float(bitWidth: 64),
            .float(bitWidth: 64),
            .integer(bitWidth: 64, signed: false),
        ])
        let expected: [UInt64] = [
            0x7FA1_2345,
            Double.infinity.bitPattern,
            (-0.0 as Double).bitPattern,
        ]
        module.functions[0].blocks[0].instructions.insert(contentsOf: [
            .constantFloat(result: .init(rawValue: 5), bitPattern: expected[0]),
            .constantFloat(result: .init(rawValue: 6), bitPattern: expected[1]),
            .constantFloat(result: .init(rawValue: 7), bitPattern: expected[2]),
            .constantInteger(result: .init(rawValue: 8), bitPattern: .max),
        ], at: 0)

        let decoded = try Bytecode.Decoder.decode(Bytecode.Encoder.encode(module)).module
        let constants = decoded.functions
            .flatMap(\.blocks)
            .flatMap(\.instructions)
            .compactMap { instruction -> UInt64? in
                guard case let .constantFloat(_, bitPattern) = instruction else {
                    return nil
                }
                return bitPattern
            }
        #expect(constants == expected)
        let integers = decoded.functions
            .flatMap(\.blocks)
            .flatMap(\.instructions)
            .compactMap { instruction -> UInt64? in
                guard case let .constantInteger(_, bitPattern) = instruction else {
                    return nil
                }
                return bitPattern
            }
        #expect(integers.contains(UInt64.max))
    }

    @Test("Disassembly retains blocks and checked operations")
    func disassembly() throws {
        var module = try makeAddModule()
        module.name = "Fixture\"\nPatch"
        module.functions[0].stackSlotTypes = [.int64]
        module.functions[0].effects = .init(mayThrow: true)
        let text = Bytecode.Disassembler.disassemble(module)
        #expect(text.contains("checked_add"))
        #expect(text.contains("cond_br"))
        #expect(text.contains("func @0"))
        #expect(text.contains("throws"))
        #expect(text.contains("stack $0: Int64"))
        #expect(text.contains(#"hlbc_module "Fixture\"\nPatch""#))
    }

    private func makeAddModule() throws -> Bytecode.Module {
        let shellHash = Core.Digest.sha256("fixture-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.fixture",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "transform",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 27),
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .add,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 3),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: [.init(rawValue: 2)]
                        ),
                    ]
                ),
                .init(id: .init(rawValue: 1), instructions: [.trap(.integerOverflow)]),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [.returnValue(.init(rawValue: 4))]
                ),
            ]
        )
        return Bytecode.Module(
            name: "FixturePatch",
            shellInterfaceHash: shellHash,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "swift-fixture"
            ),
            functions: [function],
            entries: [.init(entryIndex: .init(rawValue: 0), functionKey: key, functionID: function.id)]
        )
    }

    private enum DecodeOutcome: Equatable {
        case accepted(Core.Digest)
        case rejected(String)

        var wasAccepted: Bool {
            if case .accepted = self { return true }
            return false
        }
    }

    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            precondition(seed != 0)
            state = seed
        }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func index(upperBound: Int) -> Int {
            precondition(upperBound > 0)
            return Int(next() % UInt64(upperBound))
        }

        mutating func byte() -> UInt8 {
            UInt8(truncatingIfNeeded: next())
        }
    }

    private func decodeOutcome(_ bytes: Data) -> DecodeOutcome {
        do {
            let decoded = try Bytecode.Decoder.decode(
                bytes,
                limits: .init(
                    maximumFileBytes: 1 * 1_024 * 1_024,
                    maximumSectionCount: 16,
                    maximumSectionBytes: 512 * 1_024
                )
            )
            return .accepted(decoded.header.imageHash)
        } catch {
            return .rejected(
                "\(String(reflecting: type(of: error))):\(String(describing: error))"
            )
        }
    }

    private func mutate(
        _ canonical: Data,
        caseID: Int,
        generator: inout Generator
    ) -> Data {
        switch caseID % 5 {
        case 0:
            var result = canonical
            let index = generator.index(upperBound: result.count)
            result[index] ^= UInt8(1 << generator.index(upperBound: 8))
            return result
        case 1:
            return Data(canonical.prefix(generator.index(upperBound: canonical.count)))
        case 2:
            var result = canonical
            for _ in 0..<(1 + generator.index(upperBound: 16)) {
                result.append(generator.byte())
            }
            return result
        case 3:
            var result = canonical
            let start = generator.index(upperBound: result.count)
            let count = min(1 + generator.index(upperBound: 16), result.count - start)
            for index in start..<(start + count) {
                result[index] ^= generator.byte() | 1
            }
            return result
        default:
            let count = generator.index(upperBound: 2_048)
            return Data((0..<count).map { _ in generator.byte() })
        }
    }

    private func rebuild(
        _ encoded: Data,
        mutate: (inout [Bytecode.SectionKind: Data]) -> Void
    ) throws -> Data {
        let decoded = try Bytecode.Decoder.decode(encoded)
        var sections = decoded.sections
        mutate(&sections)
        let sorted = sections.sorted { $0.key < $1.key }
        let payloadStart = Bytecode.Header.byteCount + sorted.count * Bytecode.SectionEntry.byteCount
        let zeroHash = try Core.Digest(bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount))

        var offset = payloadStart
        var entries: [Bytecode.SectionEntry] = []
        for (kind, payload) in sorted {
            entries.append(
                .init(
                    kind: kind,
                    flags: 0,
                    offset: UInt64(offset),
                    compressedSize: UInt64(payload.count),
                    uncompressedSize: UInt64(payload.count),
                    sha256: .sha256(payload)
                )
            )
            offset += payload.count
        }

        var writer = Bytecode.BinaryWriter()
        writer.append(bytes: Bytecode.Format.magic)
        writer.append(decoded.header.formatMajor)
        writer.append(decoded.header.formatMinor)
        writer.append(decoded.header.minimumRuntimeMajor)
        writer.append(decoded.header.flags)
        writer.append(decoded.header.shellInterfaceHash.data)
        writer.append(zeroHash.data)
        writer.append(UInt32(entries.count))
        writer.append(UInt64(Bytecode.Header.byteCount))
        for entry in entries {
            writer.append(entry.kind.rawValue)
            writer.append(entry.flags)
            writer.append(entry.offset)
            writer.append(entry.compressedSize)
            writer.append(entry.uncompressedSize)
            writer.append(entry.sha256.data)
        }
        for (_, payload) in sorted { writer.append(payload) }
        let imageHash = Core.Digest.sha256(writer.data)
        writer.data.replaceSubrange(Bytecode.Header.imageHashRange, with: imageHash.data)
        return writer.data
    }
}
}
