#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Bounds logic for Array-backed standard-library adapters. Keeping it pure
/// lets the interpreter apply quota-aware copying only after every index and
/// precondition has been validated.
enum ArrayAdapters {
    struct ViewSlice: Equatable {
        var bounds: Range<Int>
        var indexBase: Int64
    }

    static func subsequence(
        storage: VM.ArrayStorage,
        bound: Int64,
        operation: Bytecode.ArraySubsequenceOperation
    ) throws -> ViewSlice {
        _ = try storage.endIndex()
        return try subsequence(
            count: storage.elements.count,
            indexBase: storage.indexBase,
            bound: bound,
            operation: operation
        )
    }

    private static func subsequence(
        count: Int,
        indexBase: Int64,
        bound: Int64,
        operation: Bytecode.ArraySubsequenceOperation
    ) throws -> ViewSlice {
        guard let count64 = Int64(exactly: count) else {
            throw VM.RuntimeTrap.integerOverflow
        }
        guard !indexBase.addingReportingOverflow(count64).overflow else {
            throw VM.RuntimeTrap.integerOverflow
        }

        switch operation {
        case .dropFirst, .dropLast, .prefix, .suffix:
            guard bound >= 0 else {
                throw VM.RuntimeTrap.explicit(
                    "collection subsequence count must not be negative"
                )
            }
            let clamped64 = min(bound, count64)
            let clamped = Int(clamped64)
            let bounds: Range<Int>
            let baseOffset: Int64
            switch operation {
            case .dropFirst:
                bounds = clamped..<count
                baseOffset = clamped64
            case .dropLast:
                bounds = 0..<(count - clamped)
                baseOffset = 0
            case .prefix:
                bounds = 0..<clamped
                baseOffset = 0
            case .suffix:
                bounds = (count - clamped)..<count
                baseOffset = count64 - clamped64
            case .prefixUpTo, .prefixThrough, .suffixFrom:
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            let resultBase = indexBase.addingReportingOverflow(
                baseOffset
            )
            guard !resultBase.overflow else {
                throw VM.RuntimeTrap.integerOverflow
            }
            return .init(
                bounds: bounds,
                indexBase: resultBase.partialValue
            )

        case .prefixUpTo, .suffixFrom:
            let offset = try physicalOffset(
                count: count,
                indexBase: indexBase,
                logicalIndex: bound,
                allowsEnd: true
            )
            return .init(
                bounds: operation == .prefixUpTo
                    ? 0..<offset : offset..<count,
                indexBase: operation == .prefixUpTo
                    ? indexBase : bound
            )

        case .prefixThrough:
            let offset = try physicalOffset(
                count: count,
                indexBase: indexBase,
                logicalIndex: bound,
                allowsEnd: false
            )
            return .init(
                bounds: 0..<(offset + 1),
                indexBase: indexBase
            )
        }
    }

    static func rangeSlice(
        storage: VM.ArrayStorage,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> ViewSlice {
        _ = try storage.endIndex()
        return try rangeSlice(
            count: storage.elements.count,
            indexBase: storage.indexBase,
            lowerBound: lowerBound,
            upperBound: upperBound
        )
    }

    private static func rangeSlice(
        count: Int,
        indexBase: Int64,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> ViewSlice {
        guard lowerBound <= upperBound else {
            throw VM.RuntimeTrap.explicit(
                "Array range lower bound exceeds its upper bound"
            )
        }
        let lower = try physicalOffset(
            count: count,
            indexBase: indexBase,
            logicalIndex: lowerBound,
            allowsEnd: true
        )
        let upper = try physicalOffset(
            count: count,
            indexBase: indexBase,
            logicalIndex: upperBound,
            allowsEnd: true
        )
        return .init(bounds: lower..<upper, indexBase: lowerBound)
    }

    private static func physicalOffset(
        count: Int,
        indexBase: Int64,
        logicalIndex: Int64,
        allowsEnd: Bool
    ) throws -> Int {
        let offset = logicalIndex.subtractingReportingOverflow(indexBase)
        guard !offset.overflow,
              offset.partialValue >= 0,
              let exact = Int(exactly: offset.partialValue),
              allowsEnd ? exact <= count : exact < count
        else {
            throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                index: logicalIndex,
                count: count
            )
        }
        return exact
    }

    static func subsequenceBounds(
        count: Int,
        bound: Int64,
        operation: Bytecode.ArraySubsequenceOperation
    ) throws -> Range<Int> {
        try subsequence(
            count: count,
            indexBase: 0,
            bound: bound,
            operation: operation
        ).bounds
    }

    static func rangeBounds(
        count: Int,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> Range<Int> {
        try rangeSlice(
            count: count,
            indexBase: 0,
            lowerBound: lowerBound,
            upperBound: upperBound
        ).bounds
    }
}
}
