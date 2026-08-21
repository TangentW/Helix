import HelixBytecode

extension CanonicalSIL {
/// Algebraic values assembled directly from verified control-flow edges.
enum AlgebraicConstruction {
    /// A standard-library constructor whose callback continuations map
    /// directly to the cases of one represented algebraic output.
    struct CatchingPlan: Equatable {
        var closureToken: String
        var resultDestination: String
        var output: CanonicalSIL.AlgebraicTransform.Container
        var successCase: CanonicalSIL.AlgebraicTransform.Case
        var failureCase: CanonicalSIL.AlgebraicTransform.Case
        var logicalSuccessType: Bytecode.ValueType
        var storedSuccessType: Bytecode.ValueType
        var errorType: Bytecode.ValueType
    }
}
}
