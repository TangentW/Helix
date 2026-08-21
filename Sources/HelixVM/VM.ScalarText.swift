#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Closed scalar/text semantics used by verifier-visible HLBC operations.
/// Swift's native parsers and formatters are implementation details here; the
/// generic standard-library ABI never crosses the VM boundary.
enum ScalarText {
    static let invalidRadixMessage = "Radix not in range 2...36"

    static func radix(from value: VM.Integer) throws -> Int {
        guard value.bitWidth == 64, value.isSigned,
              let radix = Int(exactly: value.signedValue),
              (2...36).contains(radix)
        else {
            throw VM.RuntimeTrap.explicit(invalidRadixMessage)
        }
        return radix
    }

    static func parse(
        _ text: String,
        as target: Bytecode.ValueType,
        radix explicitRadix: Int?
    ) throws -> VM.Value? {
        switch target {
        case .bool:
            guard explicitRadix == nil else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            return Bool(text).map(VM.Value.bool)

        case let .integer(bitWidth, signed):
            let radix = explicitRadix ?? 10
            guard (2...36).contains(radix) else {
                throw VM.RuntimeTrap.explicit(invalidRadixMessage)
            }
            if signed {
                let bounds = VM.Integer.signedBounds(bitWidth: bitWidth)
                guard let parsed = Int64(text, radix: radix),
                      bounds.min <= parsed,
                      parsed <= bounds.max
                else { return nil }
                return .integer(
                    try VM.Integer(
                        signed: parsed,
                        bitWidth: bitWidth,
                        isSigned: true
                    )
                )
            }
            guard let parsed = UInt64(text, radix: radix),
                  bitWidth == 64 || parsed <= VM.Integer.mask(for: bitWidth)
            else { return nil }
            return .integer(
                try VM.Integer(
                    rawBits: parsed,
                    bitWidth: bitWidth,
                    isSigned: false
                )
            )

        case .float(bitWidth: 32):
            guard explicitRadix == nil else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            return Float(text).map { .float(VM.FloatingValue($0)) }

        case .float(bitWidth: 64):
            guard explicitRadix == nil else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            return Double(text).map { .float(VM.FloatingValue($0)) }

        default:
            throw VM.RuntimeTrap.invalidProgramCounter
        }
    }

    static func maximumFormattedUTF8ByteCount(
        for value: VM.Integer
    ) -> UInt64 {
        // Base two is the longest representation. Signed minima need one byte
        // for the leading minus in addition to every payload bit.
        UInt64(value.bitWidth) + (value.isSigned ? 1 : 0)
    }

    static func format(
        _ value: VM.Integer,
        radix: Int,
        uppercase: Bool
    ) throws -> String {
        guard (2...36).contains(radix) else {
            throw VM.RuntimeTrap.explicit(invalidRadixMessage)
        }
        return value.isSigned
            ? String(value.signedValue, radix: radix, uppercase: uppercase)
            : String(value.unsignedValue, radix: radix, uppercase: uppercase)
    }
}
}
