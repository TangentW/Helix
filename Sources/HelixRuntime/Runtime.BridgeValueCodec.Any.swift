import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixVM
#endif

extension Runtime.BridgeValueCodec {
/// Encodes the supported standard-library subset of a dynamic Swift value.
/// Native objects, local nominal values, closures, and tuples have no stable
/// VM-owned representation at this boundary and remain fail-closed.
public static func encodeAny(_ value: Any) throws -> VM.Value {
    let encoder = Encoder(limits: .init())
    let result = try encoder.encodeAny(value)
    try encoder.finalize(arguments: [result])
    return result
}

/// Decodes a VM-owned existential while preserving its represented Swift
/// dynamic type, including recursively nested containers.
public static func decodeAny(_ value: VM.Value) throws -> Any {
    guard case let .any(erased) = value,
          erased.dynamicType.isAnyPayloadV1,
          erased.payload.matches(erased.dynamicType)
    else {
        throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: value.type)
    }
    return try DynamicAny.decodeValidated(
        erased.payload,
        as: erased.dynamicType,
        depth: 0
    )
}
}

extension Runtime.BridgeValueCodec.Encoder {
/// Encodes a dynamic Swift value while charging its complete object graph to
/// this dispatch's bridge-input limits.
public func encodeAny(_ value: Any) throws -> VM.Value {
    try encodeDynamicContainer(childValueCount: 1) {
        let payload = try Runtime.BridgeValueCodec.DynamicAny.encode(
            value,
            using: self
        )
        return .any(
            .init(dynamicType: payload.dynamicType, payload: payload.value)
        )
    }
}
}

private extension Runtime.BridgeValueCodec {
enum DynamicAny {
    struct Encoded {
        var dynamicType: Bytecode.DynamicType
        var value: VM.Value
    }

