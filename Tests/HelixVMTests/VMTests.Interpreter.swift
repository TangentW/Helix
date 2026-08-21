import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

private let vmPureImportContract = Core.NativeImportContract.bounded(
    kind: .globalFunction,
    domain: .application,
    access: .pure,
    maximumDurationMicroseconds: 1_000,
    allowsMainThread: true
)

private let vmWriteImportContract = Core.NativeImportContract.bounded(
    kind: .serviceMethod,
    domain: .application,
    access: .write,
    maximumDurationMicroseconds: 1_000,
    allowsMainThread: true
)

enum VMTests {}

extension VMTests {
@Suite("HLVM typed-register interpreter")
struct Interpreter {
    @Test("Local enums preserve associated values across a typed Error edge")
    func executesTypedLocalErrorCatch() throws {
        let errorKey = Bytecode.LocalTypeKey(rawValue: "Fixture.DetailedError")
        let localTypes = [
            Bytecode.LocalTypeDefinition(
                key: errorKey,
                kind: .enumeration(
                    cases: [
                        .init(name: "invalid", payloadType: .int64),
                        .init(name: "unavailable"),
                    ]
                ),
                conformsToError: true
            ),
        ]
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "catchTypedError",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64,
                .int64,
                .error,
                .optional(.local(errorKey)),
                .local(errorKey),
                .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .tryApply(
                            function: .init(rawValue: 1),
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
                        .castError(
                            result: .init(rawValue: 3),
                            error: .init(rawValue: 2),
                            expectedType: errorKey
                        ),
                        .switchOptional(
                            optional: .init(rawValue: 3),
                            someTarget: .init(rawValue: 3),
                            noneTarget: .init(rawValue: 4)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 3),
                    parameters: [.init(rawValue: 4)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
                .init(
                    id: .init(rawValue: 4),
                    instructions: [
                        .constantInteger(result: .init(rawValue: 5), bitPattern: UInt64.max),
                        .returnValue(.init(rawValue: 5)),
                    ]
                ),
            ]
        )
        let throwing = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "throwTypedError",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .local(errorKey), .error],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeEnum(
                            result: .init(rawValue: 1),
                            caseIndex: 0,
                            payload: .init(rawValue: 0)
                        ),
                        .makeError(
                            result: .init(rawValue: 2),
                            payload: .init(rawValue: 1)
                        ),
                        .throwError(.init(rawValue: 2)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )
        let image = try makeVerified(
            function: root,
            capabilities: [.baselineV1, .localNominalsV1, .structuredErrorsV1],
            localTypes: localTypes,
            additionalFunctions: [throwing]
        )
        let input = VM.Value.integer(
            try VM.Integer(signed: 42, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input]
            ) == .returned(input)
        )
    }

    @Test("Checked arithmetic and CFG branching produce the patched result")
    func executesCheckedAdd() throws {
        let fixture = try makeVerified(function: addFunction())
        let input = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)

        let result = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: fixture,
            arguments: [.integer(input)]
        )

        #expect(result == .returned(.integer(try VM.Integer(signed: 30, bitWidth: 64, isSigned: true))))
    }

    @Test("The overflow edge traps instead of returning wrapped data")
    func trapsOnOverflowEdge() throws {
        let fixture = try makeVerified(function: addFunction())
        let input = try VM.Integer(signed: Int64.max, bitWidth: 64, isSigned: true)

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture,
                arguments: [.integer(input)]
            ) == .trapped(.integerOverflow)
        )
    }

    @Test("A loop cannot mint new fuel")
    func fuelStopsInfiniteLoop() throws {
        let limits = Core.ResourceLimits(
            instructionFuelPerEntry: 5,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "loop",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .branch(
                            target: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)]
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 1)],
                    instructions: [
                        .branch(
                            target: .init(rawValue: 1),
                            arguments: [.init(rawValue: 1)]
                        ),
                    ]
                ),
            ]
        )
        let fixture = try makeVerified(function: function, limits: limits)
        let input = try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)

        #expect(
            VM.Interpreter().invoke(entry: .init(rawValue: 0), image: fixture, arguments: [.integer(input)])
                == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Linear collection work consumes proportional instruction fuel")
    func collectionWorkConsumesProportionalFuel() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let elementRegisters = (0..<8).map { Bytecode.Register(rawValue: UInt32($0)) }
        let resultRegister = Bytecode.Register(rawValue: 8)
        var instructions = elementRegisters.enumerated().map { index, register in
            Bytecode.Instruction.constantInteger(
                result: register,
                bitPattern: UInt64(index)
            )
        }
        instructions.append(
            .makeArray(result: resultRegister, elements: elementRegisters)
        )
        instructions.append(.returnValue(resultRegister))
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "linearFuel",
            parameterRegisters: [],
            resultType: arrayType,
            registerTypes: Array(repeating: .int64, count: 8) + [arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: instructions
                ),
            ]
        )

        func image(fuel: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    instructionFuelPerEntry: fuel,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(parameters: [], result: "Swift.Array<Swift.Int>"),
                parameterTypes: [],
                resultType: arrayType
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 10),
                arguments: []
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 18),
                arguments: []
            ) == .returned(
                .array(
                    try (0..<8).map {
                        .integer(
                            try VM.Integer(
                                signed: Int64($0),
                                bitWidth: 64,
                                isSigned: true
                            )
                        )
                    },
                    elementType: .int64
                )
            )
        )
    }

    @Test("HLBC 1.0 numeric conversions preserve raw bits and IEEE rounding")
    func numericConversionSemantics() throws {
        func invoke(
            operation: Bytecode.IntegerConversionOperation,
            sourceType: Bytecode.ValueType,
            resultType: Bytecode.ValueType,
            value: VM.Integer
        ) throws -> VM.ExecutionResult {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "integerConversion",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: resultType,
                registerTypes: [sourceType, resultType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .integerConvert(
                                result: .init(rawValue: 1),
                                operation: operation,
                                value: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
            return VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try makeVerified(
                    function: function,
                    signature: .init(
                        parameters: [sourceType.description],
                        result: resultType.description
                    ),
                    parameterTypes: [sourceType],
                    resultType: resultType
                ),
                arguments: [.integer(value)]
            )
        }

        #expect(
            try invoke(
                operation: .truncate,
                sourceType: .int64,
                resultType: .integer(bitWidth: 8, signed: true),
                value: .init(signed: -129, bitWidth: 64, isSigned: true)
            ) == .returned(.integer(try .init(signed: 127, bitWidth: 8, isSigned: true)))
        )
        #expect(
            try invoke(
                operation: .signExtend,
                sourceType: .integer(bitWidth: 8, signed: true),
                resultType: .int64,
                value: .init(signed: -1, bitWidth: 8, isSigned: true)
            ) == .returned(.integer(try .init(signed: -1, bitWidth: 64, isSigned: true)))
        )
        #expect(
            try invoke(
                operation: .zeroExtend,
                sourceType: .integer(bitWidth: 8, signed: false),
                resultType: .integer(bitWidth: 64, signed: false),
                value: .init(rawBits: 255, bitWidth: 8, isSigned: false)
            ) == .returned(.integer(try .init(rawBits: 255, bitWidth: 64, isSigned: false)))
        )
        #expect(
            try invoke(
                operation: .reinterpret,
                sourceType: .integer(bitWidth: 8, signed: true),
                resultType: .integer(bitWidth: 8, signed: false),
                value: .init(signed: -1, bitWidth: 8, isSigned: true)
            ) == .returned(.integer(try .init(rawBits: 255, bitWidth: 8, isSigned: false)))
        )

        func floating(
            operation: Bytecode.FloatingConversionOperation,
            sourceType: Bytecode.ValueType,
            resultType: Bytecode.ValueType,
            argument: VM.Value
        ) throws -> VM.ExecutionResult {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "floatingConversion",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: resultType,
                registerTypes: [sourceType, resultType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .floatingConvert(
                                result: .init(rawValue: 1),
                                operation: operation,
                                value: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
            return VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try makeVerified(
                    function: function,
                    signature: .init(
                        parameters: [sourceType.description],
                        result: resultType.description
                    ),
                    parameterTypes: [sourceType],
                    resultType: resultType
                ),
                arguments: [argument]
            )
        }

        let unrepresentable = 16_777_217.0
        #expect(
            try floating(
                operation: .truncate,
                sourceType: .float(bitWidth: 64),
                resultType: .float(bitWidth: 32),
                argument: .float64(unrepresentable)
            ) == .returned(.float32(Float(unrepresentable)))
        )
        #expect(
            try floating(
                operation: .unsignedIntegerToFloat,
                sourceType: .integer(bitWidth: 64, signed: false),
                resultType: .float(bitWidth: 64),
                argument: .integer(
                    try .init(rawBits: UInt64.max, bitWidth: 64, isSigned: false)
                )
            ) == .returned(.float64(Double(UInt64.max)))
        )
    }

    @Test("String predicates are Unicode-correct and substring work is fuel-bounded")
    func stringPredicateSemanticsAndFuel() throws {
        func image(
            operation: Bytecode.StringPredicateOperation,
            fuel: UInt64 = Core.ResourceLimits().instructionFuelPerEntry
        ) throws -> Verification.Image {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "stringPredicate",
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .bool,
                registerTypes: [.string, .string, .bool],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [
                            .stringPredicate(
                                result: .init(rawValue: 2),
                                operation: operation,
                                string: .init(rawValue: 0),
                                pattern: .init(rawValue: 1)
                            ),
                            .destroyValue(.init(rawValue: 0)),
                            .destroyValue(.init(rawValue: 1)),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
            return try makeVerified(
                function: function,
                limits: .init(
                    instructionFuelPerEntry: fuel,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1],
                signature: .init(
                    parameters: ["Swift.String", "Swift.String"],
                    result: "Swift.Bool"
                ),
                parameterTypes: [.string, .string],
                resultType: .bool
            )
        }

        let value = "Cafe\u{301} · Helix🧬"
        for (operation, pattern, expected) in [
            (Bytecode.StringPredicateOperation.hasPrefix, "Café", value.hasPrefix("Café")),
            (.hasSuffix, "Helix🧬", value.hasSuffix("Helix🧬")),
            (.contains, "é · H", value.contains("é · H")),
            (.contains, "missing", value.contains("missing")),
        ] {
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: try image(operation: operation),
                    arguments: [.string(value), .string(pattern)]
                ) == .returned(.bool(expected))
            )
        }

        let haystack = String(repeating: "a", count: 1_024) + "z"
        let pattern = String(repeating: "a", count: 64) + "z"
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(operation: .contains, fuel: 1_000),
                arguments: [.string(haystack), .string(pattern)]
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Text representation primitives preserve graphemes and validate Character arrays")
    func textRepresentationSemantics() throws {
        let strings = Bytecode.ValueType.array(.string)
        let resultType = Bytecode.ValueType.tuple([.string, .string])
        let function = Bytecode.Function(
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
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1, .stringsV1],
            signature: .init(
                parameters: [
                    "Swift.String", "Swift.Array<Swift.String>",
                    "Swift.String",
                ],
                result: "(Swift.String, Swift.String)"
            ),
            parameterTypes: [.string, strings, .string],
            resultType: resultType
        )
        let value = "e\u{301}👨‍👩‍👧‍👦🇨🇳"
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .string(value),
                    .array(
                        [.string("alpha"), .string("β"), .string("🧬")],
                        elementType: .string
                    ),
                    .string("|"),
                ]
            ) == .returned(.tuple([
                .string(value), .string("alpha|β|🧬"),
            ]))
        )

        let invalidCharacterFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "joinCharacters",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .string,
            registerTypes: [strings, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .stringJoin(
                            result: .init(rawValue: 1),
                            elements: .init(rawValue: 0),
                            separator: nil,
                            elementKind: .character
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let invalidCharacterImage = try makeVerified(
            function: invalidCharacterFunction,
            capabilities: [.baselineV1, .collectionsV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.Array<Swift.String>"],
                result: "Swift.String"
            ),
            parameterTypes: [strings],
            resultType: .string
        )
        for malformed in ["", "not a Character"] {
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: invalidCharacterImage,
                    arguments: [
                        .array([.string(malformed)], elementType: .string),
                    ]
                ) == .trapped(.explicit(
                    "Character sequence contains a value that is not one extended grapheme cluster"
                ))
            )
        }
    }

    @Test("String Character materialization is fuel-bounded inside one instruction")
    func stringCharacterMaterializationConsumesFuel() throws {
        let resultType = Bytecode.ValueType.array(.string)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "stringCharacters",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: resultType,
            registerTypes: [.string, resultType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .stringCharacters(
                            result: .init(rawValue: 1),
                            string: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            limits: .init(
                instructionFuelPerEntry: 400,
                maxWallTimeMainThreadMilliseconds: 1_000
            ),
            capabilities: [.baselineV1, .collectionsV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.String"],
                result: "Swift.Array<Swift.String>"
            ),
            parameterTypes: [.string],
            resultType: resultType
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.string(String(repeating: "a", count: 4_096))]
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("String joining reserves its exact output before allocation")
    func stringJoiningConsumesHeapBudget() throws {
        let strings = Bytecode.ValueType.array(.string)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "stringJoin",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .string,
            registerTypes: [strings, .string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .stringJoin(
                            result: .init(rawValue: 2),
                            elements: .init(rawValue: 0),
                            separator: .init(rawValue: 1),
                            elementKind: .string
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let components = ["a", "β", "🧬"]
        let separator = "|"
        let joined = components.joined(separator: separator)
        let input = VM.Value.array(
            components.map(VM.Value.string),
            elementType: .string
        )
        let frameBytes = UInt64(
            function.registerTypes.count * MemoryLayout<VM.Value?>.stride
        )
        let aggregateBytes = UInt64((components.count + 1) * 16)
        let inputBytes = UInt64(
            components.reduce(0) { $0 + $1.utf8.count }
                + separator.utf8.count
        )
        let outputBytes = UInt64(joined.utf8.count)
        let exactBudget = frameBytes + aggregateBytes + inputBytes + outputBytes

        func image(
            maximumHeapBytes: UInt64,
            fuel: UInt64 = 1_000_000
        ) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    instructionFuelPerEntry: fuel,
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .collectionsV1, .stringsV1],
                signature: .init(
                    parameters: ["Swift.Array<Swift.String>", "Swift.String"],
                    result: "Swift.String"
                ),
                parameterTypes: [strings, .string],
                resultType: .string
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget - 1),
                arguments: [input, .string(separator)]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget),
                arguments: [input, .string(separator)]
            ) == .returned(.string(joined))
        )

        let emptyComponents = VM.Value.array(
            Array(repeating: .string(""), count: 128),
            elementType: .string
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: 100_000, fuel: 64),
                arguments: [emptyComponents, .string("")]
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Substring work arithmetic is total at Int limits")
    func substringWorkArithmeticDoesNotOverflow() throws {
        let budget = VM.InvocationBudget(
            limits: .init(
                instructionFuelPerEntry: UInt64.max,
                maxWallTimeBackgroundMilliseconds: UInt32.max
            ),
            isMainThread: false
        )
        try budget.consumeSubstringSearchWork(
            haystackByteCount: Int.max,
            patternByteCount: 0
        )
    }

    @Test("Array subscript update is value-semantic, bounds-checked, and fuel-bounded")
    func arrayUpdateSemanticsAndFuel() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "arrayUpdate",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: arrayType,
            registerTypes: [arrayType, .int64, .int64, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
                    ],
                    instructions: [
                        .arrayUpdate(
                            result: .init(rawValue: 3),
                            array: .init(rawValue: 0),
                            index: .init(rawValue: 1),
                            value: .init(rawValue: 2)
                        ),
                        .destroyValue(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        func image(fuel: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    instructionFuelPerEntry: fuel,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(
                    parameters: ["Swift.Array<Swift.Int>", "Swift.Int", "Swift.Int"],
                    result: "Swift.Array<Swift.Int>"
                ),
                parameterTypes: [arrayType, .int64, .int64],
                resultType: arrayType
            )
        }
        let elements = try (0..<32).map {
            VM.Value.integer(
                try .init(signed: Int64($0), bitWidth: 64, isSigned: true)
            )
        }
        let input = VM.Value.array(elements, elementType: .int64)
        let index = VM.Value.integer(
            try .init(signed: 17, bitWidth: 64, isSigned: true)
        )
        let replacement = VM.Value.integer(
            try .init(signed: 999, bitWidth: 64, isSigned: true)
        )
        var expected = elements
        expected[17] = replacement
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 10_000),
                arguments: [input, index, replacement]
            ) == .returned(.array(expected, elementType: .int64))
        )
        #expect(input == .array(elements, elementType: .int64))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 100),
                arguments: [input, index, replacement]
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 10_000),
                arguments: [
                    input,
                    .integer(try .init(signed: 32, bitWidth: 64, isSigned: true)),
                    replacement,
                ]
            ) == .trapped(.arrayIndexOutOfBounds(index: 32, count: 32))
        )
    }

    @Test("Aggregate call shape validation consumes proportional fuel")
    func aggregateCallShapeConsumesFuel() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "callArrayIdentity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: arrayType,
            registerTypes: [arrayType, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .apply(
                            result: .init(rawValue: 1),
                            function: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let identity = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "arrayIdentity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: arrayType,
            registerTypes: [arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        let input = VM.Value.array(
            try (0..<4).map {
                .integer(
                    try VM.Integer(
                        signed: Int64($0),
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            },
            elementType: .int64
        )

        func image(fuel: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: root,
                limits: .init(
                    instructionFuelPerEntry: fuel,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(
                    parameters: ["Swift.Array<Swift.Int>"],
                    result: "Swift.Array<Swift.Int>"
                ),
                parameterTypes: [arrayType],
                resultType: arrayType,
                additionalFunctions: [identity]
            )
        }

        // Five units each cover the root boundary, the call argument shape,
        // and the call result shape; three more cover apply and both returns.
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 17),
                arguments: [input]
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(fuel: 18),
                arguments: [input]
            ) == .returned(input)
        )
    }

    @Test("The deadline is rechecked after an instruction body")
    func deadlineIsCheckedAfterInstruction() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "deadline",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [.returnValue(nil)]
                ),
            ]
        )
        let limits = Core.ResourceLimits(
            maxWallTimeMainThreadMilliseconds: 1
        )
        let image = try makeVerified(
            function: function,
            limits: limits,
            signature: .init(parameters: [], result: "Swift.Void"),
            parameterTypes: [],
            resultType: .void
        )
        let clock = SequenceClock(values: [0, 0, 2_000_000])
        let budget = VM.InvocationBudget(
            limits: limits,
            isMainThread: true,
            nowNanoseconds: { clock.now() }
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [],
                budget: budget
            ) == .trapped(.wallTimeExceeded)
        )
    }

    @Test("Recursive calls use the explicit frame stack and share the root depth budget")
    func recursionSharesDepthBudget() throws {
        let limits = Core.ResourceLimits(
            instructionFuelPerEntry: 1_000,
            maxCallDepth: 64,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "recursive",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .apply(result: .init(rawValue: 1), function: .init(rawValue: 0), arguments: [.init(rawValue: 0)]),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let fixture = try makeVerified(function: function, limits: limits)
        let input = try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)

        #expect(
            VM.Interpreter().invoke(entry: .init(rawValue: 0), image: fixture, arguments: [.integer(input)])
                == .trapped(.callDepthExceeded)
        )
    }

    @Test("MainActor entries fail closed when invoked off the main thread")
    func mainActorEntryRequiresMainThread() async throws {
        let limits = Core.ResourceLimits(maxWallTimeMainThreadMilliseconds: 1_000)
        let capabilities: Set<Core.Capability> = [.baselineV1, .mainActorSyncV1]
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "mainActorIdentity",
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
            effects: .init(requiresMainActor: true)
        )
        let image = try makeVerified(
            function: function,
            limits: limits,
            capabilities: capabilities,
            policy: .init(
                acceptedCapabilities: capabilities,
                resourceCeiling: limits,
                allowMainActorSynchronousEntries: true
            )
        )
        let input = VM.Value.integer(
            try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )

        let result = await Task.detached {
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input]
            )
        }.value
        #expect(result == .trapped(.mainActorViolation))
    }

    @Test("Native calls use a typed catalog and mark committed side effects")
    func invokesNativeCatalog() throws {
        let fixture = try makeNativeIncrementImage()
        let catalog = try VM.NativeCatalog([IncrementInvoker(key: fixture.shell.imports[.init(rawValue: 0)]!.key)])
        let budget = VM.InvocationBudget(limits: fixture.effectiveResourceLimits)
        let input = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)

        let result = VM.Interpreter(nativeCatalog: catalog).invoke(
            entry: .init(rawValue: 0),
            image: fixture,
            arguments: [.integer(input)],
            budget: budget
        )
        #expect(result == .returned(.integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true))))
        #expect(budget.sideEffectsCommitted)

        let rejectedBudget = VM.InvocationBudget(
            limits: .init(
                instructionFuelPerEntry: 2,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: .init(rawValue: 0),
                image: fixture,
                arguments: [.integer(input)],
                budget: rejectedBudget
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(!rejectedBudget.sideEffectsCommitted)
    }

    @Test("Native catalog effects must exactly match the frozen Shell descriptor")
    func rejectsMisdeclaredNativeEffectsBeforeInvocation() throws {
        let fixture = try makeNativeIncrementImage()
        let catalog = try VM.NativeCatalog([
            MisdeclaredIncrementInvoker(key: fixture.shell.imports[.init(rawValue: 0)]!.key),
        ])
        let budget = VM.InvocationBudget(limits: fixture.effectiveResourceLimits)
        let input = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)

        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: .init(rawValue: 0),
                image: fixture,
                arguments: [.integer(input)],
                budget: budget
            ) == .trapped(.nativeImportDescriptorMismatch(.init(rawValue: 0)))
        )
        #expect(!budget.sideEffectsCommitted)
    }

    @Test("Native catalog identity must match the frozen NativeImportKey")
    func rejectsWrongNativeImportIdentity() throws {
        let fixture = try makeNativeIncrementImage()
        let catalog = try VM.NativeCatalog([
            IncrementInvoker(key: .init(rawValue: .sha256("wrong native import"))),
        ])

        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: .init(rawValue: 0),
                image: fixture,
                arguments: [.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true))]
            ) == .trapped(.nativeImportDescriptorMismatch(.init(rawValue: 0)))
        )
    }

    @Test("Synchronous native policies enforce thread, cooperation, work, and import deadlines")
    func enforcesNativeExecutionPolicies() throws {
        let id = Core.NativeImportID(rawValue: 9)
        let cooperative = Core.NativeImportContract.cooperative(
            kind: .serviceMethod,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 10_000,
            allowsMainThread: false
        )
        let limits = Core.ResourceLimits(
            instructionFuelPerEntry: 10,
            maxWallTimeMainThreadMilliseconds: 1_000,
            maxWallTimeBackgroundMilliseconds: 1_000
        )

        let mainThreadBudget = VM.InvocationBudget(
            limits: limits,
            isMainThread: true,
            nowNanoseconds: { 0 }
        )
        #expect(throws: VM.RuntimeTrap.nativeImportThreadViolation(id)) {
            try mainThreadBudget.beginNativeInvocation(
                id: id,
                effects: .init(),
                contract: cooperative,
                isMainThread: true
            )
        }

        let missingCheckpointBudget = VM.InvocationBudget(
            limits: limits,
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let missingCheckpoint = try missingCheckpointBudget.beginNativeInvocation(
            id: id,
            effects: .init(),
            contract: cooperative,
            isMainThread: false
        )
        #expect(throws: VM.RuntimeTrap.nativeImportCooperationViolation(id)) {
            try missingCheckpoint.finish(requireCooperation: true)
        }

        let cooperativeBudget = VM.InvocationBudget(
            limits: limits,
            isMainThread: false,
            nowNanoseconds: { 0 }
        )
        let checked = try cooperativeBudget.beginNativeInvocation(
            id: id,
            effects: .init(),
            contract: cooperative,
            isMainThread: false
        )
        try checked.checkpoint(workUnits: 3)
        try checked.finish(requireCooperation: true)

        let bounded = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let deadlineClock = SequenceClock(values: [0, 0, 0, 1_000_000])
        let deadlineBudget = VM.InvocationBudget(
            limits: limits,
            isMainThread: false,
            nowNanoseconds: { deadlineClock.now() }
        )
        let expired = try deadlineBudget.beginNativeInvocation(
            id: id,
            effects: .init(),
            contract: bounded,
            isMainThread: false
        )
        #expect(throws: VM.RuntimeTrap.nativeImportDeadlineExceeded(id)) {
            try expired.finish(requireCooperation: true)
        }
    }

    @MainActor
    @Test("A verified MainActor contract provides a compile-time-safe UIKit entry")
    func authorizesMainActorNativeBody() throws {
        let id = Core.NativeImportID(rawValue: 10)
        let contract = Core.NativeImportContract.cooperative(
            kind: .instanceGetter,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 10_000,
            allowsMainThread: true
        )
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 100),
            isMainThread: true,
            nowNanoseconds: { 0 }
        )
        let context = try budget.beginNativeInvocation(
            id: id,
            effects: .init(requiresMainActor: true),
            contract: contract,
            isMainThread: true
        )
        let box = MainActorBox(value: 41)
        let value = try context.withMainActor { box.value + 1 }
        try context.finish(requireCooperation: true)
        #expect(value == 42)
    }

    @Test("Floating-point comparisons preserve unordered NaN semantics")
    func preservesNaNComparisonSemantics() throws {
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Double")
        let importKey = try Core.NativeImportKey.derive(
            namespace: namespace(),
            canonicalCallee: "Fixture.nan()",
            signature: signature,
            effects: .init(),
            contract: vmPureImportContract
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 1),
            key: importKey,
            signature: signature,
            effects: .init(),
            contract: vmPureImportContract
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 1),
            key: importKey,
            parameterTypes: [],
            resultType: .float(bitWidth: 64),
            signature: signature,
            effects: .init(),
            contract: vmPureImportContract
        )
        let policy = Core.RuntimePolicy(
            acceptedCapabilities: [.baselineV1, .nativeImportsV1],
            allowedNativeImports: [.init(rawValue: 1)]
        )
        let catalog = try VM.NativeCatalog([NaNInvoker(key: importKey)])
        for (predicate, expected) in [
            (Bytecode.ComparisonPredicate.equal, false),
            (.notEqual, true),
            (.lessThan, false),
            (.lessThanOrEqual, false),
            (.greaterThan, false),
            (.greaterThanOrEqual, false),
        ] {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "compareNaN",
                parameterRegisters: [],
                resultType: .bool,
                registerTypes: [.float(bitWidth: 64), .float(bitWidth: 64), .bool],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .nativeApply(result: .init(rawValue: 0), importID: .init(rawValue: 1), arguments: []),
                            .constantFloat(
                                result: .init(rawValue: 1),
                                bitPattern: Double(1).bitPattern
                            ),
                            .compare(
                                result: .init(rawValue: 2),
                                predicate: predicate,
                                lhs: .init(rawValue: 0),
                                rhs: .init(rawValue: 1)
                            ),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
            let fixture = try makeVerified(
                function: function,
                capabilities: [.baselineV1, .nativeImportsV1],
                imports: [requirement],
                shellImports: [descriptor],
                policy: policy,
                signature: .init(parameters: [], result: "Swift.Bool"),
                parameterTypes: [],
                resultType: .bool
            )
            #expect(
                VM.Interpreter(nativeCatalog: catalog)
                    .invoke(entry: .init(rawValue: 0), image: fixture, arguments: [])
                    == .returned(.bool(expected))
            )
        }
    }

    @Test("Integer shifts match Swift for negative and oversized amounts")
    func integerShiftSemantics() throws {
        let value = try VM.Integer(signed: -2, bitWidth: 64, isSigned: true)
        let cases: [(amount: Int64, right: Int64, left: Int64)] = [
            (-65, 0, -1),
            (-1, -4, -1),
            (0, -2, -2),
            (63, -1, 0),
            (64, -1, 0),
        ]
        for item in cases {
            let right = try makeVerified(
                function: shiftFunction(operation: .shiftRight, amount: item.amount)
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: right,
                    arguments: [.integer(value)]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: item.right,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )

            let left = try makeVerified(
                function: shiftFunction(operation: .shiftLeft, amount: item.amount)
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: left,
                    arguments: [.integer(value)]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: item.left,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("Narrow signed division reports the same overflow boundary as Swift")
    func narrowSignedDivisionOverflow() throws {
        let type = Bytecode.ValueType.integer(bitWidth: 8, signed: true)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "int8DivisionOverflow",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .bool,
            registerTypes: [type, type, type, .bool],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .divide,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            signature: .init(parameters: ["Swift.Int8", "Swift.Int8"], result: "Swift.Bool"),
            parameterTypes: [type, type],
            resultType: .bool
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: -128, bitWidth: 8, isSigned: true)),
                    .integer(try VM.Integer(signed: -1, bitWidth: 8, isSigned: true)),
                ]
            ) == .returned(.bool(true))
        )
    }

    @Test("Generated TypeOps preserve Swift values and enforce native-owned memory")
    func nativeTypeOperationsAndQuota() throws {
        let pointType = Core.TypeID.derive(namespace: namespace(), canonicalType: "Fixture.Point")
        let pointLayout = Core.Digest.sha256("Fixture.Point.layout.v1")
        let operations = VM.NativeTypeOperations(
            id: pointType,
            canonicalName: "Fixture.Point",
            kind: .value,
            layoutFingerprint: pointLayout,
            estimatedSize: 16,
            estimatedByteCount: { (_: Point) -> UInt64 in 1 }
        )
        let typeCatalog = try VM.NativeTypeCatalog([operations])
        let boxed = try typeCatalog.box(Point(x: 3, y: 4), as: pointType)
        #expect(boxed.value(as: Point.self) == Point(x: 3, y: 4))
        #expect(boxed.estimatedByteCount == 16)
        #expect(try operations.copy(boxed) == boxed)

        let makeSignature = Core.LoweredSignature(parameters: [], result: "Fixture.Point")
        let sumSignature = Core.LoweredSignature(parameters: ["Fixture.Point"], result: "Swift.Int")
        let makeKey = try Core.NativeImportKey.derive(
            namespace: namespace(),
            canonicalCallee: "Fixture.makePoint()",
            signature: makeSignature,
            effects: .init(),
            contract: vmPureImportContract
        )
        let sumKey = try Core.NativeImportKey.derive(
            namespace: namespace(),
            canonicalCallee: "Fixture.sum(_:)",
            signature: sumSignature,
            effects: .init(),
            contract: vmPureImportContract
        )
        let requirements = [
            Bytecode.ImportRequirement(
                id: .init(rawValue: 2),
                key: makeKey,
                signature: makeSignature,
                effects: .init(),
                contract: vmPureImportContract
            ),
            Bytecode.ImportRequirement(
                id: .init(rawValue: 3),
                key: sumKey,
                signature: sumSignature,
                effects: .init(),
                contract: vmPureImportContract
            ),
        ]
        let descriptors = [
            Verification.ResolvedNativeImport(
                id: .init(rawValue: 2),
                key: makeKey,
                parameterTypes: [],
                resultType: .native(pointType),
                signature: makeSignature,
                effects: .init(),
                contract: vmPureImportContract
            ),
            Verification.ResolvedNativeImport(
                id: .init(rawValue: 3),
                key: sumKey,
                parameterTypes: [.native(pointType)],
                resultType: .int64,
                signature: sumSignature,
                effects: .init(),
                contract: vmPureImportContract
            ),
        ]
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "nativePoint",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [.native(pointType), .native(pointType), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .nativeApply(result: .init(rawValue: 0), importID: .init(rawValue: 2), arguments: []),
                        .copyValue(result: .init(rawValue: 1), source: .init(rawValue: 0)),
                        .destroyValue(.init(rawValue: 0)),
                        .nativeApply(
                            result: .init(rawValue: 2),
                            importID: .init(rawValue: 3),
                            arguments: [.init(rawValue: 1)]
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [.baselineV1, .nativeImportsV1, .nativeTypesV1]
        let nativeCatalog = try VM.NativeCatalog([
            MakePointInvoker(key: makeKey, operations: operations),
            SumPointInvoker(key: sumKey, typeID: pointType),
        ])

        func verified(maximumNativeBytes: UInt64) throws -> Verification.Image {
            let limits = Core.ResourceLimits(
                maxNativeOwnedBytes: maximumNativeBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
            return try makeVerified(
                function: function,
                limits: limits,
                capabilities: capabilities,
                imports: requirements,
                shellImports: descriptors,
                policy: .init(
                    acceptedCapabilities: capabilities,
                    resourceCeiling: limits,
                    allowedNativeImports: [.init(rawValue: 2), .init(rawValue: 3)]
                ),
                signature: .init(parameters: [], result: "Swift.Int"),
                parameterTypes: [],
                resultType: .int64,
                shellTypes: [
                    .init(
                        id: pointType,
                        canonicalName: "Fixture.Point",
                        kind: .value,
                        layoutFingerprint: pointLayout,
                        isCopyable: true,
                        estimatedSize: 16
                    ),
                ]
            )
        }

        #expect(
            VM.Interpreter(nativeCatalog: nativeCatalog, nativeTypeCatalog: typeCatalog)
                .invoke(entry: .init(rawValue: 0), image: try verified(maximumNativeBytes: 32), arguments: [])
                == .returned(.integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter(nativeCatalog: nativeCatalog, nativeTypeCatalog: typeCatalog)
                .invoke(entry: .init(rawValue: 0), image: try verified(maximumNativeBytes: 31), arguments: [])
                == .trapped(.nativeOwnedMemoryLimitExceeded)
        )
    }

    @Test("Generated TypeOps support non-Hashable values and reference identity")
    func customNativeTypeOperations() throws {
        let valueType = Core.TypeID.derive(
            namespace: namespace(),
            canonicalType: "Fixture.NonHashableValue"
        )
        let valueOperations = VM.NativeTypeOperations(
            id: valueType,
            canonicalName: "Fixture.NonHashableValue",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.NonHashableValue.layout.v1"),
            estimatedSize: 24,
            estimatedByteCount: { (_: NonHashableValue) in 24 },
            equals: { $0.values == $1.values },
            hash: { value, hasher in hasher.combine(value.values) },
            describe: { $0.values.description }
        )
        let original = try valueOperations.box(NonHashableValue(values: [1, 2, 3]))
        let copied = try valueOperations.copy(original)

        #expect(original == copied)
        #expect(Set([original, copied]).count == 1)
        #expect(copied.value(as: NonHashableValue.self)?.values == [1, 2, 3])

        let referenceType = Core.TypeID.derive(
            namespace: namespace(),
            canonicalType: "Fixture.ReferenceToken"
        )
        let referenceOperations = VM.NativeTypeOperations.reference(
            id: referenceType,
            canonicalName: "Fixture.ReferenceToken",
            layoutFingerprint: .sha256("Fixture.ReferenceToken.layout.v1"),
            describe: { (value: ReferenceToken) in value.label }
        )
        let token = ReferenceToken(label: "shared")
        let boxedReference = try referenceOperations.box(token)
        let copiedReference = try referenceOperations.copy(boxedReference)
        let copiedToken = try #require(copiedReference.value(as: ReferenceToken.self))

        #expect(boxedReference == copiedReference)
        #expect(Set([boxedReference, copiedReference]).count == 1)
        #expect(copiedToken === token)

        let opaqueType = Core.TypeID.derive(
            namespace: namespace(),
            canonicalType: "Fixture.OpaqueValue"
        )
        let opaqueOperations = VM.NativeTypeOperations.opaqueValue(
            id: opaqueType,
            canonicalName: "Fixture.OpaqueValue",
            layoutFingerprint: .sha256("Fixture.OpaqueValue.layout.v1"),
            clone: { (value: NonHashableValue) in value },
            describe: { $0.values.description }
        )
        let opaque = try opaqueOperations.box(NonHashableValue(values: [4, 5]))
        let opaqueCopy = try opaqueOperations.copy(opaque)
        let separatelyBoxed = try opaqueOperations.box(
            NonHashableValue(values: [4, 5])
        )

        #expect(opaque == opaqueCopy)
        #expect(opaque != separatelyBoxed)
        #expect(opaqueCopy.value(as: NonHashableValue.self)?.values == [4, 5])
    }

    @Test("MainActor native TypeOps reject background boxing")
    func mainActorNativeTypeRejectsBackgroundAccess() async {
        let typeID = Core.TypeID.derive(
            namespace: namespace(),
            canonicalType: "Fixture.MainActorReference"
        )
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: "Fixture.MainActorReference",
            layoutFingerprint: .sha256("Fixture.MainActorReference.layout.v1"),
            requiresMainActor: true,
            describe: { (_: ReferenceToken) in "main-actor-reference" }
        )
        let trap = await Task.detached { () -> VM.RuntimeTrap? in
            do {
                _ = try operations.box(ReferenceToken(label: "background"))
                return nil
            } catch let trap as VM.RuntimeTrap {
                return trap
            } catch {
                return .nativeFailure(String(describing: error))
            }
        }.value
        #expect(trap == .mainActorViolation)
    }

    @Test("Optional values can move through a verified stack slot")
    func optionalStackLifecycle() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "optionalStack",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .string,
            registerTypes: [
                .string,
                .optional(.string),
                .optional(.string),
                .bool,
                .optional(.string),
                .string,
            ],
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
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 1),
                            mode: .initialize
                        ),
                        .loadStack(
                            result: .init(rawValue: 2),
                            slot: .init(rawValue: 0),
                            mode: .copy
                        ),
                        .optionalIsSome(
                            result: .init(rawValue: 3),
                            optional: .init(rawValue: 2)
                        ),
                        .destroyValue(.init(rawValue: 2)),
                        .loadStack(
                            result: .init(rawValue: 4),
                            slot: .init(rawValue: 0),
                            mode: .take
                        ),
                        .unwrapOptional(
                            result: .init(rawValue: 5),
                            optional: .init(rawValue: 4)
                        ),
                        .returnValue(.init(rawValue: 5)),
                    ]
                ),
            ],
            stackSlotTypes: [.optional(.string)]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(parameters: ["Swift.String"], result: "Swift.String"),
            parameterTypes: [.string],
            resultType: .string
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.string("persisted")]
            ) == .returned(.string("persisted"))
        )
    }

    @Test("Tuple construction and destruction preserve element order")
    func tupleRoundTrip() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "tuple",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .int64,
            registerTypes: [
                .int64, .int64, .tuple([.int64, .int64]), .int64, .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .makeTuple(
                            result: .init(rawValue: 2),
                            elements: [.init(rawValue: 0), .init(rawValue: 1)]
                        ),
                        .unpackTuple(
                            results: [.init(rawValue: 3), .init(rawValue: 4)],
                            tuple: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            signature: .init(parameters: ["Swift.Int", "Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64, .int64]
        )
        let first = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        let second = try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.integer(first), .integer(second)]
            ) == .returned(.integer(second))
        )
    }

    @Test("Optional switching transfers an owned payload only along the some edge")
    func optionalSwitchTransfersPayload() throws {
        let optionalString = Bytecode.ValueType.optional(.string)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "optionalDefault",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .string,
            registerTypes: [optionalString, .string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
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
                    parameters: [.init(rawValue: 1)],
                    instructions: [.returnValue(.init(rawValue: 1))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .constantString(result: .init(rawValue: 2), value: "fallback"),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.Optional<Swift.String>"],
                result: "Swift.String"
            ),
            parameterTypes: [optionalString],
            resultType: .string
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.optional(.string("patched"))]
            ) == .returned(.string("patched"))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.optional(nil)]
            ) == .returned(.string("fallback"))
        )
    }

    @Test("String operations use Swift grapheme and ordering semantics")
    func executesStringOperations() throws {
        let resultType = Bytecode.ValueType.tuple([.string, .int64, .bool, .bool])
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "strings",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: resultType,
            registerTypes: [.string, .string, .string, .int64, .bool, .bool, resultType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .stringConcat(
                            result: .init(rawValue: 2),
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .stringCount(result: .init(rawValue: 3), string: .init(rawValue: 2)),
                        .stringIsEmpty(result: .init(rawValue: 4), string: .init(rawValue: 2)),
                        .compare(
                            result: .init(rawValue: 5),
                            predicate: .lessThan,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .makeTuple(
                            result: .init(rawValue: 6),
                            elements: [
                                .init(rawValue: 2), .init(rawValue: 3),
                                .init(rawValue: 4), .init(rawValue: 5),
                            ]
                        ),
                        .returnValue(.init(rawValue: 6)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.String", "Swift.String"],
                result: "(Swift.String, Swift.Int, Swift.Bool, Swift.Bool)"
            ),
            parameterTypes: [.string, .string],
            resultType: resultType
        )
        let left = "Helix"
        let right = "🧬"

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.string(left), .string(right)]
            ) == .returned(
                .tuple([
                    .string(left + right),
                    .integer(try VM.Integer(signed: 6, bitWidth: 64, isSigned: true)),
                    .bool(false),
                    .bool(left < right),
                ])
            )
        )
    }

    @Test("String inputs and concatenation are both charged to the VM heap budget")
    func stringConcatenationConsumesHeapBudget() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "concat",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .string,
            registerTypes: [.string, .string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .stringConcat(
                            result: .init(rawValue: 2),
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let left = "abc"
        let right = "🧬"
        let payloadBytes = UInt64(left.utf8.count + right.utf8.count)
        let frameBytes = UInt64(3 * MemoryLayout<VM.Value?>.stride)
        let exactBudget = frameBytes + payloadBytes + payloadBytes

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1],
                signature: .init(
                    parameters: ["Swift.String", "Swift.String"],
                    result: "Swift.String"
                ),
                parameterTypes: [.string, .string],
                resultType: .string
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget - 1),
                arguments: [.string(left), .string(right)]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget),
                arguments: [.string(left), .string(right)]
            ) == .returned(.string(left + right))
        )
    }

    @Test("Variable-size VM allocations reserve an upper bound and charge actual bytes")
    func variableSizeAllocationReservationIsFailClosed() throws {
        let budget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: 10,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        let value = try budget.withReservedVMHeap(maximumBytes: 8) {
            (value: 42, actualBytes: 3)
        }
        #expect(value == 42)
        try budget.consumeVMHeap(bytes: 7)
        #expect(throws: VM.RuntimeTrap.vmHeapLimitExceeded) {
            try budget.consumeVMHeap(bytes: 1)
        }

        let rejected = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: 10,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(throws: VM.RuntimeTrap.vmHeapLimitExceeded) {
            try rejected.withReservedVMHeap(maximumBytes: 8) {
                (value: 42, actualBytes: 9)
            }
        }
        try rejected.consumeVMHeap(bytes: 10)
    }

    @Test("String case mapping proves its output bound before allocating")
    func stringCaseMappingReservesHeapBeforeAllocation() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "uppercase",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .string,
            registerTypes: [.string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .stringTransform(
                            result: .init(rawValue: 1),
                            operation: .uppercase,
                            string: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let input = "ß"
        let inputBytes = UInt64(input.utf8.count)
        let frameBytes = UInt64(2 * MemoryLayout<VM.Value?>.stride)
        let outputBound = try VM.StringAllocation
            .maximumCaseMappingUTF8ByteCount(for: input)
        let exactBudget = frameBytes + inputBytes + outputBound

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1],
                signature: .init(parameters: ["Swift.String"], result: "Swift.String"),
                parameterTypes: [.string],
                resultType: .string
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget - 1),
                arguments: [.string(input)]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget),
                arguments: [.string(input)]
            ) == .returned(.string("SS"))
        )
    }

    @Test("Scalar stringification proves its output bound before allocating")
    func scalarStringificationReservesHeapBeforeAllocation() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "stringify",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .string,
            registerTypes: [.int64, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .stringify(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let input = VM.Value.integer(
            try VM.Integer(signed: 42, bitWidth: 64, isSigned: true)
        )
        let outputBound = try VM.StringAllocation
            .maximumStringificationUTF8ByteCount(for: input)
        let frameBytes = UInt64(2 * MemoryLayout<VM.Value?>.stride)
        let exactBudget = frameBytes + outputBound

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1],
                signature: .init(parameters: ["Swift.Int"], result: "Swift.String"),
                parameterTypes: [.int64],
                resultType: .string
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget - 1),
                arguments: [input]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget),
                arguments: [input]
            ) == .returned(.string("42"))
        )

        let boundedScalars: [VM.Value] = [
            .bool(false),
            .integer(try VM.Integer(signed: .min, bitWidth: 64, isSigned: true)),
            .integer(try VM.Integer(rawBits: .max, bitWidth: 64, isSigned: false)),
            .float64(-Double.greatestFiniteMagnitude),
            .float32(-Float.greatestFiniteMagnitude),
            .float64(.nan),
            .float64(-.infinity),
        ]
        for scalar in boundedScalars {
            let text = try VM.StringAllocation.stringify(scalar)
            let maximum = try VM.StringAllocation
                .maximumStringificationUTF8ByteCount(for: scalar)
            #expect(UInt64(text.utf8.count) <= maximum)
        }
    }

    @Test("Scalar text conversion is bounded before native parsing and formatting")
    func scalarTextConversionRespectsResourceBudgets() throws {
        let integer = Bytecode.ValueType.int64
        let formatting = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "integerToString",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: .string,
            registerTypes: [integer, integer, .bool, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    instructions: [
                        .integerToString(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 0),
                            radix: .init(rawValue: 1),
                            uppercase: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let minimum = try VM.Integer(
            signed: .min,
            bitWidth: 64,
            isSigned: true
        )
        let radixTwo = try VM.Integer(
            signed: 2,
            bitWidth: 64,
            isSigned: true
        )
        let output = String(Int64.min, radix: 2)
        let frameBytes = UInt64(
            formatting.registerTypes.count * MemoryLayout<VM.Value?>.stride
        )
        let outputBytes = UInt64(output.utf8.count)
        #expect(
            outputBytes
                == VM.ScalarText.maximumFormattedUTF8ByteCount(for: minimum)
        )

        func formattingImage(
            maximumHeapBytes: UInt64
        ) throws -> Verification.Image {
            try makeVerified(
                function: formatting,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1],
                signature: .init(
                    parameters: ["Swift.Int", "Swift.Int", "Swift.Bool"],
                    result: "Swift.String"
                ),
                parameterTypes: [integer, integer, .bool],
                resultType: .string
            )
        }

        let arguments: [VM.Value] = [
            .integer(minimum), .integer(radixTwo), .bool(false),
        ]
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try formattingImage(
                    maximumHeapBytes: frameBytes + outputBytes - 1
                ),
                arguments: arguments
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try formattingImage(
                    maximumHeapBytes: frameBytes + outputBytes
                ),
                arguments: arguments
            ) == .returned(.string(output))
        )

        let optionalInteger = Bytecode.ValueType.optional(integer)
        let parsing = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "scalarFromString",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            resultType: optionalInteger,
            registerTypes: [.string, integer, optionalInteger],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .scalarFromString(
                            result: .init(rawValue: 2),
                            string: .init(rawValue: 0),
                            radix: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let longInput = String(repeating: "1", count: 4_096)
        let parsingImage = try makeVerified(
            function: parsing,
            limits: .init(
                instructionFuelPerEntry: 300,
                maxWallTimeMainThreadMilliseconds: 1_000
            ),
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.String", "Swift.Int"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [.string, integer],
            resultType: optionalInteger
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: parsingImage,
                arguments: [.string(longInput), .integer(radixTwo)]
            ) == .trapped(.instructionFuelExhausted)
        )
        let invalidRadix = try VM.Integer(
            signed: 1,
            bitWidth: 64,
            isSigned: true
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: parsingImage,
                arguments: [.string(longInput), .integer(invalidRadix)]
            ) == .trapped(
                .explicit(VM.ScalarText.invalidRadixMessage)
            )
        )
    }

    @Test("Source failures retain represented diagnostics and terminate execution")
    func sourceFailureTerminatesExecution() throws {
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "sourceFailure",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .void,
            registerTypes: [.string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .sourceFailure(
                            prefix: "Precondition failed",
                            detail: .init(rawValue: 0)
                        ),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(
                parameters: ["Swift.String"],
                result: "Swift.Void"
            ),
            parameterTypes: [.string],
            resultType: .void
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.string("negative")]
            ) == .trapped(
                .sourceFailure(
                    prefix: "Precondition failed",
                    detail: "negative"
                )
            )
        )
        let empty = VM.RuntimeTrap.sourceFailure(
            prefix: "Fatal error",
            detail: ""
        )
        #expect(empty.description == "Fatal error")
    }

    @Test("Array boundary storage is typed and charged before execution")
    func arrayBoundaryConsumesHeapBudget() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "arrayIdentity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: arrayType,
            registerTypes: [arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        let elements = try [1, 2, 3].map {
            VM.Value.integer(
                try VM.Integer(signed: Int64($0), bitWidth: 64, isSigned: true)
            )
        }
        let input = VM.Value.array(elements, elementType: .int64)
        let frameBytes = UInt64(MemoryLayout<VM.Value?>.stride)
        let aggregateBytes: UInt64 = 64

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(
                    parameters: ["Swift.Array<Swift.Int>"],
                    result: "Swift.Array<Swift.Int>"
                ),
                parameterTypes: [arrayType],
                resultType: arrayType
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: frameBytes + aggregateBytes - 1),
                arguments: [input]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: frameBytes + aggregateBytes),
                arguments: [input]
            ) == .returned(input)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: frameBytes + aggregateBytes),
                arguments: [.array([.string("wrong")], elementType: .int64)]
            ) == .trapped(.typeMismatch(expected: .int64, actual: .string))
        )
    }

    @Test("Dictionary literals reject duplicate keys at runtime")
    func dictionaryLiteralRejectsDuplicateKeys() throws {
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        let dictionaryType = Bytecode.ValueType.dictionary(key: .string, value: .int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "duplicateDictionaryLiteral",
            parameterRegisters: [],
            resultType: dictionaryType,
            registerTypes: [
                .string, .int64, pairType,
                .string, .int64, pairType,
                .array(pairType), dictionaryType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantString(result: .init(rawValue: 0), value: "duplicate"),
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 1),
                        .makeTuple(
                            result: .init(rawValue: 2),
                            elements: [.init(rawValue: 0), .init(rawValue: 1)]
                        ),
                        .constantString(result: .init(rawValue: 3), value: "duplicate"),
                        .constantInteger(result: .init(rawValue: 4), bitPattern: 2),
                        .makeTuple(
                            result: .init(rawValue: 5),
                            elements: [.init(rawValue: 3), .init(rawValue: 4)]
                        ),
                        .makeArray(
                            result: .init(rawValue: 6),
                            elements: [.init(rawValue: 2), .init(rawValue: 5)]
                        ),
                        .makeDictionary(
                            result: .init(rawValue: 7),
                            pairs: .init(rawValue: 6)
                        ),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .stringsV1, .collectionsV1],
            signature: .init(
                parameters: [],
                result: "Swift.Dictionary<Swift.String, Swift.Int>"
            ),
            parameterTypes: [],
            resultType: dictionaryType
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: []
            ) == .trapped(.explicit("Dictionary construction contains duplicate keys"))
        )
    }

    @Test("Dictionary boundary storage is typed, unique, and charged before execution")
    func dictionaryBoundaryConsumesHeapBudget() throws {
        let dictionaryType = Bytecode.ValueType.dictionary(key: .string, value: .int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "dictionaryIdentity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: dictionaryType,
            registerTypes: [dictionaryType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        let one = VM.Value.integer(
            try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )
        let two = VM.Value.integer(
            try VM.Integer(signed: 2, bitWidth: 64, isSigned: true)
        )
        let entries: [VM.DictionaryEntry] = [
            .init(key: .string("a"), value: one),
            .init(key: .string("beta"), value: two),
        ]
        let input = VM.Value.dictionary(
            entries,
            keyType: .string,
            valueType: .int64
        )
        let frameBytes = UInt64(MemoryLayout<VM.Value?>.stride)
        // 80 bytes for Dictionary storage plus 48 bytes for the transient
        // duplicate-key validation set.
        let aggregateBytes: UInt64 = 128
        let stringBytes: UInt64 = 5
        let exactBudget = frameBytes + aggregateBytes + stringBytes

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                capabilities: [.baselineV1, .stringsV1, .collectionsV1],
                signature: .init(
                    parameters: ["Swift.Dictionary<Swift.String, Swift.Int>"],
                    result: "Swift.Dictionary<Swift.String, Swift.Int>"
                ),
                parameterTypes: [dictionaryType],
                resultType: dictionaryType
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget - 1),
                arguments: [input]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget),
                arguments: [input]
            ) == .returned(input)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(maximumHeapBytes: exactBudget * 2),
                arguments: [
                    .dictionary(
                        entries + [entries[0]],
                        keyType: .string,
                        valueType: .int64
                    ),
                ]
            ) == .trapped(
                .nativeFailure("Dictionary boundary value contains a duplicate key")
            )
        )
    }

    @Test("Copying a tuple is charged against the VM heap budget")
    func tupleCopyConsumesHeapBudget() throws {
        let tupleType = Bytecode.ValueType.tuple([.int64, .int64])
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "copyTuple",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: tupleType,
            registerTypes: [tupleType, tupleType],
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
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let frameBytes = UInt64(2 * MemoryLayout<VM.Value?>.stride)
        let aggregateBytes: UInt64 = 48
        let boundaryBytes = aggregateBytes
        let input: VM.Value = .tuple([
            .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
            .integer(try VM.Integer(signed: 8, bitWidth: 64, isSigned: true)),
        ])

        func image(maximumHeapBytes: UInt64) throws -> Verification.Image {
            try makeVerified(
                function: function,
                limits: .init(
                    maxVMHeapBytes: maximumHeapBytes,
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                signature: .init(
                    parameters: ["(Swift.Int, Swift.Int)"],
                    result: "(Swift.Int, Swift.Int)"
                ),
                parameterTypes: [tupleType],
                resultType: tupleType
            )
        }

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(
                    maximumHeapBytes: frameBytes + boundaryBytes + aggregateBytes - 1
                ),
                arguments: [input]
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(
                    maximumHeapBytes: frameBytes + boundaryBytes + aggregateBytes
                ),
                arguments: [input]
            ) == .returned(input)
        )
    }

    @Test("Nil unwrap is a runtime trap, while explicit throw is a business error")
    func optionalTrapAndBusinessThrow() throws {
        let nilFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "nilUnwrap",
            parameterRegisters: [],
            resultType: .string,
            registerTypes: [.optional(.string), .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .makeOptionalNone(result: .init(rawValue: 0)),
                        .unwrapOptional(
                            result: .init(rawValue: 1),
                            optional: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let nilImage = try makeVerified(
            function: nilFunction,
            capabilities: [.baselineV1, .stringsV1],
            signature: .init(parameters: [], result: "Swift.String"),
            parameterTypes: [],
            resultType: .string
        )
        let diagnosticBox = TrapDiagnosticBox()
        #expect(
            VM.Interpreter(trapObserver: { diagnosticBox.record($0) }).invoke(
                entry: .init(rawValue: 0),
                image: nilImage,
                arguments: []
            ) == .trapped(.optionalUnwrapOfNil)
        )
        #expect(
            diagnosticBox.value == .init(
                trap: .optionalUnwrapOfNil,
                programCounter: .init(
                    functionID: .init(rawValue: 0),
                    blockID: .init(rawValue: 0),
                    instructionOffset: 1
                )
            )
        )

        let unknownEntryBox = TrapDiagnosticBox()
        let unknownEntry = Core.EntryIndex(rawValue: 99)
        #expect(
            VM.Interpreter(trapObserver: { unknownEntryBox.record($0) }).invoke(
                entry: unknownEntry,
                image: nilImage,
                arguments: []
            ) == .trapped(.unknownEntry(unknownEntry))
        )
        #expect(
            unknownEntryBox.value == .init(
                trap: .unknownEntry(unknownEntry),
                programCounter: nil
            )
        )

        let throwingFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "throwing",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [.string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantString(result: .init(rawValue: 0), value: "fixture failure"),
                        .throwError(.init(rawValue: 0)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )
        let throwingImage = try makeVerified(
            function: throwingFunction,
            capabilities: [.baselineV1, .stringsV1, .untypedThrowsV1],
            signature: .init(parameters: [], result: "Swift.Void", isThrowing: true),
            parameterTypes: [],
            resultType: .void
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: throwingImage,
                arguments: []
            ) == .businessError("fixture failure")
        )
    }

    @Test("try_apply catches business errors but never catches VM traps")
    func tryApplySeparatesBusinessErrorsFromRuntimeTraps() throws {
        let caller = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "catching",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.bool, .int64, .string, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .tryApply(
                            function: .init(rawValue: 1),
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
                        .constantInteger(result: .init(rawValue: 3), bitPattern: UInt64.max),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )

        let forwardingCallee = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "forwardingMayFail",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.bool, .int64, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .tryApply(
                            function: .init(rawValue: 2),
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
                    instructions: [.throwError(.init(rawValue: 2))]
                ),
            ],
            effects: .init(mayThrow: true)
        )

        func callee(failure: Bytecode.Instruction) -> Bytecode.Function {
            Bytecode.Function(
                id: .init(rawValue: 2),
                name: "mayFail",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.bool, .string, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .conditionalBranch(
                                condition: .init(rawValue: 0),
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
                            .constantString(result: .init(rawValue: 1), value: "fixture failure"),
                            failure,
                        ]
                    ),
                    .init(
                        id: .init(rawValue: 2),
                        instructions: [
                            .constantInteger(result: .init(rawValue: 2), bitPattern: 7),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ],
                effects: .init(mayThrow: true)
            )
        }

        let capabilities: Set<Core.Capability> = [
            .baselineV1, .stringsV1, .untypedThrowsV1,
        ]
        let businessImage = try makeVerified(
            function: caller,
            capabilities: capabilities,
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.Int"),
            parameterTypes: [.bool],
            resultType: .int64,
            additionalFunctions: [
                forwardingCallee,
                callee(failure: .throwError(.init(rawValue: 1))),
            ]
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: businessImage,
                arguments: [.bool(false)]
            ) == .returned(.integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: businessImage,
                arguments: [.bool(true)]
            ) == .returned(.integer(try VM.Integer(signed: -1, bitWidth: 64, isSigned: true)))
        )

        let trapImage = try makeVerified(
            function: caller,
            capabilities: capabilities,
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.Int"),
            parameterTypes: [.bool],
            resultType: .int64,
            additionalFunctions: [
                forwardingCallee,
                callee(failure: .trap(.explicit("fatal fixture"))),
            ]
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: trapImage,
                arguments: [.bool(true)]
            ) == .trapped(.explicit("fatal fixture"))
        )
    }

    @Test("native_try_apply catches only a declared native business error")
    func nativeTryApplyCatchesBusinessError() throws {
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Bool"],
            result: "Swift.Int",
            isThrowing: true
        )
        let effects = Core.Effects(mayThrow: true)
        let key = try Core.NativeImportKey.derive(
            namespace: namespace(),
            canonicalCallee: "Fixture.mayFail(_:)",
            signature: signature,
            effects: effects,
            contract: vmPureImportContract
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 2),
            key: key,
            signature: signature,
            effects: effects,
            contract: vmPureImportContract
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 2),
            key: key,
            parameterTypes: [.bool],
            resultType: .int64,
            signature: signature,
            effects: effects,
            contract: vmPureImportContract
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "catchNative",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.bool, .int64, .string, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeTryApply(
                            importID: .init(rawValue: 2),
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
                        .constantInteger(result: .init(rawValue: 3), bitPattern: UInt64.max),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .stringsV1, .nativeImportsV1, .untypedThrowsV1,
        ]
        let image = try makeVerified(
            function: function,
            capabilities: capabilities,
            imports: [requirement],
            shellImports: [descriptor],
            policy: .init(
                acceptedCapabilities: capabilities,
                allowedNativeImports: [.init(rawValue: 2)]
            ),
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.Int"),
            parameterTypes: [.bool],
            resultType: .int64
        )
        let interpreter = VM.Interpreter(
            nativeCatalog: try .init([ThrowingInvoker(key: key)])
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.bool(false)]
            ) == .returned(
                .integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true))
            )
        )
        #expect(
            interpreter.invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.bool(true)]
            ) == .returned(
                .integer(try VM.Integer(signed: -1, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Throwing closures resume through normal and error continuations")
    func executesThrowingClosureControlFlow() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .int64,
            effects: .init(mayThrow: true)
        )
        let closureType = Bytecode.ValueType.closure(signature)
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "throwingClosureRoot",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .bool, .int64, closureType, .int64, .string, .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: 7
                        ),
                        .makeClosure(
                            result: .init(rawValue: 2),
                            function: .init(rawValue: 1),
                            captures: [.init(rawValue: 1)]
                        ),
                        .closureTryApply(
                            closure: .init(rawValue: 2),
                            arguments: [.init(rawValue: 0)],
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
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
                    parameters: [.init(rawValue: 4)],
                    instructions: [
                        .destroyValue(.init(rawValue: 4)),
                        .constantInteger(
                            result: .init(rawValue: 5),
                            bitPattern: UInt64.max
                        ),
                        .returnValue(.init(rawValue: 5)),
                    ]
                ),
            ]
        )
        let body = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "throwingClosureBody",
            kind: .closureBody,
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1),
            ],
            resultType: .int64,
            registerTypes: [.bool, .int64, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    instructions: [
                        .conditionalBranch(
                            condition: .init(rawValue: 0),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: []
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [.returnValue(.init(rawValue: 1))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    instructions: [
                        .constantString(
                            result: .init(rawValue: 2),
                            value: "closure failure"
                        ),
                        .throwError(.init(rawValue: 2)),
                    ]
                ),
            ],
            effects: .init(mayThrow: true)
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .stringsV1, .closureValuesV1, .untypedThrowsV1,
        ]
        let image = try makeVerified(
            function: root,
            capabilities: capabilities,
            signature: .init(
                parameters: ["Swift.Bool"],
                result: "Swift.Int"
            ),
            parameterTypes: [.bool],
            additionalFunctions: [body]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.bool(true)]
            ) == .returned(
                .integer(try .init(signed: 7, bitWidth: 64, isSigned: true))
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.bool(false)]
            ) == .returned(
                .integer(try .init(signed: -1, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Mutable capture cells share updates across closure invocations")
    func executesMutableClosureCaptures() throws {
        let cellType = Bytecode.ValueType.mutableCell(.int64)
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [],
                parameterConventions: [],
                result: .int64
            )
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "mutableCaptureRoot",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, cellType, closureType, .int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeMutableCell(
                            result: .init(rawValue: 1),
                            initialValue: .init(rawValue: 0)
                        ),
                        .makeClosure(
                            result: .init(rawValue: 2),
                            function: .init(rawValue: 1),
                            captures: [.init(rawValue: 1)]
                        ),
                        .closureApply(
                            result: .init(rawValue: 3),
                            closure: .init(rawValue: 2),
                            arguments: []
                        ),
                        .closureApply(
                            result: .init(rawValue: 4),
                            closure: .init(rawValue: 2),
                            arguments: []
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let body = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "mutableCaptureBody",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                cellType, .int64, .int64, .int64, .bool, .int64, .int64,
            ],
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
                        .constantInteger(result: .init(rawValue: 2), bitPattern: 1),
                        .checkedBinary(
                            result: .init(rawValue: 3),
                            overflow: .init(rawValue: 4),
                            operation: .add,
                            lhs: .init(rawValue: 1),
                            rhs: .init(rawValue: 2)
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 4),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: [.init(rawValue: 3)]
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    instructions: [.trap(.integerOverflow)]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 5)],
                    instructions: [
                        .storeMutableCell(
                            cell: .init(rawValue: 0),
                            source: .init(rawValue: 5),
                            mode: .assign
                        ),
                        .loadMutableCell(
                            result: .init(rawValue: 6),
                            cell: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 6)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: root,
            capabilities: [
                .baselineV1, .closureValuesV1, .mutableCapturesV1,
            ],
            additionalFunctions: [body]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(
                        try .init(signed: 4, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try .init(signed: 6, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Natural Array sorting is typed and fuel-bounded")
    func executesNaturalArraySorting() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "naturalArraySorting",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: arrayType,
            registerTypes: [arrayType, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .arraySorted(
                            result: .init(rawValue: 1),
                            array: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType],
            resultType: arrayType
        )
        let input = VM.Value.array(
            try [8, 3, 5, 1, 3].map { value in
                .integer(
                    try .init(
                        signed: Int64(value),
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            },
            elementType: .int64
        )
        let expected = VM.Value.array(
            try [1, 3, 3, 5, 8].map { value in
                .integer(
                    try .init(
                        signed: Int64(value),
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            },
            elementType: .int64
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input]
            ) == .returned(expected)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input],
                budget: .init(
                    limits: .init(
                        instructionFuelPerEntry: 3,
                        maxWallTimeMainThreadMilliseconds: 1_000
                    )
                )
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Direct Array splitting is typed and fuel-bounded")
    func executesDirectArraySplitting() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let resultType = Bytecode.ValueType.array(arrayType)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "directArraySplitting",
            parameterRegisters: [
                .init(rawValue: 0),
                .init(rawValue: 1),
                .init(rawValue: 2),
                .init(rawValue: 3),
            ],
            resultType: resultType,
            registerTypes: [
                arrayType,
                .int64,
                .int64,
                .bool,
                resultType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0),
                        .init(rawValue: 1),
                        .init(rawValue: 2),
                        .init(rawValue: 3),
                    ],
                    instructions: [
                        .arraySplitSeparator(
                            result: .init(rawValue: 4),
                            array: .init(rawValue: 0),
                            separator: .init(rawValue: 1),
                            maxSplits: .init(rawValue: 2),
                            omittingEmptySubsequences: .init(rawValue: 3)
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: [
                    "Swift.Array<Swift.Int>",
                    "Swift.Int",
                    "Swift.Int",
                    "Swift.Bool",
                ],
                result: "Swift.Array<Swift.Array<Swift.Int>>"
            ),
            parameterTypes: [arrayType, .int64, .int64, .bool],
            resultType: resultType
        )
        func integer(_ value: Int64) throws -> VM.Value {
            .integer(
                try .init(signed: value, bitWidth: 64, isSigned: true)
            )
        }
        func array(_ values: [Int64]) throws -> VM.Value {
            .array(try values.map(integer), elementType: .int64)
        }
        let input = try array([0, 1, 0, 2, 0])
        let arguments = [
            input,
            try integer(0),
            try integer(2),
            .bool(true),
        ]
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: arguments
            ) == .returned(
                .array(
                    [try array([1]), try array([2])],
                    elementType: arrayType
                )
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: arguments,
                budget: .init(
                    limits: .init(
                        instructionFuelPerEntry: 3,
                        maxWallTimeMainThreadMilliseconds: 1_000
                    )
                )
            ) == .trapped(.instructionFuelExhausted)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    input,
                    try integer(0),
                    try integer(-1),
                    .bool(true),
                ]
            ) == .trapped(
                .explicit("maximum split count cannot be negative")
            )
        )
    }

    @Test("Linear Array builders accumulate and finish exactly once")
    func executesLinearArrayBuilder() throws {
        let builderType = Bytecode.ValueType.arrayState(
            kind: .builder,
            element: .int64
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "linearArrayBuilder",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .array(.int64),
            registerTypes: [.int64, builderType, .array(.int64)],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeArrayBuilder(result: .init(rawValue: 1)),
                        .arrayBuilderAppend(
                            builder: .init(rawValue: 1),
                            value: .init(rawValue: 0)
                        ),
                        .arrayBuilderAppend(
                            builder: .init(rawValue: 1),
                            value: .init(rawValue: 0)
                        ),
                        .finishArrayBuilder(
                            result: .init(rawValue: 2),
                            builder: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1],
            resultType: .array(.int64)
        )
        let value = VM.Value.integer(
            try .init(signed: 7, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [value]
            ) == .returned(.array([value, value], elementType: .int64))
        )
        let frameBytes = UInt64(
            function.registerTypes.count * MemoryLayout<VM.Value?>.stride
        )
        let builderBytes: UInt64 = 48
        let exactHeapBytes = frameBytes + builderBytes
        let exactBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [value],
                budget: exactBudget
            ) == .returned(.array([value, value], elementType: .int64))
        )
        let insufficientBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes - 1,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [value],
                budget: insufficientBudget
            ) == .trapped(.vmHeapLimitExceeded)
        )

        let directBuilder = VM.ArrayBuilder(elementType: .int64)
        try directBuilder.append(value)
        #expect(try directBuilder.finish() == [value])
        #expect(throws: VM.RuntimeTrap.self) {
            try directBuilder.append(value)
        }
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try directBuilder.finish()
        }

        let batchedBuilder = VM.ArrayBuilder(elementType: .int64)
        try batchedBuilder.append(contentsOf: [value, value])
        #expect(try batchedBuilder.finish() == [value, value])
        #expect(throws: VM.RuntimeTrap.self) {
            try batchedBuilder.append(contentsOf: [value])
        }

        let atomicBuilder = VM.ArrayBuilder(elementType: .int64)
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            try atomicBuilder.append(contentsOf: [value, .bool(true)])
        }
        try atomicBuilder.append(contentsOf: [value])
        #expect(try atomicBuilder.finish() == [value])
    }

    @Test("Linear Dictionary builders preserve lookup, replacement, and order")
    func executesLinearDictionaryBuilder() throws {
        let dictionaryType = Bytecode.ValueType.dictionary(
            key: .int64,
            value: .int64
        )
        let builderType = Bytecode.ValueType.dictionaryState(
            key: .int64,
            value: .int64
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "linearDictionaryBuilder",
            parameterRegisters: (0..<5).map {
                .init(rawValue: UInt32($0))
            },
            resultType: dictionaryType,
            registerTypes: [
                dictionaryType,
                .int64,
                .int64,
                .int64,
                .int64,
                builderType,
                .optional(.int64),
                dictionaryType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: (0..<5).map {
                        .init(rawValue: UInt32($0))
                    },
                    instructions: [
                        .makeDictionaryBuilder(
                            result: .init(rawValue: 5),
                            initialValue: .init(rawValue: 0)
                        ),
                        .dictionaryBuilderGet(
                            result: .init(rawValue: 6),
                            builder: .init(rawValue: 5),
                            key: .init(rawValue: 1)
                        ),
                        .dictionaryBuilderSet(
                            builder: .init(rawValue: 5),
                            key: .init(rawValue: 1),
                            value: .init(rawValue: 2)
                        ),
                        .dictionaryBuilderSet(
                            builder: .init(rawValue: 5),
                            key: .init(rawValue: 3),
                            value: .init(rawValue: 4)
                        ),
                        .finishDictionaryBuilder(
                            result: .init(rawValue: 7),
                            builder: .init(rawValue: 5)
                        ),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: [
                    "Swift.Dictionary<Swift.Int, Swift.Int>",
                    "Swift.Int", "Swift.Int", "Swift.Int", "Swift.Int",
                ],
                result: "Swift.Dictionary<Swift.Int, Swift.Int>"
            ),
            parameterTypes: [
                dictionaryType, .int64, .int64, .int64, .int64,
            ],
            resultType: dictionaryType
        )
        let one = VM.Value.integer(
            try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )
        let two = VM.Value.integer(
            try VM.Integer(signed: 2, bitWidth: 64, isSigned: true)
        )
        let ten = VM.Value.integer(
            try VM.Integer(signed: 10, bitWidth: 64, isSigned: true)
        )
        let twenty = VM.Value.integer(
            try VM.Integer(signed: 20, bitWidth: 64, isSigned: true)
        )
        let thirty = VM.Value.integer(
            try VM.Integer(signed: 30, bitWidth: 64, isSigned: true)
        )
        let initial = VM.Value.dictionary(
            [.init(key: one, value: ten)],
            keyType: .int64,
            valueType: .int64
        )
        let expected = VM.Value.dictionary(
            [
                .init(key: one, value: twenty),
                .init(key: two, value: thirty),
            ],
            keyType: .int64,
            valueType: .int64
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [initial, one, twenty, two, thirty]
            ) == .returned(expected)
        )

        let emptyFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "emptyDictionaryBuilder",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: dictionaryType,
            registerTypes: [.int64, .int64, builderType, dictionaryType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .makeDictionaryBuilder(
                            result: .init(rawValue: 2),
                            initialValue: nil
                        ),
                        .dictionaryBuilderSet(
                            builder: .init(rawValue: 2),
                            key: .init(rawValue: 0),
                            value: .init(rawValue: 1)
                        ),
                        .finishDictionaryBuilder(
                            result: .init(rawValue: 3),
                            builder: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let emptyImage = try makeVerified(
            function: emptyFunction,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: ["Swift.Int", "Swift.Int"],
                result: "Swift.Dictionary<Swift.Int, Swift.Int>"
            ),
            parameterTypes: [.int64, .int64],
            resultType: dictionaryType
        )
        let singleton = VM.Value.dictionary(
            [.init(key: one, value: ten)],
            keyType: .int64,
            valueType: .int64
        )
        let frameBytes = UInt64(
            emptyFunction.registerTypes.count
                * MemoryLayout<VM.Value?>.stride
        )
        let exactHeapBytes = frameBytes + 16 + (2 * 16)
        let exactBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: emptyImage,
                arguments: [one, ten],
                budget: exactBudget
            ) == .returned(singleton)
        )
        let insufficientBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes - 1,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: emptyImage,
                arguments: [one, ten],
                budget: insufficientBudget
            ) == .trapped(.vmHeapLimitExceeded)
        )

        let groupedDictionaryType = Bytecode.ValueType.dictionary(
            key: .int64,
            value: .array(.int64)
        )
        let groupedBuilderType = Bytecode.ValueType.dictionaryState(
            key: .int64,
            value: .array(.int64)
        )
        let groupedFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "groupedDictionaryBuilder",
            parameterRegisters: [
                .init(rawValue: 0),
                .init(rawValue: 1),
                .init(rawValue: 2),
            ],
            resultType: groupedDictionaryType,
            registerTypes: [
                .int64, .int64, .int64,
                groupedBuilderType, groupedDictionaryType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0),
                        .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    instructions: [
                        .makeDictionaryBuilder(
                            result: .init(rawValue: 3),
                            initialValue: nil
                        ),
                        .dictionaryBuilderAppendArrayElement(
                            builder: .init(rawValue: 3),
                            key: .init(rawValue: 0),
                            element: .init(rawValue: 1)
                        ),
                        .dictionaryBuilderAppendArrayElement(
                            builder: .init(rawValue: 3),
                            key: .init(rawValue: 0),
                            element: .init(rawValue: 2)
                        ),
                        .finishDictionaryBuilder(
                            result: .init(rawValue: 4),
                            builder: .init(rawValue: 3)
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let groupedImage = try makeVerified(
            function: groupedFunction,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: ["Swift.Int", "Swift.Int", "Swift.Int"],
                result: "Swift.Dictionary<Swift.Int, Swift.Array<Swift.Int>>"
            ),
            parameterTypes: [.int64, .int64, .int64],
            resultType: groupedDictionaryType
        )
        let groupedExpected = VM.Value.dictionary(
            [
                .init(
                    key: one,
                    value: .array(
                        [ten, twenty],
                        elementType: .int64
                    )
                ),
            ],
            keyType: .int64,
            valueType: .array(.int64)
        )
        let groupedFrameBytes = UInt64(
            groupedFunction.registerTypes.count
                * MemoryLayout<VM.Value?>.stride
        )
        let groupedExactHeapBytes = groupedFrameBytes
            + 16 // Dictionary builder header.
            + 32 // Key and Array-valued entry slots.
            + 32 // Singleton Array header and first element.
            + 16 // One additional grouped element.
        let groupedExactBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: groupedExactHeapBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: groupedImage,
                arguments: [one, ten, twenty],
                budget: groupedExactBudget
            ) == .returned(groupedExpected)
        )
        let groupedInsufficientBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: groupedExactHeapBytes - 1,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: groupedImage,
                arguments: [one, ten, twenty],
                budget: groupedInsufficientBudget
            ) == .trapped(.vmHeapLimitExceeded)
        )

        let groupedDirect = VM.DictionaryBuilder(
            keyType: .int64,
            valueType: .array(.int64)
        )
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            try groupedDirect.appendArrayElement(
                key: one,
                element: .bool(true),
                matchingIndex: nil
            )
        }
        #expect(throws: VM.RuntimeTrap.invalidProgramCounter) {
            try groupedDirect.appendArrayElement(
                key: one,
                element: ten,
                matchingIndex: 1
            )
        }
        let scalarDirect = VM.DictionaryBuilder(
            keyType: .int64,
            valueType: .int64
        )
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .array(.int64),
                actual: .int64
            )
        ) {
            try scalarDirect.appendArrayElement(
                key: one,
                element: ten,
                matchingIndex: nil
            )
        }

        let direct = VM.DictionaryBuilder(
            keyType: .int64,
            valueType: .int64,
            entries: [.init(key: one, value: ten)]
        )
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .int64,
                actual: .bool
            )
        ) {
            try direct.set(
                key: one,
                value: VM.Value.bool(true),
                matchingIndex: 0
            )
        }
        try direct.set(key: one, value: twenty, matchingIndex: 0)
        try direct.set(key: two, value: thirty, matchingIndex: nil)
        let expectedEntries: [VM.DictionaryEntry] = [
            .init(key: one, value: twenty),
            .init(key: two, value: thirty),
        ]
        #expect(try direct.finish() == expectedEntries)
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try direct.withEntries(\.count)
        }
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try direct.finish()
        }
    }

    @Test("Array builders append Array contents with bounded copied storage")
    func executesArrayBuilderBatchAppend() throws {
        let sourceType = Bytecode.ValueType.array(.int64)
        let builderType = Bytecode.ValueType.arrayState(
            kind: .builder,
            element: .int64
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "batchArrayBuilder",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: sourceType,
            registerTypes: [sourceType, builderType, sourceType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeArrayBuilder(result: .init(rawValue: 1)),
                        .arrayBuilderAppendContents(
                            builder: .init(rawValue: 1),
                            array: .init(rawValue: 0)
                        ),
                        .finishArrayBuilder(
                            result: .init(rawValue: 2),
                            builder: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            capabilities: [.baselineV1, .collectionsV1],
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [sourceType],
            resultType: sourceType
        )
        let first = VM.Value.integer(
            try .init(signed: 3, bitWidth: 64, isSigned: true)
        )
        let second = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )
        let source = VM.Value.array([first, second], elementType: .int64)

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source]
            ) == .returned(source)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.array([], elementType: .int64)]
            ) == .returned(.array([], elementType: .int64))
        )

        let boundaryBytes = UInt64(3 * 16)
        let frameBytes = UInt64(
            function.registerTypes.count * MemoryLayout<VM.Value?>.stride
        )
        let builderHeaderBytes: UInt64 = 16
        let copiedElementBytes = UInt64(2 * 16)
        let exactHeapBytes = boundaryBytes + frameBytes + builderHeaderBytes
            + copiedElementBytes
        let exactBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source],
                budget: exactBudget
            ) == .returned(source)
        )
        let insufficientBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: exactHeapBytes - 1,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source],
                budget: insufficientBudget
            ) == .trapped(.vmHeapLimitExceeded)
        )
    }

    @Test("Array cursors traverse both directions and reject corrupt bounds")
    func executesDirectionalArrayTraversal() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let optionalType = Bytecode.ValueType.optional(.int64)

        func function(
            direction: Bytecode.CollectionTraversalDirection,
            fixedCursor: Int64?
        ) -> Bytecode.Function {
            var instructions: [Bytecode.Instruction] = []
            if let fixedCursor {
                instructions.append(
                    .constantInteger(
                        result: .init(rawValue: 1),
                        bitPattern: UInt64(bitPattern: fixedCursor)
                    )
                )
            } else {
                instructions.append(
                    .arrayCount(
                        result: .init(rawValue: 1),
                        array: .init(rawValue: 0)
                    )
                )
            }
            instructions.append(contentsOf: [
                .storeStack(
                    slot: .init(rawValue: 0),
                    source: .init(rawValue: 1),
                    mode: .initialize
                ),
                .collectionNext(
                    result: .init(rawValue: 2),
                    collection: .init(rawValue: 0),
                    indexSlot: .init(rawValue: 0),
                    direction: direction
                ),
                .destroyStack(.init(rawValue: 0)),
                .returnValue(.init(rawValue: 2)),
            ])
            return .init(
                id: .init(rawValue: 0),
                name: "directionalArrayTraversal",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: optionalType,
                registerTypes: [arrayType, .int64, optionalType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: instructions
                    ),
                ],
                stackSlotTypes: [.int64]
            )
        }

        func image(
            direction: Bytecode.CollectionTraversalDirection,
            fixedCursor: Int64?
        ) throws -> Verification.Image {
            try makeVerified(
                function: function(
                    direction: direction,
                    fixedCursor: fixedCursor
                ),
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(
                    parameters: ["Swift.Array<Swift.Int>"],
                    result: "Swift.Optional<Swift.Int>"
                ),
                parameterTypes: [arrayType],
                resultType: optionalType
            )
        }

        let first = VM.Value.integer(
            try .init(signed: 3, bitWidth: 64, isSigned: true)
        )
        let last = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )
        let values = VM.Value.array([first, last], elementType: .int64)
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(direction: .forward, fixedCursor: 0),
                arguments: [values]
            ) == .returned(.optional(first))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(direction: .reverse, fixedCursor: nil),
                arguments: [values]
            ) == .returned(.optional(last))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(direction: .reverse, fixedCursor: nil),
                arguments: [.array([], elementType: .int64)]
            ) == .returned(.optional(nil))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(direction: .forward, fixedCursor: 2),
                arguments: [values]
            ) == .returned(.optional(nil))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(direction: .reverse, fixedCursor: 0),
                arguments: [values]
            ) == .returned(.optional(nil))
        )
        for direction in [
            Bytecode.CollectionTraversalDirection.forward, .reverse,
        ] {
            for invalidCursor: Int64 in [-1, 3] {
                #expect(
                    VM.Interpreter().invoke(
                        entry: .init(rawValue: 0),
                        image: try image(
                            direction: direction,
                            fixedCursor: invalidCursor
                        ),
                        arguments: [values]
                    ) == .trapped(
                        .collectionCursorOutOfBounds(
                            index: invalidCursor,
                            count: 2
                        )
                    )
                )
            }
        }
    }

    @Test("One managed cursor preserves Dictionary and Set element shapes")
    func executesManagedCollectionTraversal() throws {
        func first(
            collectionType: Bytecode.ValueType,
            elementType: Bytecode.ValueType,
            source: VM.Value
        ) throws -> VM.ExecutionResult {
            let optionalType = Bytecode.ValueType.optional(elementType)
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "managedCollectionTraversal",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: optionalType,
                registerTypes: [collectionType, .int64, optionalType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .constantInteger(
                                result: .init(rawValue: 1),
                                bitPattern: 0
                            ),
                            .storeStack(
                                slot: .init(rawValue: 0),
                                source: .init(rawValue: 1),
                                mode: .initialize
                            ),
                            .collectionNext(
                                result: .init(rawValue: 2),
                                collection: .init(rawValue: 0),
                                indexSlot: .init(rawValue: 0),
                                direction: .forward
                            ),
                            .destroyStack(.init(rawValue: 0)),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ],
                stackSlotTypes: [.int64]
            )
            let image = try makeVerified(
                function: function,
                capabilities: [.baselineV1, .collectionsV1],
                signature: .init(
                    parameters: [collectionType.description],
                    result: optionalType.description
                ),
                parameterTypes: [collectionType],
                resultType: optionalType
            )
            return VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source]
            )
        }

        let key = VM.Value.integer(
            try .init(signed: 3, bitWidth: 64, isSigned: true)
        )
        let value = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )
        #expect(
            try first(
                collectionType: .dictionary(key: .int64, value: .int64),
                elementType: .tuple([.int64, .int64]),
                source: .dictionary(
                    [.init(key: key, value: value)],
                    keyType: .int64,
                    valueType: .int64
                )
            ) == .returned(.optional(.tuple([key, value])))
        )
        #expect(
            try first(
                collectionType: .set(.int64),
                elementType: .int64,
                source: .set(
                    .init(elements: [value], elementType: .int64)
                )
            ) == .returned(.optional(value))
        )
    }

    @Test("Managed Collection materialization preserves element shape and order")
    func materializesManagedCollections() throws {
        func invoke(
            collectionType: Bytecode.ValueType,
            elementType: Bytecode.ValueType,
            source: VM.Value,
            limits: Core.ResourceLimits = .init(
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        ) throws -> VM.ExecutionResult {
            let resultType = Bytecode.ValueType.array(elementType)
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "managedCollectionMaterialization",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: resultType,
                registerTypes: [collectionType, resultType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .collectionMaterialize(
                                result: .init(rawValue: 1),
                                collection: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
            let image = try makeVerified(
                function: function,
                limits: limits,
                capabilities: [.baselineV1, .collectionsV1, .stringsV1],
                signature: .init(
                    parameters: [collectionType.description],
                    result: resultType.description
                ),
                parameterTypes: [collectionType],
                resultType: resultType
            )
            return VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [source]
            )
        }

        let three = VM.Value.integer(
            try .init(signed: 3, bitWidth: 64, isSigned: true)
        )
        let five = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )
        let integers = VM.Value.array(
            [three, five],
            elementType: .int64
        )
        #expect(
            try invoke(
                collectionType: .array(.int64),
                elementType: .int64,
                source: integers
            ) == .returned(integers)
        )
        #expect(
            try invoke(
                collectionType: .set(.int64),
                elementType: .int64,
                source: .set(
                    .init(elements: [five, three], elementType: .int64)
                )
            ) == .returned(
                .array([five, three], elementType: .int64)
            )
        )
        #expect(
            try invoke(
                collectionType: .set(.int64),
                elementType: .int64,
                source: .set(.init(elements: [], elementType: .int64))
            ) == .returned(.array([], elementType: .int64))
        )
        let frameBytes = UInt64(2 * MemoryLayout<VM.Value?>.stride)
        // Boundary storage, duplicate-element validation scratch, and the
        // materialized result each hold the same two-element aggregate.
        let setBoundaryScratchAndResultBytes = UInt64(3 * (2 + 1) * 16)
        let exactSetHeap = frameBytes + setBoundaryScratchAndResultBytes
        let setSource = VM.Value.set(
            .init(elements: [five, three], elementType: .int64)
        )
        #expect(
            try invoke(
                collectionType: .set(.int64),
                elementType: .int64,
                source: setSource,
                limits: .init(
                    maxVMHeapBytes: exactSetHeap - 1,
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            try invoke(
                collectionType: .set(.int64),
                elementType: .int64,
                source: setSource,
                limits: .init(
                    maxVMHeapBytes: exactSetHeap,
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            ) == .returned(.array([five, three], elementType: .int64))
        )

        let firstKey = VM.Value.string("first")
        let secondKey = VM.Value.string("second")
        let dictionaryType = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        #expect(
            try invoke(
                collectionType: dictionaryType,
                elementType: pairType,
                source: .dictionary(
                    [],
                    keyType: .string,
                    valueType: .int64
                )
            ) == .returned(.array([], elementType: pairType))
        )
        #expect(
            try invoke(
                collectionType: dictionaryType,
                elementType: pairType,
                source: .dictionary(
                    [
                        .init(key: firstKey, value: three),
                        .init(key: secondKey, value: five),
                    ],
                    keyType: .string,
                    valueType: .int64
                )
            ) == .returned(
                .array(
                    [
                        .tuple([firstKey, three]),
                        .tuple([secondKey, five]),
                    ],
                    elementType: pairType
                )
            )
        )

        let integerDictionaryType = Bytecode.ValueType.dictionary(
            key: .int64,
            value: .int64
        )
        let integerPairType = Bytecode.ValueType.tuple([.int64, .int64])
        let integerDictionary = VM.Value.dictionary(
            [
                .init(key: three, value: five),
                .init(key: five, value: three),
            ],
            keyType: .int64,
            valueType: .int64
        )
        // Boundary Dictionary storage, duplicate-key scratch, and the output
        // Array of two-field tuples consume 5, 3, and 9 aggregate slots.
        let exactDictionaryHeap = frameBytes + UInt64((5 + 3 + 9) * 16)
        #expect(
            try invoke(
                collectionType: integerDictionaryType,
                elementType: integerPairType,
                source: integerDictionary,
                limits: .init(
                    maxVMHeapBytes: exactDictionaryHeap - 1,
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            ) == .trapped(.vmHeapLimitExceeded)
        )
        #expect(
            try invoke(
                collectionType: integerDictionaryType,
                elementType: integerPairType,
                source: integerDictionary,
                limits: .init(
                    maxVMHeapBytes: exactDictionaryHeap,
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            ) == .returned(
                .array(
                    [
                        .tuple([three, five]),
                        .tuple([five, three]),
                    ],
                    elementType: integerPairType
                )
            )
        )
    }

    @Test("Collection materialization copies native ownership within quota")
    func materializesNativeCollectionOwnership() throws {
        let pointType = Core.TypeID.derive(
            namespace: namespace(),
            canonicalType: "Fixture.MaterializedPoint"
        )
        let layout = Core.Digest.sha256(
            "Fixture.MaterializedPoint.layout.v1"
        )
        let operations = VM.NativeTypeOperations(
            id: pointType,
            canonicalName: "Fixture.MaterializedPoint",
            kind: .value,
            layoutFingerprint: layout,
            estimatedSize: 16,
            estimatedByteCount: { (_: Point) -> UInt64 in 16 }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let boxed = try catalog.box(Point(x: 3, y: 5), as: pointType)
        let native = Bytecode.ValueType.native(pointType)
        let array = Bytecode.ValueType.array(native)
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .collectionsV1,
            .nativeTypesV1,
        ]

        func function(
            name: String,
            collectionType: Bytecode.ValueType,
            resultType: Bytecode.ValueType
        ) -> Bytecode.Function {
            .init(
                id: .init(rawValue: 0),
                name: name,
                parameterRegisters: [.init(rawValue: 0)],
                resultType: resultType,
                registerTypes: [collectionType, resultType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .collectionMaterialize(
                                result: .init(rawValue: 1),
                                collection: .init(rawValue: 0)
                            ),
                            .destroyValue(.init(rawValue: 0)),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
        }

        func image(
            function: Bytecode.Function,
            collectionType: Bytecode.ValueType,
            resultType: Bytecode.ValueType,
            maximumNativeBytes: UInt64
        ) throws -> Verification.Image {
            let limits = Core.ResourceLimits(
                maxNativeOwnedBytes: maximumNativeBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
            return try makeVerified(
                function: function,
                limits: limits,
                capabilities: capabilities,
                signature: .init(
                    parameters: [collectionType.description],
                    result: resultType.description
                ),
                parameterTypes: [collectionType],
                resultType: resultType,
                shellTypes: [
                    .init(
                        id: pointType,
                        canonicalName: "Fixture.MaterializedPoint",
                        kind: .value,
                        layoutFingerprint: layout,
                        isCopyable: true,
                        estimatedSize: 16
                    ),
                ]
            )
        }

        func invoke(
            function: Bytecode.Function,
            collectionType: Bytecode.ValueType,
            resultType: Bytecode.ValueType,
            argument: VM.Value,
            maximumNativeBytes: UInt64
        ) throws -> VM.ExecutionResult {
            VM.Interpreter(nativeTypeCatalog: catalog).invoke(
                entry: .init(rawValue: 0),
                image: try image(
                    function: function,
                    collectionType: collectionType,
                    resultType: resultType,
                    maximumNativeBytes: maximumNativeBytes
                ),
                arguments: [argument]
            )
        }

        let arrayFunction = function(
            name: "materializeNativeArray",
            collectionType: array,
            resultType: array
        )
        let arrayArgument = VM.Value.array(
            [.native(boxed)],
            elementType: native
        )
        #expect(
            try invoke(
                function: arrayFunction,
                collectionType: array,
                resultType: array,
                argument: arrayArgument,
                maximumNativeBytes: 32
            ) == .returned(arrayArgument)
        )
        #expect(
            try invoke(
                function: arrayFunction,
                collectionType: array,
                resultType: array,
                argument: arrayArgument,
                maximumNativeBytes: 31
            ) == .trapped(.nativeOwnedMemoryLimitExceeded)
        )

        let dictionary = Bytecode.ValueType.dictionary(
            key: .int64,
            value: native
        )
        let pair = Bytecode.ValueType.tuple([.int64, native])
        let pairs = Bytecode.ValueType.array(pair)
        let dictionaryFunction = function(
            name: "materializeNativeDictionary",
            collectionType: dictionary,
            resultType: pairs
        )
        let key = VM.Value.integer(
            try .init(signed: 1, bitWidth: 64, isSigned: true)
        )
        let dictionaryArgument = VM.Value.dictionary(
            [.init(key: key, value: .native(boxed))],
            keyType: .int64,
            valueType: native
        )
        let expectedPairs = VM.Value.array(
            [.tuple([key, .native(boxed)])],
            elementType: pair
        )
        #expect(
            try invoke(
                function: dictionaryFunction,
                collectionType: dictionary,
                resultType: pairs,
                argument: dictionaryArgument,
                maximumNativeBytes: 32
            ) == .returned(expectedPairs)
        )
        #expect(
            try invoke(
                function: dictionaryFunction,
                collectionType: dictionary,
                resultType: pairs,
                argument: dictionaryArgument,
                maximumNativeBytes: 31
            ) == .trapped(.nativeOwnedMemoryLimitExceeded)
        )
    }

    @Test("Mutable capture projections update their enclosing local value")
    func executesProjectedMutableCapture() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Pair")
        let pairType = Bytecode.ValueType.local(key)
        let cellType = Bytecode.ValueType.mutableCell(pairType)
        let fieldCellType = Bytecode.ValueType.mutableCell(.int64)
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "projectedMutableCapture",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64, .int64, pairType, cellType, fieldCellType, .int64,
                pairType, .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 2),
                        .makeStruct(
                            result: .init(rawValue: 2),
                            fields: [.init(rawValue: 0), .init(rawValue: 1)]
                        ),
                        .makeMutableCell(
                            result: .init(rawValue: 3),
                            initialValue: .init(rawValue: 2)
                        ),
                        .projectMutableCell(
                            result: .init(rawValue: 4),
                            cell: .init(rawValue: 3),
                            fieldIndex: 0
                        ),
                        .constantInteger(result: .init(rawValue: 5), bitPattern: 9),
                        .storeMutableCell(
                            cell: .init(rawValue: 4),
                            source: .init(rawValue: 5),
                            mode: .assign
                        ),
                        .loadMutableCell(
                            result: .init(rawValue: 6),
                            cell: .init(rawValue: 3)
                        ),
                        .structExtract(
                            result: .init(rawValue: 7),
                            structure: .init(rawValue: 6),
                            fieldIndex: 0
                        ),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: root,
            capabilities: [
                .baselineV1, .localNominalsV1, .mutableCapturesV1,
            ],
            localTypes: [
                .init(
                    key: key,
                    kind: .structure(
                        fields: [
                            .init(name: "first", type: .int64),
                            .init(name: "second", type: .int64),
                        ]
                    )
                ),
            ]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(
                        try .init(signed: 1, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try .init(signed: 9, bitWidth: 64, isSigned: true))
            )
        )

        let tupleType = Bytecode.ValueType.tuple([.int64, .int64])
        let tupleCellType = Bytecode.ValueType.mutableCell(tupleType)
        let tupleRoot = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "projectedMutableTuple",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64, .int64, tupleType, tupleCellType, fieldCellType,
                .int64, tupleType, .int64, .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 2),
                        .makeTuple(
                            result: .init(rawValue: 2),
                            elements: [.init(rawValue: 0), .init(rawValue: 1)]
                        ),
                        .makeMutableCell(
                            result: .init(rawValue: 3),
                            initialValue: .init(rawValue: 2)
                        ),
                        .projectMutableCell(
                            result: .init(rawValue: 4),
                            cell: .init(rawValue: 3),
                            fieldIndex: 1
                        ),
                        .constantInteger(result: .init(rawValue: 5), bitPattern: 11),
                        .storeMutableCell(
                            cell: .init(rawValue: 4),
                            source: .init(rawValue: 5),
                            mode: .assign
                        ),
                        .loadMutableCell(
                            result: .init(rawValue: 6),
                            cell: .init(rawValue: 3)
                        ),
                        .unpackTuple(
                            results: [.init(rawValue: 7), .init(rawValue: 8)],
                            tuple: .init(rawValue: 6)
                        ),
                        .returnValue(.init(rawValue: 8)),
                    ]
                ),
            ]
        )
        let tupleImage = try makeVerified(
            function: tupleRoot,
            capabilities: [.baselineV1, .mutableCapturesV1]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: tupleImage,
                arguments: [
                    .integer(
                        try .init(signed: 1, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try .init(signed: 11, bitWidth: 64, isSigned: true))
            )
        )

        let partiallyInitialized = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "partiallyInitializedMutableTuple",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [
                .int64, tupleCellType, fieldCellType, fieldCellType, .int64,
                tupleType, .int64, .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .makeMutableCell(
                            result: .init(rawValue: 1),
                            initialValue: nil
                        ),
                        .projectMutableCell(
                            result: .init(rawValue: 2),
                            cell: .init(rawValue: 1),
                            fieldIndex: 0
                        ),
                        .projectMutableCell(
                            result: .init(rawValue: 3),
                            cell: .init(rawValue: 1),
                            fieldIndex: 1
                        ),
                        .storeMutableCell(
                            cell: .init(rawValue: 2),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .constantInteger(
                            result: .init(rawValue: 4),
                            bitPattern: 10
                        ),
                        .storeMutableCell(
                            cell: .init(rawValue: 3),
                            source: .init(rawValue: 4),
                            mode: .initialize
                        ),
                        .loadMutableCell(
                            result: .init(rawValue: 5),
                            cell: .init(rawValue: 1)
                        ),
                        .unpackTuple(
                            results: [.init(rawValue: 6), .init(rawValue: 7)],
                            tuple: .init(rawValue: 5)
                        ),
                        .returnValue(.init(rawValue: 6)),
                    ]
                ),
            ]
        )
        let partiallyInitializedImage = try makeVerified(
            function: partiallyInitialized,
            capabilities: [.baselineV1, .mutableCapturesV1]
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: partiallyInitializedImage,
                arguments: [
                    .integer(
                        try .init(signed: 7, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try .init(signed: 7, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Nonescaping closures execute captured Swift value semantics")
    func executesNonescapingClosure() throws {
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "closureRoot",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, closureType, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), bitPattern: 3),
                        .makeClosure(
                            result: .init(rawValue: 2),
                            function: .init(rawValue: 2),
                            captures: [.init(rawValue: 1)]
                        ),
                        .apply(
                            result: .init(rawValue: 3),
                            function: .init(rawValue: 1),
                            arguments: [.init(rawValue: 0), .init(rawValue: 2)]
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let applyTwice = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "applyTwice",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .int64,
            registerTypes: [.int64, closureType, .int64, .int64],
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
                        .closureApply(
                            result: .init(rawValue: 3),
                            closure: .init(rawValue: 1),
                            arguments: [.init(rawValue: 2)]
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let closureBody = Bytecode.Function(
            id: .init(rawValue: 2),
            name: "closureBody",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .add,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [.baselineV1, .closureValuesV1]
        let image = try makeVerified(
            function: root,
            capabilities: capabilities,
            additionalFunctions: [applyTwice, closureBody]
        )
        let input = VM.Value.integer(
            try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )

        let shallowLimits = Core.ResourceLimits(
            maxCallDepth: 2,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let shallowImage = try makeVerified(
            function: root,
            limits: shallowLimits,
            capabilities: capabilities,
            additionalFunctions: [applyTwice, closureBody]
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: shallowImage,
                arguments: [input]
            ) == .trapped(.callDepthExceeded)
        )
    }

    @Test("Borrowed closure arguments remain live in their caller")
    func preservesBorrowedClosureArguments() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.string],
            parameterConventions: [.borrowed],
            result: .string
        )
        let closureType = Bytecode.ValueType.closure(signature)
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "borrowedClosureRoot",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.borrowed],
            resultType: .string,
            registerTypes: [.string, .string, closureType, .string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantString(result: .init(rawValue: 1), value: "!"),
                        .makeClosure(
                            result: .init(rawValue: 2),
                            function: .init(rawValue: 1),
                            captures: [.init(rawValue: 1)]
                        ),
                        .closureApply(
                            result: .init(rawValue: 3),
                            closure: .init(rawValue: 2),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .stringConcat(
                            result: .init(rawValue: 4),
                            lhs: .init(rawValue: 3),
                            rhs: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let closureBody = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "borrowedClosureBody",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            parameterConventions: [.borrowed, .borrowed],
            resultType: .string,
            registerTypes: [.string, .string, .string],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .stringConcat(
                            result: .init(rawValue: 2),
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: root,
            capabilities: [.baselineV1, .stringsV1, .closureValuesV1, .borrowCallsV1],
            signature: .init(
                parameters: ["Swift.String"],
                result: "Swift.String"
            ),
            parameterTypes: [.string],
            resultType: .string,
            additionalFunctions: [closureBody]
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [.string("A")]
            ) == .returned(.string("A!A"))
        )
    }

    @Test("Closure values cannot cross a VM boundary")
    func rejectsClosureBoundaryValue() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        let value = VM.Value.closure(
            .init(functionID: .init(rawValue: 1), signature: signature, captures: [])
        )

        #expect(throws: VM.RuntimeTrap.explicit("closure values cannot cross a VM boundary")) {
            try VM.InvocationBudget(limits: .init()).consumeBoundaryValue(value)
        }
    }

    private struct Point: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    private struct NonHashableValue: Sendable {
        var values: [Int]
    }

    private final class ReferenceToken {
        let label: String

        init(label: String) {
            self.label = label
        }
    }

    @MainActor
    private final class MainActorBox {
        let value: Int

        init(value: Int) { self.value = value }
    }

    private struct MakePointInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 2)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType] = []
        let resultType: Bytecode.ValueType
        let effects = Core.Effects()
        let contract = vmPureImportContract
        let operations: VM.NativeTypeOperations

        init(key: Core.NativeImportKey, operations: VM.NativeTypeOperations) {
            self.key = key
            self.operations = operations
            resultType = .native(operations.id)
        }

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            .returned(.native(try! operations.box(Point(x: 3, y: 4))))
        }
    }

    private struct SumPointInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 3)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType]
        let resultType: Bytecode.ValueType = .int64
        let effects = Core.Effects()
        let contract = vmPureImportContract

        init(key: Core.NativeImportKey, typeID: Core.TypeID) {
            self.key = key
            parameterTypes = [.native(typeID)]
        }

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            guard case let .native(box) = arguments[0],
                  let point = box.value(as: Point.self)
            else { return .businessError("bad Point") }
            return .returned(
                .integer(try! VM.Integer(signed: Int64(point.x + point.y), bitWidth: 64, isSigned: true))
            )
        }
    }

    private struct IncrementInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 0)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType] = [.int64]
        let resultType: Bytecode.ValueType = .int64
        let effects = Core.Effects(hasExternalSideEffects: true)
        let contract = vmWriteImportContract

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            guard case let .integer(value) = arguments[0] else { return .businessError("bad argument") }
            return .returned(.integer(try! VM.Integer(signed: value.signedValue + 1, bitWidth: 64, isSigned: true)))
        }
    }

    private struct MisdeclaredIncrementInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 0)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType] = [.int64]
        let resultType: Bytecode.ValueType = .int64
        let effects = Core.Effects()
        let contract = vmPureImportContract

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            .businessError("descriptor validation must run before this invoker")
        }
    }

    private struct NaNInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 1)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType] = []
        let resultType: Bytecode.ValueType = .float(bitWidth: 64)
        let effects = Core.Effects()
        let contract = vmPureImportContract

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            .returned(.float64(.nan))
        }
    }

    private struct ThrowingInvoker: VM.NativeInvoker {
        let id = Core.NativeImportID(rawValue: 2)
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType] = [.bool]
        let resultType: Bytecode.ValueType = .int64
        let effects = Core.Effects(mayThrow: true)
        let contract = vmPureImportContract

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            guard case let .bool(shouldFail) = arguments.first else {
                return .businessError("invalid fixture argument")
            }
            if shouldFail { return .businessError("fixture failure") }
            return .returned(
                .integer(try! VM.Integer(signed: 7, bitWidth: 64, isSigned: true))
            )
        }
    }

    private func addFunction() -> Bytecode.Function {
        Bytecode.Function(
            id: .init(rawValue: 0),
            name: "add27",
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
    }

    private func shiftFunction(
        operation: Bytecode.BinaryOperation,
        amount: Int64
    ) -> Bytecode.Function {
        Bytecode.Function(
            id: .init(rawValue: 0),
            name: "shift",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: UInt64(bitPattern: amount)
                        ),
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: operation,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
    }

    private func makeNativeIncrementImage() throws -> Verification.Image {
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let effects = Core.Effects(hasExternalSideEffects: true)
        let importKey = try Core.NativeImportKey.derive(
            namespace: namespace(),
            canonicalCallee: "Fixture.increment(_:)",
            signature: signature,
            effects: effects,
            contract: vmWriteImportContract
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 0),
            key: importKey,
            signature: signature,
            effects: effects,
            contract: vmWriteImportContract
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 0),
            key: importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            signature: signature,
            effects: effects,
            contract: vmWriteImportContract
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "native",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeApply(
                            result: .init(rawValue: 1),
                            importID: .init(rawValue: 0),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: effects
        )
        return try makeVerified(
            function: function,
            capabilities: [.baselineV1, .nativeImportsV1],
            imports: [requirement],
            shellImports: [descriptor],
            policy: .init(
                acceptedCapabilities: [.baselineV1, .nativeImportsV1],
                allowedNativeImports: [.init(rawValue: 0)]
            )
        )
    }

    private func namespace() -> Core.ShellNamespaceID {
        .derive(bundleID: "dev.helix.vm", buildNumber: "1", seed: "fixture")
    }

    private final class SequenceClock: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [UInt64]
        private var index = 0

        init(values: [UInt64]) {
            precondition(!values.isEmpty)
            self.values = values
        }

        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }

    private final class TrapDiagnosticBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: VM.TrapDiagnostic?

        var value: VM.TrapDiagnostic? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ diagnostic: VM.TrapDiagnostic) {
            lock.lock()
            storage = diagnostic
            lock.unlock()
        }
    }

    private func makeVerified(
        function: Bytecode.Function,
        limits: Core.ResourceLimits = .init(maxWallTimeMainThreadMilliseconds: 1_000),
        capabilities: Set<Core.Capability> = [.baselineV1],
        imports: [Bytecode.ImportRequirement] = [],
        shellImports: [Verification.ResolvedNativeImport] = [],
        policy: Core.RuntimePolicy? = nil,
        signature: Core.LoweredSignature = .init(parameters: ["Swift.Int"], result: "Swift.Int"),
        parameterTypes: [Bytecode.ValueType] = [.int64],
        resultType: Bytecode.ValueType = .int64,
        shellTypes: [Verification.ResolvedNativeType] = [],
        localTypes: [Bytecode.LocalTypeDefinition] = [],
        additionalFunctions: [Bytecode.Function] = []
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("vm-shell")
        let key = try Core.FunctionKey.derive(
            namespace: namespace(),
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
            compilerFingerprint: "swift-vm-fixture"
        )
        let module = Bytecode.Module(
            name: "VMFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: limits,
            localTypes: localTypes,
            functions: [function] + additionalFunctions,
            entries: [.init(entryIndex: .init(rawValue: 0), functionKey: key, functionID: function.id)],
            imports: imports
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
                    resultType: resultType,
                    effects: function.effects
                ),
            ],
            imports: shellImports,
            types: shellTypes
        )
        let resolvedPolicy = policy ?? Core.RuntimePolicy(
            acceptedCapabilities: capabilities,
            resourceCeiling: limits
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: resolvedPolicy
        )
    }
}
}
