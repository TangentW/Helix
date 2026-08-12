import Foundation
import HelixCore

extension VM {
public enum NativeTypeKind: String, Hashable, Sendable {
    case value
    case reference
    case enumeration
}

private final class OpaqueNativeIdentity: @unchecked Sendable {}

private final class OpaqueNativeStorage<Value>: @unchecked Sendable {
    let value: Value
    let identity: OpaqueNativeIdentity

    init(value: Value, identity: OpaqueNativeIdentity = .init()) {
        self.value = value
        self.identity = identity
    }
}

/// Implemented by App code for a native type explicitly frozen into the Shell.
/// The factory must return operations whose descriptor exactly matches its inputs.
public protocol NativeTypeFactory {
    static func make(
        id: Core.TypeID,
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool
    ) -> VM.NativeTypeOperations
}

public final class NativeValue: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let typeID: Core.TypeID
    public let canonicalTypeName: String
    public let layoutFingerprint: Core.Digest
    public let estimatedByteCount: UInt64

    fileprivate let storage: Any
    private let equalsStorage: @Sendable (Any, Any) -> Bool
    private let hashStorage: @Sendable (Any, inout Hasher) -> Void
    private let describeStorage: @Sendable (Any) -> String

    fileprivate init(
        typeID: Core.TypeID,
        canonicalTypeName: String,
        layoutFingerprint: Core.Digest,
        estimatedByteCount: UInt64,
        storage: Any,
        equals: @escaping @Sendable (Any, Any) -> Bool,
        hash: @escaping @Sendable (Any, inout Hasher) -> Void,
        describe: @escaping @Sendable (Any) -> String
    ) {
        self.typeID = typeID
        self.canonicalTypeName = canonicalTypeName
        self.layoutFingerprint = layoutFingerprint
        self.estimatedByteCount = estimatedByteCount
        self.storage = storage
        equalsStorage = equals
        hashStorage = hash
        describeStorage = describe
    }

    public func value<Value>(as type: Value.Type = Value.self) -> Value? {
        if let value = storage as? Value { return value }
        return (storage as? OpaqueNativeStorage<Value>)?.value
    }

    public static func == (lhs: VM.NativeValue, rhs: VM.NativeValue) -> Bool {
        lhs.typeID == rhs.typeID
            && lhs.layoutFingerprint == rhs.layoutFingerprint
            && lhs.canonicalTypeName == rhs.canonicalTypeName
            && lhs.equalsStorage(lhs.storage, rhs.storage)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(typeID)
        hasher.combine(layoutFingerprint)
        hasher.combine(canonicalTypeName)
        hashStorage(storage, &hasher)
    }

    public var description: String {
        "\(canonicalTypeName)(\(describeStorage(storage)))"
    }
}

public struct NativeTypeOperations: Sendable {
    public let id: Core.TypeID
    public let canonicalName: String
    public let kind: VM.NativeTypeKind
    public let layoutFingerprint: Core.Digest
    public let isCopyable: Bool
    public let requiresMainActor: Bool
    public let estimatedSize: UInt64

    private let boxStorage: @Sendable (Any) throws -> VM.NativeValue
    private let copyStorage: @Sendable (VM.NativeValue) throws -> VM.NativeValue

    public init<Value>(
        id: Core.TypeID,
        canonicalName: String,
        kind: VM.NativeTypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool = true,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64,
        clone: @escaping @Sendable (Value) -> Value = { $0 },
        estimatedByteCount: @escaping @Sendable (Value) -> UInt64 = { _ in
            UInt64(MemoryLayout<Value>.stride)
        },
        equals: @escaping @Sendable (Value, Value) -> Bool,
        hash: @escaping @Sendable (Value, inout Hasher) -> Void,
        describe: @escaping @Sendable (Value) -> String = { String(describing: $0) }
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
        self.isCopyable = isCopyable
        self.requiresMainActor = requiresMainActor
        self.estimatedSize = estimatedSize

        @Sendable func makeBox(_ value: Value) -> VM.NativeValue {
            VM.NativeValue(
                typeID: id,
                canonicalTypeName: canonicalName,
                layoutFingerprint: layoutFingerprint,
                estimatedByteCount: max(estimatedSize, estimatedByteCount(value)),
                storage: value,
                equals: { lhs, rhs in
                    guard let left = lhs as? Value, let right = rhs as? Value else { return false }
                    return equals(left, right)
                },
                hash: { storage, hasher in
                    guard let value = storage as? Value else { return }
                    hash(value, &hasher)
                },
                describe: { storage in
                    guard let value = storage as? Value else { return "<type mismatch>" }
                    return describe(value)
                }
            )
        }
        boxStorage = { storage in
            guard let value = storage as? Value else {
                throw VM.RuntimeTrap.nativeTypeMismatch(expected: id)
            }
            return makeBox(value)
        }
        copyStorage = { native in
            guard isCopyable else { throw VM.RuntimeTrap.nativeValueIsNotCopyable(id) }
            guard native.typeID == id,
                  native.layoutFingerprint == layoutFingerprint,
                  native.canonicalTypeName == canonicalName,
                  let value = native.storage as? Value
            else {
                throw VM.RuntimeTrap.nativeTypeMismatch(expected: id)
            }
            return makeBox(clone(value))
        }
    }

