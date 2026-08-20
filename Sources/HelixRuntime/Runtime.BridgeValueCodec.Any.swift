import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixVM
#endif

extension Runtime.BridgeValueCodec {
/// Encodes the supported standard-library subset of a dynamic Swift value.
///
/// The boundary deliberately excludes native objects, local nominal values,
/// closures, errors, and tuples. Those values have no stable representation
/// that can be reconstructed from a VM-owned existential.
public static func encodeAny(_ value: Any) throws -> VM.Value {
    let encoder = Encoder(limits: .init())
    let result = try encoder.encodeAny(value)
    try encoder.finalize(arguments: [result])
    return result
}

/// Decodes a VM-owned existential as a standard Swift value.
public static func decodeAny(_ value: VM.Value) throws -> Any {
    guard case let .any(erased) = value else {
        throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: value.type)
    }
    return try DynamicAny.decode(
        erased.payload,
        as: erased.concreteType,
        depth: 0
    )
}
}

extension Runtime.BridgeValueCodec.Encoder {
/// Encodes a dynamic Swift value while charging its complete object graph to
/// this dispatch's bridge-input limits.
public func encodeAny(_ value: Any) throws -> VM.Value {
    return try encodeDynamicContainer(childValueCount: 1) {
        let payload = try Runtime.BridgeValueCodec.DynamicAny.encode(
            value,
            using: self,
            depth: 0
        )
        return .any(.init(concreteType: payload.type, payload: payload.value))
    }
}
}

private extension Runtime.BridgeValueCodec {
enum DynamicAny {
    struct Encoded {
        var type: Bytecode.ValueType
        var value: VM.Value
    }

    static func encode(
        _ value: Any,
        using encoder: Runtime.BridgeValueCodec.Encoder,
        depth: Int
    ) throws -> Encoded {
        guard depth <= 64 else {
            throw Runtime.BridgeInputError.nestingDepthLimitExceeded(maximum: 64)
        }
        let reflectedType = String(reflecting: Swift.type(of: value))
        guard let type = parseStandardType(reflectedType) else {
            throw Runtime.BridgeInputError.unsupportedAnyType(reflectedType)
        }

        switch type {
        case .bool:
            guard let value = value as? Bool else {
                throw mismatch(expected: type, value: value)
            }
            return .init(
                type: type,
                value: try encoder.encodeDynamicLeaf(.bool(value))
            )
        case let .integer(bitWidth, signed):
            let encoded = try encodeInteger(
                value,
                bitWidth: bitWidth,
                signed: signed
            )
            return .init(
                type: type,
                value: try encoder.encodeDynamicLeaf(encoded)
            )
        case let .float(bitWidth):
            let encoded: VM.Value
            if bitWidth == 32, let value = value as? Float {
                encoded = .float(VM.FloatingValue(value))
            } else if bitWidth == 64, let value = value as? Double {
                encoded = .float(VM.FloatingValue(value))
            } else {
                throw mismatch(expected: type, value: value)
            }
            return .init(
                type: type,
                value: try encoder.encodeDynamicLeaf(encoded)
            )
        case .string:
            guard let value = value as? String else {
                throw mismatch(expected: type, value: value)
            }
            return .init(
                type: type,
                value: try encoder.encodeDynamicLeaf(.string(value))
            )
        case let .optional(wrapped):
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .optional,
                  mirror.children.count <= 1
            else {
                throw mismatch(expected: type, value: value)
            }
            let encoded = try encoder.encodeDynamicContainer(
                childValueCount: mirror.children.count
            ) {
                let payload: VM.Value?
                if let child = mirror.children.first {
                    payload = try encode(
                        child.value,
                        as: wrapped,
                        using: encoder,
                        depth: depth + 1
                    ).value
                } else {
                    payload = nil
                }
                return .optional(payload)
            }
            return .init(type: type, value: encoded)
        case let .array(element):
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .collection else {
                throw mismatch(expected: type, value: value)
            }
            let encoded = try encoder.encodeDynamicContainer(
                childValueCount: mirror.children.count
            ) {
                var elements: [VM.Value] = []
                elements.reserveCapacity(mirror.children.count)
                for child in mirror.children {
                    elements.append(
                        try encode(
                            child.value,
                            as: element,
                            using: encoder,
                            depth: depth + 1
                        ).value
                    )
                }
                return .array(elements, elementType: element)
            }
            return .init(type: type, value: encoded)
        case let .dictionary(key, element):
            let mirror = Mirror(reflecting: value)
            let childCount = mirror.children.count.multipliedReportingOverflow(by: 2)
            guard mirror.displayStyle == .dictionary, !childCount.overflow else {
                throw mismatch(expected: type, value: value)
            }
            let encoded = try encoder.encodeDynamicContainer(
                childValueCount: childCount.partialValue
            ) {
                var entries: [VM.DictionaryEntry] = []
                entries.reserveCapacity(mirror.children.count)
                for child in mirror.children {
                    let pair = Array(Mirror(reflecting: child.value).children)
                    guard pair.count == 2 else {
                        throw Runtime.BridgeInputError.invalidContainerCount
                    }
                    let encodedKey = try encode(
                        pair[0].value,
                        as: key,
                        using: encoder,
                        depth: depth + 1
                    )
                    let encodedValue = try encode(
                        pair[1].value,
                        as: element,
                        using: encoder,
                        depth: depth + 1
                    )
                    entries.append(
                        .init(key: encodedKey.value, value: encodedValue.value)
                    )
                }
                return .dictionary(entries, keyType: key, valueType: element)
            }
            return .init(type: type, value: encoded)
        case .any, .set, .tuple, .native, .local, .error, .address, .mutableCell,
             .arrayBuilder, .arraySortState, .closure,
             .void, .never:
            throw Runtime.BridgeInputError.unsupportedAnyType(reflectedType)
        }
    }

