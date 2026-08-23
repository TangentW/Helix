import HelixCore
import HelixVM
import Testing

@testable import HelixCompiler

extension CompilerTests {
@Suite("Concrete Swift standard-protocol semantics")
struct StandardProtocol {
    @Test("Represented values execute common generic protocol requirements")
    func executesRepresentedProtocolRequirements() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func same<Value: Equatable>(
                _ lhs: Value,
                _ rhs: Value
            ) -> Bool {
                lhs == rhs
            }

            private func relations<Value: Comparable>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Bool, Bool, Bool, Bool) {
                (lhs < rhs, lhs <= rhs, lhs > rhs, lhs >= rhs)
            }

            private func arithmetic<Value: AdditiveArithmetic>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Value, Value, Value) {
                (lhs + rhs, lhs - rhs, .zero)
            }

            private func product<Value: Numeric>(
                _ lhs: Value,
                _ rhs: Value
            ) -> Value {
                lhs * rhs
            }

            private func negative<Value: SignedNumeric>(_ value: Value) -> Value {
                -value
            }

            public func standardProtocolOperations(
                _ lhs: Int,
                _ rhs: Int
            ) -> (Bool, Bool, Bool, Bool, Bool, Int, Int, Int, Int, Int) {
                let order = relations(lhs, rhs)
                let values = arithmetic(lhs, rhs)
                return (
                    same(lhs, rhs),
                    order.0, order.1, order.2, order.3,
                    values.0, values.1, values.2,
                    product(lhs, rhs), negative(lhs)
                )
            }
            """,
            functionName: "standardProtocolOperations",
            moduleName: "HelixStandardProtocolOperations"
        )

        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(4), try integer(7)]
        )
        #expect(
            result
                == .returned(
                    .tuple([
                        .bool(false),
                        .bool(true), .bool(true), .bool(false), .bool(false),
                        try integer(11), try integer(-3), try integer(0),
                        try integer(28), try integer(-4),
                    ])))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("BinaryInteger requirements preserve values and traps")
    func executesBinaryIntegerRequirements() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func integerOperations<Value: BinaryInteger>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Value, Value, Value, Value, Value) {
                (lhs / rhs, lhs % rhs, lhs & rhs, lhs | rhs, lhs ^ rhs)
            }

            private func magnitude<Value: Numeric>(
                _ value: Value
            ) -> Value.Magnitude {
                value.magnitude
            }

            public func binaryIntegerRequirements(
                _ lhs: Int,
                _ rhs: Int
            ) -> (Int, Int, Int, Int, Int, UInt) {
                let values = integerOperations(lhs, rhs)
                return (
                    values.0, values.1, values.2, values.3, values.4,
                    magnitude(lhs)
                )
            }
            """,
            functionName: "binaryIntegerRequirements",
            moduleName: "HelixBinaryIntegerRequirements"
        )
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(29), try integer(6)]
            )
                == .returned(
                    .tuple([
                        try integer(4), try integer(5), try integer(4),
                        try integer(31), try integer(27), try unsigned(29),
                    ])))
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(1), try integer(0)]
            ) == .trapped(.divisionByZero))
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(.min), try integer(-1)]
            ) == .trapped(.integerOverflow))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("BinaryInteger shifts accept independent concrete RHS types")
    func executesGenericBinaryIntegerShifts() throws {
        let signedFixture = try FrontendExecutionHarness.compile(
            source: """
            private func shifts<Value: BinaryInteger, Amount: BinaryInteger>(
                _ value: Value,
                _ amount: Amount
            ) -> (Value, Value) {
                (value << amount, value >> amount)
            }

            public func signedGenericShifts(
                _ value: Int8,
                _ amount: Int64
            ) -> (Int8, Int8) {
                shifts(value, amount)
            }
            """,
            functionName: "signedGenericShifts",
            moduleName: "HelixSignedGenericShifts"
        )
        let negativeTwo = VM.Value.integer(
            try .init(signed: -2, bitWidth: 8, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: signedFixture.entry,
                image: signedFixture.image,
                arguments: [negativeTwo, try integer(9)]
            )
                == .returned(
                    .tuple([
                        .integer(try .init(signed: 0, bitWidth: 8, isSigned: true)),
                        .integer(try .init(signed: -1, bitWidth: 8, isSigned: true)),
                    ])))
        #expect(
            VM.Interpreter().invoke(
                entry: signedFixture.entry,
                image: signedFixture.image,
                arguments: [negativeTwo, try integer(-1)]
            )
                == .returned(
                    .tuple([
                        .integer(try .init(signed: -1, bitWidth: 8, isSigned: true)),
                        .integer(try .init(signed: -4, bitWidth: 8, isSigned: true)),
                    ])))

        let unsignedFixture = try FrontendExecutionHarness.compile(
            source: """
            private func shifts<Value: BinaryInteger, Amount: BinaryInteger>(
                _ value: Value,
                _ amount: Amount
            ) -> (Value, Value) {
                (value << amount, value >> amount)
            }

            public func unsignedGenericShifts(
                _ value: UInt8,
                _ amount: Int8
            ) -> (UInt8, UInt8) {
                shifts(value, amount)
            }
            """,
            functionName: "unsignedGenericShifts",
            moduleName: "HelixUnsignedGenericShifts"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: unsignedFixture.entry,
                image: unsignedFixture.image,
                arguments: [
                    .integer(try .init(rawBits: 128, bitWidth: 8, isSigned: false)),
                    .integer(try .init(signed: -1, bitWidth: 8, isSigned: true)),
                ]
            )
                == .returned(
                    .tuple([
                        .integer(try .init(rawBits: 64, bitWidth: 8, isSigned: false)),
                        .integer(try .init(rawBits: 0, bitWidth: 8, isSigned: false)),
                    ])))
        #expect(signedFixture.image.module.imports.isEmpty)
        #expect(unsignedFixture.image.module.imports.isEmpty)
    }

    @Test("FixedWidthInteger requirements preserve wrapping and overflow results")
    func executesFixedWidthIntegerRequirements() throws {
        let valueFixture = try FrontendExecutionHarness.compile(
            source: """
            private func wrapping<Value: FixedWidthInteger>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Value, Value, Value) {
                (lhs &+ rhs, lhs &- rhs, lhs &* rhs)
            }

            private func extrema<Value: FixedWidthInteger>(
                _ type: Value.Type
            ) -> (Value, Value) {
                (Value.min, Value.max)
            }

            private func metadata<Value: FixedWidthInteger>(
                _ value: Value
            ) -> (Int, Bool, Int, Int, Int) {
                (
                    Value.bitWidth, Value.isSigned,
                    value.nonzeroBitCount, value.leadingZeroBitCount,
                    value.trailingZeroBitCount
                )
            }

            private func transformed<Value: FixedWidthInteger>(
                _ value: Value
            ) -> (Value, Value) {
                (value.byteSwapped, value.signum())
            }

            private func isMultiple<Value: FixedWidthInteger>(
                _ value: Value,
                of divisor: Value
            ) -> Bool {
                value.isMultiple(of: divisor)
            }

            private func division<Value: FixedWidthInteger>(
                _ value: Value,
                by divisor: Value
            ) -> (Value, Value) {
                let result = value.quotientAndRemainder(dividingBy: divisor)
                return (result.quotient, result.remainder)
            }

            private func fullWidth<Value: FixedWidthInteger>(
                _ value: Value,
                by other: Value
            ) -> (Value, Value.Magnitude) {
                let result = value.multipliedFullWidth(by: other)
                return (result.high, result.low)
            }

            public func fixedWidthRequirements(
                _ lhs: UInt8,
                _ rhs: UInt8
            ) -> (
                UInt8, UInt8, UInt8, UInt8, UInt8, Int, Bool,
                Int, Int, Int, UInt8, UInt8, Bool,
                UInt8, UInt8, UInt8, UInt8
            ) {
                let wrapped = wrapping(lhs, rhs)
                let limits = extrema(UInt8.self)
                let facts = metadata(lhs)
                let converted = transformed(lhs)
                let quotient = division(lhs, by: rhs)
                let product = fullWidth(lhs, by: rhs)
                return (
                    wrapped.0, wrapped.1, wrapped.2,
                    limits.0, limits.1, facts.0, facts.1,
                    facts.2, facts.3, facts.4,
                    converted.0, converted.1,
                    isMultiple(lhs, of: rhs),
                    quotient.0, quotient.1,
                    product.0, product.1
                )
            }
            """,
            functionName: "fixedWidthRequirements",
            moduleName: "HelixFixedWidthRequirements"
        )
        let unsigned8: (UInt64) throws -> VM.Value = { value in
            .integer(
                try .init(
                    rawBits: value,
                    bitWidth: 8,
                    isSigned: false
                )
            )
        }
        #expect(
            VM.Interpreter().invoke(
                entry: valueFixture.entry,
                image: valueFixture.image,
                arguments: [try unsigned8(250), try unsigned8(10)]
            )
                == .returned(
                    .tuple([
                        try unsigned8(4), try unsigned8(240), try unsigned8(196),
                        try unsigned8(0), try unsigned8(255), try integer(8),
                        .bool(false), try integer(6), try integer(0), try integer(1),
                        try unsigned8(250), try unsigned8(1), .bool(true),
                        try unsigned8(25), try unsigned8(0),
                        try unsigned8(9), try unsigned8(196),
                    ])))
        #expect(valueFixture.image.module.imports.isEmpty)

        let multipleFixture = try FrontendExecutionHarness.compile(
            source: """
            private func isMultiple<Value: FixedWidthInteger>(
                _ value: Value,
                of divisor: Value
            ) -> Bool {
                value.isMultiple(of: divisor)
            }

            public func fixedWidthIsMultiple(
                _ value: Int16,
                _ divisor: Int16
            ) -> Bool {
                isMultiple(value, of: divisor)
            }
            """,
            functionName: "fixedWidthIsMultiple",
            moduleName: "HelixFixedWidthIsMultiple"
        )
        let signed16: (Int64) throws -> VM.Value = { value in
            .integer(
                try .init(
                    signed: value,
                    bitWidth: 16,
                    isSigned: true
                )
            )
        }
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: multipleFixture.entry,
                image: multipleFixture.image,
                arguments: [try signed16(0), try signed16(0)]
            ) == .returned(.bool(true)))
        #expect(
            interpreter.invoke(
                entry: multipleFixture.entry,
                image: multipleFixture.image,
                arguments: [try signed16(5), try signed16(0)]
            ) == .returned(.bool(false)))
        #expect(multipleFixture.image.module.imports.isEmpty)

        let quotientFixture = try FrontendExecutionHarness.compile(
            source: """
            private func quotient<Value: FixedWidthInteger>(
                _ value: Value,
                by divisor: Value
            ) -> (Value, Value) {
                let result = value.quotientAndRemainder(dividingBy: divisor)
                return (result.quotient, result.remainder)
            }

            public func fixedWidthQuotient(
                _ value: Int16,
                _ divisor: Int16
            ) -> (Int16, Int16) {
                quotient(value, by: divisor)
            }
            """,
            functionName: "fixedWidthQuotient",
            moduleName: "HelixFixedWidthQuotient"
        )
        #expect(
            interpreter.invoke(
                entry: quotientFixture.entry,
                image: quotientFixture.image,
                arguments: [try signed16(-17), try signed16(5)]
            ) == .returned(.tuple([try signed16(-3), try signed16(-2)])))
        #expect(
            interpreter.invoke(
                entry: quotientFixture.entry,
                image: quotientFixture.image,
                arguments: [try signed16(7), try signed16(0)]
            ) == .trapped(.divisionByZero))
        #expect(
            interpreter.invoke(
                entry: quotientFixture.entry,
                image: quotientFixture.image,
                arguments: [try signed16(Int64(Int16.min)), try signed16(-1)]
            ) == .trapped(.integerOverflow))
        #expect(quotientFixture.image.module.imports.isEmpty)

        let reportingFixture = try FrontendExecutionHarness.compile(
            source: """
            private func overflowFlags<Value: FixedWidthInteger>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Bool, Bool, Bool, Bool, Bool) {
                (
                    lhs.addingReportingOverflow(rhs).overflow,
                    lhs.subtractingReportingOverflow(rhs).overflow,
                    lhs.multipliedReportingOverflow(by: rhs).overflow,
                    lhs.dividedReportingOverflow(by: rhs).overflow,
                    lhs.remainderReportingOverflow(dividingBy: rhs).overflow
                )
            }

            public func fixedWidthOverflowFlags(
                _ lhs: Int8,
                _ rhs: Int8
            ) -> (Bool, Bool, Bool, Bool, Bool) {
                overflowFlags(lhs, rhs)
            }
            """,
            functionName: "fixedWidthOverflowFlags",
            moduleName: "HelixFixedWidthOverflowFlags"
        )
        let signed8: (Int64) throws -> VM.Value = { value in
            .integer(
                try .init(
                    signed: value,
                    bitWidth: 8,
                    isSigned: true
                )
            )
        }
        #expect(
            interpreter.invoke(
                entry: reportingFixture.entry,
                image: reportingFixture.image,
                arguments: [try signed8(120), try signed8(10)]
            ) == .returned(
                .tuple([
                    .bool(true), .bool(false), .bool(true),
                    .bool(false), .bool(false),
                ])))
        #expect(
            interpreter.invoke(
                entry: reportingFixture.entry,
                image: reportingFixture.image,
                arguments: [try signed8(7), try signed8(0)]
            ) == .returned(
                .tuple([
                    .bool(false), .bool(false), .bool(false),
                    .bool(true), .bool(true),
                ])))
        #expect(reportingFixture.image.module.imports.isEmpty)

        let partialFixture = try FrontendExecutionHarness.compile(
            source: """
            private func overflowPartials<Value: FixedWidthInteger>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Value, Value, Value, Value, Value) {
                (
                    lhs.addingReportingOverflow(rhs).partialValue,
                    lhs.subtractingReportingOverflow(rhs).partialValue,
                    lhs.multipliedReportingOverflow(by: rhs).partialValue,
                    lhs.dividedReportingOverflow(by: rhs).partialValue,
                    lhs.remainderReportingOverflow(dividingBy: rhs).partialValue
                )
            }

            public func fixedWidthOverflowPartials(
                _ lhs: Int8,
                _ rhs: Int8
            ) -> (Int8, Int8, Int8, Int8, Int8) {
                overflowPartials(lhs, rhs)
            }
            """,
            functionName: "fixedWidthOverflowPartials",
            moduleName: "HelixFixedWidthOverflowPartials"
        )
        #expect(
            interpreter.invoke(
                entry: partialFixture.entry,
                image: partialFixture.image,
                arguments: [try signed8(120), try signed8(10)]
            ) == .returned(
                .tuple([
                    try signed8(-126), try signed8(110), try signed8(-80),
                    try signed8(12), try signed8(0),
                ])))
        #expect(
            interpreter.invoke(
                entry: partialFixture.entry,
                image: partialFixture.image,
                arguments: [try signed8(7), try signed8(0)]
            ) == .returned(
                .tuple([
                    try signed8(7), try signed8(7), try signed8(0),
                    try signed8(7), try signed8(7),
                ])))
        #expect(partialFixture.image.module.imports.isEmpty)
    }

    @Test("Floating requirements preserve IEEE comparisons and sign bits")
    func executesFloatingRequirements() throws {
        let operations = try FrontendExecutionHarness.compile(
            source: """
            private func floating<Value: FloatingPoint>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Value, Value) {
                (lhs / rhs, lhs.remainder(dividingBy: rhs))
            }

            private func magnitude<Value: Numeric>(_ value: Value) -> Value.Magnitude {
                value.magnitude
            }

            public func floatingRequirements(
                _ lhs: Double,
                _ rhs: Double
            ) -> (Double, Double, Double) {
                let values = floating(lhs, rhs)
                return (values.0, values.1, magnitude(lhs))
            }
            """,
            functionName: "floatingRequirements",
            moduleName: "HelixFloatingRequirements"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: operations.entry,
                image: operations.image,
                arguments: [.float64(-5.5), .float64(2)]
            )
                == .returned(
                    .tuple([
                        .float64(-2.75), .float64(0.5), .float64(5.5),
                    ])))

        let relations = try FrontendExecutionHarness.compile(
            source: """
            private func relations<Value: Comparable>(
                _ lhs: Value,
                _ rhs: Value
            ) -> (Bool, Bool, Bool, Bool, Bool, Bool) {
                (
                    lhs == rhs, lhs != rhs, lhs < rhs,
                    lhs <= rhs, lhs > rhs, lhs >= rhs
                )
            }

            public func floatingRelations(
                _ lhs: Double,
                _ rhs: Double
            ) -> (Bool, Bool, Bool, Bool, Bool, Bool) {
                relations(lhs, rhs)
            }
            """,
            functionName: "floatingRelations",
            moduleName: "HelixFloatingRelations"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: relations.entry,
                image: relations.image,
                arguments: [.float64(.nan), .float64(1)]
            )
                == .returned(
                    .tuple([
                        .bool(false), .bool(true), .bool(false),
                        .bool(false), .bool(false), .bool(false),
                    ])))
        #expect(
            interpreter.invoke(
                entry: relations.entry,
                image: relations.image,
                arguments: [.float64(-0.0), .float64(0.0)]
            )
                == .returned(
                    .tuple([
                        .bool(true), .bool(false), .bool(false),
                        .bool(true), .bool(false), .bool(true),
                    ])))
        #expect(operations.image.module.imports.isEmpty)
        #expect(relations.image.module.imports.isEmpty)
    }

    @Test("Mutating numeric requirements write back through concrete inout")
    func executesMutatingNumericRequirements() throws {
        let integerFixture = try FrontendExecutionHarness.compile(
            source: """
            private func update<Value: SignedNumeric>(
                _ input: Value,
                _ other: Value
            ) -> Value {
                var value = input
                value += other
                value -= other
                value *= other
                value.negate()
                return value
            }

            public func mutatingIntegerRequirements(
                _ input: Int,
                _ other: Int
            ) -> Int {
                update(input, other)
            }
            """,
            functionName: "mutatingIntegerRequirements",
            moduleName: "HelixMutatingIntegerRequirements"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: integerFixture.entry,
                image: integerFixture.image,
                arguments: [try integer(3), try integer(4)]
            ) == .returned(try integer(-12)))
        #expect(
            interpreter.invoke(
                entry: integerFixture.entry,
                image: integerFixture.image,
                arguments: [try integer(.max), try integer(1)]
            ) == .trapped(.integerOverflow))

        let floatingFixture = try FrontendExecutionHarness.compile(
            source: """
            private func update<Value: SignedNumeric>(
                _ input: Value,
                _ other: Value
            ) -> Value {
                var value = input
                value += other
                value -= other
                value *= other
                value.negate()
                return value
            }

            public func mutatingFloatingRequirements(
                _ input: Double,
                _ other: Double
            ) -> Double {
                update(input, other)
            }
            """,
            functionName: "mutatingFloatingRequirements",
            moduleName: "HelixMutatingFloatingRequirements"
        )
        #expect(
            interpreter.invoke(
                entry: floatingFixture.entry,
                image: floatingFixture.image,
                arguments: [.float64(3.5), .float64(2)]
            ) == .returned(.float64(-7)))
        #expect(integerFixture.image.module.imports.isEmpty)
        #expect(floatingFixture.image.module.imports.isEmpty)
    }

    @Test("Lossless parsing and descriptions use represented scalar semantics")
    func executesTextualProtocolRequirements() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func parse<Value: LosslessStringConvertible>(
                _ type: Value.Type,
                _ text: String
            ) -> Value? {
                Value(text)
            }

            private func describe<Value: CustomStringConvertible>(
                _ value: Value
            ) -> String {
                value.description
            }

            public func textualProtocolRequirements(
                _ integerText: String,
                _ floatingText: String,
                _ booleanText: String
            ) -> (Int?, Double?, Bool?, String?, String) {
                (
                    parse(Int.self, integerText),
                    parse(Double.self, floatingText),
                    parse(Bool.self, booleanText),
                    parse(String.self, integerText),
                    describe(42)
                )
            }
            """,
            functionName: "textualProtocolRequirements",
            moduleName: "HelixTextualProtocolRequirements"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("17"), .string("2.5"), .string("true")]
            )
                == .returned(
                    .tuple([
                        .optional(try integer(17)), .optional(.float64(2.5)),
                        .optional(.bool(true)), .optional(.string("17")), .string("42"),
                    ])))
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("no"), .string("no"), .string("no")]
            )
                == .returned(
                    .tuple([
                        .optional(nil), .optional(nil), .optional(nil),
                        .optional(.string("no")), .string("42"),
                    ])))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Generic standard literal protocols preserve concrete Swift values")
    func executesGenericLiteralRequirements() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import CoreGraphics

            private func integer<Value: ExpressibleByIntegerLiteral>(
                _ type: Value.Type
            ) -> Value { 3 }

            private func maximumInteger<Value: ExpressibleByIntegerLiteral>(
                _ type: Value.Type
            ) -> Value { 18446744073709551615 }

            private func numeric<Value: Numeric>(
                _ type: Value.Type
            ) -> Value { 7 }

            private func negative<Value: SignedNumeric>(
                _ type: Value.Type
            ) -> Value { -5 }

            private func boolean<Value: ExpressibleByBooleanLiteral>(
                _ type: Value.Type
            ) -> Value { true }

            private func floating<Value: ExpressibleByFloatLiteral>(
                _ type: Value.Type
            ) -> Value { 2.5 }

            private func string<Value: ExpressibleByStringLiteral>(
                _ type: Value.Type
            ) -> Value { "hello" }

            private func grapheme<Value: ExpressibleByExtendedGraphemeClusterLiteral>(
                _ type: Value.Type
            ) -> Value { "é" }

            private func scalar<Value: ExpressibleByUnicodeScalarLiteral>(
                _ type: Value.Type
            ) -> Value { "界" }

            public func genericStandardLiterals() -> (
                Int8, UInt64, Float, Double, Bool,
                String, Character, Character, Double, Int16, Int32,
                CGFloat, CGFloat, UInt64
            ) {
                (
                    integer(Int8.self), integer(UInt64.self),
                    floating(Float.self), floating(Double.self),
                    boolean(Bool.self), string(String.self),
                    grapheme(Character.self), scalar(Character.self),
                    integer(Double.self), numeric(Int16.self),
                    negative(Int32.self), integer(CGFloat.self),
                    floating(CGFloat.self), maximumInteger(UInt64.self)
                )
            }
            """,
            functionName: "genericStandardLiterals",
            moduleName: "HelixGenericStandardLiterals"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: []
            )
                == .returned(
                    .tuple([
                        .integer(try .init(signed: 3, bitWidth: 8, isSigned: true)),
                        try unsigned(3),
                        .float32(2.5), .float64(2.5), .bool(true),
                        .string("hello"), .string("é"), .string("界"),
                        .float64(3),
                        .integer(try .init(signed: 7, bitWidth: 16, isSigned: true)),
                        .integer(try .init(signed: -5, bitWidth: 32, isSigned: true)),
                        .float64(3), .float64(2.5),
                        try unsigned(.max),
                    ])))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Strideable requirements preserve signed, unsigned, and floating bounds")
    func executesStrideableRequirements() throws {
        let signedFixture = try FrontendExecutionHarness.compile(
            source: """
            private func stride<Value: Strideable>(
                _ value: Value,
                to destination: Value,
                by offset: Value.Stride
            ) -> (Value.Stride, Value) {
                (
                    value.distance(to: destination),
                    value.advanced(by: offset)
                )
            }

            public func signedStride(
                _ value: Int8,
                _ destination: Int8,
                _ offset: Int
            ) -> (Int, Int8) {
                stride(value, to: destination, by: offset)
            }
            """,
            functionName: "signedStride",
            moduleName: "HelixSignedStride"
        )
        let signedArguments: [VM.Value] = [
            .integer(try .init(signed: -120, bitWidth: 8, isSigned: true)),
            .integer(try .init(signed: 127, bitWidth: 8, isSigned: true)),
            try integer(7),
        ]
        #expect(
            VM.Interpreter().invoke(
                entry: signedFixture.entry,
                image: signedFixture.image,
                arguments: signedArguments
            )
                == .returned(
                    .tuple([
                        try integer(247),
                        .integer(try .init(signed: -113, bitWidth: 8, isSigned: true)),
                    ])))
        #expect(
            VM.Interpreter().invoke(
                entry: signedFixture.entry,
                image: signedFixture.image,
                arguments: [
                    .integer(try .init(signed: 120, bitWidth: 8, isSigned: true)),
                    .integer(try .init(signed: 127, bitWidth: 8, isSigned: true)),
                    try integer(8),
                ]
            ) == .trapped(.integerOverflow))

        let unsignedFixture = try FrontendExecutionHarness.compile(
            source: """
            private func stride<Value: Strideable>(
                _ value: Value,
                to destination: Value,
                by offset: Value.Stride
            ) -> (Value.Stride, Value) {
                (
                    value.distance(to: destination),
                    value.advanced(by: offset)
                )
            }

            public func unsignedStride(
                _ value: UInt64,
                _ destination: UInt64,
                _ offset: Int
            ) -> (Int, UInt64) {
                stride(value, to: destination, by: offset)
            }
            """,
            functionName: "unsignedStride",
            moduleName: "HelixUnsignedStride"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: unsignedFixture.entry,
                image: unsignedFixture.image,
                arguments: [try unsigned(.max), try unsigned(.max - 3), try integer(-2)]
            )
                == .returned(
                    .tuple([
                        try integer(-3), try unsigned(.max - 2),
                    ])))
        #expect(
            VM.Interpreter().invoke(
                entry: unsignedFixture.entry,
                image: unsignedFixture.image,
                arguments: [try unsigned(0), try unsigned(.max), try integer(0)]
            ) == .trapped(.integerOverflow))
        #expect(
            VM.Interpreter().invoke(
                entry: unsignedFixture.entry,
                image: unsignedFixture.image,
                arguments: [try unsigned(0), try unsigned(1), try integer(-1)]
            ) == .trapped(.integerOverflow))

        let floatingFixture = try FrontendExecutionHarness.compile(
            source: """
            private func stride<Value: Strideable>(
                _ value: Value,
                to destination: Value,
                by offset: Value.Stride
            ) -> (Value.Stride, Value) {
                (
                    value.distance(to: destination),
                    value.advanced(by: offset)
                )
            }

            public func floatingStride(
                _ value: Double,
                _ destination: Double,
                _ offset: Double
            ) -> (Double, Double) {
                stride(value, to: destination, by: offset)
            }
            """,
            functionName: "floatingStride",
            moduleName: "HelixFloatingStride"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: floatingFixture.entry,
                image: floatingFixture.image,
                arguments: [.float64(1.5), .float64(4), .float64(-0.25)]
            ) == .returned(.tuple([.float64(2.5), .float64(1.25)])))

        #expect(signedFixture.image.module.imports.isEmpty)
        #expect(unsignedFixture.image.module.imports.isEmpty)
        #expect(floatingFixture.image.module.imports.isEmpty)
    }

    @Test("Standard protocol operations compose through ordinary closure values")
    func executesStandardProtocolClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func equality<Value: Equatable>() -> (Value, Value) -> Bool {
                (==)
            }

            private func description<Value: CustomStringConvertible>(
                _ value: Value
            ) -> () -> String {
                { value.description }
            }

            private func advance<Value: Strideable>(
                _ value: Value
            ) -> (Value.Stride) -> Value {
                value.advanced
            }

            public func standardProtocolClosures(
                _ lhs: Int,
                _ rhs: Int
            ) -> (Bool, String, Int) {
                let compare: (Int, Int) -> Bool = equality()
                let describe = description(lhs)
                let advanced = advance(lhs)
                return (compare(lhs, rhs), describe(), advanced(2))
            }
            """,
            functionName: "standardProtocolClosures",
            moduleName: "HelixStandardProtocolClosures"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(9), try integer(9)]
            ) == .returned(.tuple([.bool(true), .string("9"), try integer(11)])))
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(9), try integer(8)]
            ) == .returned(.tuple([.bool(false), .string("9"), try integer(11)])))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Standard evidence and compiler literals fail closed by source identity")
    func rejectsShapeOnlyConformanceAndInvalidLiterals() throws {
        let environment = CanonicalSIL.TypeEnvironment.empty
        #expect(
            environment.standardConformanceAssociatedTypes(
                concrete: "Builtin.Int64",
                protocolName: "Numeric"
            ) == nil)
        #expect(
            environment.standardConformanceAssociatedTypes(
                concrete: "(Int, Int)",
                protocolName: "Equatable"
            ) == nil)
        #expect(
            environment.standardConformanceAssociatedTypes(
                concrete: "Bool",
                protocolName: "Numeric"
            ) == nil)
        let nativeID = Core.TypeID(rawValue: .sha256("Foundation.Date"))
        let nativeEnvironment = try environment.includingNativeTypes(
            ["Foundation.Date": nativeID]
        )
        #expect(
            nativeEnvironment.standardConformanceAssociatedTypes(
                concrete: "Foundation.Date",
                protocolName: "Comparable"
            ) == nil)
        #expect(
            environment.standardConformanceAssociatedTypes(
                concrete: "Int8",
                protocolName: "Numeric"
            ) == [
                "Magnitude": "UInt8",
                "IntegerLiteralType": "Int8",
            ])

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try FrontendExecutionHarness.compile(
                source: """
              private func literal<Value: ExpressibleByIntegerLiteral>(
                  _ type: Value.Type
              ) -> Value { 128 }

              public func invalidConcreteLiteral() -> Int8 {
                  literal(Int8.self)
              }
              """,
                functionName: "invalidConcreteLiteral",
                moduleName: "HelixInvalidConcreteLiteral"
            )
        }
    }

    @Test("Recursive represented values satisfy Equatable without user witnesses")
    func executesRecursiveRepresentedEquality() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func same<Value: Equatable>(_ lhs: Value, _ rhs: Value) -> Bool {
                lhs == rhs
            }

            private func preserve<Value: Hashable>(_ value: Value) -> Value {
                value
            }

            public func recursiveRepresentedEquality(_ value: Int) -> (
                Bool, Bool, Bool, Bool, Bool
            ) {
                (
                    same([value, 2], [value, 2]),
                    same(Optional(value), Optional(value)),
                    same(["value": value], ["value": value]),
                    same(Set([value]), Set([value])),
                    preserve([value: 2]) == [value: 2]
                )
            }
            """,
            functionName: "recursiveRepresentedEquality",
            moduleName: "HelixRecursiveRepresentedEquality"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(9)]
            ) == .returned(.tuple(Array(repeating: .bool(true), count: 5))))
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Derived local protocols remain exact frontend witnesses")
    func executesDerivedLocalProtocolRequirements() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Direction: Int, CaseIterable {
                case north = 2
                case east = 4
            }

            private struct Item: Identifiable, CustomStringConvertible {
                var id: Int
                var description: String { "item:" + String(id) }
            }

            private func raw<Value: RawRepresentable>(_ value: Value) -> Value.RawValue {
                value.rawValue
            }

            private func all<Value: CaseIterable>(_: Value.Type) -> Value.AllCases {
                Value.allCases
            }

            private func identity<Value: Identifiable>(_ value: Value) -> Value.ID {
                value.id
            }

            private func describe<Value: CustomStringConvertible>(_ value: Value) -> String {
                value.description
            }

            public func derivedProtocolOperations(_ value: Int) -> String {
                let cases = all(Direction.self)
                let item = Item(id: value)
                return String(raw(cases[0])) + ":" + String(identity(item))
                    + ":" + describe(item)
            }
            """,
            functionName: "derivedProtocolOperations",
            moduleName: "HelixDerivedProtocolOperations"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(9)]
            ) == .returned(.string("2:9:item:9"))
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func unsigned(_ value: UInt64) throws -> VM.Value {
        .integer(try .init(rawBits: value, bitWidth: 64, isSigned: false))
    }
}
}