    public init<Value: Hashable & Sendable>(
        id: Core.TypeID,
        canonicalName: String,
        kind: VM.NativeTypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool = true,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64,
        clone: @escaping @Sendable (Value) -> Value = { $0 },
        estimatedByteCount: @escaping @Sendable (Value) -> UInt64 = { _ in
            UInt64(MemoryLayout<Value>.stride)
        },
        describe: @escaping @Sendable (Value) -> String = { String(describing: $0) }
    ) {
        self.init(
            id: id,
            canonicalName: canonicalName,
            kind: kind,
            layoutFingerprint: layoutFingerprint,
            isCopyable: isCopyable,
            requiresMainActor: requiresMainActor,
            estimatedSize: estimatedSize,
            clone: clone,
            estimatedByteCount: estimatedByteCount,
            equals: { $0 == $1 },
            hash: { value, hasher in hasher.combine(value) },
            describe: describe
        )
    }

    public static func reference<Value: AnyObject>(
        id: Core.TypeID,
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64 = UInt64(MemoryLayout<Value>.stride),
        estimatedByteCount: @escaping @Sendable (Value) -> UInt64 = { _ in
            UInt64(MemoryLayout<Value>.stride)
        },
        describe: @escaping @Sendable (Value) -> String = { String(describing: $0) }
    ) -> Self {
        Self(
            id: id,
            canonicalName: canonicalName,
            kind: .reference,
            layoutFingerprint: layoutFingerprint,
            requiresMainActor: requiresMainActor,
            estimatedSize: estimatedSize,
            estimatedByteCount: estimatedByteCount,
            equals: { $0 === $1 },
            hash: { value, hasher in hasher.combine(ObjectIdentifier(value)) },
            describe: describe
        )
    }

    /// Creates TypeOps for a copyable Swift value whose layout and equality
    /// semantics are intentionally opaque to HLBC. Copies preserve a stable
    /// box identity, while a value returned from a mutating native adapter is
    /// boxed as a new identity. The VM never reflects or serializes its fields.
    public static func opaqueValue<Value>(
        id: Core.TypeID,
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64 = UInt64(MemoryLayout<Value>.stride),
        clone: @escaping @Sendable (Value) -> Value = { $0 },
        estimatedByteCount: @escaping @Sendable (Value) -> UInt64 = { _ in
            UInt64(MemoryLayout<Value>.stride)
        },
        describe: @escaping @Sendable (Value) -> String = { String(describing: $0) }
    ) -> Self {
        typealias Storage = OpaqueNativeStorage<Value>
        return Self(
            id: id,
            canonicalName: canonicalName,
            kind: .value,
            layoutFingerprint: layoutFingerprint,
            requiresMainActor: requiresMainActor,
            estimatedSize: estimatedSize,
            clone: { storage in
                Storage(value: clone(storage.value), identity: storage.identity)
            },
            estimatedByteCount: { estimatedByteCount($0.value) },
            equals: { $0.identity === $1.identity },
            hash: { storage, hasher in
                hasher.combine(ObjectIdentifier(storage.identity))
            },
            describe: { describe($0.value) }
        ).acceptingOpaqueValues(as: Value.self)
    }

    private func acceptingOpaqueValues<Value>(as type: Value.Type) -> Self {
        let operations = self
        return Self(
            id: id,
            canonicalName: canonicalName,
            kind: kind,
            layoutFingerprint: layoutFingerprint,
            isCopyable: isCopyable,
            requiresMainActor: requiresMainActor,
            estimatedSize: estimatedSize,
            boxStorage: { storage in
                guard let value = storage as? Value else {
                    throw VM.RuntimeTrap.nativeTypeMismatch(expected: operations.id)
                }
                return try operations.boxStorage(OpaqueNativeStorage(value: value))
            },
            copyStorage: operations.copyStorage
        )
    }

    private init(
        id: Core.TypeID,
        canonicalName: String,
        kind: VM.NativeTypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool,
        requiresMainActor: Bool,
        estimatedSize: UInt64,
        boxStorage: @escaping @Sendable (Any) throws -> VM.NativeValue,
        copyStorage: @escaping @Sendable (VM.NativeValue) throws -> VM.NativeValue
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
        self.isCopyable = isCopyable
        self.requiresMainActor = requiresMainActor
        self.estimatedSize = estimatedSize
        self.boxStorage = boxStorage
        self.copyStorage = copyStorage
    }

    public func box<Value>(_ value: Value) throws -> VM.NativeValue {
        guard !requiresMainActor || Thread.isMainThread else {
            throw VM.RuntimeTrap.mainActorViolation
        }
        return try boxStorage(value)
    }

    public func copy(_ value: VM.NativeValue) throws -> VM.NativeValue {
        guard !requiresMainActor || Thread.isMainThread else {
            throw VM.RuntimeTrap.mainActorViolation
        }
        return try copyStorage(value)
    }
}

public struct NativeTypeCatalog: Sendable {
    private let operations: [Core.TypeID: VM.NativeTypeOperations]

    public init() {
        operations = [:]
    }

    public init(_ operations: [VM.NativeTypeOperations]) throws {
        var table: [Core.TypeID: VM.NativeTypeOperations] = [:]
        for item in operations {
            guard table.updateValue(item, forKey: item.id) == nil else {
                throw VM.RuntimeTrap.nativeFailure("duplicate native type \(item.id)")
            }
        }
        self.operations = table
    }

    public subscript(id: Core.TypeID) -> VM.NativeTypeOperations? {
        operations[id]
    }

    public func box<Value>(
        _ value: Value,
        as id: Core.TypeID
    ) throws -> VM.NativeValue {
        guard let operations = operations[id] else {
            throw VM.RuntimeTrap.unknownNativeType(id)
        }
        return try operations.box(value)
    }

    func copy(_ value: VM.NativeValue) throws -> VM.NativeValue {
        guard let operations = operations[value.typeID] else {
            throw VM.RuntimeTrap.unknownNativeType(value.typeID)
        }
        return try operations.copy(value)
    }
}
}