    static func decode(
        _ value: VM.Value,
        as type: Bytecode.ValueType,
        depth: Int
    ) throws -> Any {
        guard depth <= 64 else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(maximum: 64)
        }
        switch type {
        case .bool:
            return try Runtime.BridgeValueCodec.decode(value, as: Bool.self)
        case let .integer(bitWidth, signed):
            return try decodeInteger(value, bitWidth: bitWidth, signed: signed)
        case let .float(bitWidth):
            if bitWidth == 32 {
                return try Runtime.BridgeValueCodec.decode(value, as: Float.self)
            }
            return try Runtime.BridgeValueCodec.decode(value, as: Double.self)
        case .string:
            return try Runtime.BridgeValueCodec.decode(value, as: String.self)
        case .any:
            guard case let .any(erased) = value else {
                throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: value.type)
            }
            return try decode(
                erased.payload,
                as: erased.concreteType,
                depth: depth + 1
            )
        case let .optional(wrapped):
            guard case let .optional(payload) = value else {
                throw VM.RuntimeTrap.typeMismatch(expected: type, actual: value.type)
            }
            let decoded = try payload.map {
                try decode($0, as: wrapped, depth: depth + 1)
            }
            return try boxOptional(decoded, wrappedType: wrapped)
        case let .array(element):
            guard case let .array(elements, actualElement) = value,
                  actualElement == element
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: type, actual: value.type)
            }
            return try decodeArray(
                elements,
                elementType: element,
                depth: depth + 1
            )
        case let .dictionary(key, element):
            guard case let .dictionary(entries, actualKey, actualElement) = value,
                  actualKey == key,
                  actualElement == element
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: type, actual: value.type)
            }
            return try decodeDictionary(
                entries,
                keyType: key,
                valueType: element,
                depth: depth + 1
            )
        case .set, .tuple, .native, .local, .error, .address, .mutableCell,
             .arrayBuilder, .arraySortState, .closure, .void, .never:
            throw VM.RuntimeTrap.nativeFailure(
                "Swift Any boundary cannot materialize \(type)"
            )
        }
    }

    private static func encode(
        _ value: Any,
        as expected: Bytecode.ValueType,
        using encoder: Runtime.BridgeValueCodec.Encoder,
        depth: Int
    ) throws -> Encoded {
        if expected == .any {
            return .init(
                type: .any,
                value: try encoder.encodeAny(value)
            )
        }
        let encoded = try encode(value, using: encoder, depth: depth)
        guard encoded.type == expected else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: expected.description,
                actual: encoded.type.description
            )
        }
        return encoded
    }

    private static func encodeInteger(
        _ value: Any,
        bitWidth: UInt16,
        signed: Bool
    ) throws -> VM.Value {
        switch (bitWidth, signed) {
        case (8, true):
            guard let value = value as? Int8 else {
                throw mismatch(.integer(bitWidth: 8, signed: true), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (16, true):
            guard let value = value as? Int16 else {
                throw mismatch(.integer(bitWidth: 16, signed: true), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (32, true):
            guard let value = value as? Int32 else {
                throw mismatch(.integer(bitWidth: 32, signed: true), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (64, true):
            if let value = value as? Int {
                return try Runtime.BridgeValueCodec.encode(value)
            }
            guard let value = value as? Int64 else {
                throw mismatch(.int64, value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (8, false):
            guard let value = value as? UInt8 else {
                throw mismatch(.integer(bitWidth: 8, signed: false), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (16, false):
            guard let value = value as? UInt16 else {
                throw mismatch(.integer(bitWidth: 16, signed: false), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (32, false):
            guard let value = value as? UInt32 else {
                throw mismatch(.integer(bitWidth: 32, signed: false), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        case (64, false):
            if let value = value as? UInt {
                return try Runtime.BridgeValueCodec.encode(value)
            }
            guard let value = value as? UInt64 else {
                throw mismatch(.integer(bitWidth: 64, signed: false), value)
            }
            return try Runtime.BridgeValueCodec.encode(value)
        default:
            throw Runtime.BridgeInputError.unsupportedAnyType(
                "integer width \(bitWidth)"
            )
        }
    }

    private static func decodeInteger(
        _ value: VM.Value,
        bitWidth: UInt16,
        signed: Bool
    ) throws -> Any {
        switch (bitWidth, signed) {
        case (8, true): try Runtime.BridgeValueCodec.decode(value, as: Int8.self)
        case (16, true): try Runtime.BridgeValueCodec.decode(value, as: Int16.self)
        case (32, true): try Runtime.BridgeValueCodec.decode(value, as: Int32.self)
        case (64, true): try Runtime.BridgeValueCodec.decode(value, as: Int.self)
        case (8, false): try Runtime.BridgeValueCodec.decode(value, as: UInt8.self)
        case (16, false): try Runtime.BridgeValueCodec.decode(value, as: UInt16.self)
        case (32, false): try Runtime.BridgeValueCodec.decode(value, as: UInt32.self)
        case (64, false): try Runtime.BridgeValueCodec.decode(value, as: UInt.self)
        default:
            throw VM.RuntimeTrap.invalidIntegerWidth(bitWidth)
        }
    }

    private static func decodeArray(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        depth: Int
    ) throws -> Any {
        switch elementType {
        case .bool:
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Bool.self) }
        case .integer(bitWidth: 8, signed: true):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Int8.self) }
        case .integer(bitWidth: 16, signed: true):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Int16.self) }
        case .integer(bitWidth: 32, signed: true):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Int32.self) }
        case .integer(bitWidth: 64, signed: true):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Int.self) }
        case .integer(bitWidth: 8, signed: false):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: UInt8.self) }
        case .integer(bitWidth: 16, signed: false):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: UInt16.self) }
        case .integer(bitWidth: 32, signed: false):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: UInt32.self) }
        case .integer(bitWidth: 64, signed: false):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: UInt.self) }
        case .float(bitWidth: 32):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Float.self) }
        case .float(bitWidth: 64):
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: Double.self) }
        case .string:
            try elements.map { try Runtime.BridgeValueCodec.decode($0, as: String.self) }
        default:
            try elements.map { try decode($0, as: elementType, depth: depth) }
        }
    }

    private static func decodeDictionary(
        _ entries: [VM.DictionaryEntry],
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType,
        depth: Int
    ) throws -> Any {
        switch keyType {
        case .bool:
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: Bool.self)
            }
        case .integer(bitWidth: 8, signed: true):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: Int8.self)
            }
        case .integer(bitWidth: 16, signed: true):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: Int16.self)
            }
        case .integer(bitWidth: 32, signed: true):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: Int32.self)
            }
        case .integer(bitWidth: 64, signed: true):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: Int.self)
            }
        case .integer(bitWidth: 8, signed: false):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt8.self)
            }
        case .integer(bitWidth: 16, signed: false):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt16.self)
            }
        case .integer(bitWidth: 32, signed: false):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt32.self)
            }
        case .integer(bitWidth: 64, signed: false):
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt.self)
            }
        case .string:
            return try decodeDictionary(entries, valueType: valueType, depth: depth) {
                try Runtime.BridgeValueCodec.decode($0, as: String.self)
            }
        default:
            throw VM.RuntimeTrap.nativeFailure(
                "Swift Any boundary cannot materialize Dictionary key \(keyType)"
            )
        }
    }

    private static func decodeDictionary<Key: Hashable>(
        _ entries: [VM.DictionaryEntry],
        valueType: Bytecode.ValueType,
        depth: Int,
        decodeKey: (VM.Value) throws -> Key
    ) throws -> Any {
        switch valueType {
        case .bool:
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Bool.self)
            }
        case .integer(bitWidth: 8, signed: true):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Int8.self)
            }
        case .integer(bitWidth: 16, signed: true):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Int16.self)
            }
        case .integer(bitWidth: 32, signed: true):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Int32.self)
            }
        case .integer(bitWidth: 64, signed: true):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Int.self)
            }
        case .integer(bitWidth: 8, signed: false):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt8.self)
            }
        case .integer(bitWidth: 16, signed: false):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt16.self)
            }
        case .integer(bitWidth: 32, signed: false):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt32.self)
            }
        case .integer(bitWidth: 64, signed: false):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: UInt.self)
            }
        case .float(bitWidth: 32):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Float.self)
            }
        case .float(bitWidth: 64):
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: Double.self)
            }
        case .string:
            return try decodeTypedDictionary(entries, decodeKey: decodeKey) {
                try Runtime.BridgeValueCodec.decode($0, as: String.self)
            }
        default:
            break
        }
        var result: [Key: Any] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            let key = try decodeKey(entry.key)
            let value = try decode(entry.value, as: valueType, depth: depth)
            guard result.updateValue(value, forKey: key) == nil else {
                throw VM.RuntimeTrap.nativeFailure(
                    "VM Dictionary contains a duplicate key"
                )
            }
        }
        return result
    }

    private static func decodeTypedDictionary<Key: Hashable, Value>(
        _ entries: [VM.DictionaryEntry],
        decodeKey: (VM.Value) throws -> Key,
        decodeValue: (VM.Value) throws -> Value
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            let key = try decodeKey(entry.key)
            let value = try decodeValue(entry.value)
            guard result.updateValue(value, forKey: key) == nil else {
                throw VM.RuntimeTrap.nativeFailure(
                    "VM Dictionary contains a duplicate key"
                )
            }
        }
        return result
    }

    private static func boxOptional(
        _ payload: Any?,
        wrappedType: Bytecode.ValueType
    ) throws -> Any {
        switch wrappedType {
        case .bool:
            let value: Bool? = try castOptional(payload, as: Bool.self)
            return value as Any
        case .integer(bitWidth: 8, signed: true):
            let value: Int8? = try castOptional(payload, as: Int8.self)
            return value as Any
        case .integer(bitWidth: 16, signed: true):
            let value: Int16? = try castOptional(payload, as: Int16.self)
            return value as Any
        case .integer(bitWidth: 32, signed: true):
            let value: Int32? = try castOptional(payload, as: Int32.self)
            return value as Any
        case .integer(bitWidth: 64, signed: true):
            let value: Int? = try castOptional(payload, as: Int.self)
            return value as Any
        case .integer(bitWidth: 8, signed: false):
            let value: UInt8? = try castOptional(payload, as: UInt8.self)
            return value as Any
        case .integer(bitWidth: 16, signed: false):
            let value: UInt16? = try castOptional(payload, as: UInt16.self)
            return value as Any
        case .integer(bitWidth: 32, signed: false):
            let value: UInt32? = try castOptional(payload, as: UInt32.self)
            return value as Any
        case .integer(bitWidth: 64, signed: false):
            let value: UInt? = try castOptional(payload, as: UInt.self)
            return value as Any
        case .float(bitWidth: 32):
            let value: Float? = try castOptional(payload, as: Float.self)
            return value as Any
        case .float(bitWidth: 64):
            let value: Double? = try castOptional(payload, as: Double.self)
            return value as Any
        case .string:
            let value: String? = try castOptional(payload, as: String.self)
            return value as Any
        default:
            let value: Any? = payload
            return value as Any
        }
    }

    private static func castOptional<Value>(
        _ payload: Any?,
        as type: Value.Type
    ) throws -> Value? {
        guard let payload else { return nil }
        guard let value = payload as? Value else {
            throw VM.RuntimeTrap.nativeFailure(
                "Swift Any Optional payload has an inconsistent dynamic type"
            )
        }
        return value
    }

    private static func parseStandardType(
        _ raw: String
    ) -> Bytecode.ValueType? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "Swift.Bool": return .bool
        case "Swift.Int", "Swift.Int64": return .int64
        case "Swift.Int8": return .integer(bitWidth: 8, signed: true)
        case "Swift.Int16": return .integer(bitWidth: 16, signed: true)
        case "Swift.Int32": return .integer(bitWidth: 32, signed: true)
        case "Swift.UInt", "Swift.UInt64":
            return .integer(bitWidth: 64, signed: false)
        case "Swift.UInt8": return .integer(bitWidth: 8, signed: false)
        case "Swift.UInt16": return .integer(bitWidth: 16, signed: false)
        case "Swift.UInt32": return .integer(bitWidth: 32, signed: false)
        case "Swift.Float": return .float(bitWidth: 32)
        case "Swift.Double": return .float(bitWidth: 64)
        case "Swift.String": return .string
        case "Any", "Swift.Any": return .any
        default: break
        }
        if let wrapped = genericArguments(value, prefix: "Swift.Optional<"),
           wrapped.count == 1,
           let type = parseStandardType(wrapped[0]) {
            return .optional(type)
        }
        if let wrapped = genericArguments(value, prefix: "Swift.Array<"),
           wrapped.count == 1,
           let type = parseStandardType(wrapped[0]) {
            return .array(type)
        }
        if let wrapped = genericArguments(value, prefix: "Swift.Dictionary<"),
           wrapped.count == 2,
           let key = parseStandardType(wrapped[0]),
           let element = parseStandardType(wrapped[1]),
           isDictionaryKey(key) {
            return .dictionary(key: key, value: element)
        }
        return nil
    }

    private static func isDictionaryKey(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .bool, .integer, .string: true
        default: false
        }
    }

    private static func genericArguments(
        _ value: String,
        prefix: String
    ) -> [String]? {
        guard value.hasPrefix(prefix), value.hasSuffix(">") else { return nil }
        let body = String(value.dropFirst(prefix.count).dropLast())
        var components: [String] = []
        var start = body.startIndex
        var depth = 0
        for index in body.indices {
            switch body[index] {
            case "<", "(", "[": depth += 1
            case ">", ")", "]":
                depth -= 1
                guard depth >= 0 else { return nil }
            case "," where depth == 0:
                components.append(
                    String(body[start..<index]).trimmingCharacters(in: .whitespaces)
                )
                start = body.index(after: index)
            default: break
            }
        }
        guard depth == 0 else { return nil }
        components.append(
            String(body[start...]).trimmingCharacters(in: .whitespaces)
        )
        return components.allSatisfy({ !$0.isEmpty }) ? components : nil
    }

    private static func mismatch(
        expected: Bytecode.ValueType,
        value: Any
    ) -> Runtime.BridgeInputError {
        .encodedTypeMismatch(
            expected: expected.description,
            actual: String(reflecting: Swift.type(of: value))
        )
    }

    private static func mismatch(
        _ expected: Bytecode.ValueType,
        _ value: Any
    ) -> Runtime.BridgeInputError {
        mismatch(expected: expected, value: value)
    }
}
}
