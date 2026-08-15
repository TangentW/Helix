#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Reproduces the value equality and hashing of the closed family accepted by
/// `Bytecode.ValueType.isVMHashable`. Collection cases deliberately do not use
/// `VM.Value`'s synthesized equality because Dictionary and Set order is not
/// part of Swift equality.
struct HashableValue: Hashable, Sendable {
    let value: VM.Value

    static func == (lhs: Self, rhs: Self) -> Bool {
        equal(lhs.value, rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        Self.hash(value, into: &hasher)
    }

    static func equal(_ lhs: VM.Value, _ rhs: VM.Value) -> Bool {
        switch (lhs, rhs) {
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs
        case let (.integer(lhs), .integer(rhs)):
            return lhs == rhs
        case let (.float(lhs), .float(rhs)):
            return lhs == rhs
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs
        case let (.optional(lhs), .optional(rhs)):
            return switch (lhs, rhs) {
            case (.none, .none): true
            case let (.some(lhs), .some(rhs)): equal(lhs, rhs)
            default: false
            }
        case let (.array(lhs, lhsType), .array(rhs, rhsType)):
            return lhsType == rhsType
                && lhs.count == rhs.count
                && (sharesStorage(lhs, rhs) || zip(lhs, rhs).allSatisfy(equal))
        case let (
            .dictionary(lhs, lhsKey, lhsValue),
            .dictionary(rhs, rhsKey, rhsValue)
        ):
            guard lhsKey == rhsKey,
                  lhsValue == rhsValue,
                  lhs.count == rhs.count
            else { return false }
            if sharesStorage(lhs, rhs) { return true }
            var rightByKey: [VM.HashableValue: VM.Value] = [:]
            rightByKey.reserveCapacity(rhs.count)
            for entry in rhs {
                guard rightByKey.updateValue(
                    entry.value,
                    forKey: .init(value: entry.key)
                ) == nil else { return false }
            }
            return lhs.allSatisfy { entry in
                rightByKey[.init(value: entry.key)].map {
                    equal(entry.value, $0)
                } ?? false
            }
        case let (.set(lhs), .set(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }

    private static func hash(_ value: VM.Value, into hasher: inout Hasher) {
        switch value {
        case let .bool(value):
            hasher.combine(0 as UInt8)
            hasher.combine(value)
        case let .integer(value):
            hasher.combine(1 as UInt8)
            hasher.combine(value)
        case let .float(value):
            hasher.combine(2 as UInt8)
            hasher.combine(value)
        case let .string(value):
            hasher.combine(3 as UInt8)
            hasher.combine(value)
        case let .optional(value):
            hasher.combine(4 as UInt8)
            if let value {
                hasher.combine(true)
                hash(value, into: &hasher)
            } else {
                hasher.combine(false)
            }
        case let .array(values, elementType):
            hasher.combine(5 as UInt8)
            hasher.combine(elementType)
            hasher.combine(values.count)
            for value in values {
                hash(value, into: &hasher)
            }
        case let .dictionary(entries, keyType, valueType):
            hasher.combine(6 as UInt8)
            hasher.combine(keyType)
            hasher.combine(valueType)
            hasher.combine(entries.count)
            let aggregate = unorderedDigest(entries, digest: entryDigest)
            hasher.combine(aggregate.xor)
            hasher.combine(aggregate.sum)
        case let .set(set):
            hasher.combine(7 as UInt8)
            hasher.combine(set.elementType)
            hasher.combine(set.elements.count)
            let aggregate = unorderedDigest(set.elements, digest: digest)
            hasher.combine(aggregate.xor)
            hasher.combine(aggregate.sum)
        default:
            // Unsupported values can never be valid Dictionary keys or Set
            // elements. Keep hashing total so malformed test values fail in
            // verification/matching instead of crashing diagnostics.
            hasher.combine(UInt8.max)
            hasher.combine(value.type)
        }
    }

    private static func digest(_ value: VM.Value) -> Int {
        var hasher = Hasher()
        hash(value, into: &hasher)
        return hasher.finalize()
    }

    private static func entryDigest(_ entry: VM.DictionaryEntry) -> Int {
        var hasher = Hasher()
        hash(entry.key, into: &hasher)
        hash(entry.value, into: &hasher)
        return hasher.finalize()
    }

    private static func unorderedDigest<Element>(
        _ elements: [Element],
        digest: (Element) -> Int
    ) -> (xor: UInt, sum: UInt) {
        var xor: UInt = 0
        var sum: UInt = 0
        for element in elements {
            let value = UInt(bitPattern: digest(element))
            xor ^= value
            sum &+= value
        }
        return (xor, sum)
    }

    /// Returns the logical VM heap required by the temporary unordered indexes
    /// built while comparing against `rhs`. Keep this model synchronized with
    /// the Dictionary and Set branches in `equal`.
    static func equalityScratchBytes(
        for rhs: VM.Value,
        depth: Int = 0
    ) throws -> UInt64 {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }

        func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
            let sum = lhs.addingReportingOverflow(rhs)
            guard !sum.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            return sum.partialValue
        }

        func aggregateBytes(elementCount: Int) throws -> UInt64 {
            guard let count = UInt64(exactly: elementCount) else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            let slots = count.addingReportingOverflow(1)
            let bytes = slots.partialValue.multipliedReportingOverflow(by: 16)
            guard !slots.overflow, !bytes.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            return bytes.partialValue
        }

        var bytes: UInt64 = 0
        switch rhs {
        case let .array(elements, _):
            for element in elements {
                bytes = try checkedAdd(
                    bytes,
                    equalityScratchBytes(for: element, depth: depth + 1)
                )
            }
        case let .dictionary(entries, _, _):
            let indexedValues = entries.count.multipliedReportingOverflow(by: 2)
            guard !indexedValues.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            bytes = try aggregateBytes(elementCount: indexedValues.partialValue)
            for entry in entries {
                bytes = try checkedAdd(
                    bytes,
                    equalityScratchBytes(for: entry.key, depth: depth + 1)
                )
                bytes = try checkedAdd(
                    bytes,
                    equalityScratchBytes(for: entry.value, depth: depth + 1)
                )
            }
        case let .set(set):
            bytes = try aggregateBytes(elementCount: set.elements.count)
            for element in set.elements {
                bytes = try checkedAdd(
                    bytes,
                    equalityScratchBytes(for: element, depth: depth + 1)
                )
            }
        case let .optional(.some(wrapped)):
            bytes = try equalityScratchBytes(for: wrapped, depth: depth + 1)
        case .optional(nil), .bool, .integer, .float, .string:
            break
        default:
            // Non-Hashable VM values cannot reach the allocating equality
            // branches, so malformed callers require no scratch reservation.
            break
        }
        return bytes
    }

    private static func sharesStorage<Element>(
        _ lhs: [Element],
        _ rhs: [Element]
    ) -> Bool {
        guard !lhs.isEmpty else { return rhs.isEmpty }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress
            }
        }
    }
}
}
