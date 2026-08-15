extension VM {
enum StringAllocation {
    /// Unicode full case mappings contain at most three output scalars for one
    /// input scalar. Four UTF-8 bytes per output scalar is therefore a safe
    /// allocation bound for non-ASCII input; ASCII mappings remain one byte.
    static let maximumUTF8BytesPerNonASCIIInputScalar: UInt64 = 3 * 4

    static func maximumCaseMappingUTF8ByteCount(for source: String) throws -> UInt64 {
        var maximum: UInt64 = 0
        for scalar in source.unicodeScalars {
            let contribution: UInt64 = scalar.value < 0x80
                ? 1
                : maximumUTF8BytesPerNonASCIIInputScalar
            let next = maximum.addingReportingOverflow(contribution)
            guard !next.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            maximum = next.partialValue
        }
        return maximum
    }

    /// Swift's canonical scalar descriptions are bounded by their fixed-width
    /// payloads. The floating allowance deliberately exceeds the longest exact
    /// finite, infinity, and NaN spellings emitted by the supported widths.
    static func maximumStringificationUTF8ByteCount(for value: VM.Value) throws -> UInt64 {
        switch value {
        case .bool:
            5
        case .integer:
            20
        case let .float(number) where number.bitWidth == 32 || number.bitWidth == 64:
            64
        default:
            throw VM.RuntimeTrap.nativeFailure(
                "stringify is unsupported for \(value.type)"
            )
        }
    }

    static func stringify(_ value: VM.Value) throws -> String {
        switch value {
        case let .bool(boolean):
            String(boolean)
        case let .integer(integer):
            integer.description
        case let .float(number) where number.bitWidth == 32:
            String(number.floatValue)
        case let .float(number) where number.bitWidth == 64:
            String(number.doubleValue)
        default:
            throw VM.RuntimeTrap.nativeFailure(
                "stringify is unsupported for \(value.type)"
            )
        }
    }
}
}
