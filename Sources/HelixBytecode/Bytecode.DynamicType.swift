import Foundation

extension Bytecode {
/// Source-level identity retained by a VM-owned `Any` value.
///
/// HLBC value types describe storage. Swift dynamic casts additionally need
/// distinctions such as `Int` versus `Int64`, `String` versus `Character`, and
/// `Array` versus `ArraySlice`. This closed recursive grammar carries those
/// distinctions without serializing Swift metadata or private runtime ABI.
public indirect enum DynamicType: Codable, Hashable, Sendable,
    CustomStringConvertible {
    public static let maximumNestingDepthV1 = 32
    public static let maximumTupleElementCountV1 = 64
    public static let maximumTupleLabelUTF8LengthV1 = 256

    case any
    case bool
    case integer(Bytecode.DynamicIntegerType)
    case floatingPoint(Bytecode.DynamicFloatingPointType)
    case string
    case character
    case substring
    case local(Bytecode.LocalTypeKey)
    case optional(Bytecode.DynamicType)
    case array(Bytecode.DynamicType)
    case arraySlice(Bytecode.DynamicType)
    case dictionary(
        key: Bytecode.DynamicType,
        value: Bytecode.DynamicType
    )
    case set(Bytecode.DynamicType)
    case tuple([Bytecode.DynamicTupleElement])

    /// Physical register/storage shape used by HLBC execution.
    public var storageType: Bytecode.ValueType {
        switch self {
        case .any:
            .any
        case .bool:
            .bool
        case let .integer(identity):
            identity.storageType
        case let .floatingPoint(identity):
            identity.storageType
        case .string, .character:
            .string
        case .substring:
            .array(.string)
        case let .local(key):
            .local(key)
        case let .optional(wrapped):
            .optional(wrapped.storageType)
        case let .array(element), let .arraySlice(element):
            .array(element.storageType)
        case let .dictionary(key, value):
            .dictionary(key: key.storageType, value: value.storageType)
        case let .set(element):
            .set(element.storageType)
        case let .tuple(elements):
            .tuple(elements.map { $0.type.storageType })
        }
    }

    /// Direct boxes record a concrete identity. `Any` is admitted only as a
    /// child of a represented aggregate or as a redundant erasure source.
    public var isAnyPayloadV1: Bool {
        isWellFormedV1 && self != .any
    }

    public var isAnyPayloadOrExistentialV1: Bool {
        isWellFormedV1
    }

    public var isAnyCastTargetV1: Bool {
        isWellFormedV1
    }

    /// Whether Runtime can reconstruct this logical Swift type without
    /// private metadata or an application-defined codec. This is narrower
    /// than the image-local `Any` grammar: ArraySlice bases, tuples, and local
    /// nominal values deliberately remain inside HLVM.
    public var isSwiftBridgeMaterializableV1: Bool {
        isSwiftBridgeMaterializableV1(depth: 0)
    }

    private func isSwiftBridgeMaterializableV1(depth: Int) -> Bool {
        guard depth <= Self.maximumNestingDepthV1 else { return false }
        return switch self {
        case .any, .bool, .integer, .floatingPoint, .string, .character,
             .substring:
            true
        case let .optional(wrapped), let .array(wrapped), let .set(wrapped):
            wrapped.isSwiftBridgeMaterializableV1(depth: depth + 1)
        case let .dictionary(key, value):
            key.isSwiftBridgeMaterializableV1(depth: depth + 1)
                && value.isSwiftBridgeMaterializableV1(depth: depth + 1)
        case .arraySlice, .local, .tuple:
            false
        }
    }

    /// Swift `Hashable` semantics that can be reproduced without user code.
    public var hasVMDefinedHashableSemantics: Bool {
        hasVMDefinedHashableSemantics(depth: 0)
    }

    private func hasVMDefinedHashableSemantics(depth: Int) -> Bool {
        guard depth <= Self.maximumNestingDepthV1 else { return false }
        return switch self {
        case .bool, .integer, .floatingPoint, .string, .character, .substring:
            true
        case let .optional(wrapped), let .array(wrapped),
             let .arraySlice(wrapped), let .set(wrapped):
            wrapped.hasVMDefinedHashableSemantics(depth: depth + 1)
        case let .dictionary(key, value):
            key.hasVMDefinedHashableSemantics(depth: depth + 1)
                && value.hasVMDefinedHashableSemantics(depth: depth + 1)
        case .any, .local, .tuple:
            false
        }
    }

    public var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case let .integer(identity): identity.description
        case let .floatingPoint(identity): identity.description
        case .string: "String"
        case .character: "Character"
        case .substring: "Substring"
        case let .local(key): key.description
        case let .optional(wrapped): "Optional<\(wrapped)>"
        case let .array(element): "Array<\(element)>"
        case let .arraySlice(element): "ArraySlice<\(element)>"
        case let .dictionary(key, value):
            "Dictionary<\(key), \(value)>"
        case let .set(element): "Set<\(element)>"
        case let .tuple(elements):
            "(" + elements.map(\.description).joined(separator: ", ") + ")"
        }
    }

    private var isWellFormedV1: Bool {
        isWellFormedV1(depth: 0)
    }

    private func isWellFormedV1(depth: Int) -> Bool {
        guard depth <= Self.maximumNestingDepthV1 else { return false }
        switch self {
        case .any, .bool, .integer, .floatingPoint, .string, .character,
             .substring, .local:
            return true
        case let .optional(wrapped), let .array(wrapped),
             let .arraySlice(wrapped):
            return wrapped.isWellFormedV1(depth: depth + 1)
        case let .dictionary(key, value):
            return key.hasVMDefinedHashableSemantics(depth: depth + 1)
                && key.isWellFormedV1(depth: depth + 1)
                && value.isWellFormedV1(depth: depth + 1)
        case let .set(element):
            return element.hasVMDefinedHashableSemantics(depth: depth + 1)
                && element.isWellFormedV1(depth: depth + 1)
        case let .tuple(elements):
            // Swift has no one-element tuple; parentheses around one type do
            // not create a distinct dynamic identity. Void is not represented
            // as an Any payload because HLVM models it as absence of a value.
            let labels = elements.compactMap(\.label)
            return elements.count >= 2
                && elements.count <= Self.maximumTupleElementCountV1
                && Set(labels).count == labels.count
                && elements.allSatisfy {
                    $0.hasValidLabel
                        && $0.type.isWellFormedV1(depth: depth + 1)
                }
        }
    }
}

