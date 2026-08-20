extension CanonicalSIL {
/// Predicate-driven mutations whose observable control flow depends on the
/// concrete standard-library algorithm. They share Array storage, closure,
/// ownership, and continuation machinery without adding API-specific HLBC.
enum ArrayPredicateMutationIntrinsic: Equatable {
    /// Bidirectional in-place partition used by Array's constrained overload.
    case partition
    /// Half-stable partition followed by suffix removal.
    case removeAllWhere
}
}
