#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Runtime storage shared by `Array` and contiguous Array-backed views.
///
/// Elements are kept in physical zero-based order, while `indexBase` retains
/// the public integer-index identity of a view such as `ArraySlice`. Keeping
/// both facts in the value makes the identity survive ordinary ownership,
/// storage, aggregate, and function-call boundaries without importing the
/// Swift standard library's private collection ABI.
public struct ArrayStorage: Hashable, Sendable, CustomStringConvertible {
    public let elements: [VM.Value]
    public let elementType: Bytecode.ValueType
    public let indexBase: Int64

    public init(
        elements: [VM.Value],
        elementType: Bytecode.ValueType,
        indexBase: Int64 = 0
    ) {
        self.elements = elements
        self.elementType = elementType
        self.indexBase = indexBase
    }

    public var description: String {
        "ArrayStorage<\(elementType)>(base: \(indexBase), count: \(elements.count))"
    }

    func endIndex() throws -> Int64 {
        try Self.validatedEndIndex(
            elementCount: elements.count,
            indexBase: indexBase
        )
    }

    static func validatedEndIndex(
        elementCount: Int,
        indexBase: Int64
    ) throws -> Int64 {
        guard let count = Int64(exactly: elementCount) else {
            throw VM.RuntimeTrap.integerOverflow
        }
        let end = indexBase.addingReportingOverflow(count)
        guard !end.overflow else { throw VM.RuntimeTrap.integerOverflow }
        return end.partialValue
    }

    func physicalOffset(
        for logicalIndex: Int64,
        allowsEnd: Bool = false
    ) throws -> Int {
        let offset = logicalIndex.subtractingReportingOverflow(indexBase)
        guard !offset.overflow,
              offset.partialValue >= 0,
              let exact = Int(exactly: offset.partialValue),
              allowsEnd ? exact <= elements.count : exact < elements.count
        else {
            throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                index: logicalIndex,
                count: elements.count
            )
        }
        return exact
    }

    func physicalBounds(
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> Range<Int> {
        guard lowerBound <= upperBound else {
            throw VM.RuntimeTrap.explicit(
                "Array range lower bound exceeds its upper bound"
            )
        }
        let lower = try physicalOffset(for: lowerBound, allowsEnd: true)
        let upper = try physicalOffset(for: upperBound, allowsEnd: true)
        return lower..<upper
    }
}
}
