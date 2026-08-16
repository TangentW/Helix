#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Bounds logic for Array-backed standard-library adapters. Keeping it pure
/// lets the interpreter apply quota-aware copying only after every index and
/// precondition has been validated.
enum ArrayAdapters {
    static func subsequenceBounds(
        count: Int,
        bound: Int64,
        operation: Bytecode.ArraySubsequenceOperation
    ) throws -> Range<Int> {
        guard let count64 = Int64(exactly: count) else {
            throw VM.RuntimeTrap.integerOverflow
        }

        switch operation {
        case .dropFirst, .dropLast, .prefix, .suffix:
            guard bound >= 0 else {
                throw VM.RuntimeTrap.explicit(
                    "collection subsequence count must not be negative"
                )
            }
            let clamped = Int(min(bound, count64))
            return switch operation {
            case .dropFirst: clamped..<count
            case .dropLast: 0..<(count - clamped)
            case .prefix: 0..<clamped
            case .suffix: (count - clamped)..<count
            case .prefixUpTo, .prefixThrough, .suffixFrom:
                throw VM.RuntimeTrap.invalidProgramCounter
            }

        case .prefixUpTo, .suffixFrom:
            guard bound >= 0, bound <= count64 else {
                throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                    index: bound,
                    count: count
                )
            }
            let index = Int(bound)
            return operation == .prefixUpTo
                ? 0..<index
                : index..<count

        case .prefixThrough:
            guard bound >= 0, bound < count64 else {
                throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                    index: bound,
                    count: count
                )
            }
            return 0..<(Int(bound) + 1)
        }
    }

    static func rangeBounds(
        count: Int,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> Range<Int> {
        guard let count64 = Int64(exactly: count) else {
            throw VM.RuntimeTrap.integerOverflow
        }
        guard lowerBound <= upperBound else {
            throw VM.RuntimeTrap.explicit(
                "Array slice lower bound exceeds its upper bound"
            )
        }
        guard lowerBound >= 0, lowerBound <= count64 else {
            throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                index: lowerBound,
                count: count
            )
        }
        guard upperBound >= 0, upperBound <= count64 else {
            throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                index: upperBound,
                count: count
            )
        }
        return Int(lowerBound)..<Int(upperBound)
    }
}
}
