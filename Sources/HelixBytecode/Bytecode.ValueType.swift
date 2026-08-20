extension Bytecode.ValueType {
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
                 .mutableCell, .arrayBuilder, .arraySortState, .closure, .tuple:
                return false
            }
        }
        return true
    }
}
