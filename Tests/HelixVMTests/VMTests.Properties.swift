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
            .remainder,
            .truncatingRemainder,
            .minimum,
            .maximum,
            .minimumMagnitude,
            .maximumMagnitude,
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
                      ![.divide, .remainder, .truncatingRemainder]
                        .contains(operation) || rhs != 0
                else { continue }
                let expected: Float = switch operation {
                case .add: lhs + rhs
                case .subtract: lhs - rhs
                case .multiply: lhs * rhs
                case .divide: lhs / rhs
                case .remainder: lhs.remainder(dividingBy: rhs)
                case .truncatingRemainder:
                    lhs.truncatingRemainder(dividingBy: rhs)
                case .minimum: Float.minimum(lhs, rhs)
                case .maximum: Float.maximum(lhs, rhs)
                case .minimumMagnitude:
                    Float.minimumMagnitude(lhs, rhs)
                case .maximumMagnitude:
                    Float.maximumMagnitude(lhs, rhs)
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

    @Test("Floating scalar transforms and predicates agree with Swift")
    func floatingScalarOperationsMatchSwift() throws {
        func transformImage(
            width: UInt16,
            operation: Bytecode.FloatUnaryOperation
        ) throws -> Verification.Image {
            let type = Bytecode.ValueType.float(bitWidth: width)
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "float_\(width)_\(operation.rawValue)",
                    parameterRegisters: [.init(rawValue: 0)],
                    resultType: type,
                    registerTypes: [type, type],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [.init(rawValue: 0)],
                            instructions: [
                                .floatingUnary(
                                    result: .init(rawValue: 1),
                                    operation: operation,
                                    operand: .init(rawValue: 0)
                                ),
                                .returnValue(.init(rawValue: 1)),
                            ]
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [type.description],
                    result: type.description
                ),
                parameterTypes: [type],
                resultType: type,
                capabilities: [.baselineV1]
            )
        }

        func predicateImage(
            width: UInt16,
            operation: Bytecode.FloatPredicateOperation
        ) throws -> Verification.Image {
            let type = Bytecode.ValueType.float(bitWidth: width)
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "float_\(width)_\(operation.rawValue)",
                    parameterRegisters: [.init(rawValue: 0)],
                    resultType: .bool,
                    registerTypes: [type, .bool],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [.init(rawValue: 0)],
                            instructions: [
                                .floatingPredicate(
                                    result: .init(rawValue: 1),
                                    operation: operation,
                                    operand: .init(rawValue: 0)
                                ),
                                .returnValue(.init(rawValue: 1)),
                            ]
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [type.description],
                    result: "Swift.Bool"
                ),
                parameterTypes: [type],
                resultType: .bool,
                capabilities: [.baselineV1]
            )
        }

        let transforms: [Bytecode.FloatUnaryOperation] = [
            .negate, .absolute, .squareRoot, .ulp, .nextUp, .binade, .significand,
            .roundDown, .roundUp, .roundTowardZero, .roundAwayFromZero,
            .roundToNearestOrAwayFromZero, .roundToNearestOrEven,
        ]
        let floatInputs: [Float] = [
            -2.5, -0.3, -0.0, 0, 2.5, .infinity,
            Float(bitPattern: 0xFFA1_2345),
        ]
        for operation in transforms {
            let image = try transformImage(width: 32, operation: operation)
            for input in floatInputs {
                let expected: Float = switch operation {
                case .negate: -input
                case .absolute: abs(input)
                case .squareRoot: input.squareRoot()
                case .ulp: input.ulp
                case .nextUp: input.nextUp
                case .binade: input.binade
                case .significand: input.significand
                case .roundDown: input.rounded(.down)
                case .roundUp: input.rounded(.up)
                case .roundTowardZero: input.rounded(.towardZero)
                case .roundAwayFromZero: input.rounded(.awayFromZero)
                case .roundToNearestOrAwayFromZero:
                    input.rounded(.toNearestOrAwayFromZero)
                case .roundToNearestOrEven: input.rounded(.toNearestOrEven)
                }
                guard case let .returned(.some(.float(actual))) = VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [.float32(input)]
                ) else {
                    Issue.record("Float32 \(operation) did not return a scalar")
                    continue
                }
                #expect(actual.floatValue.bitPattern == expected.bitPattern)
            }
        }

        let doubleInputs: [Double] = [
            -2.5, -0.3, -0.0, 0, 2.5, .infinity,
            Double(bitPattern: 0xFFF0_0000_0000_1234),
        ]
        for operation in transforms {
            let image = try transformImage(width: 64, operation: operation)
            for input in doubleInputs {
                let expected: Double = switch operation {
                case .negate: -input
                case .absolute: abs(input)
                case .squareRoot: input.squareRoot()
                case .ulp: input.ulp
                case .nextUp: input.nextUp
                case .binade: input.binade
                case .significand: input.significand
                case .roundDown: input.rounded(.down)
                case .roundUp: input.rounded(.up)
                case .roundTowardZero: input.rounded(.towardZero)
                case .roundAwayFromZero: input.rounded(.awayFromZero)
                case .roundToNearestOrAwayFromZero:
                    input.rounded(.toNearestOrAwayFromZero)
                case .roundToNearestOrEven: input.rounded(.toNearestOrEven)
                }
                guard case let .returned(.some(.float(actual))) = VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: image,
                    arguments: [.float64(input)]
                ) else {
                    Issue.record("Float64 \(operation) did not return a scalar")
                    continue
                }
                #expect(actual.doubleValue.bitPattern == expected.bitPattern)
            }
        }

        let predicates: [Bytecode.FloatPredicateOperation] = [
            .isFinite, .isInfinite, .isNaN, .isSignalingNaN,
            .isNormal, .isSubnormal, .isZero, .isSignMinus, .isCanonical,
        ]
        let predicateValues: [VM.FloatingValue] = [
            .init(-0.0 as Float),
            .init(Float.leastNonzeroMagnitude),
            .init(Float.infinity),
            try .init(bitPattern: 0x7FA1_2345, bitWidth: 32),
            .init(-0.0 as Double),
            .init(Double.leastNonzeroMagnitude),
            .init(Double.infinity),
            try .init(bitPattern: 0xFFF0_0000_0000_1234, bitWidth: 64),
        ]
        for operation in predicates {
            for value in predicateValues {
                let image = try predicateImage(
                    width: value.bitWidth,
                    operation: operation
                )
                let expected: Bool
                if value.bitWidth == 32 {
                    let scalar = value.floatValue
                    expected = switch operation {
                    case .isFinite: scalar.isFinite
                    case .isInfinite: scalar.isInfinite
                    case .isNaN: scalar.isNaN
                    case .isSignalingNaN: scalar.isSignalingNaN
                    case .isNormal: scalar.isNormal
                    case .isSubnormal: scalar.isSubnormal
                    case .isZero: scalar.isZero
                    case .isSignMinus: scalar.bitPattern >> 31 == 1
                    case .isCanonical: scalar.isCanonical
                    }
                } else {
                    let scalar = value.doubleValue
                    expected = switch operation {
                    case .isFinite: scalar.isFinite
                    case .isInfinite: scalar.isInfinite
                    case .isNaN: scalar.isNaN
                    case .isSignalingNaN: scalar.isSignalingNaN
                    case .isNormal: scalar.isNormal
                    case .isSubnormal: scalar.isSubnormal
                    case .isZero: scalar.isZero
                    case .isSignMinus: scalar.bitPattern >> 63 == 1
                    case .isCanonical: scalar.isCanonical
                    }
                }
                #expect(
                    VM.Interpreter().invoke(
                        entry: .init(rawValue: 0),
                        image: image,
                        arguments: [.float(value)]
                    ) == .returned(.bool(expected))
                )
            }
        }
    }

    @Test("Floating decomposition, FMA, and total order agree with Swift")
    func advancedFloatingOperationsMatchSwift() throws {
        func image(width: UInt16) throws -> Verification.Image {
            let float = Bytecode.ValueType.float(bitWidth: width)
            let uint64 = Bytecode.ValueType.integer(
                bitWidth: 64,
                signed: false
            )
            let significandBits = Bytecode.ValueType.integer(
                bitWidth: width,
                signed: false
            )
            let result = Bytecode.ValueType.tuple([
                float, .bool, .int64, uint64, significandBits, .int64,
            ])
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "advancedFloat\(width)",
                    parameterRegisters: [
                        .init(rawValue: 0),
                        .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    resultType: result,
                    registerTypes: [
                        float, float, float, float, .bool, .int64, uint64,
                        significandBits, .int64, result,
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
                                .floatingTernary(
                                    result: .init(rawValue: 3),
                                    operation: .fusedMultiplyAdd,
                                    multiplicand: .init(rawValue: 0),
                                    multiplier: .init(rawValue: 1),
                                    addend: .init(rawValue: 2)
                                ),
                                .floatingBinaryPredicate(
                                    result: .init(rawValue: 4),
                                    operation: .isTotallyOrderedBelowOrEqual,
                                    lhs: .init(rawValue: 0),
                                    rhs: .init(rawValue: 1)
                                ),
                                .floatingIntegerProperty(
                                    result: .init(rawValue: 5),
                                    operation: .exponent,
                                    operand: .init(rawValue: 0)
                                ),
                                .floatingIntegerProperty(
                                    result: .init(rawValue: 6),
                                    operation: .exponentBitPattern,
                                    operand: .init(rawValue: 0)
                                ),
                                .floatingIntegerProperty(
                                    result: .init(rawValue: 7),
                                    operation: .significandBitPattern,
                                    operand: .init(rawValue: 0)
                                ),
                                .floatingIntegerProperty(
                                    result: .init(rawValue: 8),
                                    operation: .significandWidth,
                                    operand: .init(rawValue: 0)
                                ),
                                .makeTuple(
                                    result: .init(rawValue: 9),
                                    elements: [
                                        .init(rawValue: 3),
                                        .init(rawValue: 4),
                                        .init(rawValue: 5),
                                        .init(rawValue: 6),
                                        .init(rawValue: 7),
                                        .init(rawValue: 8),
                                    ]
                                ),
                                .returnValue(.init(rawValue: 9)),
                            ]
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [float.description, float.description, float.description],
                    result: result.description
                ),
                parameterTypes: [float, float, float],
                resultType: result,
                capabilities: [.baselineV1]
            )
        }

        let floatImage = try image(width: 32)
        let floatCases: [(Float, Float, Float)] = [
            (1.25, 2.5, -3),
            (-0.0, 0.0, 1),
            (Float(bitPattern: 0x7FA1_2345), 1, 0),
        ]
        for (lhs, rhs, addend) in floatCases {
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: floatImage,
                arguments: [.float32(lhs), .float32(rhs), .float32(addend)]
            )
            guard case let .returned(.some(.tuple(values))) = result,
                  values.count == 6,
                  case let .float(fma) = values[0]
            else {
                Issue.record("unexpected advanced Float32 result: \(result)")
                continue
            }
            #expect(
                fma.bitPattern
                    == UInt64(addend.addingProduct(lhs, rhs).bitPattern)
            )
            #expect(
                values[1]
                    == .bool(lhs.isTotallyOrdered(belowOrEqualTo: rhs))
            )
            #expect(values[2] == .integer(try .init(
                signed: Int64(lhs.exponent),
                bitWidth: 64,
                isSigned: true
            )))
            #expect(values[3] == .integer(try .init(
                rawBits: UInt64(lhs.exponentBitPattern),
                bitWidth: 64,
                isSigned: false
            )))
            #expect(values[4] == .integer(try .init(
                rawBits: UInt64(lhs.significandBitPattern),
                bitWidth: 32,
                isSigned: false
            )))
            #expect(values[5] == .integer(try .init(
                signed: Int64(lhs.significandWidth),
                bitWidth: 64,
                isSigned: true
            )))
        }

        let doubleImage = try image(width: 64)
        let doubleCases: [(Double, Double, Double)] = [
            (1.25, 2.5, -3),
            (-0.0, 0.0, 1),
            (Double(bitPattern: 0xFFF0_0000_0000_1234), 1, 0),
        ]
        for (lhs, rhs, addend) in doubleCases {
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: doubleImage,
                arguments: [.float64(lhs), .float64(rhs), .float64(addend)]
            )
            guard case let .returned(.some(.tuple(values))) = result,
                  values.count == 6,
                  case let .float(fma) = values[0]
            else {
                Issue.record("unexpected advanced Float64 result: \(result)")
                continue
            }
            #expect(fma.bitPattern == addend.addingProduct(lhs, rhs).bitPattern)
            #expect(
                values[1]
                    == .bool(lhs.isTotallyOrdered(belowOrEqualTo: rhs))
            )
            #expect(values[2] == .integer(try .init(
                signed: Int64(lhs.exponent),
                bitWidth: 64,
                isSigned: true
            )))
            #expect(values[3] == .integer(try .init(
                rawBits: UInt64(lhs.exponentBitPattern),
                bitWidth: 64,
                isSigned: false
            )))
            #expect(values[4] == .integer(try .init(
                rawBits: lhs.significandBitPattern,
                bitWidth: 64,
                isSigned: false
            )))
            #expect(values[5] == .integer(try .init(
                signed: Int64(lhs.significandWidth),
                bitWidth: 64,
                isSigned: true
            )))
        }
    }

    @Test("Scalar bitcasts preserve every IEEE payload bit")
    func scalarBitcastsPreservePayloads() throws {
        func image(width: UInt16) throws -> Verification.Image {
            let floating = Bytecode.ValueType.float(bitWidth: width)
            let integer = Bytecode.ValueType.integer(
                bitWidth: width,
                signed: false
            )
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "bitcast_\(width)",
                    parameterRegisters: [.init(rawValue: 0)],
                    resultType: floating,
                    registerTypes: [floating, integer, floating],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [.init(rawValue: 0)],
                            instructions: [
                                .scalarBitCast(
                                    result: .init(rawValue: 1),
                                    operand: .init(rawValue: 0)
                                ),
                                .scalarBitCast(
                                    result: .init(rawValue: 2),
                                    operand: .init(rawValue: 1)
                                ),
                                .returnValue(.init(rawValue: 2)),
                            ]
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [floating.description],
                    result: floating.description
                ),
                parameterTypes: [floating],
                resultType: floating,
                capabilities: [.baselineV1]
            )
        }

        let values: [VM.FloatingValue] = [
            try .init(bitPattern: 0x8000_0000, bitWidth: 32),
            try .init(bitPattern: 0x7FA1_2345, bitWidth: 32),
            try .init(bitPattern: 0x8000_0000_0000_0000, bitWidth: 64),
            try .init(bitPattern: 0xFFF0_0000_0000_1234, bitWidth: 64),
        ]
        for value in values {
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(width: value.bitWidth),
                arguments: [.float(value)]
            )
            guard case let .returned(.some(.float(actual))) = result else {
                Issue.record("scalar bitcast did not return a float: \(result)")
                continue
            }
            #expect(actual.bitWidth == value.bitWidth)
            #expect(actual.bitPattern == value.bitPattern)
        }
    }

    @Test("Integer unary operations preserve width and signedness contracts")
    func integerUnaryOperationsMatchSwift() throws {
        func image(
            sourceType: Bytecode.ValueType,
            includeSignum: Bool
        ) throws -> Verification.Image {
            guard case let .integer(width, _) = sourceType else {
                throw VM.RuntimeTrap.invalidIntegerWidth(0)
            }
            let magnitudeType = Bytecode.ValueType.integer(
                bitWidth: width,
                signed: false
            )
            let operations: [Bytecode.IntegerUnaryOperation] = [
                .magnitude, .nonzeroBitCount, .leadingZeroBitCount,
                .trailingZeroBitCount, .byteSwapped,
            ] + (includeSignum ? [.signum] : [])
            let resultTypes = [magnitudeType]
                + Array(repeating: sourceType, count: operations.count - 1)
            let tupleType = Bytecode.ValueType.tuple(resultTypes)
            let tuple = Bytecode.Register(rawValue: UInt32(operations.count + 1))
            var instructions = operations.enumerated().map { index, operation in
                Bytecode.Instruction.integerUnary(
                    result: .init(rawValue: UInt32(index + 1)),
                    operation: operation,
                    operand: .init(rawValue: 0)
                )
            }
            instructions.append(
                .makeTuple(
                    result: tuple,
                    elements: operations.indices.map {
                        .init(rawValue: UInt32($0 + 1))
                    }
                )
            )
            instructions.append(.returnValue(tuple))
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "integer_unary_\(sourceType)",
                    parameterRegisters: [.init(rawValue: 0)],
                    resultType: tupleType,
                    registerTypes: [sourceType] + resultTypes + [tupleType],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [.init(rawValue: 0)],
                            instructions: instructions
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [sourceType.description],
                    result: tupleType.description
                ),
                parameterTypes: [sourceType],
                resultType: tupleType,
                capabilities: [.baselineV1]
            )
        }

        let cases: [(type: Bytecode.ValueType, raw: UInt64)] = [
            (.integer(bitWidth: 8, signed: true), 0x81),
            (.integer(bitWidth: 16, signed: true), 0x8001),
            (.integer(bitWidth: 32, signed: false), 0x0100_0010),
            (.integer(bitWidth: 64, signed: false), 0x8000_0000_0000_0001),
        ]
        for item in cases {
            guard case let .integer(width, signed) = item.type else { continue }
            let source = try VM.Integer(
                rawBits: item.raw,
                bitWidth: width,
                isSigned: signed
            )
            let fixture = try image(sourceType: item.type, includeSignum: signed)

            func integer(raw: UInt64, signed resultSigned: Bool) throws -> VM.Value {
                .integer(
                    try .init(
                        rawBits: raw,
                        bitWidth: width,
                        isSigned: resultSigned
                    )
                )
            }

            let magnitude = signed && source.signedValue < 0
                ? (0 &- source.rawBits) & VM.Integer.mask(for: width)
                : source.rawBits
            let byteSwapped: UInt64 = switch width {
            case 8: source.rawBits
            case 16: UInt64(UInt16(truncatingIfNeeded: source.rawBits).byteSwapped)
            case 32: UInt64(UInt32(truncatingIfNeeded: source.rawBits).byteSwapped)
            default: source.rawBits.byteSwapped
            }
            var expected: [VM.Value] = [
                try integer(raw: magnitude, signed: false),
                try integer(raw: UInt64(source.rawBits.nonzeroBitCount), signed: signed),
                try integer(
                    raw: UInt64(source.rawBits.leadingZeroBitCount - (64 - Int(width))),
                    signed: signed
                ),
                try integer(
                    raw: UInt64(min(source.rawBits.trailingZeroBitCount, Int(width))),
                    signed: signed
                ),
                try integer(raw: byteSwapped, signed: signed),
            ]
            if signed {
                expected.append(
                    try integer(
                        raw: UInt64(bitPattern: source.signedValue < 0 ? -1 : 1),
                        signed: true
                    )
                )
            }
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture,
                    arguments: [.integer(source)]
                ) == .returned(.tuple(expected))
            )

            let zero = try VM.Integer(rawBits: 0, bitWidth: width, isSigned: signed)
            guard case let .returned(.some(.tuple(zeroValues))) = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture,
                arguments: [.integer(zero)]
            ) else {
                Issue.record("integer unary zero case did not return a tuple")
                continue
            }
            #expect(zeroValues[2] == (try integer(raw: UInt64(width), signed: signed)))
            #expect(zeroValues[3] == (try integer(raw: UInt64(width), signed: signed)))
        }
    }

    @Test("Checked division reports exceptional arithmetic without trapping")
    func checkedDivisionReportsExceptionalArithmetic() throws {
        func image(
            type: Bytecode.ValueType,
            operation: Bytecode.BinaryOperation
        ) throws -> Verification.Image {
            let tuple = Bytecode.ValueType.tuple([type, .bool])
            return try makeVerified(
                function: .init(
                    id: .init(rawValue: 0),
                    name: "reporting_\(operation.rawValue)",
                    parameterRegisters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    resultType: tuple,
                    registerTypes: [type, type, type, .bool, tuple],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [
                                .init(rawValue: 0), .init(rawValue: 1),
                            ],
                            instructions: [
                                .checkedBinary(
                                    result: .init(rawValue: 2),
                                    overflow: .init(rawValue: 3),
                                    operation: operation,
                                    lhs: .init(rawValue: 0),
                                    rhs: .init(rawValue: 1)
                                ),
                                .makeTuple(
                                    result: .init(rawValue: 4),
                                    elements: [
                                        .init(rawValue: 2),
                                        .init(rawValue: 3),
                                    ]
                                ),
                                .returnValue(.init(rawValue: 4)),
                            ]
                        ),
                    ]
                ),
                signature: .init(
                    parameters: [type.description, type.description],
                    result: tuple.description
                ),
                parameterTypes: [type, type],
                resultType: tuple,
                capabilities: [.baselineV1]
            )
        }

        let signed = Bytecode.ValueType.integer(bitWidth: 8, signed: true)
        let signedCases: [(
            Bytecode.BinaryOperation,
            Int64,
            Int64,
            Int64,
            Bool
        )] = [
            (.divide, 7, 0, 7, true),
            (.remainder, 7, 0, 7, true),
            (.divide, -128, -1, -128, true),
            (.remainder, -128, -1, 0, true),
            (.divide, 7, 3, 2, false),
            (.remainder, 7, 3, 1, false),
        ]
        for (operation, lhs, rhs, partial, overflow) in signedCases {
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: try image(type: signed, operation: operation),
                arguments: [
                    .integer(
                        try .init(
                            signed: lhs,
                            bitWidth: 8,
                            isSigned: true
                        )
                    ),
                    .integer(
                        try .init(
                            signed: rhs,
                            bitWidth: 8,
                            isSigned: true
                        )
                    ),
                ]
            )
            #expect(
                result == .returned(
                    .tuple([
                        .integer(
                            try .init(
                                signed: partial,
                                bitWidth: 8,
                                isSigned: true
                            )
                        ),
                        .bool(overflow),
                    ])
                )
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

    @Test("Seeded Array range replacement and swap agree with Swift")
    func arrayStructuralEditsMatchSwiftReferenceModel() throws {
        let arrayType = Bytecode.ValueType.array(.int64)
        let replacementFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "replaceSubrange",
            parameterRegisters: (0..<4).map {
                .init(rawValue: UInt32($0))
            },
            resultType: arrayType,
            registerTypes: [arrayType, .int64, .int64, arrayType, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: (0..<4).map {
                        .init(rawValue: UInt32($0))
                    },
                    instructions: [
                        .arrayReplaceSubrange(
                            result: .init(rawValue: 4),
                            array: .init(rawValue: 0),
                            lowerBound: .init(rawValue: 1),
                            upperBound: .init(rawValue: 2),
                            replacement: .init(rawValue: 3)
                        ),
                        .returnValue(.init(rawValue: 4)),
                    ]
                ),
            ]
        )
        let replacementImage = try makeVerified(
            function: replacementFunction,
            signature: .init(
                parameters: [
                    "Swift.Array<Swift.Int>",
                    "Swift.Int",
                    "Swift.Int",
                    "Swift.Array<Swift.Int>",
                ],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64, .int64, arrayType],
            resultType: arrayType,
            capabilities: [.baselineV1, .collectionsV1]
        )
        let swapFunction = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "swapAt",
            parameterRegisters: (0..<3).map {
                .init(rawValue: UInt32($0))
            },
            resultType: arrayType,
            registerTypes: [arrayType, .int64, .int64, arrayType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: (0..<3).map {
                        .init(rawValue: UInt32($0))
                    },
                    instructions: [
                        .arraySwap(
                            result: .init(rawValue: 3),
                            array: .init(rawValue: 0),
                            lhsIndex: .init(rawValue: 1),
                            rhsIndex: .init(rawValue: 2)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let swapImage = try makeVerified(
            function: swapFunction,
            signature: .init(
                parameters: [
                    "Swift.Array<Swift.Int>", "Swift.Int", "Swift.Int",
                ],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64, .int64],
            resultType: arrayType,
            capabilities: [.baselineV1, .collectionsV1]
        )
        var generator = Generator(seed: 0x484c_5852_4550_4c43)

        for caseID in 0..<300 {
            let sourceCount = Int(generator.next() % 13)
            let source = (0..<sourceCount).map { _ in
                generator.integer(in: -50...50)
            }
            let lower = Int(generator.next() % UInt64(sourceCount + 1))
            let upper = lower + Int(
                generator.next() % UInt64(sourceCount - lower + 1)
            )
            let replacementCount = Int(generator.next() % 8)
            let replacement = (0..<replacementCount).map { _ in
                generator.integer(in: -50...50)
            }
            var expected = source
            expected.replaceSubrange(lower..<upper, with: replacement)
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: replacementImage,
                    arguments: [
                        .array(try source.map(integerValue), elementType: .int64),
                        try integerValue(Int64(lower)),
                        try integerValue(Int64(upper)),
                        .array(
                            try replacement.map(integerValue),
                            elementType: .int64
                        ),
                    ]
                ) == .returned(
                    .array(try expected.map(integerValue), elementType: .int64)
                ),
                Comment(rawValue: "Array replacement mismatch for case \(caseID)")
            )

            let swapCount = Int(generator.next() % 12) + 1
            var swapped = (0..<swapCount).map { _ in
                generator.integer(in: -50...50)
            }
            let lhs = Int(generator.next() % UInt64(swapCount))
            let rhs = Int(generator.next() % UInt64(swapCount))
            let swapInput = swapped
            swapped.swapAt(lhs, rhs)
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: swapImage,
                    arguments: [
                        .array(try swapInput.map(integerValue), elementType: .int64),
                        try integerValue(Int64(lhs)),
                        try integerValue(Int64(rhs)),
                    ]
                ) == .returned(
                    .array(try swapped.map(integerValue), elementType: .int64)
                ),
                Comment(rawValue: "Array swap mismatch for case \(caseID)")
            )
        }

        let pair = VM.Value.array(
            try [1, 2].map(integerValue),
            elementType: .int64
        )
        let empty = VM.Value.array([], elementType: .int64)
        func replace(
            lower: Int64,
            upper: Int64
        ) throws -> VM.ExecutionResult {
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: replacementImage,
                arguments: [
                    pair, try integerValue(lower), try integerValue(upper),
                    empty,
                ]
            )
        }
        func swap(
            lhs: Int64,
            rhs: Int64
        ) throws -> VM.ExecutionResult {
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: swapImage,
                arguments: [
                    pair, try integerValue(lhs), try integerValue(rhs),
                ]
            )
        }

        #expect(
            try replace(lower: 2, upper: 1)
                == .trapped(
                    .explicit(
                        "Array range lower bound exceeds its upper bound"
                    )
                )
        )
        #expect(
            try replace(lower: -1, upper: 1)
                == .trapped(.arrayIndexOutOfBounds(index: -1, count: 2))
        )
        #expect(
            try replace(lower: 0, upper: 3)
                == .trapped(.arrayIndexOutOfBounds(index: 3, count: 2))
        )
        #expect(
            try swap(lhs: -1, rhs: 0)
                == .trapped(.arrayIndexOutOfBounds(index: -1, count: 2))
        )
        #expect(
            try swap(lhs: 0, rhs: 2)
                == .trapped(.arrayIndexOutOfBounds(index: 2, count: 2))
        )
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
        let resultType = Bytecode.ValueType.tuple([
            .optional(.int64), dictionaryType,
        ])
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "update",
            parameterRegisters: [
                .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            ],
            resultType: resultType,
            registerTypes: [
                dictionaryType, .string, .optional(.int64),
                .optional(.int64), dictionaryType, resultType,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
                    ],
                    instructions: [
                        .dictionarySet(
                            previousValueResult: .init(rawValue: 3),
                            dictionaryResult: .init(rawValue: 4),
                            dictionary: .init(rawValue: 0),
                            key: .init(rawValue: 1),
                            value: .init(rawValue: 2)
                        ),
                        .makeTuple(
                            result: .init(rawValue: 5),
                            elements: [.init(rawValue: 3), .init(rawValue: 4)]
                        ),
                        .returnValue(.init(rawValue: 5)),
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
                result: "(Swift.Optional<Swift.Int>, Swift.Dictionary<Swift.String, Swift.Int>)"
            ),
            parameterTypes: [dictionaryType, .string, .optional(.int64)],
            resultType: resultType,
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
            let expectedPrevious = source[key]
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
            guard case let .returned(.some(.tuple(outputs))) = result,
                  outputs.count == 2,
                  case let .optional(actualPrevious) = outputs[0],
                  case let .dictionary(actualEntries, _, _) = outputs[1]
            else {
                Issue.record("unexpected Dictionary result for case \(caseID): \(result)")
                continue
            }
            let expectedPreviousValue = try expectedPrevious.map(integerValue)
            #expect(
                actualPrevious == expectedPreviousValue,
                Comment(rawValue: "Dictionary previous value mismatch for case \(caseID)")
            )
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
