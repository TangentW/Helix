extension VM {
/// Width-parametric integer semantics that need more than one host machine
/// operation. Inputs and outputs remain raw fixed-width bit patterns so the
/// implementation is independent of Swift's overflow-checking build mode.
enum IntegerSemantics {
    static func byteSwapped(_ value: VM.Integer) -> UInt64 {
        switch value.bitWidth {
        case 8:
            value.rawBits
        case 16:
            UInt64(UInt16(truncatingIfNeeded: value.rawBits).byteSwapped)
        case 32:
            UInt64(UInt32(truncatingIfNeeded: value.rawBits).byteSwapped)
        default:
            value.rawBits.byteSwapped
        }
    }

    static func endianAdjusted(
        _ value: VM.Integer,
        bigEndian: Bool
    ) -> UInt64 {
        #if _endian(little)
        return bigEndian ? byteSwapped(value) : value.rawBits
        #else
        return bigEndian ? value.rawBits : byteSwapped(value)
        #endif
    }

    static func clamped(
        _ source: VM.Integer,
        bitWidth: UInt16,
        isSigned: Bool
    ) throws -> VM.Integer {
        let rawBits: UInt64
        if isSigned {
            let bounds = VM.Integer.signedBounds(bitWidth: bitWidth)
            if source.isSigned {
                let value = min(max(source.signedValue, bounds.min), bounds.max)
                rawBits = UInt64(bitPattern: value)
            } else {
                rawBits = min(source.unsignedValue, UInt64(bounds.max))
            }
        } else {
            let maximum = VM.Integer.mask(for: bitWidth)
            if source.isSigned {
                rawBits = source.signedValue < 0
                    ? 0
                    : min(UInt64(source.signedValue), maximum)
            } else {
                rawBits = min(source.unsignedValue, maximum)
            }
        }
        return try VM.Integer(
            rawBits: rawBits,
            bitWidth: bitWidth,
            isSigned: isSigned
        )
    }

    static func fullWidthProduct(
        _ lhs: VM.Integer,
        _ rhs: VM.Integer
    ) throws -> (high: VM.Integer, low: VM.Integer) {
        guard lhs.bitWidth == rhs.bitWidth,
              lhs.isSigned == rhs.isSigned
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .integer(
                    bitWidth: lhs.bitWidth,
                    signed: lhs.isSigned
                ),
                actual: .integer(
                    bitWidth: rhs.bitWidth,
                    signed: rhs.isSigned
                )
            )
        }

        let width = lhs.bitWidth
        let mask = VM.Integer.mask(for: width)
        var highBits: UInt64
        let lowBits: UInt64
        if width == 64 {
            let product = lhs.rawBits.multipliedFullWidth(by: rhs.rawBits)
            highBits = product.high
            lowBits = product.low
        } else {
            let product = lhs.rawBits * rhs.rawBits
            highBits = (product >> UInt64(width)) & mask
            lowBits = product & mask
        }

        // Convert the unsigned 2N-bit product into the signed 2N-bit product
        // without ever forming a host integer wider than 64 bits.
        if lhs.isSigned {
            if lhs.signedValue < 0 {
                highBits = (highBits &- rhs.rawBits) & mask
            }
            if rhs.signedValue < 0 {
                highBits = (highBits &- lhs.rawBits) & mask
            }
        }
        return (
            high: try VM.Integer(
                rawBits: highBits,
                bitWidth: width,
                isSigned: lhs.isSigned
            ),
            low: try VM.Integer(
                rawBits: lowBits,
                bitWidth: width,
                isSigned: false
            )
        )
    }

    static func fullWidthQuotient(
        dividendHigh: VM.Integer,
        dividendLow: VM.Integer,
        divisor: VM.Integer
    ) throws -> (quotient: VM.Integer, remainder: VM.Integer) {
        guard dividendHigh.bitWidth == divisor.bitWidth,
              dividendHigh.isSigned == divisor.isSigned,
              dividendLow.bitWidth == divisor.bitWidth,
              !dividendLow.isSigned
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .integer(
                    bitWidth: divisor.bitWidth,
                    signed: divisor.isSigned
                ),
                actual: .integer(
                    bitWidth: dividendHigh.bitWidth,
                    signed: dividendHigh.isSigned
                )
            )
        }
        guard divisor.rawBits != 0 else {
            throw VM.RuntimeTrap.divisionByZero
        }

        let width = divisor.bitWidth
        let mask = VM.Integer.mask(for: width)
        if !divisor.isSigned {
            let result = try unsignedFullWidthQuotient(
                high: dividendHigh.rawBits,
                low: dividendLow.rawBits,
                divisor: divisor.rawBits,
                bitWidth: width
            )
            return (
                quotient: try VM.Integer(
                    rawBits: result.quotient,
                    bitWidth: width,
                    isSigned: false
                ),
                remainder: try VM.Integer(
                    rawBits: result.remainder,
                    bitWidth: width,
                    isSigned: false
                )
            )
        }

        let dividendIsNegative = dividendHigh.signedValue < 0
        let divisorIsNegative = divisor.signedValue < 0
        let dividendMagnitude: (high: UInt64, low: UInt64)
        if dividendIsNegative {
            let low = ((~dividendLow.rawBits) & mask) &+ 1
            let normalizedLow = low & mask
            let carry: UInt64 = normalizedLow == 0 ? 1 : 0
            dividendMagnitude = (
                high: (((~dividendHigh.rawBits) & mask) &+ carry) & mask,
                low: normalizedLow
            )
        } else {
            dividendMagnitude = (
                high: dividendHigh.rawBits,
                low: dividendLow.rawBits
            )
        }
        let divisorMagnitude = divisorIsNegative
            ? (0 &- divisor.rawBits) & mask
            : divisor.rawBits
        let magnitude = try unsignedFullWidthQuotient(
            high: dividendMagnitude.high,
            low: dividendMagnitude.low,
            divisor: divisorMagnitude,
            bitWidth: width
        )

        let quotientIsNegative = dividendIsNegative != divisorIsNegative
        let signBit = UInt64(1) << (width - 1)
        let quotientLimit = quotientIsNegative ? signBit : signBit - 1
        guard magnitude.quotient <= quotientLimit else {
            throw VM.RuntimeTrap.integerOverflow
        }
        let quotientBits = quotientIsNegative && magnitude.quotient != 0
            ? (0 &- magnitude.quotient) & mask
            : magnitude.quotient
        let remainderBits = dividendIsNegative && magnitude.remainder != 0
            ? (0 &- magnitude.remainder) & mask
            : magnitude.remainder
        return (
            quotient: try VM.Integer(
                rawBits: quotientBits,
                bitWidth: width,
                isSigned: true
            ),
            remainder: try VM.Integer(
                rawBits: remainderBits,
                bitWidth: width,
                isSigned: true
            )
        )
    }

    private static func unsignedFullWidthQuotient(
        high: UInt64,
        low: UInt64,
        divisor: UInt64,
        bitWidth: UInt16
    ) throws -> (quotient: UInt64, remainder: UInt64) {
        // In base 2^N, high >= divisor implies an N-bit quotient overflow.
        guard high < divisor else {
            throw VM.RuntimeTrap.integerOverflow
        }
        if bitWidth == 64 {
            return divisor.dividingFullWidth((high: high, low: low))
        }
        let dividend = (high << UInt64(bitWidth)) | low
        return (dividend / divisor, dividend % divisor)
    }
}
}
