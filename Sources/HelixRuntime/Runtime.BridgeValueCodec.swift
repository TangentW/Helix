import Foundation
import HelixBytecode
import HelixCore
import HelixVM

extension Runtime {
/// Strongly typed primitives used by generated Shell bridges. Aggregate shape
/// remains compiler-generated; this codec never infers a Swift ABI from `Any`.
public enum BridgeValueCodec {
    public static func encode(_ value: Bool) throws -> VM.Value {
        .bool(value)
    }

    public static func decode(_ value: VM.Value, as type: Bool.Type) throws -> Bool {
        guard case let .bool(result) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: value.type)
        }
        return result
    }

    public static func encode<Integer: FixedWidthInteger>(_ value: Integer) throws -> VM.Value {
        guard let width = UInt16(exactly: Integer.bitWidth), [8, 16, 32, 64].contains(width) else {
            throw VM.RuntimeTrap.invalidIntegerWidth(
                UInt16(clamping: Integer.bitWidth)
            )
        }
        return .integer(
            try VM.Integer(
                rawBits: UInt64(truncatingIfNeeded: value),
                bitWidth: width,
                isSigned: Integer.isSigned
            )
        )
    }

    public static func decode<Integer: FixedWidthInteger>(
        _ value: VM.Value,
        as type: Integer.Type
    ) throws -> Integer {
        guard case let .integer(integer) = value,
              integer.bitWidth == UInt16(Integer.bitWidth),
              integer.isSigned == Integer.isSigned
        else {
            let expected = Bytecode.ValueType.integer(
                bitWidth: UInt16(Integer.bitWidth),
                signed: Integer.isSigned
            )
            throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
        }
        return Integer(truncatingIfNeeded: integer.rawBits)
    }

    public static func encode(_ value: Float) throws -> VM.Value {
        .float(Double(value), bitWidth: 32)
    }

    public static func decode(_ value: VM.Value, as type: Float.Type) throws -> Float {
        guard case let .float(result, bitWidth: 32) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 32), actual: value.type)
        }
        return Float(result)
    }

    public static func encode(_ value: Double) throws -> VM.Value {
        .float(value, bitWidth: 64)
    }

    public static func decode(_ value: VM.Value, as type: Double.Type) throws -> Double {
        guard case let .float(result, bitWidth: 64) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 64), actual: value.type)
        }
        return result
    }

    public static func encode(_ value: String) throws -> VM.Value {
        .string(value)
    }

    public static func decode(_ value: VM.Value, as type: String.Type) throws -> String {
        guard case let .string(result) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .string, actual: value.type)
        }
        return result
    }

    public static func encodeArray<Element>(
        _ value: [Element],
        elementType: Bytecode.ValueType,
        encodeElement: (Element) throws -> VM.Value
    ) rethrows -> VM.Value {
        .array(try value.map(encodeElement), elementType: elementType)
    }

    public static func decodeArray<Element>(
        _ value: VM.Value,
        elementType: Bytecode.ValueType,
        decodeElement: (VM.Value) throws -> Element
    ) throws -> [Element] {
        guard case let .array(elements, actualElementType) = value,
              actualElementType == elementType
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .array(elementType),
                actual: value.type
            )
        }
        return try elements.map(decodeElement)
    }

    public static func encodeDictionary<Key: Hashable, Value>(
        _ value: [Key: Value],
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType,
        encodeKey: (Key) throws -> VM.Value,
        encodeValue: (Value) throws -> VM.Value
    ) rethrows -> VM.Value {
        let entries = try value.map { key, value in
            VM.DictionaryEntry(
                key: try encodeKey(key),
                value: try encodeValue(value)
            )
        }
        return .dictionary(entries, keyType: keyType, valueType: valueType)
    }

    public static func decodeDictionary<Key: Hashable, Value>(
        _ value: VM.Value,
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType,
        decodeKey: (VM.Value) throws -> Key,
        decodeValue: (VM.Value) throws -> Value
    ) throws -> [Key: Value] {
        guard case let .dictionary(entries, actualKeyType, actualValueType) = value,
              actualKeyType == keyType,
              actualValueType == valueType
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .dictionary(key: keyType, value: valueType),
                actual: value.type
            )
        }
        var result: [Key: Value] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            let key = try decodeKey(entry.key)
            let decodedValue = try decodeValue(entry.value)
            guard result.updateValue(decodedValue, forKey: key) == nil else {
                throw VM.RuntimeTrap.nativeFailure(
                    "VM Dictionary contains a duplicate key"
                )
            }
        }
        return result
    }

    public static func encodeOptional<Wrapped>(
        _ value: Wrapped?,
        encodeWrapped: (Wrapped) throws -> VM.Value
    ) rethrows -> VM.Value {
        .optional(try value.map(encodeWrapped))
    }

    public static func decodeOptional<Wrapped>(
        _ value: VM.Value,
        decodeWrapped: (VM.Value) throws -> Wrapped
    ) throws -> Wrapped? {
        guard case let .optional(wrapped) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .optional(.never),
                actual: value.type
            )
        }
        return try wrapped.map(decodeWrapped)
    }

    public static func encodeTuple(_ elements: [VM.Value]) throws -> VM.Value {
        .tuple(elements)
    }

    public static func decodeTuple(
        _ value: VM.Value,
        count: Int
    ) throws -> [VM.Value] {
        guard case let .tuple(elements) = value, elements.count == count else {
            throw VM.RuntimeTrap.nativeFailure(
                "generated bridge expected a tuple with \(count) elements"
            )
        }
        return elements
    }

    public static func encodeNative<Value>(
        _ value: Value,
        as typeID: Core.TypeID,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value {
        .native(try catalog.box(value, as: typeID))
    }

    public static func decodeNative<Value>(
        _ value: VM.Value,
        as type: Value.Type,
        typeID: Core.TypeID
    ) throws -> Value {
        guard case let .native(native) = value,
              native.typeID == typeID,
              let result = native.value(as: type)
        else {
            throw VM.RuntimeTrap.nativeTypeMismatch(expected: typeID)
        }
        return result
    }

    public static func encodeVoid(_ value: Void = ()) throws -> VM.Value? {
        nil
    }

    public static func decodeVoid(_ value: VM.Value?) throws {
        guard value == nil else {
            throw VM.RuntimeTrap.typeMismatch(expected: .void, actual: value?.type)
        }
    }
}
}
