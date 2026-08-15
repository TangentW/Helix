import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Heap-promoted mutable storage captured by a closure. Unlike `VM.Address`,
/// this reference carries no frame-scoped access token and therefore remains
/// valid when the closure outlives its creating frame.
public struct MutableCell: Hashable, @unchecked Sendable,
    CustomStringConvertible {
    let storage: VM.MemoryCell
    let path: [UInt32]
    let pointee: Bytecode.ValueType

    init(
        initialValue: VM.Value?,
        pointee: Bytecode.ValueType,
        shape: VM.StorageShape
    ) {
        storage = .init(initialValue, storageShape: shape)
        path = []
        self.pointee = pointee
    }

    private init(
        storage: VM.MemoryCell,
        path: [UInt32],
        pointee: Bytecode.ValueType
    ) {
        self.storage = storage
        self.path = path
        self.pointee = pointee
    }

    func projected(field: UInt32, pointee: Bytecode.ValueType) -> Self {
        .init(
            storage: storage,
            path: path + [field],
            pointee: pointee
        )
    }

    func read() throws -> VM.Value {
        try storage.unscopedRead(path: path)
    }

    func store(_ value: VM.Value, mode: Bytecode.StackStoreMode) throws {
        try storage.unscopedStore(value, path: path, mode: mode)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage
            && lhs.path == rhs.path
            && lhs.pointee == rhs.pointee
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(storage))
        hasher.combine(path)
        hasher.combine(pointee)
    }

    public var description: String {
        "MutableCell<\(pointee)>"
    }
}
}
