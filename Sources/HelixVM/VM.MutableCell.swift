import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Mutable storage captured through one closure ABI. Owned backing promotes a
/// local into context-owned storage; borrowed backing retains an active address
/// token and is therefore valid only for a lexical nonescaping closure.
public struct MutableCell: Hashable, @unchecked Sendable,
    CustomStringConvertible {
    private enum Backing: Hashable {
        case owned(storage: VM.MemoryCell, path: [UInt32])
        case borrowed(VM.Address)
    }

    private let backing: Backing
    let pointee: Bytecode.ValueType

    init(
        initialValue: VM.Value?,
        pointee: Bytecode.ValueType,
        shape: VM.StorageShape
    ) {
        backing = .owned(
            storage: .init(initialValue, storageShape: shape),
            path: []
        )
        self.pointee = pointee
    }

    private init(
        backing: Backing,
        pointee: Bytecode.ValueType
    ) {
        self.backing = backing
        self.pointee = pointee
    }

    init(borrowing address: VM.Address) throws {
        guard address.isScoped else {
            throw VM.RuntimeTrap.inactiveAddressAccess
        }
        guard address.canModify else {
            throw VM.RuntimeTrap.addressWriteRequiresModifyAccess
        }
        backing = .borrowed(address)
        pointee = address.pointee
    }

    func projected(field: UInt32, pointee: Bytecode.ValueType) -> Self {
        switch backing {
        case let .owned(storage, path):
            .init(
                backing: .owned(
                    storage: storage,
                    path: path + [field]
                ),
                pointee: pointee
            )
        case let .borrowed(address):
            .init(
                backing: .borrowed(
                    address.projected(field: field, pointee: pointee)
                ),
                pointee: pointee
            )
        }
    }

    func read() throws -> VM.Value {
        switch backing {
        case let .owned(storage, path):
            try storage.unscopedRead(path: path)
        case let .borrowed(address):
            try address.read()
        }
    }

    func store(_ value: VM.Value, mode: Bytecode.StackStoreMode) throws {
        switch backing {
        case let .owned(storage, path):
            try storage.unscopedStore(value, path: path, mode: mode)
        case let .borrowed(address):
            try address.store(value, mode: mode)
        }
    }

    var storageForInspection: VM.MemoryCell {
        switch backing {
        case let .owned(storage, _): storage
        case let .borrowed(address): address.cell
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backing == rhs.backing && lhs.pointee == rhs.pointee
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(backing)
        hasher.combine(pointee)
    }

    public var description: String {
        "MutableCell<\(pointee)>"
    }
}
}
