extension CanonicalSIL {
/// Current standard-library helpers whose source-level value is independent
/// of private Swift runtime representation.
enum DefaultValueIntrinsic: Equatable {
    case emptyString

    init?(mangledName: String) {
        switch mangledName {
        case "$ss12precondition__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_",
             "$ss19preconditionFailure_4file4lines5NeverOSSyXK_s12StaticStringVSutFfA_SSycfu_",
             "$ss10fatalError_4file4lines5NeverOSSyXK_s12StaticStringVSutFfA_SSycfu_",
             "$ss6assert__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_",
             "$ss16assertionFailure_4file4lineySSyXK_s12StaticStringVSutFfA_SSycfu_":
            self = .emptyString
        default:
            return nil
        }
    }

    /// Intrinsics normally disappear at direct call sites. When Swift turns
    /// one into a function value, provide an ordinary verified closure body
    /// instead of importing the standard library's private representation.
    func closureReplacement(
        for function: CanonicalSIL.Function
    ) -> CanonicalSIL.Function {
        switch self {
        case .emptyString:
            CanonicalSIL.Function(
                mangledName: function.mangledName,
                loweredType: function.loweredType,
                body: """
                bb0:
                  %0 = string_literal utf8 ""
                  %1 = integer_literal $Builtin.Word, 0
                  %2 = integer_literal $Builtin.Int1, -1
                  %3 = metatype $@thin String.Type
                  %4 = function_ref @$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC : $@convention(method) (Builtin.RawPointer, Builtin.Word, Builtin.Int1, @thin String.Type) -> @owned String
                  %5 = apply %4(%0, %1, %2, %3) : $@convention(method) (Builtin.RawPointer, Builtin.Word, Builtin.Int1, @thin String.Type) -> @owned String
                  return %5
                """
            )
        }
    }
}
}