    static func encode(
        _ value: Any,
        using encoder: Runtime.BridgeValueCodec.Encoder
    ) throws -> Encoded {
        let reflectedType = String(reflecting: Swift.type(of: value))
        guard let dynamicType = parseStandardType(reflectedType),
              dynamicType.isAnyPayloadV1,
              let codec = codec(for: dynamicType)
        else {
            throw Runtime.BridgeInputError.unsupportedAnyType(reflectedType)
        }
        let encoded = try codec.encodeAny(value, using: encoder)
        guard encoded.matches(dynamicType) else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: dynamicType.description,
                actual: encoded.type.description
            )
        }
        return .init(dynamicType: dynamicType, value: encoded)
    }

    /// Materializes a value whose complete graph was already validated by the
    /// public Shell boundary. Nested codecs must preserve this invariant so a
    /// large graph is not rescanned at every existential layer.
    static func decodeValidated(
        _ value: VM.Value,
        as dynamicType: Bytecode.DynamicType,
        depth: Int
    ) throws -> Any {
        try requireDepth(depth)
        guard let codec = codec(for: dynamicType) else {
            throw VM.RuntimeTrap.nativeFailure(
                "Swift Any boundary cannot materialize \(dynamicType)"
            )
        }
        return try codec.decodeAny(value, depth: depth)
    }

    private static func codec(
        for type: Bytecode.DynamicType
    ) -> (any DynamicCodecBox)? {
        switch type {
        case .any:
            return NonHashableDynamicCodecBox(codec: anyCodec())
        case .bool:
            return scalarCodec(
                .bool,
                as: Bool.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: Bool.self)
                }
            )
        case let .integer(identity):
            return integerCodec(identity)
        case let .floatingPoint(identity):
            return floatingPointCodec(identity)
        case .string:
            return scalarCodec(
                .string,
                as: String.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: String.self)
                }
            )
        case .character:
            return scalarCodec(
                .character,
                as: Character.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: Character.self)
                }
            )
        case .substring:
            return scalarCodec(
                .substring,
                as: Substring.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: Substring.self)
                }
            )
        case let .optional(wrapped):
            return codec(for: wrapped)?.optionalCodec()
        case let .array(element):
            return codec(for: element)?.arrayCodec()
        case let .dictionary(key, value):
            guard let keyCodec = codec(for: key),
                  let valueCodec = codec(for: value)
            else { return nil }
            return keyCodec.dictionaryCodec(value: valueCodec)
        case let .set(element):
            return codec(for: element)?.setCodec()
        case .arraySlice, .local, .tuple:
            // ArraySlice's nonzero public index base and arbitrary tuple
            // arity cannot be reconstructed through a type-erased Shell ABI.
            return nil
        }
    }

    private static func scalarCodec<Value: Hashable>(
        _ dynamicType: Bytecode.DynamicType,
        as _: Value.Type,
        encode: @escaping (
            Value,
            Runtime.BridgeValueCodec.Encoder
        ) throws -> VM.Value,
        decode: @escaping (VM.Value) throws -> Value
    ) -> any DynamicCodecBox {
        HashableDynamicCodecBox(
            codec: makeScalarCodec(
                dynamicType,
                encode: encode,
                decode: decode
            )
        )
    }

    private static func makeScalarCodec<Value>(
        _ dynamicType: Bytecode.DynamicType,
        encode: @escaping (
            Value,
            Runtime.BridgeValueCodec.Encoder
        ) throws -> VM.Value,
        decode: @escaping (VM.Value) throws -> Value
    ) -> DynamicCodec<Value> {
        .init(
            dynamicType: dynamicType,
            encode: encode,
            decode: { value, depth in
                try requireDepth(depth)
                return try decode(value)
            }
        )
    }

    private static func integerCodec(
        _ identity: Bytecode.DynamicIntegerType
    ) -> any DynamicCodecBox {
        switch identity {
        case .int: fixedWidthIntegerCodec(identity, Int.self)
        case .int8: fixedWidthIntegerCodec(identity, Int8.self)
        case .int16: fixedWidthIntegerCodec(identity, Int16.self)
        case .int32: fixedWidthIntegerCodec(identity, Int32.self)
        case .int64: fixedWidthIntegerCodec(identity, Int64.self)
        case .uint: fixedWidthIntegerCodec(identity, UInt.self)
        case .uint8: fixedWidthIntegerCodec(identity, UInt8.self)
        case .uint16: fixedWidthIntegerCodec(identity, UInt16.self)
        case .uint32: fixedWidthIntegerCodec(identity, UInt32.self)
        case .uint64: fixedWidthIntegerCodec(identity, UInt64.self)
        }
    }

    private static func fixedWidthIntegerCodec<Value>(
        _ identity: Bytecode.DynamicIntegerType,
        _ type: Value.Type
    ) -> any DynamicCodecBox where Value: FixedWidthInteger & Hashable {
        scalarCodec(
            .integer(identity),
            as: type,
            encode: { try $1.encode($0) },
            decode: {
                try Runtime.BridgeValueCodec.decode($0, as: Value.self)
            }
        )
    }

    private static func floatingPointCodec(
        _ identity: Bytecode.DynamicFloatingPointType
    ) -> any DynamicCodecBox {
        switch identity {
        case .float:
            return scalarCodec(
                .floatingPoint(.float),
                as: Float.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: Float.self)
                }
            )
        case .double:
            return scalarCodec(
                .floatingPoint(.double),
                as: Double.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: Double.self)
                }
            )
        case .cgFloat:
            return scalarCodec(
                .floatingPoint(.cgFloat),
                as: CGFloat.self,
                encode: { try $1.encode($0) },
                decode: {
                    try Runtime.BridgeValueCodec.decode($0, as: CGFloat.self)
                }
            )
        }
    }

    private static func anyCodec() -> DynamicCodec<Any> {
        .init(
            dynamicType: .any,
            encode: { value, encoder in
                try encoder.encodeAny(value)
            },
            decode: { value, depth in
                try requireDepth(depth)
                guard case let .any(erased) = value,
                      erased.dynamicType.isAnyPayloadV1
                else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .any,
                        actual: value.type
                    )
                }
                return try decodeValidated(
                    erased.payload,
                    as: erased.dynamicType,
                    depth: depth + 1
                )
            }
        )
    }

    fileprivate static func optionalCodec<Wrapped>(
        _ wrapped: DynamicCodec<Wrapped>
    ) -> DynamicCodec<Wrapped?> {
        .init(
            dynamicType: .optional(wrapped.dynamicType),
            encode: { value, encoder in
                try encoder.encodeOptional(value) {
                    try wrapped.encode($0, encoder)
                }
            },
            decode: { value, depth in
                try requireDepth(depth)
                guard case let .optional(payload) = value else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .optional(wrapped.dynamicType.storageType),
                        actual: value.type
                    )
                }
                return try payload.map {
                    try wrapped.decode($0, depth + 1)
                }
            }
        )
    }

    fileprivate static func arrayCodec<Element>(
        _ element: DynamicCodec<Element>
    ) -> DynamicCodec<[Element]> {
        .init(
            dynamicType: .array(element.dynamicType),
            encode: { value, encoder in
                try encoder.encodeArray(
                    value,
                    elementType: element.dynamicType.storageType
                ) {
                    try element.encode($0, encoder)
                }
            },
            decode: { value, depth in
                try requireDepth(depth)
                guard case let .array(storage) = value,
                      storage.indexBase == 0,
                      storage.elementType == element.dynamicType.storageType
                else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .array(element.dynamicType.storageType),
                        actual: value.type
                    )
                }
                return try storage.elements.map {
                    try element.decode($0, depth + 1)
                }
            }
        )
    }

    fileprivate static func setCodec<Element: Hashable>(
        _ element: DynamicCodec<Element>
    ) -> DynamicCodec<Set<Element>> {
        .init(
            dynamicType: .set(element.dynamicType),
            encode: { value, encoder in
                try encoder.encodeSet(
                    value,
                    elementType: element.dynamicType.storageType
                ) {
                    try element.encode($0, encoder)
                }
            },
            decode: { value, depth in
                try requireDepth(depth)
                return try Runtime.BridgeValueCodec.decodeSet(
                    value,
                    elementType: element.dynamicType.storageType
                ) {
                    try element.decode($0, depth + 1)
                }
            }
        )
    }

    fileprivate static func dictionaryCodec<Key: Hashable, Value>(
        key: DynamicCodec<Key>,
        value: DynamicCodec<Value>
    ) -> DynamicCodec<[Key: Value]> {
        .init(
            dynamicType: .dictionary(
                key: key.dynamicType,
                value: value.dynamicType
            ),
            encode: { dictionary, encoder in
                try encoder.encodeDictionary(
                    dictionary,
                    keyType: key.dynamicType.storageType,
                    valueType: value.dynamicType.storageType,
                    encodeKey: { try key.encode($0, encoder) },
                    encodeValue: { try value.encode($0, encoder) }
                )
            },
            decode: { encoded, depth in
                try requireDepth(depth)
                return try Runtime.BridgeValueCodec.decodeDictionary(
                    encoded,
                    keyType: key.dynamicType.storageType,
                    valueType: value.dynamicType.storageType,
                    decodeKey: { try key.decode($0, depth + 1) },
                    decodeValue: { try value.decode($0, depth + 1) }
                )
            }
        )
    }

    private static func requireDepth(_ depth: Int) throws {
        guard depth <= 64 else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(maximum: 64)
        }
    }

    private static func parseStandardType(
        _ raw: String,
        depth: Int = 0
    ) -> Bytecode.DynamicType? {
        guard depth <= Bytecode.DynamicType.maximumNestingDepthV1 else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "Any", "Swift.Any": return .any
        case "Swift.Bool": return .bool
        case "Swift.Int": return .integer(.int)
        case "Swift.Int8": return .integer(.int8)
        case "Swift.Int16": return .integer(.int16)
        case "Swift.Int32": return .integer(.int32)
        case "Swift.Int64": return .integer(.int64)
        case "Swift.UInt": return .integer(.uint)
        case "Swift.UInt8": return .integer(.uint8)
        case "Swift.UInt16": return .integer(.uint16)
        case "Swift.UInt32": return .integer(.uint32)
        case "Swift.UInt64": return .integer(.uint64)
        case "Swift.Float": return .floatingPoint(.float)
        case "Swift.Double": return .floatingPoint(.double)
        case "CoreGraphics.CGFloat": return .floatingPoint(.cgFloat)
        case "Swift.String": return .string
        case "Swift.Character": return .character
        case "Swift.Substring": return .substring
        default:
            break
        }
        if let arguments = genericArguments(value, prefix: "Swift.Optional<"),
           arguments.count == 1,
           let wrapped = parseStandardType(arguments[0], depth: depth + 1) {
            return .optional(wrapped)
        }
        if let arguments = genericArguments(value, prefix: "Swift.Array<"),
           arguments.count == 1,
           let element = parseStandardType(arguments[0], depth: depth + 1) {
            return .array(element)
        }
        if let arguments = genericArguments(value, prefix: "Swift.ArraySlice<"),
           arguments.count == 1,
           let element = parseStandardType(arguments[0], depth: depth + 1) {
            return .arraySlice(element)
        }
        if let arguments = genericArguments(value, prefix: "Swift.Set<"),
           arguments.count == 1,
           let element = parseStandardType(arguments[0], depth: depth + 1) {
            return .set(element)
        }
        if let arguments = genericArguments(value, prefix: "Swift.Dictionary<"),
           arguments.count == 2,
           let key = parseStandardType(arguments[0], depth: depth + 1),
           let element = parseStandardType(arguments[1], depth: depth + 1) {
            return .dictionary(key: key, value: element)
        }
        return nil
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
            default:
                break
            }
        }
        guard depth == 0 else { return nil }
        components.append(
            String(body[start...]).trimmingCharacters(in: .whitespaces)
        )
        return components.allSatisfy({ !$0.isEmpty }) ? components : nil
    }
}

