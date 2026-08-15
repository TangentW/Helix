extension Bytecode.ValueType {
    /// Types whose Swift `Hashable` semantics can be reproduced entirely by
    /// the VM without invoking user code or crossing the native boundary.
    public var isVMHashable: Bool {
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
                 .mutableCell, .arrayBuilder, .closure, .tuple:
                return false
            }
        }
        return true
    }
}
