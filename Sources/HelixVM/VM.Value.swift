import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension VM {
public struct Integer: Hashable, Sendable, CustomStringConvertible {
    public let rawBits: UInt64
    public let bitWidth: UInt16
    public let isSigned: Bool

    public init(rawBits: UInt64, bitWidth: UInt16, isSigned: Bool) throws {
        guard [8, 16, 32, 64].contains(bitWidth) else {
            throw VM.RuntimeTrap.invalidIntegerWidth(bitWidth)
        }
        self.bitWidth = bitWidth
        self.isSigned = isSigned
        self.rawBits = rawBits & Self.mask(for: bitWidth)
    }

    public init(signed value: Int64, bitWidth: UInt16, isSigned: Bool) throws {
        guard [8, 16, 32, 64].contains(bitWidth) else {
            throw VM.RuntimeTrap.invalidIntegerWidth(bitWidth)
        }
        if isSigned {
            let bounds = Self.signedBounds(bitWidth: bitWidth)
            guard value >= bounds.min, value <= bounds.max else {
                throw VM.RuntimeTrap.integerOverflow
            }
        } else {
            guard value >= 0, bitWidth == 64 || UInt64(value) <= Self.mask(for: bitWidth) else {
                throw VM.RuntimeTrap.integerOverflow
            }
        }
        try self.init(rawBits: UInt64(bitPattern: value), bitWidth: bitWidth, isSigned: isSigned)
    }

    public var signedValue: Int64 {
        guard isSigned else { return Int64(bitPattern: rawBits) }
        guard bitWidth < 64 else { return Int64(bitPattern: rawBits) }
        let signBit = UInt64(1) << (bitWidth - 1)
        if rawBits & signBit == 0 { return Int64(rawBits) }
        return Int64(bitPattern: rawBits | ~Self.mask(for: bitWidth))
    }

    public var unsignedValue: UInt64 { rawBits }

    public var description: String {
        isSigned ? String(signedValue) : String(unsignedValue)
    }

    static func mask(for bitWidth: UInt16) -> UInt64 {
        bitWidth == 64 ? UInt64.max : (UInt64(1) << bitWidth) - 1
    }

    static func signedBounds(bitWidth: UInt16) -> (min: Int64, max: Int64) {
        guard bitWidth < 64 else { return (Int64.min, Int64.max) }
        let high = Int64(1) << (bitWidth - 1)
        return (-high, high - 1)
    }
}

public indirect enum Value: Hashable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case integer(VM.Integer)
    case float(VM.FloatingValue)
    case string(String)
    case any(VM.AnyValue)
    case array(VM.ArrayStorage)
    case dictionary(
        [VM.DictionaryEntry],
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType
    )
    case set(VM.SetValue)
    case native(VM.NativeValue)
    case tuple([VM.Value])
    case optional(VM.Value?)
    case structure(type: Bytecode.LocalTypeKey, fields: [VM.Value])
    case enumeration(
        type: Bytecode.LocalTypeKey,
        caseIndex: UInt32,
        payload: VM.Value?
    )
    case object(VM.ObjectReference)
    case error(VM.ErrorValue)
    case address(VM.Address)
    case mutableCell(VM.MutableCell)
    case nonOwningReference(VM.NonOwningReference)
    case arrayBuilder(VM.ArrayBuilder)
    case arrayMutationState(VM.ArrayMutationState)
    case dictionaryBuilder(VM.DictionaryBuilder)
    case arraySortState(VM.ArraySortState)
    case arraySplitState(VM.ArraySplitState)
    case closure(VM.Closure)

    public var type: Bytecode.ValueType {
        switch self {
        case .bool: .bool
        case let .integer(value): .integer(bitWidth: value.bitWidth, signed: value.isSigned)
        case let .float(value): .float(bitWidth: value.bitWidth)
        case .string: .string
        case .any: .any
        case let .array(storage): .array(storage.elementType)
        case let .dictionary(_, keyType, valueType):
            .dictionary(key: keyType, value: valueType)
        case let .set(value): .set(value.elementType)
        case let .native(value): .native(value.typeID)
        case let .tuple(elements): .tuple(elements.map(\.type))
        case let .optional(value): .optional(value?.type ?? .never)
        case let .structure(type, _), let .enumeration(type, _, _): .local(type)
        case let .object(object): .local(object.typeKey)
        case .error: .error
        case let .address(address): .address(address.pointee)
        case let .mutableCell(cell): .mutableCell(cell.pointee)
        case let .nonOwningReference(reference):
            .nonOwningReference(kind: reference.kind, pointee: reference.pointee)
        case let .arrayBuilder(builder):
            .arrayState(kind: .builder, element: builder.elementType)
        case let .arrayMutationState(state):
            .arrayState(kind: .mutation, element: state.elementType)
        case let .dictionaryBuilder(builder):
            .dictionaryState(key: builder.keyType, value: builder.valueType)
        case let .arraySortState(state):
            .arrayState(kind: .stableSort, element: state.elementType)
        case let .arraySplitState(state):
            .arrayState(kind: .split, element: state.elementType)
        case let .closure(closure): .closure(closure.signature)
        }
    }

    public var description: String {
        switch self {
        case let .bool(value): String(value)
        case let .integer(value): value.description
        case let .float(value): value.description
        case let .string(value): String(reflecting: value)
        case let .any(value): value.payload.description
        case let .array(storage):
            "[\(storage.elements.map(\.description).joined(separator: ", "))]"
        case let .dictionary(entries, _, _):
            "[\(entries.map { "\($0.key.description): \($0.value.description)" }.joined(separator: ", "))]"
        case let .set(value): value.description
        case let .native(value): value.description
        case let .tuple(values): "(\(values.map(\.description).joined(separator: ", ")))"
        case let .optional(value): value.map { "Optional(\($0))" } ?? "nil"
        case let .structure(type, fields):
            "\(type)(\(fields.map(\.description).joined(separator: ", ")))"
        case let .enumeration(type, caseIndex, payload):
            "\(type).#\(caseIndex)" + (payload.map { "(\($0))" } ?? "")
        case let .object(object): object.description
        case let .error(error): error.description
        case let .address(address): address.description
        case let .mutableCell(cell): cell.description
        case let .nonOwningReference(reference): reference.description
        case let .arrayBuilder(builder): builder.description
        case let .arrayMutationState(state): state.description
        case let .dictionaryBuilder(builder): builder.description
        case let .arraySortState(state): state.description
        case let .arraySplitState(state): state.description
        case let .closure(closure): closure.description
        }
    }

    /// Constructs zero-based Array storage by default. Derived collection
    /// views opt into a preserved logical base explicitly.
    public static func array(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        indexBase: Int64 = 0
    ) -> Self {
        .array(
            .init(
                elements: elements,
                elementType: elementType,
                indexBase: indexBase
            )
        )
    }
}

