import Testing
@testable import HelixVM

extension VMTests {
@Suite("Width-parametric integer semantics")
struct IntegerSemantics {
    @Test("Full-width products agree with every Swift fixed-width family")
    func fullWidthProductsMatchSwift() throws {
        var state: UInt64 = 0x484c_5846_554c_4c57
        for width: UInt16 in [8, 16, 32, 64] {
            for signed in [false, true] {
                for caseID in 0..<1_000 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let lhsBits = state
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let rhsBits = state
                    let lhs = try VM.Integer(
                        rawBits: lhsBits,
                        bitWidth: width,
                        isSigned: signed
                    )
                    let rhs = try VM.Integer(
                        rawBits: rhsBits,
                        bitWidth: width,
                        isSigned: signed
                    )
                    let expected = expectedProduct(lhs, rhs)
                    let actual = try VM.IntegerSemantics.fullWidthProduct(
                        lhs,
                        rhs
                    )
                    #expect(
                        actual.high.rawBits == expected.high,
                        Comment(
                            rawValue: "high mismatch at width \(width), signed \(signed), case \(caseID)"
                        )
                    )
                    #expect(
                        actual.low.rawBits == expected.low,
                        Comment(
                            rawValue: "low mismatch at width \(width), signed \(signed), case \(caseID)"
                        )
                    )
                    #expect(actual.high.isSigned == signed)
                    #expect(!actual.low.isSigned)
                }
            }
        }
    }

    @Test("Full-width quotients match Swift across signs and widths")
    func fullWidthQuotientsMatchSwift() throws {
        let cases: [DivisionCase] = [
            .init(width: 8, signed: false, high: 3, low: 201, divisor: 7),
            .init(width: 16, signed: false, high: 17, low: 50_000, divisor: 91),
            .init(width: 32, signed: false, high: 3, low: 0xFEDC_BA98, divisor: 11),
            .init(width: 64, signed: false, high: 7, low: .max, divisor: 13),
            .init(width: 8, signed: true, high: 2, low: 200, divisor: 7),
            .init(width: 8, signed: true, high: 254, low: 56, divisor: 7),
            .init(width: 8, signed: true, high: 254, low: 56, divisor: 249),
            .init(width: 16, signed: true, high: 100, low: 12_345, divisor: 300),
            .init(
                width: 16,
                signed: true,
                high: UInt64(UInt16(bitPattern: -100)),
                low: 12_345,
                divisor: 300
            ),
            .init(width: 32, signed: true, high: 1, low: 123, divisor: 1 << 20),
            .init(
                width: 32,
                signed: true,
                high: UInt64(UInt32(bitPattern: -2)),
                low: 0,
                divisor: 1 << 20
            ),
            .init(width: 64, signed: true, high: 1, low: 0, divisor: UInt64(Int64.max)),
            .init(width: 64, signed: true, high: .max, low: 0, divisor: UInt64(Int64.max)),
        ]

        for item in cases {
            let high = try VM.Integer(
                rawBits: item.high,
                bitWidth: item.width,
                isSigned: item.signed
            )
            let low = try VM.Integer(
                rawBits: item.low,
                bitWidth: item.width,
                isSigned: false
            )
            let divisor = try VM.Integer(
                rawBits: item.divisor,
                bitWidth: item.width,
                isSigned: item.signed
            )
            let expected = expectedDivision(
                high: high,
                low: low,
                divisor: divisor
            )
            let actual = try VM.IntegerSemantics.fullWidthQuotient(
                dividendHigh: high,
                dividendLow: low,
                divisor: divisor
            )
            #expect(actual.quotient.rawBits == expected.quotient)
            #expect(actual.remainder.rawBits == expected.remainder)
            #expect(actual.quotient.isSigned == item.signed)
            #expect(actual.remainder.isSigned == item.signed)
        }

        // A full-width product divided by either factor must recover the
        // other factor exactly. Seeded cases exercise arbitrary high words,
        // including signed 2N-bit dividends, without relying on trap-prone
        // random calls to Swift's dividingFullWidth implementation.
        var state: UInt64 = 0x484c_5844_4956_4944
        for width: UInt16 in [8, 16, 32, 64] {
            for signed in [false, true] {
                for caseID in 0..<1_000 {
                    state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                    var divisor = try VM.Integer(
                        rawBits: state,
                        bitWidth: width,
                        isSigned: signed
                    )
                    if divisor.rawBits == 0 {
                        divisor = try VM.Integer(
                            rawBits: 1,
                            bitWidth: width,
                            isSigned: signed
                        )
                    }
                    state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                    let expectedQuotient = try VM.Integer(
                        rawBits: state,
                        bitWidth: width,
                        isSigned: signed
                    )
                    let product = expectedProduct(
                        divisor,
                        expectedQuotient
                    )
                    let actual = try VM.IntegerSemantics.fullWidthQuotient(
                        dividendHigh: VM.Integer(
                            rawBits: product.high,
                            bitWidth: width,
                            isSigned: signed
                        ),
                        dividendLow: VM.Integer(
                            rawBits: product.low,
                            bitWidth: width,
                            isSigned: false
                        ),
                        divisor: divisor
                    )
                    #expect(
                        actual.quotient == expectedQuotient,
                        Comment(
                            rawValue: "inverse-product quotient mismatch at width \(width), signed \(signed), case \(caseID)"
                        )
                    )
                    #expect(actual.remainder.rawBits == 0)
                }
            }
        }
    }

    @Test("Full-width division rejects zero and unrepresentable quotients")
    func fullWidthDivisionTrapsPrecisely() throws {
        let unsigned = try VM.Integer(
            rawBits: 1,
            bitWidth: 64,
            isSigned: false
        )
        let zero = try VM.Integer(
            rawBits: 0,
            bitWidth: 64,
            isSigned: false
        )
        #expect(throws: VM.RuntimeTrap.divisionByZero) {
            _ = try VM.IntegerSemantics.fullWidthQuotient(
                dividendHigh: zero,
                dividendLow: unsigned,
                divisor: zero
            )
        }
        #expect(throws: VM.RuntimeTrap.integerOverflow) {
            _ = try VM.IntegerSemantics.fullWidthQuotient(
                dividendHigh: unsigned,
                dividendLow: zero,
                divisor: unsigned
            )
        }

        let signedOne = try VM.Integer(
            rawBits: 1,
            bitWidth: 64,
            isSigned: true
        )
        #expect(throws: VM.RuntimeTrap.integerOverflow) {
            _ = try VM.IntegerSemantics.fullWidthQuotient(
                dividendHigh: signedOne,
                dividendLow: zero,
                divisor: signedOne
            )
        }
    }

    @Test("Clamping and endian transforms cover signedness boundaries")
    func conversionsAndEndianBoundaries() throws {
        let cases: [(
            source: VM.Integer,
            width: UInt16,
            signed: Bool,
            expected: UInt64
        )] = [
            (try integer(-1, width: 64, signed: true), 8, false, 0),
            (try integer(300, width: 64, signed: true), 8, false, 255),
            (try integer(200, width: 64, signed: false), 8, true, 127),
            (try integer(UInt64.max, width: 64, signed: false), 64, true, UInt64(Int64.max)),
            (try integer(Int64.min, width: 64, signed: true), 64, false, 0),
            (try integer(42, width: 8, signed: false), 64, true, 42),
        ]
        for item in cases {
            let actual = try VM.IntegerSemantics.clamped(
                item.source,
                bitWidth: item.width,
                isSigned: item.signed
            )
            #expect(actual.rawBits == item.expected)
            #expect(actual.bitWidth == item.width)
            #expect(actual.isSigned == item.signed)
        }

        let value = try integer(0x0102_0304, width: 32, signed: false)
        #expect(
            VM.IntegerSemantics.byteSwapped(value) == 0x0403_0201
        )
        #if _endian(little)
        #expect(
            VM.IntegerSemantics.endianAdjusted(value, bigEndian: true)
                == 0x0403_0201
        )
        #expect(
            VM.IntegerSemantics.endianAdjusted(value, bigEndian: false)
                == value.rawBits
        )
        #else
        #expect(
            VM.IntegerSemantics.endianAdjusted(value, bigEndian: true)
                == value.rawBits
        )
        #expect(
            VM.IntegerSemantics.endianAdjusted(value, bigEndian: false)
                == 0x0403_0201
        )
        #endif
    }

    private struct DivisionCase {
        var width: UInt16
        var signed: Bool
        var high: UInt64
        var low: UInt64
        var divisor: UInt64
    }

    private func expectedProduct(
        _ lhs: VM.Integer,
        _ rhs: VM.Integer
    ) -> (high: UInt64, low: UInt64) {
        switch (lhs.bitWidth, lhs.isSigned) {
        case (8, false):
            let value = UInt8(truncatingIfNeeded: lhs.rawBits)
                .multipliedFullWidth(
                    by: UInt8(truncatingIfNeeded: rhs.rawBits)
                )
            return (UInt64(value.high), UInt64(value.low))
        case (8, true):
            let value = Int8(bitPattern: UInt8(truncatingIfNeeded: lhs.rawBits))
                .multipliedFullWidth(
                    by: Int8(bitPattern: UInt8(truncatingIfNeeded: rhs.rawBits))
                )
            return (
                UInt64(UInt8(bitPattern: value.high)),
                UInt64(value.low)
            )
        case (16, false):
            let value = UInt16(truncatingIfNeeded: lhs.rawBits)
                .multipliedFullWidth(
                    by: UInt16(truncatingIfNeeded: rhs.rawBits)
                )
            return (UInt64(value.high), UInt64(value.low))
        case (16, true):
            let value = Int16(bitPattern: UInt16(truncatingIfNeeded: lhs.rawBits))
                .multipliedFullWidth(
                    by: Int16(bitPattern: UInt16(truncatingIfNeeded: rhs.rawBits))
                )
            return (
                UInt64(UInt16(bitPattern: value.high)),
                UInt64(value.low)
            )
        case (32, false):
            let value = UInt32(truncatingIfNeeded: lhs.rawBits)
                .multipliedFullWidth(
                    by: UInt32(truncatingIfNeeded: rhs.rawBits)
                )
            return (UInt64(value.high), UInt64(value.low))
        case (32, true):
            let value = Int32(bitPattern: UInt32(truncatingIfNeeded: lhs.rawBits))
                .multipliedFullWidth(
                    by: Int32(bitPattern: UInt32(truncatingIfNeeded: rhs.rawBits))
                )
            return (
                UInt64(UInt32(bitPattern: value.high)),
                UInt64(value.low)
            )
        case (64, false):
            let value = lhs.rawBits.multipliedFullWidth(by: rhs.rawBits)
            return (value.high, value.low)
        default:
            let value = Int64(bitPattern: lhs.rawBits).multipliedFullWidth(
                by: Int64(bitPattern: rhs.rawBits)
            )
            return (UInt64(bitPattern: value.high), value.low)
        }
    }

    private func expectedDivision(
        high: VM.Integer,
        low: VM.Integer,
        divisor: VM.Integer
    ) -> (quotient: UInt64, remainder: UInt64) {
        switch (divisor.bitWidth, divisor.isSigned) {
        case (8, false):
            let value = UInt8(truncatingIfNeeded: divisor.rawBits)
                .dividingFullWidth((
                    high: UInt8(truncatingIfNeeded: high.rawBits),
                    low: UInt8(truncatingIfNeeded: low.rawBits)
                ))
            return (UInt64(value.quotient), UInt64(value.remainder))
        case (8, true):
            let value = Int8(bitPattern: UInt8(truncatingIfNeeded: divisor.rawBits))
                .dividingFullWidth((
                    high: Int8(bitPattern: UInt8(truncatingIfNeeded: high.rawBits)),
                    low: UInt8(truncatingIfNeeded: low.rawBits)
                ))
            return (
                UInt64(UInt8(bitPattern: value.quotient)),
                UInt64(UInt8(bitPattern: value.remainder))
            )
        case (16, false):
            let value = UInt16(truncatingIfNeeded: divisor.rawBits)
                .dividingFullWidth((
                    high: UInt16(truncatingIfNeeded: high.rawBits),
                    low: UInt16(truncatingIfNeeded: low.rawBits)
                ))
            return (UInt64(value.quotient), UInt64(value.remainder))
        case (16, true):
            let value = Int16(bitPattern: UInt16(truncatingIfNeeded: divisor.rawBits))
                .dividingFullWidth((
                    high: Int16(bitPattern: UInt16(truncatingIfNeeded: high.rawBits)),
                    low: UInt16(truncatingIfNeeded: low.rawBits)
                ))
            return (
                UInt64(UInt16(bitPattern: value.quotient)),
                UInt64(UInt16(bitPattern: value.remainder))
            )
        case (32, false):
            let value = UInt32(truncatingIfNeeded: divisor.rawBits)
                .dividingFullWidth((
                    high: UInt32(truncatingIfNeeded: high.rawBits),
                    low: UInt32(truncatingIfNeeded: low.rawBits)
                ))
            return (UInt64(value.quotient), UInt64(value.remainder))
        case (32, true):
            let value = Int32(bitPattern: UInt32(truncatingIfNeeded: divisor.rawBits))
                .dividingFullWidth((
                    high: Int32(bitPattern: UInt32(truncatingIfNeeded: high.rawBits)),
                    low: UInt32(truncatingIfNeeded: low.rawBits)
                ))
            return (
                UInt64(UInt32(bitPattern: value.quotient)),
                UInt64(UInt32(bitPattern: value.remainder))
            )
        case (64, false):
            let value = divisor.rawBits.dividingFullWidth((
                high: high.rawBits,
                low: low.rawBits
            ))
            return (value.quotient, value.remainder)
        default:
            let value = Int64(bitPattern: divisor.rawBits)
                .dividingFullWidth((
                    high: Int64(bitPattern: high.rawBits),
                    low: low.rawBits
                ))
            return (
                UInt64(bitPattern: value.quotient),
                UInt64(bitPattern: value.remainder)
            )
        }
    }

    private func integer<T: BinaryInteger>(
        _ value: T,
        width: UInt16,
        signed: Bool
    ) throws -> VM.Integer {
        if signed {
            return try .init(
                signed: Int64(truncatingIfNeeded: value),
                bitWidth: width,
                isSigned: true
            )
        }
        return try .init(
            rawBits: UInt64(truncatingIfNeeded: value),
            bitWidth: width,
            isSigned: false
        )
    }
}
}
