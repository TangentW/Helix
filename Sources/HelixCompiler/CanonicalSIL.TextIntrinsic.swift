import HelixBytecode

extension CanonicalSIL {
/// Semantic text operations recognized from concrete Swift frontend entry
/// points. Logical Character and Substring values use TextRepresentation;
/// runtime execution stays on verifier-visible String/Collection primitives.
enum TextIntrinsic: Equatable {
    enum LiteralKind: Equatable {
        case string
        case character
    }

    struct Comparison: Equatable {
        enum Operation: Equatable {
            case equal
            case less
        }

        var operation: Operation
        var operandKind: CanonicalSIL.TextRepresentation.Kind
    }

    enum Construction: Equatable {
        case repeating
        case losslessDescription
        case customDescription
        case fromCharacter
        case fromSubstring
        case fromCharacterSequence
    }

    enum Interpolation: Equatable {
        case initialize
        case appendLiteral
        case appendValue
        case finalize
    }

    case literal(LiteralKind)
    case comparison(Comparison)
    case concatenation
    case transform(Bytecode.StringTransformOperation)
    case predicate(Bytecode.StringPredicateOperation)
    case construction(Construction)
    case joinStringCollection
    case joinDefaultSeparator
    case interpolation(Interpolation)

    init?(mangledName: String) {
        switch mangledName {
        case "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC":
            self = .literal(.string)
        case "$sSJ38_builtinExtendedGraphemeClusterLiteral17utf8CodeUnitCount7isASCIISJBp_BwBi1_tcfC":
            self = .literal(.character)
        case "$sSS2eeoiySbSS_SStFZ":
            self = .comparison(.init(operation: .equal, operandKind: .string))
        case "$sSJ2eeoiySbSJ_SJtFZ":
            self = .comparison(.init(operation: .equal, operandKind: .character))
        case "$sSS1loiySbSS_SStFZ":
            self = .comparison(.init(operation: .less, operandKind: .string))
        case "$sSJ1loiySbSJ_SJtFZ":
            self = .comparison(.init(operation: .less, operandKind: .character))
        case "$sSS1poiyS2S_SStFZ":
            self = .concatenation
        case "$sSS10uppercasedSSyF":
            self = .transform(.uppercase)
        case "$sSS10lowercasedSSyF":
            self = .transform(.lowercase)
        case "$sSS9hasPrefixySbSSF":
            self = .predicate(.hasPrefix)
        case "$sSS9hasSuffixySbSSF":
            self = .predicate(.hasSuffix)
        case "$sSy17_StringProcessingE8containsySbSSF":
            self = .predicate(.contains)
        case "$sSS9repeating5countS2S_SitcfC":
            self = .construction(.repeating)
        case "$sSSySSxcs25LosslessStringConvertibleRzlufC":
            self = .construction(.losslessDescription)
        case "$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC":
            self = .construction(.customDescription)
        case "$sSSySSSJcfC":
            self = .construction(.fromCharacter)
        case "$sSSySSSshcfC":
            self = .construction(.fromSubstring)
        case "$sSSySSxcSTRzSJ7ElementRtzlufC",
             "$sSSySSxcs25LosslessStringConvertibleRzSTRzSJ7ElementSTRtzlufC":
            self = .construction(.fromCharacterSequence)
        case "$sSKsSS7ElementRtzrlE6joined9separatorS2S_tF":
            self = .joinStringCollection
        case "$sSKsSS7ElementRtzrlE6joined9separatorS2S_tFfA_":
            self = .joinDefaultSeparator
        case "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC":
            self = .interpolation(.initialize)
        case "$ss26DefaultStringInterpolationV13appendLiteralyySSF":
            self = .interpolation(.appendLiteral)
        case "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF",
             "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF":
            self = .interpolation(.appendValue)
        case "$sSS19stringInterpolationSSs013DefaultStringB0V_tcfC":
            self = .interpolation(.finalize)
        default:
            return nil
        }
    }
}
}
