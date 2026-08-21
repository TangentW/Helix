import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Value codecs used by generated Shell bridges. Statically typed aggregates
/// remain compiler-generated; dynamic `Any` uses a closed standard-library
/// subset and never interprets native object layout or Swift ABI metadata.
public enum BridgeValueCodec {
    /// Encodes a Swift Boolean as a VM Boolean value.
    public static func encode(_ value: Bool) throws -> VM.Value {
        .bool(value)
    }

    /// Decodes a VM Boolean and rejects every other value type.
    public static func decode(_ value: VM.Value, as type: Bool.Type) throws -> Bool {
        guard case let .bool(result) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: value.type)
        }
        return result
    }

    /// Encodes an 8-, 16-, 32-, or 64-bit fixed-width Swift integer losslessly.
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

    /// Decodes a VM integer whose width and signedness exactly match `Integer`.
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

    /// Encodes a Swift `Float` while preserving its 32-bit VM type identity.
    public static func encode(_ value: Float) throws -> VM.Value {
        .float(VM.FloatingValue(value))
    }

    /// Decodes a 32-bit VM floating-point value as `Float`.
    public static func decode(_ value: VM.Value, as type: Float.Type) throws -> Float {
        guard case let .float(result) = value, result.bitWidth == 32 else {
            throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 32), actual: value.type)
        }
        return result.floatValue
    }

    /// Encodes a Swift `Double` as a 64-bit VM floating-point value.
    public static func encode(_ value: Double) throws -> VM.Value {
        .float(VM.FloatingValue(value))
    }

    /// Decodes a 64-bit VM floating-point value as `Double`.
    public static func decode(_ value: VM.Value, as type: Double.Type) throws -> Double {
        guard case let .float(result) = value, result.bitWidth == 64 else {
            throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 64), actual: value.type)
        }
        return result.doubleValue
    }

    /// Encodes the 64-bit `CGFloat` used by Helix's supported Apple targets.
    public static func encode(_ value: CGFloat) throws -> VM.Value {
        .float(VM.FloatingValue(Double(value)))
    }

    /// Decodes a 64-bit VM floating-point value as `CGFloat`.
    public static func decode(_ value: VM.Value, as type: CGFloat.Type) throws -> CGFloat {
        guard case let .float(result) = value, result.bitWidth == 64 else {
            throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 64), actual: value.type)
        }
        return CGFloat(result.doubleValue)
    }

    /// Encodes a Swift string as an owned VM string value.
    public static func encode(_ value: String) throws -> VM.Value {
        .string(value)
    }

    /// Decodes a VM string and rejects every other value type.
    public static func decode(_ value: VM.Value, as type: String.Type) throws -> String {
        guard case let .string(result) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .string, actual: value.type)
        }
        return result
    }

    /// Encodes a Character through the compact one-grapheme String
    /// representation used by HLBC text algorithms.
    public static func encode(_ value: Character) throws -> VM.Value {
        .string(String(value))
    }

    /// Decodes a represented Character and revalidates its erased grapheme
    /// invariant at the Shell boundary.
    public static func decode(
        _ value: VM.Value,
        as type: Character.Type
    ) throws -> Character {
        guard case let .string(result) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .string,
                actual: value.type
            )
        }
        guard result.count == 1, let character = result.first else {
            throw VM.RuntimeTrap.explicit(
                "represented Character must contain exactly one extended grapheme cluster"
            )
        }
        return character
    }

    /// Substring crosses a Shell boundary as its normalized Character sequence;
    /// private slice storage and index identity never enter HLBC.
    public static func encode(_ value: Substring) throws -> VM.Value {
        .array(
            value.map { .string(String($0)) },
            elementType: .string
        )
    }

    public static func decode(
        _ value: VM.Value,
        as type: Substring.Type
    ) throws -> Substring {
        guard case let .array(storage) = value,
              storage.elementType == .string
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .array(.string),
                actual: value.type
            )
        }
        var result = String()
        for element in storage.elements {
            let character = try decode(element, as: Character.self)
            result.append(character)
        }
        return Substring(result)
    }

    /// Encodes an array with a compiler-supplied element codec and VM element type.
    public static func encodeArray<Element>(
        _ value: [Element],
        elementType: Bytecode.ValueType,
        encodeElement: (Element) throws -> VM.Value
    ) rethrows -> VM.Value {
        .array(try value.map(encodeElement), elementType: elementType)
    }

    /// Decodes an array after verifying its declared VM element type.
    public static func decodeArray<Element>(
        _ value: VM.Value,
        elementType: Bytecode.ValueType,
        decodeElement: (VM.Value) throws -> Element
    ) throws -> [Element] {
        guard case let .array(storage) = value,
              storage.elementType == elementType
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .array(elementType),
                actual: value.type
            )
        }
        return try storage.elements.map(decodeElement)
    }

    /// Encodes a Set with a compiler-supplied element codec and VM element type.
    public static func encodeSet<Element: Hashable>(
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
        var elements: [VM.Value] = []
        elements.reserveCapacity(value.count)
        for element in value {
            let encoded = try encodeElement(element)
            guard encoded.matches(elementType) else {
                throw Runtime.BridgeInputError.encodedTypeMismatch(
                    expected: elementType.description,
                    actual: encoded.type.description
                )
            }
            elements.append(encoded)
        }
        let set = VM.SetValue(elements: elements, elementType: elementType)
        guard set.elements.count == elements.count else {
            throw Runtime.BridgeInputError.duplicateEncodedSetElement
        }
        return .set(set)
    }

    /// Decodes a Set after verifying its declared VM element type.
    public static func decodeSet<Element: Hashable>(
        _ value: VM.Value,
        elementType: Bytecode.ValueType,
        decodeElement: (VM.Value) throws -> Element
    ) throws -> Set<Element> {
        guard case let .set(set) = value, set.elementType == elementType else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .set(elementType),
                actual: value.type
            )
        }
        var result: Set<Element> = []
        result.reserveCapacity(set.elements.count)
        for element in set.elements {
            guard element.matches(elementType) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: elementType,
                    actual: element.type
                )
            }
            guard result.insert(try decodeElement(element)).inserted else {
                throw VM.RuntimeTrap.nativeFailure(
                    "VM Set contains duplicate Swift-equivalent elements"
                )
            }
        }
        return result
    }

    /// Encodes dictionary entries with compiler-supplied key and value codecs.
    public static func encodeDictionary<Key: Hashable, Value>(
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
        var entries: [VM.DictionaryEntry] = []
        entries.reserveCapacity(value.count)
        for (key, value) in value {
            let encodedKey = try encodeKey(key)
            let encodedValue = try encodeValue(value)
            guard encodedKey.matches(keyType) else {
                throw Runtime.BridgeInputError.encodedTypeMismatch(
                    expected: keyType.description,
                    actual: encodedKey.type.description
                )
            }
            guard encodedValue.matches(valueType) else {
                throw Runtime.BridgeInputError.encodedTypeMismatch(
                    expected: valueType.description,
                    actual: encodedValue.type.description
                )
            }
            entries.append(.init(key: encodedKey, value: encodedValue))
        }
        let uniqueKeys = VM.SetValue(
            elements: entries.map(\.key),
            elementType: keyType
        )
        guard uniqueKeys.elements.count == entries.count else {
            throw Runtime.BridgeInputError.duplicateEncodedDictionaryKey
        }
        return .dictionary(entries, keyType: keyType, valueType: valueType)
    }

    /// Decodes a typed dictionary and rejects duplicate decoded Swift keys.
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
            guard entry.key.matches(keyType) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: keyType,
                    actual: entry.key.type
                )
            }
            guard entry.value.matches(valueType) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: valueType,
                    actual: entry.value.type
                )
            }
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

    /// Encodes a Swift optional with a compiler-supplied wrapped-value codec.
    public static func encodeOptional<Wrapped>(
        _ value: Wrapped?,
        encodeWrapped: (Wrapped) throws -> VM.Value
    ) rethrows -> VM.Value {
        .optional(try value.map(encodeWrapped))
    }

    /// Decodes a VM optional with a compiler-supplied wrapped-value codec.
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

    /// Encodes already typed tuple elements in declaration order.
    public static func encodeTuple(_ elements: [VM.Value]) throws -> VM.Value {
        .tuple(elements)
    }

    /// Decodes a VM tuple whose arity exactly matches `count`.
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

    /// Boxes an approved native Swift value under its generated type identity.
    public static func encodeNative<Value>(
        _ value: Value,
        as typeID: Core.TypeID,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value {
        .native(try catalog.box(value, as: typeID))
    }

    /// Decodes a native box only when both generated type ID and Swift type match.
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

    /// Encodes `Void` as the absence of a VM result value.
    public static func encodeVoid(_ value: Void = ()) throws -> VM.Value? {
        nil
    }

    /// Decodes `Void` and rejects an unexpected result value.
    public static func decodeVoid(_ value: VM.Value?) throws {
        guard value == nil else {
            throw VM.RuntimeTrap.typeMismatch(expected: .void, actual: value?.type)
        }
    }
}
}
