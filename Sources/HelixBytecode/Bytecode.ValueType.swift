import HelixCore

extension Bytecode.ValueType {
    /// Every native TypeID nested anywhere in this logical value shape.
    /// Keeping this traversal beside the schema prevents capability planning,
    /// verification, and build receipts from disagreeing on recursive types.
    public var referencedNativeTypeIDs: Set<Core.TypeID> {
        switch self {
        case let .native(id): [id]
        case let .array(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element),
             let .arrayState(_, element), let .optional(element):
            element.referencedNativeTypeIDs
        case let .dictionary(key, value),
             let .dictionaryState(key, value):
            key.referencedNativeTypeIDs.union(value.referencedNativeTypeIDs)
        case let .closure(signature):
            signature.parameters.reduce(
                signature.result.referencedNativeTypeIDs
            ) { $0.union($1.referencedNativeTypeIDs) }
                .union(
                    signature.thrownType?.referencedNativeTypeIDs ?? []
                )
        case let .tuple(elements):
            elements.reduce(into: Set<Core.TypeID>()) {
                $0.formUnion($1.referencedNativeTypeIDs)
            }
        case .void, .never, .bool, .integer, .float, .string, .any,
             .local, .error:
            []
        }
    }

    /// The element shape exposed by the managed Collection representations.
    /// Dictionary iteration carries one `(key, value)` tuple, matching Swift's
    /// `Dictionary.Element`; compiler-only adapters are represented as Arrays.
    public var managedCollectionElement: Self? {
        switch self {
        case let .array(element), let .set(element):
            element
        case let .dictionary(key, value):
            .tuple([key, value])
        default:
            nil
        }
    }

    /// Types whose Swift `Equatable` semantics are completely defined by the
    /// VM. The recursive family deliberately excludes native and local values:
    /// their equality may execute user or framework code.
    public var isVMEquatable: Bool {
        hasRecursiveValueSemantics
    }

    /// Types whose Swift `Hashable` semantics can be reproduced entirely by
    /// the VM without invoking user code or crossing the native boundary.
    public var isVMHashable: Bool {
        hasRecursiveValueSemantics
    }

    /// Types whose strict ordering is completely defined by the VM. Container
    /// equality is supported recursively, but containers do not acquire a
    /// synthetic ordering that Swift itself does not declare.
    public var isVMComparable: Bool {
        switch self {
        case .integer, .float, .string:
            true
        default:
            false
        }
    }

    private var hasRecursiveValueSemantics: Bool {
        var pending: [(type: Self, depth: Int)] = [(self, 0)]
        while let item = pending.popLast() {
            guard item.depth <= 32 else { return false }
            switch item.type {
            case .bool, .integer, .float, .string:
                continue
            case let .optional(wrapped), let .array(wrapped), let .set(wrapped):
                pending.append((wrapped, item.depth + 1))
            case let .dictionary(key, value):
                pending.append((key, item.depth + 1))
                pending.append((value, item.depth + 1))
            case .void, .never, .any, .native, .local, .error, .address,
                 .mutableCell, .nonOwningReference, .arrayState,
                 .dictionaryState, .closure, .tuple:
                return false
            }
        }
        return true
    }
}