struct DynamicCodec<Value> {
    var dynamicType: Bytecode.DynamicType
    var encode: (
        Value,
        Runtime.BridgeValueCodec.Encoder
    ) throws -> VM.Value
    var decode: (VM.Value, Int) throws -> Value
}

protocol DynamicCodecBox {
    var dynamicType: Bytecode.DynamicType { get }
    func encodeAny(
        _ value: Any,
        using encoder: Runtime.BridgeValueCodec.Encoder
    ) throws -> VM.Value
    func decodeAny(_ value: VM.Value, depth: Int) throws -> Any
    func optionalCodec() -> any DynamicCodecBox
    func arrayCodec() -> any DynamicCodecBox
    func setCodec() -> (any DynamicCodecBox)?
    func dictionaryCodec(
        value: any DynamicCodecBox
    ) -> (any DynamicCodecBox)?
    func dictionaryValueCodec<Key: Hashable>(
        key: DynamicCodec<Key>
    ) -> any DynamicCodecBox
}

struct NonHashableDynamicCodecBox<Value>: DynamicCodecBox {
    var codec: DynamicCodec<Value>
    var dynamicType: Bytecode.DynamicType { codec.dynamicType }

    func encodeAny(
        _ value: Any,
        using encoder: Runtime.BridgeValueCodec.Encoder
    ) throws -> VM.Value {
        guard let value = value as? Value else {
            throw mismatch(value)
        }
        return try codec.encode(value, encoder)
    }

