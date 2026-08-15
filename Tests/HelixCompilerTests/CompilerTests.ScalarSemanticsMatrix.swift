import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift scalar semantics")
struct ScalarSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
    }

    @Test("Fixed-width integer properties execute across every scalar width")
    func lowersIntegerPropertyMatrix() throws {
        let signedInput: Int16 = -0x1234
        let unsignedInputs: (UInt8, UInt16, UInt32, UInt64) = (
            0b1011_0000,
            0x1234,
            0x0102_0304,
            0x0102_0304_0506_0708
        )
        try run([
            Probe(
                name: "signedWidthProbe",
                source: """
                public func signedWidthProbe(_ value: Int16) -> (
                    UInt16, Int, Int, Int, Int16, Int16, Int, Bool
                ) {
                    (
                        value.magnitude,
                        value.nonzeroBitCount,
                        value.leadingZeroBitCount,
                        value.trailingZeroBitCount,
                        value.byteSwapped,
                        value.signum(),
                        Int16.bitWidth,
                        Int16.isSigned
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try signed(Int64(signedInput), width: 16)],
                        expected: .returned(
                            .tuple([
                                try unsigned(
                                    UInt64(signedInput.magnitude),
                                    width: 16
                                ),
                                try signed(Int64(signedInput.nonzeroBitCount)),
                                try signed(Int64(signedInput.leadingZeroBitCount)),
                                try signed(Int64(signedInput.trailingZeroBitCount)),
                                try signed(
                                    Int64(signedInput.byteSwapped),
                                    width: 16
                                ),
                                try signed(Int64(signedInput.signum()), width: 16),
                                try signed(16),
                                .bool(true),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try signed(0, width: 16)],
                        expected: .returned(
                            .tuple([
                                try unsigned(0, width: 16),
                                try signed(0),
                                try signed(16),
                                try signed(16),
                                try signed(0, width: 16),
                                try signed(0, width: 16),
                                try signed(16),
                                .bool(true),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "unsignedBitProperties",
                source: """
                public func unsignedBitProperties(
                    _ u8: UInt8,
                    _ u16: UInt16,
                    _ u32: UInt32,
                    _ u64: UInt64
                ) -> (
                    Int, Int, Int, UInt8,
                    Int, Int, Int, UInt16,
                    Int, Int, Int, UInt32,
                    Int, Int, Int, UInt64
                ) {
                    (
                        u8.nonzeroBitCount,
                        u8.leadingZeroBitCount,
                        u8.trailingZeroBitCount,
                        u8.byteSwapped,
                        u16.nonzeroBitCount,
                        u16.leadingZeroBitCount,
                        u16.trailingZeroBitCount,
                        u16.byteSwapped,
                        u32.nonzeroBitCount,
                        u32.leadingZeroBitCount,
                        u32.trailingZeroBitCount,
                        u32.byteSwapped,
                        u64.nonzeroBitCount,
                        u64.leadingZeroBitCount,
                        u64.trailingZeroBitCount,
                        u64.byteSwapped
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsigned(UInt64(unsignedInputs.0), width: 8),
                            try unsigned(UInt64(unsignedInputs.1), width: 16),
                            try unsigned(UInt64(unsignedInputs.2), width: 32),
                            try unsigned(unsignedInputs.3, width: 64),
                        ],
                        expected: .returned(
                            .tuple(
                                try unsignedBitPropertyValues(unsignedInputs)
                            )
                        )
                    ),
                    .init(
                        arguments: [
                            try unsigned(0, width: 8),
                            try unsigned(0, width: 16),
                            try unsigned(0, width: 32),
                            try unsigned(0, width: 64),
                        ],
                        expected: .returned(
                            .tuple(
                                try unsignedBitPropertyValues((0, 0, 0, 0))
                            )
                        )
                    ),
                ]
            ),
            Probe(
                name: "integerStaticProperties",
                source: """
                public func integerStaticProperties() -> (
                    Int8, Int8, Int16, Int16, Int32, Int32, Int64, Int64,
                    UInt8, UInt8, UInt16, UInt16, UInt32, UInt32, UInt64, UInt64,
                    Int, Int, Bool, Bool
                ) {
                    (
                        Int8.min, Int8.max, Int16.min, Int16.max,
                        Int32.min, Int32.max, Int64.min, Int64.max,
                        UInt8.min, UInt8.max, UInt16.min, UInt16.max,
                        UInt32.min, UInt32.max, UInt64.min, UInt64.max,
                        Int.bitWidth, UInt.bitWidth, Int.isSigned, UInt.isSigned
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [],
                        expected: .returned(
                            .tuple([
                                try signed(Int64(Int8.min), width: 8),
                                try signed(Int64(Int8.max), width: 8),
                                try signed(Int64(Int16.min), width: 16),
                                try signed(Int64(Int16.max), width: 16),
                                try signed(Int64(Int32.min), width: 32),
                                try signed(Int64(Int32.max), width: 32),
                                try signed(Int64.min),
                                try signed(Int64.max),
                                try unsigned(UInt64(UInt8.min), width: 8),
                                try unsigned(UInt64(UInt8.max), width: 8),
                                try unsigned(UInt64(UInt16.min), width: 16),
                                try unsigned(UInt64(UInt16.max), width: 16),
                                try unsigned(UInt64(UInt32.min), width: 32),
                                try unsigned(UInt64(UInt32.max), width: 32),
                                try unsigned(UInt64.min),
                                try unsigned(UInt64.max),
                                try signed(64),
                                try signed(64),
                                .bool(true),
                                .bool(false),
                            ])
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Floating-point predicates, derived values, signs, and rounding execute exactly")
    func lowersFloatingPointMatrix() throws {
        let signalingFloat = Float(bitPattern: 0x7F80_0001)
        let signalingDouble = Double(bitPattern: 0x7FF0_0000_0000_0001)
        let derivedFloat: Float = 6.25
        let derivedDouble: Double = 20.25
        try run([
            Probe(
                name: "floatingPredicates",
                source: """
                public func floatingPredicates(
                    _ float: Float,
                    _ double: Double
                ) -> (
                    Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool,
                    Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool
                ) {
                    (
                        float.isFinite,
                        float.isInfinite,
                        float.isNaN,
                        float.isSignalingNaN,
                        float.isNormal,
                        float.isSubnormal,
                        float.isZero,
                        float.sign == .minus,
                        double.isFinite,
                        double.isInfinite,
                        double.isNaN,
                        double.isSignalingNaN,
                        double.isNormal,
                        double.isSubnormal,
                        double.isZero,
                        double.sign == .minus
                    )
                }
                """,
                scenarios: [
                    floatingPredicateScenario(signalingFloat, signalingDouble),
                    floatingPredicateScenario(-0.0, -0.0),
                    floatingPredicateScenario(
                        Float.leastNonzeroMagnitude,
                        Double.leastNonzeroMagnitude
                    ),
                    floatingPredicateScenario(.infinity, -.infinity),
                ]
            ),
            Probe(
                name: "floatingDerivedValues",
                source: """
                public func floatingDerivedValues(
                    _ float: Float,
                    _ double: Double
                ) -> (
                    Float, Float, Float, Float, Float, Float, Float,
                    Double, Double, Double, Double, Double, Double, Double
                ) {
                    (
                        float.magnitude,
                        float.ulp,
                        float.nextUp,
                        float.binade,
                        float.significand,
                        float.squareRoot(),
                        float.rounded(),
                        double.magnitude,
                        double.ulp,
                        double.nextUp,
                        double.binade,
                        double.significand,
                        double.squareRoot(),
                        double.rounded()
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            .float32(derivedFloat),
                            .float64(derivedDouble),
                        ],
                        expected: .returned(
                            .tuple([
                                .float32(derivedFloat.magnitude),
                                .float32(derivedFloat.ulp),
                                .float32(derivedFloat.nextUp),
                                .float32(derivedFloat.binade),
                                .float32(derivedFloat.significand),
                                .float32(derivedFloat.squareRoot()),
                                .float32(derivedFloat.rounded()),
                                .float64(derivedDouble.magnitude),
                                .float64(derivedDouble.ulp),
                                .float64(derivedDouble.nextUp),
                                .float64(derivedDouble.binade),
                                .float64(derivedDouble.significand),
                                .float64(derivedDouble.squareRoot()),
                                .float64(derivedDouble.rounded()),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "floatingRoundingRules",
                source: """
                public func floatingRoundingRules(
                    _ float: Float,
                    _ double: Double
                ) -> (
                    Float, Float, Float, Float, Float, Float,
                    Double, Double, Double, Double, Double, Double
                ) {
                    (
                        float.rounded(.down),
                        float.rounded(.up),
                        float.rounded(.towardZero),
                        float.rounded(.awayFromZero),
                        float.rounded(.toNearestOrAwayFromZero),
                        float.rounded(.toNearestOrEven),
                        double.rounded(.down),
                        double.rounded(.up),
                        double.rounded(.towardZero),
                        double.rounded(.awayFromZero),
                        double.rounded(.toNearestOrAwayFromZero),
                        double.rounded(.toNearestOrEven)
                    )
                }
                """,
                scenarios: [
                    floatingRoundingScenario(2.5, 2.5),
                    floatingRoundingScenario(-2.5, -2.5),
                ]
            ),
            Probe(
                name: "floatingSignSwitch",
                source: """
                public func floatingSignSwitch(_ value: Double) -> Int {
                    switch value.sign {
                    case .plus: 1
                    case .minus: -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.float64(0.0)],
                        expected: .returned(try signed(1))
                    ),
                    .init(
                        arguments: [.float64(-0.0)],
                        expected: .returned(try signed(-1))
                    ),
                    .init(
                        arguments: [
                            .float64(
                                Double(bitPattern: 0xFFF8_0000_0000_0001)
                            ),
                        ],
                        expected: .returned(try signed(-1))
                    ),
                ]
            ),
            Probe(
                name: "floatingStaticProperties",
                source: """
                public func floatingStaticProperties() -> (
                    Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool,
                    Int, Int
                ) {
                    (
                        Float.nan.isNaN,
                        Float.signalingNaN.isSignalingNaN,
                        Float.infinity.isInfinite,
                        Float.greatestFiniteMagnitude.isFinite,
                        Float.leastNormalMagnitude.isNormal,
                        Double.nan.isNaN,
                        Double.signalingNaN.isSignalingNaN,
                        Double.infinity.isInfinite,
                        Double.leastNonzeroMagnitude.isSubnormal,
                        Double.zero.isZero,
                        Float.radix,
                        Double.radix
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [],
                        expected: .returned(
                            .tuple(
                                Array(repeating: .bool(true), count: 10)
                                    + [try signed(2), try signed(2)]
                            )
                        )
                    ),
                ]
            ),
        ])
    }

    @Test("Integer reporting and quotient APIs preserve zero and overflow behavior")
    func lowersIntegerArithmeticMatrix() throws {
        try run([
            Probe(
                name: "integerReportingOverflow",
                source: """
                public func integerReportingOverflow(
                    _ lhs: Int,
                    _ rhs: Int
                ) -> (
                    Int, Bool, Int, Bool, Int, Bool, Int, Bool, Int, Bool
                ) {
                    let added = lhs.addingReportingOverflow(rhs)
                    let subtracted = lhs.subtractingReportingOverflow(rhs)
                    let multiplied = lhs.multipliedReportingOverflow(by: rhs)
                    let divided = lhs.dividedReportingOverflow(by: rhs)
                    let remainder = lhs.remainderReportingOverflow(dividingBy: rhs)
                    return (
                        added.partialValue, added.overflow,
                        subtracted.partialValue, subtracted.overflow,
                        multiplied.partialValue, multiplied.overflow,
                        divided.partialValue, divided.overflow,
                        remainder.partialValue, remainder.overflow
                    )
                }
                """,
                scenarios: [
                    try reportingScenario(lhs: 21, rhs: 4),
                    try reportingScenario(lhs: .max, rhs: 2),
                    try reportingScenario(lhs: 7, rhs: 0),
                    try reportingScenario(lhs: .min, rhs: -1),
                ]
            ),
            Probe(
                name: "integerIsMultiple",
                source: """
                public func integerIsMultiple(_ value: Int16, _ divisor: Int16) -> Bool {
                    value.isMultiple(of: divisor)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try signed(12, width: 16), try signed(3, width: 16)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try signed(0, width: 16), try signed(0, width: 16)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [try signed(5, width: 16), try signed(0, width: 16)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "unsignedIsMultiple",
                source: """
                public func unsignedIsMultiple(
                    _ value: UInt16,
                    _ divisor: UInt16
                ) -> Bool {
                    value.isMultiple(of: divisor)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try unsigned(12, width: 16),
                            try unsigned(3, width: 16),
                        ],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [
                            try unsigned(0, width: 16),
                            try unsigned(0, width: 16),
                        ],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [
                            try unsigned(5, width: 16),
                            try unsigned(0, width: 16),
                        ],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "integerQuotientAndRemainder",
                source: """
                public func integerQuotientAndRemainder(
                    _ value: Int16,
                    _ divisor: Int16
                ) -> (Int16, Int16) {
                    let result = value.quotientAndRemainder(dividingBy: divisor)
                    return (result.quotient, result.remainder)
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try signed(-17, width: 16), try signed(5, width: 16)],
                        expected: .returned(
                            .tuple([
                                try signed(-3, width: 16),
                                try signed(-2, width: 16),
                            ])
                        )
                    ),
                    .init(
                        arguments: [try signed(7, width: 16), try signed(0, width: 16)],
                        expected: .trapped(.divisionByZero)
                    ),
                    .init(
                        arguments: [
                            try signed(Int64(Int16.min), width: 16),
                            try signed(-1, width: 16),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
        ])
    }

    @Test("Integer representation, clamping, endian, and full-width APIs execute")
    func lowersIntegerRepresentationMatrix() throws {
        let signedValue: Int32 = -0x1234_567
        let unsignedValue: UInt32 = 97
        let product = signedValue.multipliedFullWidth(by: 7)
        let division = unsignedValue.dividingFullWidth((
            high: 0,
            low: 123_456
        ))
        try run([
            Probe(
                name: "integerRepresentation",
                source: """
                public func integerRepresentation(
                    _ signed: Int32,
                    _ unsigned: UInt32
                ) -> (
                    Int32, Int32, UInt32, UInt32,
                    Int32, UInt32, UInt32, UInt32
                ) {
                    let product = signed.multipliedFullWidth(by: 7)
                    let division = unsigned.dividingFullWidth((
                        high: 0,
                        low: 123_456
                    ))
                    return (
                        signed.bigEndian,
                        signed.littleEndian,
                        unsigned.bigEndian,
                        unsigned.littleEndian,
                        product.high,
                        product.low,
                        division.quotient,
                        division.remainder
                    )
                }
                """,
                scenarios: [
                    .init(
                        arguments: [
                            try signed(Int64(signedValue), width: 32),
                            try unsigned(UInt64(unsignedValue), width: 32),
                        ],
                        expected: .returned(
                            .tuple([
                                try signed(
                                    Int64(signedValue.bigEndian),
                                    width: 32
                                ),
                                try signed(
                                    Int64(signedValue.littleEndian),
                                    width: 32
                                ),
                                try unsigned(
                                    UInt64(unsignedValue.bigEndian),
                                    width: 32
                                ),
                                try unsigned(
                                    UInt64(unsignedValue.littleEndian),
                                    width: 32
                                ),
                                try signed(Int64(product.high), width: 32),
                                try unsigned(UInt64(product.low), width: 32),
                                try unsigned(
                                    UInt64(division.quotient),
                                    width: 32
                                ),
                                try unsigned(
                                    UInt64(division.remainder),
                                    width: 32
                                ),
                            ])
                        )
                    ),
                ]
            ),
            Probe(
                name: "integerClamping",
                source: """
                public func integerClamping(
                    _ signed: Int64,
                    _ unsigned: UInt64
                ) -> (UInt8, Int16, Int32, UInt32, Int64, UInt64) {
                    (
                        UInt8(clamping: signed),
                        Int16(clamping: unsigned),
                        Int32(clamping: signed),
                        UInt32(clamping: signed),
                        Int64(clamping: unsigned),
                        UInt64(clamping: signed)
                    )
                }
                """,
                scenarios: [
                    try clampingScenario(signed: .min, unsigned: .max),
                    try clampingScenario(signed: -1, unsigned: 127),
                    try clampingScenario(signed: 42, unsigned: 42),
                    try clampingScenario(
                        signed: .max,
                        unsigned: UInt64(Int64.max)
                    ),
                ]
            ),
            Probe(
                name: "signedFullWidthDivision",
                source: """
                public func signedFullWidthDivision(
                    _ divisor: Int64,
                    _ high: Int64,
                    _ low: UInt64
                ) -> (Int64, Int64) {
                    let result = divisor.dividingFullWidth((
                        high: high,
                        low: low
                    ))
                    return (result.quotient, result.remainder)
                }
                """,
                scenarios: [
                    try signedFullWidthDivisionScenario(
                        divisor: .max,
                        high: 1,
                        low: 0
                    ),
                    try signedFullWidthDivisionScenario(
                        divisor: .max,
                        high: -1,
                        low: 0
                    ),
                    .init(
                        arguments: [
                            try signed(0),
                            try signed(0),
                            try unsigned(1),
                        ],
                        expected: .trapped(.divisionByZero)
                    ),
                    .init(
                        arguments: [
                            try signed(1),
                            try signed(1),
                            try unsigned(0),
                        ],
                        expected: .trapped(.integerOverflow)
                    ),
                ]
            ),
        ])
    }

    @Test("Floating representation and advanced IEEE operations preserve bits")
    func lowersFloatingRepresentationMatrix() throws {
        let floatValues: [Float] = [
            -0.0,
            .leastNonzeroMagnitude,
            6.25,
            .infinity,
            Float(bitPattern: 0x7F80_1234),
        ]
        let doubleValues: [Double] = [
            -0.0,
            .leastNonzeroMagnitude,
            20.25,
            .infinity,
            Double(bitPattern: 0x7FF0_0000_0000_1234),
        ]
        try run([
            Probe(
                name: "floatRepresentation",
                source: """
                public func floatRepresentation(_ value: Float) -> (
                    UInt32, UInt32, Int, UInt, UInt32, Int, Bool
                ) {
                    let roundTrip = Float(bitPattern: value.bitPattern)
                    return (
                        value.bitPattern,
                        roundTrip.bitPattern,
                        value.exponent,
                        value.exponentBitPattern,
                        value.significandBitPattern,
                        value.significandWidth,
                        value.isCanonical
                    )
                }
                """,
                scenarios: try floatValues.map(floatRepresentationScenario)
            ),
            Probe(
                name: "doubleRepresentation",
                source: """
                public func doubleRepresentation(_ value: Double) -> (
                    UInt64, UInt64, Int, UInt, UInt64, Int, Bool
                ) {
                    let roundTrip = Double(bitPattern: value.bitPattern)
                    return (
                        value.bitPattern,
                        roundTrip.bitPattern,
                        value.exponent,
                        value.exponentBitPattern,
                        value.significandBitPattern,
                        value.significandWidth,
                        value.isCanonical
                    )
                }
                """,
                scenarios: try doubleValues.map(doubleRepresentationScenario)
            ),
            Probe(
                name: "floatingArithmeticBits",
                source: """
                public func floatingArithmeticBits(
                    _ lhs: Double,
                    _ rhs: Double
                ) -> (
                    UInt64, UInt64, UInt64, Bool,
                    UInt64, UInt64, UInt64, UInt64
                ) {
                    (
                        lhs.remainder(dividingBy: rhs).bitPattern,
                        lhs.truncatingRemainder(dividingBy: rhs).bitPattern,
                        lhs.addingProduct(rhs, 2).bitPattern,
                        lhs.isTotallyOrdered(belowOrEqualTo: rhs),
                        Double.minimum(lhs, rhs).bitPattern,
                        Double.maximum(lhs, rhs).bitPattern,
                        Double.minimumMagnitude(lhs, rhs).bitPattern,
                        Double.maximumMagnitude(lhs, rhs).bitPattern
                    )
                }
                """,
                scenarios: [
                    try floatingArithmeticScenario(5.5, 2),
                    try floatingArithmeticScenario(-0.0, 0.0),
                    try floatingArithmeticScenario(
                        Double(bitPattern: 0x7FF0_0000_0000_1234),
                        1
                    ),
                ]
            ),
            Probe(
                name: "mutatingFloatingBits",
                source: """
                public func mutatingFloatingBits(_ input: Double) -> UInt64 {
                    var value = input
                    value.formSquareRoot()
                    value.round(.towardZero)
                    value.addProduct(2, 3)
                    value.formRemainder(dividingBy: 5)
                    value.formTruncatingRemainder(dividingBy: 2)
                    return value.bitPattern
                }
                """,
                scenarios: try [4.0, 20.25, .infinity].map(
                    mutatingFloatingScenario
                )
            ),
        ])
    }

    @Test("Undefined-zero count builtins fail closed")
    func rejectsUndefinedZeroCountBuiltin() {
        let function = CanonicalSIL.Function(
            mangledName: "$s18ScalarFailClosed5countys5UInt8VADF",
            loweredType: "@convention(thin) (UInt8) -> UInt8",
            body: """
            bb0(%0 : $UInt8):
              %1 = struct_extract %0, #UInt8._value
              %2 = integer_literal $Builtin.Int1, -1
              %3 = builtin "int_ctlz_Int8"(%1, %2) : $Builtin.Int8
              %4 = struct $UInt8 (%3)
              return %4
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "count"
            )
        }
    }

    @Test("Scalar symbol discovery is operation-driven and receiver-generic")
    func classifiesScalarSymbols() {
        let cases: [(String, CanonicalSIL.ScalarIntrinsic)] = [
            (
                "$sSZss17FixedWidthIntegerRzrlE3minxvgZ",
                .staticValue(.minimum)
            ),
            ("$sSf2piSfvgZ", .staticValue(.pi)),
            ("$ss5Int16V8bitWidthSivgZ", .staticValue(.bitWidth)),
            (
                "$ss6UInt32V15nonzeroBitCountSivg",
                .integerUnary(.nonzeroBitCount)
            ),
            (
                "$ss6UInt64V11byteSwappedABvg",
                .integerUnary(.byteSwapped)
            ),
            ("$sSf6nextUpSfvg", .floatingUnary(.nextUp)),
            ("$sSd8isFiniteSbvg", .floatingPredicate(.isFinite)),
            (
                "$sSd10bitPatterns6UInt64Vvg",
                .floatingBitPattern(.extract)
            ),
            (
                "$sSf18exponentBitPatternSuvg",
                .floatingIntegerProperty(.exponentBitPattern)
            ),
            (
                "$sSFsE19truncatingRemainder10dividingByxx_tF",
                .floatingBinary(.truncatingRemainder, form: .instance)
            ),
            (
                "$sSBsE16isTotallyOrdered14belowOrEqualToSbx_tF",
                .floatingBinaryPredicate(.isTotallyOrderedBelowOrEqual)
            ),
            ("$sSzsE10isMultiple2ofSbx_tF", .integerIsMultiple),
            (
                "$ss17FixedWidthIntegerPsE8clampingxqd___tcSzRd__lufC",
                .integerClampingConversion
            ),
            (
                "$ss5Int64V19multipliedFullWidth2byAB4high_s6UInt64V3lowtAB_tF",
                .integerFullWidthMultiply
            ),
            (
                "$sSi23addingReportingOverflowySi12partialValue_Sb8overflowtSiF",
                .integerReportingOverflow(.add)
            ),
        ]
        for (symbol, expected) in cases {
            #expect(
                CanonicalSIL.ScalarIntrinsic(mangledName: symbol) == expected
            )
        }
        #expect(
            CanonicalSIL.ScalarIntrinsic(
                mangledName: "$sFakeType15nonzeroBitCountSivg"
            ) == nil
        )
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixScalarSemantics"
                )
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
                                + "\(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "scalar semantic gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func unsignedBitPropertyValues(
        _ values: (UInt8, UInt16, UInt32, UInt64)
    ) throws -> [VM.Value] {
        [
            try signed(Int64(values.0.nonzeroBitCount)),
            try signed(Int64(values.0.leadingZeroBitCount)),
            try signed(Int64(values.0.trailingZeroBitCount)),
            try unsigned(UInt64(values.0.byteSwapped), width: 8),
            try signed(Int64(values.1.nonzeroBitCount)),
            try signed(Int64(values.1.leadingZeroBitCount)),
            try signed(Int64(values.1.trailingZeroBitCount)),
            try unsigned(UInt64(values.1.byteSwapped), width: 16),
            try signed(Int64(values.2.nonzeroBitCount)),
            try signed(Int64(values.2.leadingZeroBitCount)),
            try signed(Int64(values.2.trailingZeroBitCount)),
            try unsigned(UInt64(values.2.byteSwapped), width: 32),
            try signed(Int64(values.3.nonzeroBitCount)),
            try signed(Int64(values.3.leadingZeroBitCount)),
            try signed(Int64(values.3.trailingZeroBitCount)),
            try unsigned(values.3.byteSwapped),
        ]
    }

    private func floatingPredicateScenario(
        _ float: Float,
        _ double: Double
    ) -> Scenario {
        .init(
            arguments: [.float32(float), .float64(double)],
            expected: .returned(
                .tuple(
                    [
                        float.isFinite,
                        float.isInfinite,
                        float.isNaN,
                        float.isSignalingNaN,
                        float.isNormal,
                        float.isSubnormal,
                        float.isZero,
                        float.sign == .minus,
                        double.isFinite,
                        double.isInfinite,
                        double.isNaN,
                        double.isSignalingNaN,
                        double.isNormal,
                        double.isSubnormal,
                        double.isZero,
                        double.sign == .minus,
                    ].map(VM.Value.bool)
                )
            )
        )
    }

    private func floatingRoundingScenario(
        _ float: Float,
        _ double: Double
    ) -> Scenario {
        let rules: [FloatingPointRoundingRule] = [
            .down,
            .up,
            .towardZero,
            .awayFromZero,
            .toNearestOrAwayFromZero,
            .toNearestOrEven,
        ]
        return .init(
            arguments: [.float32(float), .float64(double)],
            expected: .returned(
                .tuple(
                    rules.map { .float32(float.rounded($0)) }
                        + rules.map { .float64(double.rounded($0)) }
                )
            )
        )
    }

    private func reportingScenario(
        lhs: Int64,
        rhs: Int64
    ) throws -> Scenario {
        let added = lhs.addingReportingOverflow(rhs)
        let subtracted = lhs.subtractingReportingOverflow(rhs)
        let multiplied = lhs.multipliedReportingOverflow(by: rhs)
        let divided = lhs.dividedReportingOverflow(by: rhs)
        let remainder = lhs.remainderReportingOverflow(dividingBy: rhs)
        return .init(
            arguments: [try signed(lhs), try signed(rhs)],
            expected: .returned(
                .tuple([
                    try signed(added.partialValue), .bool(added.overflow),
                    try signed(subtracted.partialValue), .bool(subtracted.overflow),
                    try signed(multiplied.partialValue), .bool(multiplied.overflow),
                    try signed(divided.partialValue), .bool(divided.overflow),
                    try signed(remainder.partialValue), .bool(remainder.overflow),
                ])
            )
        )
    }

    private func clampingScenario(
        signed signedValue: Int64,
        unsigned unsignedValue: UInt64
    ) throws -> Scenario {
        .init(
            arguments: [
                try signed(signedValue),
                try unsigned(unsignedValue),
            ],
            expected: .returned(
                .tuple([
                    try unsigned(
                        UInt64(UInt8(clamping: signedValue)),
                        width: 8
                    ),
                    try signed(
                        Int64(Int16(clamping: unsignedValue)),
                        width: 16
                    ),
                    try signed(
                        Int64(Int32(clamping: signedValue)),
                        width: 32
                    ),
                    try unsigned(
                        UInt64(UInt32(clamping: signedValue)),
                        width: 32
                    ),
                    try signed(Int64(clamping: unsignedValue)),
                    try unsigned(UInt64(clamping: signedValue)),
                ])
            )
        )
    }

    private func signedFullWidthDivisionScenario(
        divisor: Int64,
        high: Int64,
        low: UInt64
    ) throws -> Scenario {
        let result = divisor.dividingFullWidth((high: high, low: low))
        return .init(
            arguments: [
                try signed(divisor),
                try signed(high),
                try unsigned(low),
            ],
            expected: .returned(
                .tuple([
                    try signed(result.quotient),
                    try signed(result.remainder),
                ])
            )
        )
    }

    private func floatRepresentationScenario(
        _ value: Float
    ) throws -> Scenario {
        .init(
            arguments: [.float32(value)],
            expected: .returned(
                .tuple([
                    try unsigned(UInt64(value.bitPattern), width: 32),
                    try unsigned(UInt64(value.bitPattern), width: 32),
                    try signed(Int64(value.exponent)),
                    try unsigned(UInt64(value.exponentBitPattern)),
                    try unsigned(
                        UInt64(value.significandBitPattern),
                        width: 32
                    ),
                    try signed(Int64(value.significandWidth)),
                    .bool(value.isCanonical),
                ])
            )
        )
    }

    private func doubleRepresentationScenario(
        _ value: Double
    ) throws -> Scenario {
        .init(
            arguments: [.float64(value)],
            expected: .returned(
                .tuple([
                    try unsigned(value.bitPattern),
                    try unsigned(value.bitPattern),
                    try signed(Int64(value.exponent)),
                    try unsigned(UInt64(value.exponentBitPattern)),
                    try unsigned(value.significandBitPattern),
                    try signed(Int64(value.significandWidth)),
                    .bool(value.isCanonical),
                ])
            )
        )
    }

    private func floatingArithmeticScenario(
        _ lhs: Double,
        _ rhs: Double
    ) throws -> Scenario {
        .init(
            arguments: [.float64(lhs), .float64(rhs)],
            expected: .returned(
                .tuple([
                    try unsigned(
                        lhs.remainder(dividingBy: rhs).bitPattern
                    ),
                    try unsigned(
                        lhs.truncatingRemainder(dividingBy: rhs).bitPattern
                    ),
                    try unsigned(lhs.addingProduct(rhs, 2).bitPattern),
                    .bool(lhs.isTotallyOrdered(belowOrEqualTo: rhs)),
                    try unsigned(Double.minimum(lhs, rhs).bitPattern),
                    try unsigned(Double.maximum(lhs, rhs).bitPattern),
                    try unsigned(
                        Double.minimumMagnitude(lhs, rhs).bitPattern
                    ),
                    try unsigned(
                        Double.maximumMagnitude(lhs, rhs).bitPattern
                    ),
                ])
            )
        )
    }

    private func mutatingFloatingScenario(
        _ input: Double
    ) throws -> Scenario {
        var value = input
        value.formSquareRoot()
        value.round(.towardZero)
        value.addProduct(2, 3)
        value.formRemainder(dividingBy: 5)
        value.formTruncatingRemainder(dividingBy: 2)
        return .init(
            arguments: [.float64(input)],
            expected: .returned(
                try unsigned(value.bitPattern)
            )
        )
    }

    private func signed(
        _ value: Int64,
        width: UInt16 = 64
    ) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: width, isSigned: true)
        )
    }

    private func unsigned(
        _ value: UInt64,
        width: UInt16 = 64
    ) throws -> VM.Value {
        .integer(
            try .init(rawBits: value, bitWidth: width, isSigned: false)
        )
    }
}
}
