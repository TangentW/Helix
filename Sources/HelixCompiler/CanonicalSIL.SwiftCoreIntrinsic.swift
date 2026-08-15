import HelixBytecode

extension CanonicalSIL {
enum SwiftCoreIntrinsic: Equatable {
    case minimum
    case maximum
    case absoluteValue
    case stringLiteral
    case characterLiteral
    case stringEqual
    case stringLess
    case stringConcat
    case stringCount
    case stringIsEmpty
    case stringTransform(Bytecode.StringTransformOperation)
    case stringHasPrefix
    case stringHasSuffix
    case stringContains
    case stringInterpolationInit
    case stringInterpolationAppendLiteral
    case stringInterpolationAppendValue
    case stringFromInterpolation
    case arrayCount
    case collectionIsEmpty
    case arraySubscript
    case arraySubscriptModify
    case collectionBoundary(Bytecode.ArrayBoundaryOperation)
    case sequenceContains
    case arrayAppend
    case arrayPopLast
    case collectionMakeIterator
    case indexingIteratorNext
    case dictionaryCount
    case dictionaryIsEmpty
    case dictionarySubscriptGet
    case dictionarySubscriptSet
    case dictionaryRemoveValue
    case dictionaryLiteral
    case dictionaryMakeIterator
    case dictionaryIteratorNext
    case allocateUninitializedArray
    case finalizeUninitializedArray
    case assertionFailure

    init?(mangledName: String) {
        switch mangledName {
        case "$ss3minyxx_xtSLRzlF": self = .minimum
        case "$ss3maxyxx_xtSLRzlF": self = .maximum
        case "$ss3absyxxSLRzs13SignedNumericRzlF": self = .absoluteValue
        case "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC":
            self = .stringLiteral
        case "$sSJ38_builtinExtendedGraphemeClusterLiteral17utf8CodeUnitCount7isASCIISJBp_BwBi1_tcfC":
            self = .characterLiteral
        case "$sSS2eeoiySbSS_SStFZ": self = .stringEqual
        case "$sSS1loiySbSS_SStFZ": self = .stringLess
        case "$sSS1poiyS2S_SStFZ": self = .stringConcat
        case "$sSS5countSivg": self = .stringCount
        case "$sSS7isEmptySbvg": self = .stringIsEmpty
        case "$sSS10uppercasedSSyF": self = .stringTransform(.uppercase)
        case "$sSS10lowercasedSSyF": self = .stringTransform(.lowercase)
        case "$sSS9hasPrefixySbSSF": self = .stringHasPrefix
        case "$sSS9hasSuffixySbSSF": self = .stringHasSuffix
        case "$sSy17_StringProcessingE8containsySbSSF": self = .stringContains
        case "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC":
            self = .stringInterpolationInit
        case "$ss26DefaultStringInterpolationV13appendLiteralyySSF":
            self = .stringInterpolationAppendLiteral
        case "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF":
            self = .stringInterpolationAppendValue
        case "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF":
            self = .stringInterpolationAppendValue
        case "$sSS19stringInterpolationSSs013DefaultStringB0V_tcfC":
            self = .stringFromInterpolation
        case "$sSa5countSivg": self = .arrayCount
        case "$sSlsE7isEmptySbvg": self = .collectionIsEmpty
        case "$sSayxSicig": self = .arraySubscript
        case "$sSayxSiciM": self = .arraySubscriptModify
        case "$sSlsE5first7ElementQzSgvg": self = .collectionBoundary(.first)
        case "$sSKsE4last7ElementQzSgvg": self = .collectionBoundary(.last)
        case "$sSTsSQ7ElementRpzrlE8containsySbABF": self = .sequenceContains
        case "$sSa6appendyyxnF": self = .arrayAppend
        case "$sSmsSKRzrlE7popLast7ElementSTQzSgyF": self = .arrayPopLast
        case "$sSlss16IndexingIteratorVyxG0B0RtzrlE04makeB0ACyF":
            self = .collectionMakeIterator
        case "$ss16IndexingIteratorV4next7ElementQzSgyF":
            self = .indexingIteratorNext
        case "$sSD5countSivg": self = .dictionaryCount
        case "$sSD7isEmptySbvg": self = .dictionaryIsEmpty
        case "$sSDyq_Sgxcig": self = .dictionarySubscriptGet
        case "$sSDyq_Sgxcis": self = .dictionarySubscriptSet
        case "$sSD11removeValue6forKeyq_Sgx_tF": self = .dictionaryRemoveValue
        case "$sSD17dictionaryLiteralSDyxq_Gx_q_td_tcfC": self = .dictionaryLiteral
        case "$sSD12makeIteratorSD0B0Vyxq__GyF": self = .dictionaryMakeIterator
        case "$sSD8IteratorV4nextx3key_q_5valuetSgyF": self = .dictionaryIteratorNext
        case "$ss27_allocateUninitializedArrayySayxG_BptBwlF":
            self = .allocateUninitializedArray
        case "$ss27_finalizeUninitializedArrayySayxGABnlF":
            self = .finalizeUninitializedArray
        case "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF":
            self = .assertionFailure
        default:
            return nil
        }
    }
}
}