public struct Closure: Hashable, Sendable, CustomStringConvertible {
    package enum Target: Hashable, Sendable {
        case image(Bytecode.FunctionID)
        case entry(Core.EntryIndex)
        case native(VM.NativeClosure)
    }

    package var target: Target
    public var signature: Bytecode.ClosureSignature
    public var captures: [VM.Value]
    var dynamicScope: VM.ClosureScope?

    public init(
        functionID: Bytecode.FunctionID,
        signature: Bytecode.ClosureSignature,
        captures: [VM.Value]
    ) {
        target = .image(functionID)
        self.signature = signature
        self.captures = captures
        dynamicScope = nil
    }

    init(
        target: Target,
        signature: Bytecode.ClosureSignature,
        captures: [VM.Value],
        dynamicScope: VM.ClosureScope?
    ) {
        self.target = target
        self.signature = signature
        self.captures = captures
        self.dynamicScope = dynamicScope
    }

    package init(nativeClosure: VM.NativeClosure) {
        target = .native(nativeClosure)
        signature = nativeClosure.signature
        captures = []
        dynamicScope = nil
    }

    package var isNativeCallbackTarget: Bool {
        switch target {
        case .image, .entry: true
        case .native: false
        }
    }

    package var nativeTarget: VM.NativeClosure? {
        guard case let .native(closure) = target else { return nil }
        return closure
    }

    public var description: String {
        let identity = switch target {
        case let .image(functionID): "@\(functionID)"
        case let .entry(entry): "#\(entry)"
        case .native: "native"
        }
        return "Closure<\(identity), \(signature), captures: \(captures.count)>"
    }
}

public struct ErrorValue: Hashable, Sendable, CustomStringConvertible {
    public var concreteType: Bytecode.LocalTypeKey?
    public var payload: VM.Value?
    public var message: String

    public init(message: String) {
        concreteType = nil
        payload = nil
        self.message = message
    }

    public init(
        concreteType: Bytecode.LocalTypeKey,
        payload: VM.Value,
        message: String
    ) {
        self.concreteType = concreteType
        self.payload = payload
        self.message = message
    }

    init(
        concreteType: Bytecode.LocalTypeKey?,
        payload: VM.Value?,
        message: String
    ) {
        self.concreteType = concreteType
        self.payload = payload
        self.message = message
    }

    public var description: String {
        concreteType.map { "Error<\($0)>(\(message))" } ?? "Error(\(message))"
    }
}

public struct DictionaryEntry: Hashable, Sendable {
    public var key: VM.Value
    public var value: VM.Value

    public init(key: VM.Value, value: VM.Value) {
        self.key = key
        self.value = value
    }
}
}

