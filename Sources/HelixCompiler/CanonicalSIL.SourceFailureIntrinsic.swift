extension CanonicalSIL {
/// Current Swift frontend entry points that all terminate source execution.
/// Their physical diagnostic metadata stays compiler-side; HLBC carries only
/// the represented detail required by the runtime trap.
enum SourceFailureIntrinsic: Equatable {
    /// Mandatory inlining lowers precondition and fatal-error families here.
    case runtimeAssertion
    /// Runtime assertion form used when the inlined helper has no physical
    /// file/line operands; the HLBC source map still carries location.
    case runtimeAssertionWithoutLocation
    /// Current generic standard-library bodies may retain a StaticString
    /// diagnostic rather than materializing a represented String.
    case runtimeStaticAssertion
    /// The public debug-only assertion API retains its message autoclosure.
    case debugAssertion
    /// The Swift runtime sink emitted for a failed `try!` expression.
    case unexpectedError
    /// The generic runtime sink emitted when `try!` consumes a concrete
    /// `throws(Failure)` error result.
    case typedUnexpectedError

    init?(mangledName: String) {
        switch mangledName {
        case "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF":
            self = .runtimeAssertion
        case "$ss17_assertionFailure__5flagss5NeverOs12StaticStringV_SSs6UInt32VtF":
            self = .runtimeAssertionWithoutLocation
        case "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF",
             "$ss18_fatalErrorMessage__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF":
            self = .runtimeStaticAssertion
        case "$ss16assertionFailure_4file4lineySSyXK_s12StaticStringVSutF":
            self = .debugAssertion
        case "swift_unexpectedError":
            self = .unexpectedError
        case "swift_unexpectedErrorTyped":
            self = .typedUnexpectedError
        default:
            return nil
        }
    }
}
}
