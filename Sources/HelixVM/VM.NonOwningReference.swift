import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension VM {
/// A safe VM-owned replacement for Swift weak and unowned reference storage.
/// The holder never retains its referent. Unowned loads use the same zeroing
/// primitive internally so a dangling access becomes a controlled VM trap
/// instead of a process-level runtime abort.
public final class NonOwningReference: @unchecked Sendable, Hashable,
    CustomStringConvertible {
    enum Target: Hashable {
        case local(Bytecode.LocalTypeKey)
        case native(Core.TypeID)
    }

    private enum State {
        case uninitialized
        case explicitNil
        case object
    }

    public let kind: Bytecode.NonOwningReferenceKind
    public let pointee: Bytecode.ValueType
    let target: Target

    private let lock = NSLock()
    private var state: State = .uninitialized
    private weak var objectStorage: AnyObject?

    init(
        kind: Bytecode.NonOwningReferenceKind,
        pointee: Bytecode.ValueType,
        target: Target
    ) {
        self.kind = kind
        self.pointee = pointee
        self.target = target
    }

    func store(
        object: AnyObject?,
        mode: Bytecode.StackStoreMode
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        switch mode {
        case .initialize:
            guard case .uninitialized = state else {
                throw VM.RuntimeTrap.addressAlreadyInitialized
            }
        case .assign:
            guard case .uninitialized = state else { break }
            throw VM.RuntimeTrap.uninitializedAddress
        case .replace:
            break
        }
        objectStorage = object
        state = object == nil ? .explicitNil : .object
    }

    /// Returns a temporary strong reference acquired by the Swift weak-load
    /// primitive. Explicit nil remains distinct from a deallocated referent so
    /// Optional unowned storage preserves Swift's checked-load semantics.
    func loadObject(mode: Bytecode.StackLoadMode) throws -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }

        let result: AnyObject?
        switch state {
        case .uninitialized:
            throw VM.RuntimeTrap.uninitializedAddress
        case .explicitNil:
            result = nil
        case .object:
            if let objectStorage {
                result = objectStorage
            } else {
                switch kind {
                case .weak:
                    result = nil
                case .unowned:
                    throw VM.RuntimeTrap.danglingUnownedReference
                }
            }
        }
        if mode == .take {
            objectStorage = nil
            state = .uninitialized
        }
        return result
    }

    public static func == (lhs: VM.NonOwningReference, rhs: VM.NonOwningReference) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        "NonOwningReference<\(kind.rawValue), \(pointee)>"
    }
}
}