extension VM.Value {
    /// Checks the type carried by an already validated runtime value.
    ///
    /// A payload-free Optional has no value from which to recover its wrapped
    /// type, so `type` necessarily spells it as `Optional<Never>`. Internal VM
    /// states instead supply that missing type from their verified bytecode
    /// context. Tuples and nested Optionals are the only aggregate shapes that
    /// need recursive recovery; collection values already carry explicit
    /// element metadata.
    func hasRuntimeType(_ expected: Bytecode.ValueType) -> Bool {
        hasRuntimeType(expected, depth: 0)
    }

    private func hasRuntimeType(
        _ expected: Bytecode.ValueType,
        depth: Int
    ) -> Bool {
        guard depth <= VM.ValueLimits.maximumNestingDepth else { return false }
        return switch (self, expected) {
        case (.optional(nil), .optional):
            true
        case let (.optional(.some(value)), .optional(wrapped)):
            value.hasRuntimeType(wrapped, depth: depth + 1)
        case let (.tuple(values), .tuple(types)):
            values.count == types.count
                && zip(values, types).allSatisfy {
                    $0.hasRuntimeType($1, depth: depth + 1)
                }
        default:
            type == expected
        }
    }

    public func matches(_ expected: Bytecode.ValueType) -> Bool {
        matches(expected, depth: 0)
    }

    private func matches(_ expected: Bytecode.ValueType, depth: Int) -> Bool {
        guard depth <= VM.ValueLimits.maximumNestingDepth else { return false }
        return switch (self, expected) {
        case (.bool, .bool), (.string, .string): true
        case let (.any(value), .any):
            value.dynamicType.isAnyPayloadV1
                && value.payload.matchesDynamicType(
                    value.dynamicType,
                    depth: depth + 1
                )
        case let (.array(storage), .array(expectedElement)):
            storage.elementType == expectedElement
                && storage.elements.allSatisfy {
                    $0.matches(expectedElement, depth: depth + 1)
                }
        case let (
            .dictionary(entries, actualKey, actualValue),
            .dictionary(expectedKey, expectedValue)
        ):
            actualKey == expectedKey
                && actualValue == expectedValue
                && entries.allSatisfy {
                    $0.key.matches(expectedKey, depth: depth + 1)
                        && $0.value.matches(expectedValue, depth: depth + 1)
                }
        case let (.set(value), .set(expectedElement)):
            expectedElement.isVMHashable
                && value.elementType == expectedElement
                && value.elements.allSatisfy {
                    $0.matches(expectedElement, depth: depth + 1)
                }
        case let (.native(value), .native(typeID)):
            value.typeID == typeID
        case let (.structure(actual, _), .local(expected)),
             let (.enumeration(actual, _, _), .local(expected)):
            actual == expected
        case let (.object(object), .local(expected)):
            object.typeKey == expected
        case (.error, .error):
            true
        case let (.address(address), .address(pointee)):
            address.pointee == pointee && address.isScoped
        case let (.mutableCell(cell), .mutableCell(pointee)):
            cell.pointee == pointee
        case let (
            .nonOwningReference(reference),
            .nonOwningReference(kind, pointee)
        ):
            reference.kind == kind && reference.pointee == pointee
        case let (.arrayBuilder(builder), .arrayState(kind: .builder, element)):
            builder.elementType == element
        case let (
            .arrayMutationState(state),
            .arrayState(kind: .mutation, element)
        ):
            state.elementType == element
        case let (
            .dictionaryBuilder(builder),
            .dictionaryState(key, value)
        ):
            builder.keyType == key && builder.valueType == value
        case let (.arraySortState(state), .arrayState(kind: .stableSort, element)):
            state.elementType == element
        case let (.arraySplitState(state), .arrayState(kind: .split, element)):
            state.elementType == element
        case let (.closure(closure), .closure(signature)):
            closure.signature == signature
        case let (.integer(value), .integer(width, signed)):
            value.bitWidth == width && value.isSigned == signed
        case let (.float(value), .float(expected)):
            value.bitWidth == expected
        case let (.tuple(values), .tuple(types)):
            values.count == types.count
                && zip(values, types).allSatisfy {
                    $0.matches($1, depth: depth + 1)
                }
        case (.optional(nil), .optional):
            true
        case let (.optional(.some(value)), .optional(wrapped)):
            value.matches(wrapped, depth: depth + 1)
        default:
            false
        }
    }

    /// Constructs an exact binary32 VM scalar without exposing an invalid
    /// width parameter or routing the payload through binary64 storage.
    public static func float32(_ value: Float) -> Self {
        .float(VM.FloatingValue(value))
    }

    /// Constructs an exact binary64 VM scalar.
    public static func float64(_ value: Double) -> Self {
        .float(VM.FloatingValue(value))
    }
}
