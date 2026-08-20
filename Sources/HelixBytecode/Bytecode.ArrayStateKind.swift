extension Bytecode {
/// Identifies an invocation-local Array algorithm state. The kind is part of
/// the verifier type so one linear state machine cannot be consumed by a
/// different algorithm's instructions.
public enum ArrayStateKind: String, Codable, Hashable, Sendable,
    CustomStringConvertible {
    case builder
    case mutation
    case stableSort
    case split

    public var description: String { rawValue }
}
}
