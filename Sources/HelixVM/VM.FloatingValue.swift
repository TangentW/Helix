extension VM {
/// An IEEE-754 scalar whose storage width remains exact inside HLVM.
///
/// In particular, binary32 values never pass through `Double` storage, so
/// signed zero, every NaN payload, and signaling-vs-quiet state survive bridge,
/// constant, copy, and collection paths unchanged.
public struct FloatingValue: Hashable, Sendable, CustomStringConvertible {
    public let bitPattern: UInt64
    public let bitWidth: UInt16

    public init(bitPattern: UInt64, bitWidth: UInt16) throws {
        guard bitWidth == 32 || bitWidth == 64 else {
            throw VM.RuntimeTrap.invalidFloatingPointWidth(bitWidth)
        }
        guard bitWidth == 64 || bitPattern <= UInt32.max else {
            throw VM.RuntimeTrap.invalidFloatingPointBitPattern(
                bitPattern,
                bitWidth: bitWidth
            )
        }
        self.bitPattern = bitPattern
        self.bitWidth = bitWidth
    }

    public init(_ value: Float) {
        bitPattern = UInt64(value.bitPattern)
        bitWidth = 32
    }

    public init(_ value: Double) {
        bitPattern = value.bitPattern
        bitWidth = 64
    }

    /// Returns the scalar as Swift `Float`, converting only when this value is
    /// binary64. The stored `bitPattern` itself is never rewritten.
    public var floatValue: Float {
        bitWidth == 32
            ? Float(bitPattern: UInt32(truncatingIfNeeded: bitPattern))
            : Float(Double(bitPattern: bitPattern))
    }

    /// Returns the scalar as Swift `Double`, converting only when this value is
    /// binary32. The stored `bitPattern` itself is never rewritten.
    public var doubleValue: Double {
        bitWidth == 32
            ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: bitPattern)))
            : Double(bitPattern: bitPattern)
    }

    public var description: String {
        bitWidth == 32 ? String(floatValue) : String(doubleValue)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.bitWidth == rhs.bitWidth else { return false }
        return lhs.bitWidth == 32
            ? lhs.floatValue == rhs.floatValue
            : lhs.doubleValue == rhs.doubleValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bitWidth)
        if bitWidth == 32 {
            hasher.combine(floatValue)
        } else {
            hasher.combine(doubleValue)
        }
    }
}
}