public enum DynamicIntegerType: String, Codable, Hashable, Sendable,
    CustomStringConvertible {
    case int
    case int8
    case int16
    case int32
    case int64
    case uint
    case uint8
    case uint16
    case uint32
    case uint64

    public var storageType: Bytecode.ValueType {
        switch self {
        case .int, .int64:
            .integer(bitWidth: 64, signed: true)
        case .int8:
            .integer(bitWidth: 8, signed: true)
        case .int16:
            .integer(bitWidth: 16, signed: true)
        case .int32:
            .integer(bitWidth: 32, signed: true)
        case .uint, .uint64:
            .integer(bitWidth: 64, signed: false)
        case .uint8:
            .integer(bitWidth: 8, signed: false)
        case .uint16:
            .integer(bitWidth: 16, signed: false)
        case .uint32:
            .integer(bitWidth: 32, signed: false)
        }
    }

    public var description: String {
        switch self {
        case .int: "Int"
        case .int8: "Int8"
        case .int16: "Int16"
        case .int32: "Int32"
        case .int64: "Int64"
        case .uint: "UInt"
        case .uint8: "UInt8"
        case .uint16: "UInt16"
        case .uint32: "UInt32"
        case .uint64: "UInt64"
        }
    }
}

public enum DynamicFloatingPointType: String, Codable, Hashable, Sendable,
    CustomStringConvertible {
    case float
    case double
    case cgFloat

    public var storageType: Bytecode.ValueType {
        switch self {
        case .float:
            .float(bitWidth: 32)
        case .double, .cgFloat:
            .float(bitWidth: 64)
        }
    }

    public var description: String {
        switch self {
        case .float: "Float"
        case .double: "Double"
        case .cgFloat: "CGFloat"
        }
    }
}

public struct DynamicTupleElement: Codable, Hashable, Sendable,
    CustomStringConvertible {
    public var label: String?
    public var type: Bytecode.DynamicType

    public init(label: String? = nil, type: Bytecode.DynamicType) {
        self.label = label
        self.type = type
    }

    public var description: String {
        label.map { "\($0): \(type)" } ?? type.description
    }

    fileprivate var hasValidLabel: Bool {
        guard let label else { return true }
        return !label.isEmpty
            && label.utf8.count
                <= Bytecode.DynamicType.maximumTupleLabelUTF8LengthV1
            && !label.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}
}
