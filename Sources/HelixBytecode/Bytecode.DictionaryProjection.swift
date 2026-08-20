extension Bytecode {
/// Selects the element sequence materialized from a Dictionary. Dictionary
/// iteration order remains deterministic within one VM value, but is not an
/// equality or wire-identity guarantee.
public enum DictionaryProjection: String, Codable, Hashable, Sendable,
    CustomStringConvertible {
    case keys
    case values

    public var description: String { rawValue }
}
}
