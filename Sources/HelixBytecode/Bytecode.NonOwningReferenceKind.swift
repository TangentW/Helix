extension Bytecode {
/// Ownership policy for a VM-managed reference that deliberately does not
/// retain its referent. Weak loads zero to nil; unowned loads trap after the
/// referent dies instead of relying on process-unsafe Swift `unowned` storage.
public enum NonOwningReferenceKind: String, Codable, Hashable, Sendable {
    case weak
    case unowned
}
}
