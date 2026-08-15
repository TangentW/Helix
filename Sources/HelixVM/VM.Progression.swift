#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
enum Progression {
    struct Step: Sendable {
        var result: VM.Value
        var cursor: VM.Value
    }

    static func next(
        cursor: VM.Value,
        end: VM.Value,
        stride: VM.Value,
        boundary: Bytecode.ProgressionBoundary
    ) throws -> Step {
        guard case let .optional(wrapped) = cursor else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .optional(end.type),
                actual: cursor.type
            )
        }
        guard let current = wrapped else {
            return .init(result: .optional(nil), cursor: .optional(nil))
        }

        let advance: VM.Value?
        let hasCurrent: Bool
        switch (current, end, stride) {
        case let (
            .integer(currentValue),
            .integer(endValue),
            .integer(strideValue)
        ):
            guard currentValue.bitWidth == endValue.bitWidth,
                  currentValue.isSigned == endValue.isSigned,
                  strideValue.bitWidth == 64,
                  strideValue.isSigned
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: current.type,
                    actual: end.type
                )
            }
            let distance = strideValue.signedValue
            guard distance != 0 else {
                throw VM.RuntimeTrap.explicit("Stride size must not be zero")
            }
            let isAscending = distance > 0
            hasCurrent = contains(
                currentValue,
                before: endValue,
                ascending: isAscending,
                boundary: boundary
            )
            advance = hasCurrent
                ? try advanced(currentValue, by: distance).map(VM.Value.integer)
                : nil

        case let (
            .float(currentValue, currentWidth),
            .float(endValue, endWidth),
            .float(strideValue, strideWidth)
        ):
            guard currentWidth == endWidth, currentWidth == strideWidth else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: current.type,
                    actual: stride.type
                )
            }
            if currentWidth == 32 {
                let current = Float(currentValue)
                let end = Float(endValue)
                let stride = Float(strideValue)
                guard stride != 0 else {
                    throw VM.RuntimeTrap.explicit("Stride size must not be zero")
                }
                let isAscending = stride > 0
                hasCurrent = containsFloating(
                    current,
                    before: end,
                    ascending: isAscending,
                    boundary: boundary
                )
                advance = hasCurrent
                    ? .float(Double(current + stride), bitWidth: 32)
                    : nil
            } else {
                guard strideValue != 0 else {
                    throw VM.RuntimeTrap.explicit("Stride size must not be zero")
                }
                let isAscending = strideValue > 0
                hasCurrent = containsFloating(
                    currentValue,
                    before: endValue,
                    ascending: isAscending,
                    boundary: boundary
                )
                advance = hasCurrent
                    ? .float(currentValue + strideValue, bitWidth: 64)
                    : nil
            }

        default:
            throw VM.RuntimeTrap.typeMismatch(
                expected: current.type,
                actual: stride.type
            )
        }

        guard hasCurrent else {
            return .init(result: .optional(nil), cursor: .optional(nil))
        }
        return .init(
            result: .optional(current),
            cursor: .optional(advance)
        )
    }

    private static func contains<T: Comparable>(
        _ current: T,
        before end: T,
        ascending: Bool,
        boundary: Bytecode.ProgressionBoundary
    ) -> Bool {
        switch (ascending, boundary) {
        case (true, .exclusive): current < end
        case (true, .inclusive): current <= end
        case (false, .exclusive): current > end
        case (false, .inclusive): current >= end
        }
    }

    private static func containsFloating<T: BinaryFloatingPoint>(
        _ current: T,
        before end: T,
        ascending: Bool,
        boundary: Bytecode.ProgressionBoundary
    ) -> Bool {
        // Swift's Stride iterators negate their terminal comparison. This is
        // observably different from a positive containment test for NaN: a
        // descending NaN stride remains live and is bounded here by HLVM's
        // ordinary instruction budget rather than silently terminating.
        switch (ascending, boundary) {
        case (true, .exclusive): !(current >= end)
        case (true, .inclusive): !(current > end)
        case (false, .exclusive): !(current <= end)
        case (false, .inclusive): !(current < end)
        }
    }

    private static func contains(
        _ current: VM.Integer,
        before end: VM.Integer,
        ascending: Bool,
        boundary: Bytecode.ProgressionBoundary
    ) -> Bool {
        if current.isSigned {
            return contains(
                current.signedValue,
                before: end.signedValue,
                ascending: ascending,
                boundary: boundary
            )
        }
        return contains(
            current.unsignedValue,
            before: end.unsignedValue,
            ascending: ascending,
            boundary: boundary
        )
    }

    private static func advanced(
        _ current: VM.Integer,
        by distance: Int64
    ) throws -> VM.Integer? {
        if current.isSigned {
            let sum = current.signedValue.addingReportingOverflow(distance)
            guard !sum.overflow else { return nil }
            let bounds = VM.Integer.signedBounds(bitWidth: current.bitWidth)
            guard sum.partialValue >= bounds.min,
                  sum.partialValue <= bounds.max
            else { return nil }
            return try .init(
                signed: sum.partialValue,
                bitWidth: current.bitWidth,
                isSigned: true
            )
        }

        let value: UInt64
        if distance > 0 {
            let sum = current.unsignedValue.addingReportingOverflow(
                UInt64(distance)
            )
            guard !sum.overflow,
                  sum.partialValue <= VM.Integer.mask(for: current.bitWidth)
            else { return nil }
            value = sum.partialValue
        } else {
            let magnitude = distance == .min
                ? UInt64(1) << 63
                : UInt64(-distance)
            let difference = current.unsignedValue.subtractingReportingOverflow(
                magnitude
            )
            guard !difference.overflow else { return nil }
            value = difference.partialValue
        }
        return try .init(
            rawBits: value,
            bitWidth: current.bitWidth,
            isSigned: false
        )
    }
}
}
