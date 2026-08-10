extension LiveReload {
/// A Native Live Reload compiler marker for explicitly invoking the preceding
/// dynamic-replacement generation.
///
/// Use a single-expression closure, for example
/// `LiveReload.previous { original(argument) }`. The Helix compiler removes
/// the marker and binds the enclosed self reference to Swift's lexical
/// previous implementation. Calling this API without Helix transformation is
/// a programmer error and traps instead of silently selecting another target.
@inline(never)
public static func previous<Result>(
    _ operation: () async throws -> Result
) -> Result {
    _ = operation
    fatalError("LiveReload.previous must be compiled by the Helix Native backend")
}
}
