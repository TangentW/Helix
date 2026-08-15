import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime.BridgeValueCodec {
/// A per-dispatch encoder supplied to generated bridge code. It reserves the
/// complete container shape before allocating the VM-side copy and encodes
/// collection elements incrementally.
public final class Encoder {
    /// Effective host-side limits for this one dispatch.
    public let limits: Runtime.BridgeInputLimits

    private struct Footprint: Equatable {
        var valueNodes: UInt64 = 0
        var estimatedVMBytes: UInt64 = 0
        var estimatedNativeBytes: UInt64 = 0
        var maximumDepth: UInt32 = 0
    }

    private var footprint = Footprint()
    private var currentDepth: UInt32 = 0
    private var isFinished = false
    private var nodesSinceDeadlineCheck: UInt32 = 0
    private let checkDeadline: () throws -> Void

    init(
        limits: Runtime.BridgeInputLimits,
        checkDeadline: @escaping () throws -> Void = {}
    ) {
        self.limits = limits
        self.checkDeadline = checkDeadline
    }

    /// Encodes one Boolean leaf and charges it to the argument graph.
    public func encode(_ value: Bool) throws -> VM.Value {
        try reserveLeaf()
        return .bool(value)
    }

    /// Encodes one supported fixed-width integer leaf and charges it to the graph.
    public func encode<Integer: FixedWidthInteger>(_ value: Integer) throws -> VM.Value {
        try reserveLeaf()
        return try Runtime.BridgeValueCodec.encode(value)
    }

    /// Encodes one 32-bit floating-point leaf and charges it to the graph.
    public func encode(_ value: Float) throws -> VM.Value {
        try reserveLeaf()
        return .float(Double(value), bitWidth: 32)
    }

    /// Encodes one 64-bit floating-point leaf and charges it to the graph.
    public func encode(_ value: Double) throws -> VM.Value {
        try reserveLeaf()
        return .float(value, bitWidth: 64)
    }

    /// Encodes a 64-bit `CGFloat` leaf and charges it to the graph.
    public func encode(_ value: CGFloat) throws -> VM.Value {
        try reserveLeaf()
        return .float(Double(value), bitWidth: 64)
    }

    /// Encodes a string after reserving its UTF-8 storage and polling the deadline.
    public func encode(_ value: String) throws -> VM.Value {
        try requireActive()
        try pollDeadline(force: true)
        let byteCount = try count(value.utf8.count)
        try reserveLeaf(estimatedVMBytes: byteCount)
        try pollDeadline(force: true)
        return .string(value)
    }

    func encodeDynamicLeaf(_ value: VM.Value) throws -> VM.Value {
        switch value {
        case let .string(string):
            try requireActive()
            try pollDeadline(force: true)
            let byteCount = try count(string.utf8.count)
            try reserveLeaf(estimatedVMBytes: byteCount)
            try pollDeadline(force: true)
        case .bool, .integer, .float:
            try reserveLeaf()
        default:
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a scalar Swift Any payload",
                actual: value.type.description
            )
        }
        return value
    }

    func encodeDynamicContainer(
        childValueCount: Int,
        body: () throws -> VM.Value
    ) throws -> VM.Value {
        try withContainer(childValueCount: childValueCount, body: body)
    }

    /// Boxes an approved native value and charges its estimated owned bytes.
    public func encodeNative<Value>(
        _ value: Value,
        as typeID: Core.TypeID,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value {
        try requireActive()
        try pollDeadline(force: true)
        let native = try catalog.box(value, as: typeID)
        try reserveLeaf(estimatedNativeBytes: native.estimatedByteCount)
        try pollDeadline(force: true)
        return .native(native)
    }

    /// Reserves and encodes an optional container with zero or one child.
    public func encodeOptional<Wrapped>(
        _ value: Wrapped?,
        encodeWrapped: (Wrapped) throws -> VM.Value
    ) throws -> VM.Value {
        switch value {
        case let .some(wrapped):
            return try withContainer(childValueCount: 1) {
                .optional(try encodeWrapped(wrapped))
            }
        case .none:
            return try withContainer(childValueCount: 0) { .optional(nil) }
        }
    }

    /// Encodes a root argument list whose produced arity must equal `expectedCount`.
    public func encodeArguments(
        count expectedCount: Int,
        elements: () throws -> [VM.Value]
    ) throws -> [VM.Value] {
        try requireActive()
        try pollDeadline(force: true)
        try validateContainerCount(expectedCount)
        let values = try elements()
        guard values.count == expectedCount else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        return values
    }

    /// Reserves and encodes a tuple whose produced arity must equal `expectedCount`.
    public func encodeTuple(
        count expectedCount: Int,
        elements: () throws -> [VM.Value]
    ) throws -> VM.Value {
        try withContainer(childValueCount: expectedCount) {
            let values = try elements()
            guard values.count == expectedCount else {
                throw Runtime.BridgeInputError.invalidContainerCount
            }
            return .tuple(values)
        }
    }

    /// Reserves the complete array shape before encoding and type-checking elements.
    public func encodeArray<Element>(
        _ value: [Element],
        elementType: Bytecode.ValueType,
        encodeElement: (Element) throws -> VM.Value
    ) throws -> VM.Value {
        try withContainer(childValueCount: value.count) {
            var elements: [VM.Value] = []
            elements.reserveCapacity(value.count)
            for element in value {
                let encoded = try encodeElement(element)
                try require(encoded, matches: elementType)
                elements.append(encoded)
            }
            return .array(elements, elementType: elementType)
        }
    }

    /// Reserves the complete Set shape before encoding and type-checking elements.
    public func encodeSet<Element: Hashable>(
        _ value: Set<Element>,
        elementType: Bytecode.ValueType,
        encodeElement: (Element) throws -> VM.Value
    ) throws -> VM.Value {
        guard elementType.isVMHashable else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a VM-defined Hashable Set element",
                actual: elementType.description
            )
        }
        return try withContainer(childValueCount: value.count) {
            var elements: [VM.Value] = []
            elements.reserveCapacity(value.count)
            for element in value {
                let encoded = try encodeElement(element)
                try require(encoded, matches: elementType)
                elements.append(encoded)
            }
            let set = VM.SetValue(elements: elements, elementType: elementType)
            guard set.elements.count == elements.count else {
                throw Runtime.BridgeInputError.duplicateEncodedSetElement
            }
            try pollDeadline(force: true)
            return .set(set)
        }
    }

    /// Reserves key/value nodes before encoding and type-checking dictionary entries.
    public func encodeDictionary<Key: Hashable, Value>(
        _ value: [Key: Value],
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType,
        encodeKey: (Key) throws -> VM.Value,
        encodeValue: (Value) throws -> VM.Value
    ) throws -> VM.Value {
        guard keyType.isVMHashable else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a VM-defined Hashable Dictionary key",
                actual: keyType.description
            )
        }
        let childCount = value.count.multipliedReportingOverflow(by: 2)
        guard !childCount.overflow else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        return try withContainer(childValueCount: childCount.partialValue) {
            var entries: [VM.DictionaryEntry] = []
            entries.reserveCapacity(value.count)
            for (key, value) in value {
                let encodedKey = try encodeKey(key)
                let encodedValue = try encodeValue(value)
                try require(encodedKey, matches: keyType)
                try require(encodedValue, matches: valueType)
                entries.append(.init(key: encodedKey, value: encodedValue))
            }
            let uniqueKeys = VM.SetValue(
                elements: entries.map(\.key),
                elementType: keyType
            )
            guard uniqueKeys.elements.count == entries.count else {
                throw Runtime.BridgeInputError.duplicateEncodedDictionaryKey
            }
            try pollDeadline(force: true)
            return .dictionary(entries, keyType: keyType, valueType: valueType)
        }
    }

    func finalize(arguments: [VM.Value]) throws {
        try requireActive()
        isFinished = true
        guard currentDepth == 0 else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        try validateContainerCount(arguments.count)
        let measured = try Self.measure(
            arguments,
            limits: limits,
            recordDeadlineWork: { try self.recordDeadlineWork() }
        )
        try pollDeadline(force: true)
        guard measured == footprint else {
            throw Runtime.BridgeInputError.untrackedEncodedValue
        }
    }

    private func reserveLeaf(
        estimatedVMBytes: UInt64 = 0,
        estimatedNativeBytes: UInt64 = 0
    ) throws {
        try requireActive()
        try reserveNode(at: try nextDepth())
        try reserveVMBytes(estimatedVMBytes)
        try reserveNativeBytes(estimatedNativeBytes)
    }

    private func withContainer<Result>(
        childValueCount: Int,
        body: () throws -> Result
    ) throws -> Result {
        try requireActive()
        try pollDeadline(force: true)
        let children = try count(childValueCount)
        try validateContainerCount(children)
        try ensureNodeCapacity(additional: try adding(1, children))

        let depth = try nextDepth()
        try reserveNode(at: depth)
        try reserveAggregateStorage(childValueCount: children)
        currentDepth = depth
        defer { currentDepth -= 1 }
        return try body()
    }

    private func require(_ value: VM.Value, matches expected: Bytecode.ValueType) throws {
        guard value.matches(expected) else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: expected.description,
                actual: value.type.description
            )
        }
    }

    private func requireActive() throws {
        guard !isFinished else {
            throw Runtime.BridgeInputError.encoderAlreadyFinished
        }
    }

    private func nextDepth() throws -> UInt32 {
        let result = currentDepth.addingReportingOverflow(1)
        guard !result.overflow, result.partialValue <= limits.maximumNestingDepth else {
            throw Runtime.BridgeInputError.nestingDepthLimitExceeded(
                maximum: limits.maximumNestingDepth
            )
        }
        return result.partialValue
    }

    private func reserveNode(at depth: UInt32) throws {
        try ensureNodeCapacity(additional: 1)
        footprint.valueNodes += 1
        footprint.maximumDepth = max(footprint.maximumDepth, depth)
        try recordDeadlineWork()
    }

    private func recordDeadlineWork() throws {
        nodesSinceDeadlineCheck += 1
        try pollDeadline()
    }

    private func pollDeadline(force: Bool = false) throws {
        guard force || nodesSinceDeadlineCheck >= 64 else { return }
        try checkDeadline()
        nodesSinceDeadlineCheck = 0
    }

    private func ensureNodeCapacity(additional: UInt64) throws {
        let total = footprint.valueNodes.addingReportingOverflow(additional)
        guard !total.overflow, total.partialValue <= limits.maximumValueNodes else {
            throw Runtime.BridgeInputError.valueNodeLimitExceeded(
                maximum: limits.maximumValueNodes
            )
        }
    }

    private func reserveAggregateStorage(childValueCount: UInt64) throws {
        let slots = try adding(childValueCount, 1)
        let bytes = slots.multipliedReportingOverflow(by: 16)
        guard !bytes.overflow else {
            throw Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: limits.maximumEstimatedVMBytes
            )
        }
        try reserveVMBytes(bytes.partialValue)
    }

    private func reserveVMBytes(_ bytes: UInt64) throws {
        let total = footprint.estimatedVMBytes.addingReportingOverflow(bytes)
        guard !total.overflow,
              total.partialValue <= limits.maximumEstimatedVMBytes
        else {
            throw Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: limits.maximumEstimatedVMBytes
            )
        }
        footprint.estimatedVMBytes = total.partialValue
    }

    private func reserveNativeBytes(_ bytes: UInt64) throws {
        let total = footprint.estimatedNativeBytes.addingReportingOverflow(bytes)
        guard !total.overflow,
              total.partialValue <= limits.maximumEstimatedNativeBytes
        else {
            throw Runtime.BridgeInputError.estimatedNativeByteLimitExceeded(
                maximum: limits.maximumEstimatedNativeBytes
            )
        }
        footprint.estimatedNativeBytes = total.partialValue
    }

    private func validateContainerCount(_ value: Int) throws {
        try validateContainerCount(try count(value))
    }

    private func validateContainerCount(_ value: UInt64) throws {
        guard value <= limits.maximumContainerElements else {
            throw Runtime.BridgeInputError.containerElementLimitExceeded(
                actual: value,
                maximum: limits.maximumContainerElements
            )
        }
    }

    private func count(_ value: Int) throws -> UInt64 {
        guard value >= 0, let result = UInt64(exactly: value) else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        return result
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw Runtime.BridgeInputError.valueNodeLimitExceeded(
                maximum: limits.maximumValueNodes
            )
        }
        return result.partialValue
    }

    private static func measure(
        _ roots: [VM.Value],
        limits: Runtime.BridgeInputLimits,
        recordDeadlineWork: () throws -> Void
    ) throws -> Footprint {
        var result = Footprint()
        var pending = roots.reversed().map { ($0, UInt32(1)) }

        while let (value, depth) = pending.popLast() {
            try recordDeadlineWork()
            guard depth <= limits.maximumNestingDepth else {
                throw Runtime.BridgeInputError.nestingDepthLimitExceeded(
                    maximum: limits.maximumNestingDepth
                )
            }
            let nextNodeCount = result.valueNodes.addingReportingOverflow(1)
            guard !nextNodeCount.overflow,
                  nextNodeCount.partialValue <= limits.maximumValueNodes
            else {
                throw Runtime.BridgeInputError.valueNodeLimitExceeded(
                    maximum: limits.maximumValueNodes
                )
            }
            result.valueNodes = nextNodeCount.partialValue
            result.maximumDepth = max(result.maximumDepth, depth)

            switch value {
            case let .string(string):
                try add(UInt64(string.utf8.count), toVMBytesOf: &result, limits: limits)
            case let .native(native):
                try add(native.estimatedByteCount, toNativeBytesOf: &result, limits: limits)
            case let .any(erased):
                try addAggregate(1, to: &result, limits: limits)
                try append([erased.payload], below: depth, to: &pending, limits: limits)
            case let .array(elements, _):
                try validate(elements.count, limits: limits)
                try addAggregate(elements.count, to: &result, limits: limits)
                try append(elements, below: depth, to: &pending, limits: limits)
            case let .dictionary(entries, _, _):
                let childCount = entries.count.multipliedReportingOverflow(by: 2)
                guard !childCount.overflow else {
                    throw Runtime.BridgeInputError.invalidContainerCount
                }
                try validate(childCount.partialValue, limits: limits)
                try addAggregate(childCount.partialValue, to: &result, limits: limits)
                let childDepth = try increment(depth, limits: limits)
                for entry in entries.reversed() {
                    pending.append((entry.value, childDepth))
                    pending.append((entry.key, childDepth))
                }
            case let .set(set):
                try validate(set.elements.count, limits: limits)
                try addAggregate(set.elements.count, to: &result, limits: limits)
                try append(set.elements, below: depth, to: &pending, limits: limits)
            case let .tuple(elements):
                try validate(elements.count, limits: limits)
                try addAggregate(elements.count, to: &result, limits: limits)
                try append(elements, below: depth, to: &pending, limits: limits)
            case let .optional(wrapped):
                let elements = wrapped.map { [$0] } ?? []
                try addAggregate(elements.count, to: &result, limits: limits)
                try append(elements, below: depth, to: &pending, limits: limits)
            case .structure, .enumeration, .object, .error, .address,
                 .mutableCell, .arrayBuilder, .closure:
                throw Runtime.BridgeInputError.encodedTypeMismatch(
                    expected: "Shell boundary value",
                    actual: value.type.description
                )
            case .bool, .integer, .float:
                break
            }
        }
        return result
    }

    private static func append(
        _ values: [VM.Value],
        below depth: UInt32,
        to pending: inout [(VM.Value, UInt32)],
        limits: Runtime.BridgeInputLimits
    ) throws {
        guard !values.isEmpty else { return }
        let childDepth = try increment(depth, limits: limits)
        for value in values.reversed() {
            pending.append((value, childDepth))
        }
    }

    private static func increment(
        _ depth: UInt32,
        limits: Runtime.BridgeInputLimits
    ) throws -> UInt32 {
        let result = depth.addingReportingOverflow(1)
        guard !result.overflow, result.partialValue <= limits.maximumNestingDepth else {
            throw Runtime.BridgeInputError.nestingDepthLimitExceeded(
                maximum: limits.maximumNestingDepth
            )
        }
        return result.partialValue
    }

    private static func validate(
        _ count: Int,
        limits: Runtime.BridgeInputLimits
    ) throws {
        guard count >= 0, let value = UInt64(exactly: count) else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        try validate(value, limits: limits)
    }

    private static func validate(
        _ count: UInt64,
        limits: Runtime.BridgeInputLimits
    ) throws {
        guard count <= limits.maximumContainerElements else {
            throw Runtime.BridgeInputError.containerElementLimitExceeded(
                actual: count,
                maximum: limits.maximumContainerElements
            )
        }
    }

    private static func addAggregate(
        _ childCount: Int,
        to result: inout Footprint,
        limits: Runtime.BridgeInputLimits
    ) throws {
        guard childCount >= 0, let count = UInt64(exactly: childCount) else {
            throw Runtime.BridgeInputError.invalidContainerCount
        }
        try addAggregate(count, to: &result, limits: limits)
    }

    private static func addAggregate(
        _ childCount: UInt64,
        to result: inout Footprint,
        limits: Runtime.BridgeInputLimits
    ) throws {
        let slots = childCount.addingReportingOverflow(1)
        let bytes = slots.partialValue.multipliedReportingOverflow(by: 16)
        guard !slots.overflow, !bytes.overflow else {
            throw Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: limits.maximumEstimatedVMBytes
            )
        }
        try add(bytes.partialValue, toVMBytesOf: &result, limits: limits)
    }

    private static func add(
        _ bytes: UInt64,
        toVMBytesOf result: inout Footprint,
        limits: Runtime.BridgeInputLimits
    ) throws {
        let total = result.estimatedVMBytes.addingReportingOverflow(bytes)
        guard !total.overflow,
              total.partialValue <= limits.maximumEstimatedVMBytes
        else {
            throw Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: limits.maximumEstimatedVMBytes
            )
        }
        result.estimatedVMBytes = total.partialValue
    }

    private static func add(
        _ bytes: UInt64,
        toNativeBytesOf result: inout Footprint,
        limits: Runtime.BridgeInputLimits
    ) throws {
        let total = result.estimatedNativeBytes.addingReportingOverflow(bytes)
        guard !total.overflow,
              total.partialValue <= limits.maximumEstimatedNativeBytes
        else {
            throw Runtime.BridgeInputError.estimatedNativeByteLimitExceeded(
                maximum: limits.maximumEstimatedNativeBytes
            )
        }
        result.estimatedNativeBytes = total.partialValue
    }
}
}
