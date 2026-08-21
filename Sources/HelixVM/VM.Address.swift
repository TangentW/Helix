import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Shape-aware mutable storage shared by frame-owned addresses and
/// heap-promoted closure cells. Construction remains internal so host code
/// cannot manufacture a VM storage capability.
public final class MemoryCell: @unchecked Sendable, Hashable {
    private struct Access {
        var path: [UInt32]
        var kind: Bytecode.AccessKind
    }

    private let lock = NSLock()
    private var storage: VM.Value?
    private let storageShape: VM.StorageShape?
    private var partialStorage: [[UInt32]: VM.Value] = [:]
    private var accesses: [UUID: Access] = [:]

    init(
        _ value: VM.Value? = nil,
        storageShape: VM.StorageShape? = nil
    ) {
        storage = value
        self.storageShape = storageShape
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
            return try storedValue(at: [])
        }
    }

    func directTake() throws -> VM.Value {
        try lock.withLock {
            guard accesses.isEmpty else { throw VM.RuntimeTrap.exclusivityViolation }
            let value = try storedValue(at: [])
            self.storage = nil
            partialStorage.removeAll(keepingCapacity: true)
            return value
        }
    }

    func directStore(_ value: VM.Value, mode: Bytecode.StackStoreMode) throws {
        try lock.withLock {
            guard accesses.isEmpty else { throw VM.RuntimeTrap.exclusivityViolation }
            try storeValue(value, at: [], mode: mode)
        }
    }

    func directDestroyIfInitialized() throws {
        let retained = try lock.withLock {
            guard accesses.isEmpty
                    || (accesses.count == 1
                        && accesses.values.first?.kind == .modify
                        && accesses.values.first?.path.isEmpty == true)
            else {
                throw VM.RuntimeTrap.exclusivityViolation
            }
            let retained = (storage, partialStorage)
            storage = nil
            partialStorage.removeAll(keepingCapacity: true)
            return retained
        }
        withExtendedLifetime(retained) {}
    }

    /// Security inspection used when ending a dynamically scoped closure.
    /// Raw initialized fragments are sufficient: every reachable value is
    /// present either in whole storage or in one partial leaf.
    func initializedValuesForInspection() -> [VM.Value] {
        lock.withLock {
            var values = Array(partialStorage.values)
            if let storage { values.append(storage) }
            return values
        }
    }

    func unscopedRead(path: [UInt32]) throws -> VM.Value {
        try lock.withLock {
            guard accesses.isEmpty else {
                throw VM.RuntimeTrap.exclusivityViolation
            }
            return try storedValue(at: path)
        }
    }

    func unscopedStore(
        _ value: VM.Value,
        path: [UInt32],
        mode: Bytecode.StackStoreMode
    ) throws {
        try lock.withLock {
            guard accesses.isEmpty else {
                throw VM.RuntimeTrap.exclusivityViolation
            }
            try storeValue(value, at: path, mode: mode)
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
            return try storedValue(at: path)
        }
    }

    func take(path: [UInt32], token: UUID) throws -> VM.Value {
        try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: true)
            let value = try storedValue(at: path)
            try removeStoredValue(at: path)
            return value
        }
    }

    /// Returns a deterministic upper bound for projected aggregate
    /// decomposition. The interpreter charges it before mutation so an
    /// exhausted budget cannot leave storage partially changed.
    func projectedRemovalWork(path: [UInt32], token: UUID) throws -> Int {
        try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: true)
            guard !path.isEmpty else { return 0 }
            guard let storageShape else {
                throw VM.RuntimeTrap.invalidAddressProjection
            }
            _ = try Self.storageShape(at: path[...], in: storageShape)
            guard let nodeCount = storageShape.nodeCount else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            return nodeCount
        }
    }

    func destroy(
        path: [UInt32],
        token: UUID,
        ifInitialized: Bool
    ) throws {
        let retained = try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: true)
            if !ifInitialized {
                _ = try storedValue(at: path)
            }
            // Keep removed native owners alive until after the cell lock is
            // released; an arbitrary host object's deinit must not reenter a
            // locked storage cell.
            let retained = (storage, partialStorage)
            // Conditional aggregate cleanup removes every initialized leaf in
            // the projection while preserving independently owned siblings.
            try removeStoredValue(at: path)
            return retained
        }
        withExtendedLifetime(retained) {}
    }

    func store(
        _ value: VM.Value,
        path: [UInt32],
        token: UUID,
        mode: Bytecode.StackStoreMode
    ) throws {
        try lock.withLock {
            _ = try activeAccess(token: token, path: path, requiresModify: true)
            try storeValue(value, at: path, mode: mode)
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

    /// Called only while `lock` is held.
    private func storedValue(at path: [UInt32]) throws -> VM.Value {
        if let storage {
            return try Self.project(storage, path: path[...])
        }
        guard let storageShape else {
            throw VM.RuntimeTrap.uninitializedAddress
        }
        if let ancestor = Self.closestStoredAncestor(
            of: path,
            values: partialStorage
        ), let value = partialStorage[ancestor] {
            return try Self.project(
                value,
                path: path.dropFirst(ancestor.count)
            )
        }
        return try Self.materializeValue(
            shape: try Self.storageShape(
                at: path[...],
                in: storageShape
            ),
            path: path,
            values: partialStorage
        )
    }

    /// Called only while `lock` is held.
    private func storeValue(
        _ value: VM.Value,
        at path: [UInt32],
        mode: Bytecode.StackStoreMode
    ) throws {
        if var storage {
            guard mode != .initialize else {
                throw VM.RuntimeTrap.addressAlreadyInitialized
            }
            try Self.assign(value, into: &storage, path: path[...])
            self.storage = storage
            return
        }
        guard let storageShape else {
            guard path.isEmpty, mode != .assign else {
                throw VM.RuntimeTrap.uninitializedAddress
            }
            storage = value
            return
        }
        let shape = try Self.storageShape(
            at: path[...],
            in: storageShape
        )
        switch mode {
        case .initialize:
            guard !Self.hasStoredAncestor(
                of: path,
                values: partialStorage
            ), !Self.hasStoredDescendant(
                of: path,
                values: partialStorage
            ), (try? Self.materializeValue(
                shape: shape,
                path: path,
                values: partialStorage
            )) == nil
            else {
                throw VM.RuntimeTrap.addressAlreadyInitialized
            }
            partialStorage[path] = value
        case .assign:
            if let ancestor = Self.closestStoredAncestor(
                of: path,
                values: partialStorage
            ) {
                guard var ancestorValue = partialStorage[ancestor] else {
                    throw VM.RuntimeTrap.uninitializedAddress
                }
                try Self.assign(
                    value,
                    into: &ancestorValue,
                    path: path.dropFirst(ancestor.count)
                )
                partialStorage[ancestor] = ancestorValue
            } else {
                _ = try Self.materializeValue(
                    shape: shape,
                    path: path,
                    values: partialStorage
                )
                partialStorage = partialStorage.filter {
                    !$0.key.starts(with: path)
                }
                partialStorage[path] = value
            }
        case .replace:
            if let ancestor = Self.closestStoredAncestor(
                of: path,
                values: partialStorage
            ) {
                guard var ancestorValue = partialStorage[ancestor] else {
                    throw VM.RuntimeTrap.uninitializedAddress
                }
                try Self.assign(
                    value,
                    into: &ancestorValue,
                    path: path.dropFirst(ancestor.count)
                )
                partialStorage[ancestor] = ancestorValue
            } else {
                partialStorage = partialStorage.filter {
                    !$0.key.starts(with: path)
                }
                partialStorage[path] = value
            }
        }
        if let completed = try? Self.materializeValue(
            shape: storageShape,
            path: [],
            values: partialStorage
        ) {
            storage = completed
            partialStorage.removeAll(keepingCapacity: false)
        }
    }

    /// Called only while `lock` is held. A projected take decomposes the
    /// nearest initialized aggregate into independently owned sibling fields.
    private func removeStoredValue(at path: [UInt32]) throws {
        if path.isEmpty {
            storage = nil
            partialStorage.removeAll(keepingCapacity: true)
            return
        }
        guard let storageShape else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        _ = try Self.storageShape(at: path[...], in: storageShape)
        if let storage {
            let fragments = try Self.fragments(
                of: storage,
                shape: storageShape,
                at: [],
                removing: path
            )
            self.storage = nil
            partialStorage = fragments
            return
        }
        if let ancestor = Self.closestStoredAncestor(
            of: path,
            values: partialStorage
        ), let value = partialStorage[ancestor] {
            let shape = try Self.storageShape(
                at: ancestor[...],
                in: storageShape
            )
            let fragments = try Self.fragments(
                of: value,
                shape: shape,
                at: ancestor,
                removing: path
            )
            for fragmentPath in fragments.keys where fragmentPath != ancestor {
                guard partialStorage[fragmentPath] == nil else {
                    throw VM.RuntimeTrap.addressAlreadyInitialized
                }
            }
            partialStorage.removeValue(forKey: ancestor)
            for (fragmentPath, fragment) in fragments {
                partialStorage[fragmentPath] = fragment
            }
            return
        }
        partialStorage = partialStorage.filter {
            !Self.contains(path, $0.key)
        }
    }

    private static func fragments(
        of value: VM.Value,
        shape: VM.StorageShape,
        at path: [UInt32],
        removing removedPath: [UInt32]
    ) throws -> [[UInt32]: VM.Value] {
        if path == removedPath { return [:] }
        guard contains(path, removedPath) else { return [path: value] }

        let children: [VM.Value]
        let childShapes: [VM.StorageShape]
        switch (value, shape) {
        case let (.tuple(values), .tuple(shapes))
        where values.count == shapes.count:
            children = values
            childShapes = shapes
        case let (.structure(valueKey, fields), .structure(shapeKey, shapes))
        where valueKey == shapeKey && fields.count == shapes.count:
            children = fields
            childShapes = shapes
        default:
            throw VM.RuntimeTrap.invalidAddressProjection
        }

        var result: [[UInt32]: VM.Value] = [:]
        for index in children.indices {
            guard let field = UInt32(exactly: index) else {
                throw VM.RuntimeTrap.invalidAddressProjection
            }
            let childPath = path + [field]
            let childFragments = try fragments(
                of: children[index],
                shape: childShapes[index],
                at: childPath,
                removing: removedPath
            )
            for (fragmentPath, fragment) in childFragments {
                guard result.updateValue(fragment, forKey: fragmentPath) == nil else {
                    throw VM.RuntimeTrap.addressAlreadyInitialized
                }
            }
        }
        return result
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

    private static func storageShape(
        at path: ArraySlice<UInt32>,
        in shape: VM.StorageShape
    ) throws -> VM.StorageShape {
        guard let field = path.first else { return shape }
        guard let index = Int(exactly: field) else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        let child: VM.StorageShape = switch shape {
        case let .tuple(elements) where elements.indices.contains(index):
            elements[index]
        case let .structure(_, fields) where fields.indices.contains(index):
            fields[index]
        default:
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        return try storageShape(at: path.dropFirst(), in: child)
    }

    private static func materializeValue(
        shape: VM.StorageShape,
        path: [UInt32],
        values: [[UInt32]: VM.Value]
    ) throws -> VM.Value {
        if let value = values[path] { return value }
        switch shape {
        case .leaf:
            throw VM.RuntimeTrap.uninitializedAddress
        case let .tuple(elements):
            return .tuple(
                try elements.enumerated().map { index, child in
                    guard let field = UInt32(exactly: index) else {
                        throw VM.RuntimeTrap.invalidAddressProjection
                    }
                    return try materializeValue(
                        shape: child,
                        path: path + [field],
                        values: values
                    )
                }
            )
        case let .structure(key, fields):
            return .structure(
                type: key,
                fields: try fields.enumerated().map { index, child in
                    guard let field = UInt32(exactly: index) else {
                        throw VM.RuntimeTrap.invalidAddressProjection
                    }
                    return try materializeValue(
                        shape: child,
                        path: path + [field],
                        values: values
                    )
                }
            )
        }
    }

    private static func closestStoredAncestor(
        of path: [UInt32],
        values: [[UInt32]: VM.Value]
    ) -> [UInt32]? {
        for count in stride(from: path.count, through: 0, by: -1) {
            let prefix = Array(path.prefix(count))
            if values[prefix] != nil { return prefix }
        }
        return nil
    }

    private static func hasStoredAncestor(
        of path: [UInt32],
        values: [[UInt32]: VM.Value]
    ) -> Bool {
        closestStoredAncestor(of: path, values: values) != nil
    }

    private static func hasStoredDescendant(
        of path: [UInt32],
        values: [[UInt32]: VM.Value]
    ) -> Bool {
        values.keys.contains {
            $0.count > path.count && $0.starts(with: path)
        }
    }

    private static func project(
        _ value: VM.Value,
        path: ArraySlice<UInt32>
    ) throws -> VM.Value {
        guard let field = path.first else { return value }
        guard let index = Int(exactly: field) else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        let element: VM.Value = switch value {
        case let .structure(_, fields) where fields.indices.contains(index):
            fields[index]
        case let .tuple(elements) where elements.indices.contains(index):
            elements[index]
        default:
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        return try project(element, path: path.dropFirst())
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
        guard let index = Int(exactly: field) else {
            throw VM.RuntimeTrap.invalidAddressProjection
        }
        switch destination {
        case let .structure(type, oldFields)
            where oldFields.indices.contains(index):
            var fields = oldFields
            try assign(value, into: &fields[index], path: path.dropFirst())
            destination = .structure(type: type, fields: fields)
        case let .tuple(oldElements) where oldElements.indices.contains(index):
            var elements = oldElements
            try assign(value, into: &elements[index], path: path.dropFirst())
            destination = .tuple(elements)
        default:
            throw VM.RuntimeTrap.invalidAddressProjection
        }
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

    func take() throws -> VM.Value {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        return try cell.take(path: path, token: token)
    }

    func projectedRemovalWork() throws -> Int {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        return try cell.projectedRemovalWork(path: path, token: token)
    }

    func destroy(ifInitialized: Bool) throws {
        guard let token else { throw VM.RuntimeTrap.inactiveAddressAccess }
        try cell.destroy(
            path: path,
            token: token,
            ifInitialized: ifInitialized
        )
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
