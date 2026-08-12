import Foundation
import HelixBytecode

extension VM {
/// A frame-owned mutable cell. Its initializer is intentionally internal so
/// host code cannot manufacture an address that crosses the VM boundary.
public final class MemoryCell: @unchecked Sendable, Hashable {
    private struct Access {
        var path: [UInt32]
        var kind: Bytecode.AccessKind
    }

    private let lock = NSLock()
    private var storage: VM.Value?
    private var accesses: [UUID: Access] = [:]

    init(_ value: VM.Value? = nil) {
        storage = value
    }

    public static func == (lhs: VM.MemoryCell, rhs: VM.MemoryCell) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func directRead() throws -> VM.Value {
        try lock.withLock {
            guard accesses.isEmpty else { throw VM.RuntimeTrap.exclusivityViolation }
            guard let storage else { throw VM.RuntimeTrap.uninitializedAddress }
            return storage
        }
    }

    func directTake() throws -> VM.Value {
        try lock.withLock {
            guard accesses.isEmpty else { throw VM.RuntimeTrap.exclusivityViolation }
            guard let storage else { throw VM.RuntimeTrap.uninitializedAddress }
            self.storage = nil
            return storage
        }
    }

    func directStore(_ value: VM.Value, mode: Bytecode.StackStoreMode) throws {
        try lock.withLock {
            guard accesses.isEmpty else { throw VM.RuntimeTrap.exclusivityViolation }
            switch mode {
            case .initialize:
                guard storage == nil else { throw VM.RuntimeTrap.addressAlreadyInitialized }
            case .assign:
                guard storage != nil else { throw VM.RuntimeTrap.uninitializedAddress }
            }
            storage = value
        }
    }

    func begin(path: [UInt32], kind: Bytecode.AccessKind) throws -> UUID {
        try lock.withLock {
            for access in accesses.values where Self.overlaps(path, access.path) {
                guard kind == .read, access.kind == .read else {
                    throw VM.RuntimeTrap.exclusivityViolation
                }
            }
            let token = UUID()
            accesses[token] = .init(path: path, kind: kind)
            return token
        }
    }

    func end(token: UUID) throws {
        try lock.withLock {
            guard accesses.removeValue(forKey: token) != nil else {
                throw VM.RuntimeTrap.inactiveAddressAccess
            }
        }
    }

    func read(path: [UInt32], token: UUID) throws -> VM.Value {
        try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: false)
            guard let storage else { throw VM.RuntimeTrap.uninitializedAddress }
            return try Self.project(storage, path: path[...])
        }
    }

    func store(
        _ value: VM.Value,
        path: [UInt32],
        token: UUID,
        mode: Bytecode.StackStoreMode
    ) throws {
        try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: true)
            if path.isEmpty {
                switch mode {
                case .initialize:
                    guard storage == nil else {
                        throw VM.RuntimeTrap.addressAlreadyInitialized
                    }
                case .assign:
                    guard storage != nil else {
                        throw VM.RuntimeTrap.uninitializedAddress
                    }
                }
                storage = value
                return
            }
            guard mode == .assign, var storage else {
                throw VM.RuntimeTrap.uninitializedAddress
            }
            try Self.assign(value, into: &storage, path: path[...])
            self.storage = storage
        }
    }

    func isActive(path: [UInt32], token: UUID, requiresModify: Bool) -> Bool {
        lock.withLock {
            (try? activeAccess(
                token: token,
                path: path,
                requiresModify: requiresModify
            )) != nil
        }
    }

    private func activeAccess(
        token: UUID,
        path: [UInt32],
        requiresModify: Bool
    ) throws -> Access {
        guard let access = accesses[token], Self.contains(access.path, path) else {
            throw VM.RuntimeTrap.inactiveAddressAccess
        }
        guard !requiresModify || access.kind == .modify else {
            throw VM.RuntimeTrap.addressWriteRequiresModifyAccess
        }
        return access
    }

    private static func contains(_ parent: [UInt32], _ child: [UInt32]) -> Bool {
        guard parent.count <= child.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    private static func overlaps(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
        let shared = min(lhs.count, rhs.count)
        return Array(lhs.prefix(shared)) == Array(rhs.prefix(shared))
    }

    private static func project(
        _ value: VM.Value,
        path: ArraySlice<UInt32>
    ) throws -> VM.Value {
        guard let field = path.first else { return value }
        guard case let .structure(_, fields) = value,
              let index = Int(exactly: field),
              fields.indices.contains(index)
        else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        return try project(fields[index], path: path.dropFirst())
    }

    private static func assign(
        _ value: VM.Value,
        into destination: inout VM.Value,
        path: ArraySlice<UInt32>
    ) throws {
        guard let field = path.first else {
            destination = value
            return
        }
        guard case let .structure(type, oldFields) = destination,
              let index = Int(exactly: field),
              oldFields.indices.contains(index)
        else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        var fields = oldFields
        try assign(value, into: &fields[index], path: path.dropFirst())
        destination = .structure(type: type, fields: fields)
    }
}

/// An address is an internal VM capability: a cell identity, a projection, and
/// optionally an active access token. Public construction is deliberately absent.
public struct Address: Hashable, @unchecked Sendable, CustomStringConvertible {
    let cell: VM.MemoryCell
    let path: [UInt32]
    let token: UUID?
    let pointee: Bytecode.ValueType

    init(
        cell: VM.MemoryCell,
        path: [UInt32] = [],
        token: UUID? = nil,
        pointee: Bytecode.ValueType
    ) {
        self.cell = cell
        self.path = path
        self.token = token
        self.pointee = pointee
    }

    var isScoped: Bool {
        guard let token else { return false }
        return cell.isActive(path: path, token: token, requiresModify: false)
    }

    var canModify: Bool {
        guard let token else { return false }
        return cell.isActive(path: path, token: token, requiresModify: true)
    }

    func projected(field: UInt32, pointee: Bytecode.ValueType) -> Self {
        .init(cell: cell, path: path + [field], token: token, pointee: pointee)
    }

    func begin(_ kind: Bytecode.AccessKind) throws -> Self {
        guard token == nil else { throw VM.RuntimeTrap.exclusivityViolation }
        return .init(
            cell: cell,
            path: path,
            token: try cell.begin(path: path, kind: kind),
            pointee: pointee
        )
    }

    func end() throws {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        try cell.end(token: token)
    }

    func read() throws -> VM.Value {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        return try cell.read(path: path, token: token)
    }

    func store(_ value: VM.Value, mode: Bytecode.StackStoreMode) throws {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        try cell.store(value, path: path, token: token, mode: mode)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cell === rhs.cell
            && lhs.path == rhs.path
            && lhs.token == rhs.token
            && lhs.pointee == rhs.pointee
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(cell))
        hasher.combine(path)
        hasher.combine(token)
        hasher.combine(pointee)
    }

    public var description: String {
        "<address depth=\(path.count) scoped=\(token != nil)>"
    }
}
}