    func decodeAny(_ value: VM.Value, depth: Int) throws -> Any {
        try codec.decode(value, depth)
    }

    func optionalCodec() -> any DynamicCodecBox {
        NonHashableDynamicCodecBox<Value?>(
            codec: DynamicAny.optionalCodec(codec)
        )
    }

    func arrayCodec() -> any DynamicCodecBox {
        NonHashableDynamicCodecBox<[Value]>(
            codec: DynamicAny.arrayCodec(codec)
        )
    }

    func setCodec() -> (any DynamicCodecBox)? { nil }

    func dictionaryCodec(
        value: any DynamicCodecBox
    ) -> (any DynamicCodecBox)? {
        nil
    }

    func dictionaryValueCodec<Key: Hashable>(
        key: DynamicCodec<Key>
    ) -> any DynamicCodecBox {
        NonHashableDynamicCodecBox<[Key: Value]>(
            codec: DynamicAny.dictionaryCodec(key: key, value: codec)
        )
    }

    private func mismatch(_ value: Any) -> Runtime.BridgeInputError {
        .encodedTypeMismatch(
            expected: dynamicType.description,
            actual: String(reflecting: Swift.type(of: value))
        )
    }
}

struct HashableDynamicCodecBox<Value: Hashable>: DynamicCodecBox {
    var codec: DynamicCodec<Value>
    var dynamicType: Bytecode.DynamicType { codec.dynamicType }

    func encodeAny(
        _ value: Any,
        using encoder: Runtime.BridgeValueCodec.Encoder
    ) throws -> VM.Value {
        guard let value = value as? Value else {
            throw mismatch(value)
        }
        return try codec.encode(value, encoder)
    }

    func decodeAny(_ value: VM.Value, depth: Int) throws -> Any {
        try codec.decode(value, depth)
    }

    func optionalCodec() -> any DynamicCodecBox {
        HashableDynamicCodecBox<Value?>(
            codec: DynamicAny.optionalCodec(codec)
        )
    }

    func arrayCodec() -> any DynamicCodecBox {
        HashableDynamicCodecBox<[Value]>(
            codec: DynamicAny.arrayCodec(codec)
        )
    }

    func setCodec() -> (any DynamicCodecBox)? {
        HashableDynamicCodecBox<Set<Value>>(
            codec: DynamicAny.setCodec(codec)
        )
    }

    func dictionaryCodec(
        value: any DynamicCodecBox
    ) -> (any DynamicCodecBox)? {
        value.dictionaryValueCodec(key: codec)
    }

    func dictionaryValueCodec<Key: Hashable>(
        key: DynamicCodec<Key>
    ) -> any DynamicCodecBox {
        HashableDynamicCodecBox<[Key: Value]>(
            codec: DynamicAny.dictionaryCodec(key: key, value: codec)
        )
    }

    private func mismatch(_ value: Any) -> Runtime.BridgeInputError {
        .encodedTypeMismatch(
            expected: dynamicType.description,
            actual: String(reflecting: Swift.type(of: value))
        )
    }
}
}
