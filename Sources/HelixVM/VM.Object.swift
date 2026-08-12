import Foundation
import HelixBytecode

extension VM {
/// Shared mutable storage behind one patch-local class identity.
///
/// Fields use independent cells so Swift exclusivity is enforced per stored
/// property while copies of the object preserve reference identity.
public final class ObjectStorage: @unchecked Sendable, Hashable {
    private let fields: [VM.MemoryCell]

    init(fieldCount: Int) {
        fields = (0..<fieldCount).map { _ in VM.MemoryCell() }
    }

    public static func == (lhs: VM.ObjectStorage, rhs: VM.ObjectStorage) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    var fieldCount: Int { fields.count }

    func address(
        field index: UInt32,
        pointee: Bytecode.ValueType
    ) throws -> VM.Address {
        guard let index = Int(exactly: index), fields.indices.contains(index) else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        return VM.Address(cell: fields[index], pointee: pointee)
    }
}

/// Identity-preserving HLVM representation of a patch-local class instance.
/// A native host is attached only for a verified Objective-C-compatible class.
public final class ObjectReference: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let typeKey: Bytecode.LocalTypeKey
    public let storage: VM.ObjectStorage

    private let lock = NSLock()
    private var nativeHostStorage: VM.NativeValue?

    init(
        typeKey: Bytecode.LocalTypeKey,
        fieldCount: Int,
        nativeHost: VM.NativeValue? = nil
    ) {
        self.typeKey = typeKey
        storage = VM.ObjectStorage(fieldCount: fieldCount)
        nativeHostStorage = nativeHost
    }

    public init(
        typeKey: Bytecode.LocalTypeKey,
        storage: VM.ObjectStorage,
        nativeHost: VM.NativeValue
    ) {
        self.typeKey = typeKey
        self.storage = storage
        nativeHostStorage = nativeHost
    }

    public static func == (lhs: VM.ObjectReference, rhs: VM.ObjectReference) -> Bool {
        lhs.storage === rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(storage))
    }

    var nativeHost: VM.NativeValue? {
        lock.withLock { nativeHostStorage }
    }

    func attach(nativeHost: VM.NativeValue) throws {
        try lock.withLock {
            guard nativeHostStorage == nil else {
                throw VM.RuntimeTrap.explicit("a local object already has a native host")
            }
            nativeHostStorage = nativeHost
        }
    }

    func address(
        field index: UInt32,
        pointee: Bytecode.ValueType
    ) throws -> VM.Address {
        try storage.address(field: index, pointee: pointee)
    }

    public var description: String {
        "\(typeKey)<object:\(ObjectIdentifier(storage))>"
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
