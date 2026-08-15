import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLBC semantic properties")
struct Properties {
    @Test("Seeded integer programs agree with the Swift reference model")
    func integerProgramsMatchReferenceModel() throws {
        var generator = Generator(seed: 0x484c_564d_5052_4f50)

        for caseID in 0..<500 {
            let program = try makeProgram(caseID: caseID, generator: &generator)
            let firstEncoding = try Bytecode.Encoder.encode(program.module)
            #expect(
                firstEncoding == (try Bytecode.Encoder.encode(program.module)),
                Comment(rawValue: "non-canonical encoding for case \(caseID)")
            )
            let image = try Verification.Engine().verify(
                bytes: firstEncoding,
                shell: program.shell,
                policy: .init()
            )
            let input = try VM.Integer(
                signed: program.input,
                bitWidth: 64,
                isSigned: true
            )
            let expected = try VM.Integer(
                signed: program.expected,
                bitWidth: 64,
                isSigned: true
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [.integer(input)]
                ) == .returned(.integer(expected)),
                Comment(rawValue: "reference mismatch for case \(caseID)")
            )
        }
    }

    @Test("Seeded Float32 operations preserve Swift bit patterns")
    func float32OperationsMatchSwiftBitPatterns() throws {
        let floatType = Bytecode.ValueType.float(bitWidth: 32)
        var images: [Bytecode.FloatBinaryOperation: Verification.Image] = [:]
        for operation in [
            Bytecode.FloatBinaryOperation.add,
            .subtract,
            .multiply,
            .divide,
        ] {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "float32_\(operation.rawValue)",
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: floatType,
                registerTypes: [floatType, floatType, floatType],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [
                            .floatingBinary(
                                result: .init(rawValue: 2),
                                operation: operation,
                                lhs: .init(rawValue: 0),
                                rhs: .init(rawValue: 1)
                            ),
                            .returnValue(.init(rawValue: 2)),
                        ]
                    ),
                ]
            )
            images[operation] = try makeVerified(
                function: function,
                signature: .init(
                    parameters: ["Swift.Float", "Swift.Float"],
                    result: "Swift.Float"
                ),
                parameterTypes: [floatType, floatType],
                resultType: floatType,
                capabilities: [.baselineV1]
            )
        }

        var generator = Generator(seed: 0x484c_5846_4c4f_4154)
        for operation in images.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let image = try #require(images[operation])
            var accepted = 0
            while accepted < 400 {
                let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: generator.next()))
                let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: generator.next()))
                guard lhs.isFinite, rhs.isFinite,
                      operation != .divide || rhs != 0
                else { continue }
                let expected: Float = switch operation {
                case .add: lhs + rhs
                case .subtract: lhs - rhs
                case .multiply: lhs * rhs
                case .divide: lhs / rhs
                }
                let result = VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [
                        .float32(lhs),
                        .float32(rhs),
                    ]
                )
                guard case let .returned(.some(.float(actual))) = result,
                      actual.bitWidth == 32
                else {
                    Issue.record("unexpected Float32 result for \(operation): \(result)")
                    accepted += 1
                    continue
                }
                #expect(
                    actual.floatValue.bitPattern == expected.bitPattern,
                    Comment(
                        rawValue: "Float32 \(operation) mismatch for "
                            + "0x\(String(lhs.bitPattern, radix: 16)) and "
                            + "0x\(String(rhs.bitPattern, radix: 16))"
                    )
                )
                accepted += 1
            }
        }
    }

    @Test("HLVM constants retain non-finite payloads at their native width")
    func scalarConstantsRetainRawBits() throws {
        let cases: [(width: UInt16, bitPattern: UInt64)] = [
            (32, 0x7FA1_2345),
            (32, UInt64(Float.infinity.bitPattern)),
            (32, UInt64((-0.0 as Float).bitPattern)),
            (64, 0x7FF0_0000_0000_1234),
            (64, Double.infinity.bitPattern),
            (64, (-0.0 as Double).bitPattern),
        ]
        for (index, item) in cases.enumerated() {
            let type = Bytecode.ValueType.float(bitWidth: item.width)
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "float_constant_\(index)",
                parameterRegisters: [],
                resultType: type,
                registerTypes: [type],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .constantFloat(
                                result: .init(rawValue: 0),
                                bitPattern: item.bitPattern
                            ),
                            .returnValue(.init(rawValue: 0)),
                        ]
                    ),
                ]
            )
            let image = try makeVerified(
                function: function,
                signature: .init(
                    parameters: [],
                    result: item.width == 32 ? "Swift.Float" : "Swift.Double"
                ),
                parameterTypes: [],
                resultType: type,
                capabilities: [.baselineV1]
            )
            guard case let .returned(.some(.float(value))) = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: []
            ) else {
                Issue.record("floating constant did not return its VM scalar")
                continue
            }
            #expect(value.bitWidth == item.width)
            #expect(value.bitPattern == item.bitPattern)
            if item.width == 32 {
                #expect(
                    value.floatValue.isSignalingNaN
                        == Float(bitPattern: UInt32(item.bitPattern)).isSignalingNaN
                )
            } else {
                #expect(
                    value.doubleValue.isSignalingNaN
                        == Double(bitPattern: item.bitPattern).isSignalingNaN
                )
            }
        }

        #expect(throws: VM.RuntimeTrap.invalidFloatingPointWidth(16)) {
            _ = try VM.FloatingValue(bitPattern: 0, bitWidth: 16)
        }
        #expect(
            throws: VM.RuntimeTrap.invalidFloatingPointBitPattern(
                UInt64(UInt32.max) + 1,
                bitWidth: 32
            )
        ) {
            _ = try VM.FloatingValue(
                bitPattern: UInt64(UInt32.max) + 1,
                bitWidth: 32
            )
        }
    }

    @Test("Seeded HLBC 1.0 conversions agree with Swift bit patterns")
    func conversionsMatchSwiftBitPatterns() throws {
        let int8 = Bytecode.ValueType.integer(bitWidth: 8, signed: true)
        let truncation = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "truncateToInt8",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: int8,
            registerTypes: [.int64, int8],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .integerConvert(
                            result: .init(rawValue: 1),
                            operation: .truncate,
                            value: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let truncationImage = try makeVerified(
            function: truncation,
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int8"),
            parameterTypes: [.int64],
            resultType: int8,
            capabilities: [.baselineV1]
        )
        var generator = Generator(seed: 0x484c_5843_4f4e_5631)
        for caseID in 0..<1_000 {
            let raw = Int64(bitPattern: generator.next())
            let expected = Int64(Int8(truncatingIfNeeded: raw))
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: truncationImage,
                    arguments: [
                        .integer(try .init(signed: raw, bitWidth: 64, isSigned: true)),
                    ]
                ) == .returned(
                    .integer(try .init(signed: expected, bitWidth: 8, isSigned: true))
                ),
                Comment(rawValue: "integer truncation mismatch for case \(caseID)")
            )
        }

        let doubleType = Bytecode.ValueType.float(bitWidth: 64)
        let floatType = Bytecode.ValueType.float(bitWidth: 32)
        let floatTruncation = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "truncateToFloat",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: floatType,
            registerTypes: [doubleType, floatType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .floatingConvert(
                            result: .init(rawValue: 1),
                            operation: .truncate,
                            value: .init(rawValue: 0)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let floatImage = try makeVerified(
            function: floatTruncation,
            signature: .init(parameters: ["Swift.Double"], result: "Swift.Float"),
            parameterTypes: [doubleType],
            resultType: floatType,
            capabilities: [.baselineV1]
        )
        for caseID in 0..<1_000 {
            let input = Double(bitPattern: generator.next())
            let expected = Float(input)
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: floatImage,
                arguments: [.float64(input)]
            )
            guard case let .returned(.some(.float(actual))) = result,
                  actual.bitWidth == 32
            else {
                Issue.record("unexpected Float conversion result for case \(caseID): \(result)")
                continue
            }
            #expect(
                actual.floatValue.bitPattern == expected.bitPattern,
                Comment(rawValue: "floating truncation mismatch for case \(caseID)")
            )
        }
    }

    @Test("Seeded Array append programs agree with Swift value semantics")
    func arrayAppendMatchesSwiftReferenceModel() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "append",
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: arrayType,
            registerTypes: [arrayType, .int64, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .arrayAppend(
                            result: .init(rawValue: 2),
                            array: .init(rawValue: 0),
                            value: .init(rawValue: 1)
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64],
            resultType: arrayType,
            capabilities: [.baselineV1, .collectionsV1]
        )
        var generator = Generator(seed: 0x484c_5841_5252_4159)

        for caseID in 0..<300 {
            let count = Int(generator.next() % 13)
            let source = (0..<count).map { _ in generator.integer(in: -50...50) }
            let appended = generator.integer(in: -50...50)
            let input = try source.map(integerValue)
            let expected = try (source + [appended]).map(integerValue)
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [
                        .array(input, elementType: .int64),
                        try integerValue(appended),
                    ]
                ) == .returned(.array(expected, elementType: .int64)),
                Comment(rawValue: "Array value mismatch for case \(caseID)")
            )
        }
    }

    @Test("Seeded Array updates agree with Swift value semantics")
    func arrayUpdatesMatchSwiftReferenceModel() throws {
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
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int", "Swift.Int"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64, .int64],
            resultType: arrayType,
            capabilities: [.baselineV1, .collectionsV1]
        )
        var generator = Generator(seed: 0x484c_5841_5550_4431)
        for caseID in 0..<500 {
            let count = Int(generator.next() % 32) + 1
            let index = Int(generator.next() % UInt64(count))
            let replacement = generator.integer(in: -1_000...1_000)
            let source = (0..<count).map { _ in generator.integer(in: -1_000...1_000) }
            var expected = source
            expected[index] = replacement
            let input = try source.map(integerValue)
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [
                        .array(input, elementType: .int64),
                        try integerValue(Int64(index)),
                        try integerValue(replacement),
                    ]
                ) == .returned(
                    .array(try expected.map(integerValue), elementType: .int64)
                ),
                Comment(rawValue: "Array update mismatch for case \(caseID)")
            )
            #expect(
                input == (try source.map(integerValue)),
                Comment(rawValue: "Array input mutated for case \(caseID)")
            )
        }
    }

    @Test("Seeded Dictionary updates agree with Swift lookup and value semantics")
    func dictionaryUpdatesMatchSwiftReferenceModel() throws {
        let dictionaryType = Bytecode.ValueType.dictionary(key: .string, value: .int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "update",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: dictionaryType,
            registerTypes: [
                dictionaryType, .string, .optional(.int64), dictionaryType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
                    ],
                    instructions: [
                        .dictionaryUpdate(
                            result: .init(rawValue: 3),
                            dictionary: .init(rawValue: 0),
                            key: .init(rawValue: 1),
                            value: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let image = try makeVerified(
            function: function,
            signature: .init(
                parameters: [
                    "Swift.Dictionary<Swift.String, Swift.Int>",
                    "Swift.String",
                    "Swift.Optional<Swift.Int>",
                ],
                result: "Swift.Dictionary<Swift.String, Swift.Int>"
            ),
            parameterTypes: [dictionaryType, .string, .optional(.int64)],
            resultType: dictionaryType,
            capabilities: [.baselineV1, .stringsV1, .collectionsV1]
        )
        var generator = Generator(seed: 0x484c_5844_4943_5421)

        for caseID in 0..<300 {
            let count = Int(generator.next() % 9)
            var source: [String: Int64] = [:]
            for index in 0..<count {
                source["k\(index)"] = generator.integer(in: -50...50)
            }
            let key = "k\(generator.next() % 12)"
            let shouldDelete = generator.next() & 1 == 0
            let update = generator.integer(in: -50...50)
            var expected = source
            if shouldDelete {
                expected.removeValue(forKey: key)
            } else {
                expected[key] = update
            }
            let entries = try source.sorted(by: { $0.key < $1.key }).map {
                VM.DictionaryEntry(key: .string($0.key), value: try integerValue($0.value))
            }
            let updateValue: VM.Value = shouldDelete
                ? .optional(nil)
                : .optional(try integerValue(update))
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .dictionary(entries, keyType: .string, valueType: .int64),
                    .string(key),
                    updateValue,
                ]
            )
            guard case let .returned(.some(.dictionary(actualEntries, _, _))) = result else {
                Issue.record("unexpected Dictionary result for case \(caseID): \(result)")
                continue
            }
            var actual: [String: Int64] = [:]
            for entry in actualEntries {
                guard case let .string(actualKey) = entry.key,
                      case let .integer(actualValue) = entry.value
                else {
                    Issue.record("malformed Dictionary entry for case \(caseID)")
                    continue
                }
                actual[actualKey] = actualValue.signedValue
            }
            #expect(
                actual == expected,
                Comment(rawValue: "Dictionary value mismatch for case \(caseID)")
            )
            #expect(
                Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                    guard case let .string(key) = entry.key,
                          case let .integer(value) = entry.value
                    else { return nil }
                    return (key, value.signedValue)
                }) == source,
                Comment(rawValue: "Dictionary input mutated for case \(caseID)")
            )
        }
    }

    private struct Program {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var input: Int64
        var expected: Int64
    }

    private func integerValue(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }

    private func makeVerified(
        function: Bytecode.Function,
        signature: Core.LoweredSignature,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        capabilities: Set<Core.Capability>
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("vm-collection-property-shell-\(function.name)")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.vm-properties",
            buildNumber: "1",
            seed: function.name
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "PropertyFixture",
            sourceFileLogicalID: "Sources/PropertyFixture.swift",
            canonicalDeclaration: "func \(function.name)",
            loweredSignature: signature,
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-vm-property-fixture"
        )
        let module = Bytecode.Module(
            name: "VMPropertyFixture-\(function.name)",
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
                    parameterTypes: parameterTypes,
                    resultType: resultType
                ),
            ]
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
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

        mutating func integer(in range: ClosedRange<Int64>) -> Int64 {
            let width = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int64(next() % width)
        }
    }

    private func makeProgram(
        caseID: Int,
        generator: inout Generator
    ) throws -> Program {
        let input = generator.integer(in: -50...50)
        let operationCount = Int(generator.next() % 12) + 1
        var expected = input
        var registerTypes: [Bytecode.ValueType] = [.int64]
        var instructions: [Bytecode.Instruction] = []
        var current = Bytecode.Register(rawValue: 0)

        for _ in 0..<operationCount {
            let literalValue = generator.integer(in: -3...3)
            let literal = Bytecode.Register(rawValue: UInt32(registerTypes.count))
            registerTypes.append(.int64)
            let result = Bytecode.Register(rawValue: UInt32(registerTypes.count))
            registerTypes.append(.int64)
            let overflow = Bytecode.Register(rawValue: UInt32(registerTypes.count))
            registerTypes.append(.bool)
            let operation: Bytecode.BinaryOperation
            switch generator.next() % 3 {
            case 0:
                operation = .add
                expected += literalValue
            case 1:
                operation = .subtract
                expected -= literalValue
            default:
                operation = .multiply
                expected *= literalValue
            }
            instructions.append(
                .constantInteger(
                    result: literal,
                    bitPattern: UInt64(bitPattern: literalValue)
                )
            )
            instructions.append(
                .checkedBinary(
                    result: result,
                    overflow: overflow,
                    operation: operation,
                    lhs: current,
                    rhs: literal
                )
            )
            current = result
        }
        instructions.append(.returnValue(current))

        let shellHash = Core.Digest.sha256("vm-property-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.vm-properties",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "PropertyFixture",
            sourceFileLogicalID: "Sources/PropertyFixture.swift",
            canonicalDeclaration: "func evaluate(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "evaluate_case_\(caseID)",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: registerTypes,
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: instructions
                ),
            ]
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-vm-property-fixture"
        )
        let module = Bytecode.Module(
            name: "VMPropertyFixture\(caseID)",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
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
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        return .init(module: module, shell: shell, input: input, expected: expected)
    }
}
}
