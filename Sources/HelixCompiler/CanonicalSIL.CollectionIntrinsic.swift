import HelixBytecode

extension CanonicalSIL {
/// Common collection operations classified by semantic shape instead of by
/// one concrete element type. Lowering still validates every specialization
/// and only accepts Array-backed Sequence/Collection forms the VM can model.
enum CollectionIntrinsic: Equatable {
    enum EqualityContainer: Equatable {
        case array
        case dictionary
    }

    enum ArrayIndexOperation: Equatable {
        case start
        case end
        case distance
        case indices
        case after
        case before
        case offsetBy
        case offsetByLimited
    }

    enum IteratorShape: Equatable {
        case collection
        case reversed
        case enumerated
        case zipped
        case flattened
        case joined
    }

    enum Adapter: Equatable {
        case transform(Bytecode.ArrayAdapterOperation)
        case arrayFromSequence
        case arrayRepeat(hasMetatype: Bool)
        case subsequence(Bytecode.ArraySubsequenceOperation)
        case rangeSlice
        case zip
        case joined(hasSeparator: Bool)
    }

    case equality(EqualityContainer)
    case search(Bytecode.ArraySearchOperation)
    case extremum(Bytecode.ArrayExtremumOperation)
    case relation(Bytecode.ArrayRelationOperation)
    case arrayIndex(ArrayIndexOperation)
    case adapter(Adapter)

    init?(mangledName: String) {
        switch mangledName {
        case "$sSasSQRzlE2eeoiySbSayxG_ABtFZ":
            self = .equality(.array)
        case "$sSDsSQR_rlE2eeoiySbSDyxq_G_ABtFZ":
            self = .equality(.dictionary)
        case "$sSlsSQ7ElementRpzrlE10firstIndex2of0C0QzSgAB_tF":
            self = .search(.firstIndex)
        case "$sSKsSQ7ElementRpzrlE9lastIndex2of0C0QzSgAB_tF":
            self = .search(.lastIndex)
        case "$sSTsSL7ElementRpzrlE3minABSgyF":
            self = .extremum(.minimum)
        case "$sSTsSL7ElementRpzrlE3maxABSgyF":
            self = .extremum(.maximum)
        case "$sSTsSQ7ElementRpzrlE13elementsEqualySbqd__STRd__AAQyd__ABRSlF":
            self = .relation(.elementsEqual)
        case "$sSTsSQ7ElementRpzrlE6starts4withSbqd___tSTRd__AAQyd__ABRSlF":
            self = .relation(.startsWith)
        case "$sSTsSL7ElementRpzrlE25lexicographicallyPrecedesySbqd__STRd__AAQyd__ABRSlF":
            self = .relation(.lexicographicallyPrecedes)
        case "$sSa10startIndexSivg":
            self = .arrayIndex(.start)
        case "$sSa8endIndexSivg":
            self = .arrayIndex(.end)
        case "$sSa8distance4from2toS2i_SitF":
            self = .arrayIndex(.distance)
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE7indicesACvg":
            self = .arrayIndex(.indices)
        case "$sSa5index5afterS2i_tF":
            self = .arrayIndex(.after)
        case "$sSa5index6beforeS2i_tF":
            self = .arrayIndex(.before)
        case "$sSa5index_8offsetByS2i_SitF":
            self = .arrayIndex(.offsetBy)
        case "$sSa5index_8offsetBy07limitedC0SiSgSi_S2itF":
            self = .arrayIndex(.offsetByLimited)
        case "$sSTsE10enumerateds18EnumeratedSequenceVyxGyF":
            self = .adapter(.transform(.enumerated))
        case "$sSKsE8reverseds18ReversedCollectionVyxGyF":
            self = .adapter(.transform(.reversed))
        case "$sSaySayxGqd__c7ElementQyd__RszSTRd__lufC":
            self = .adapter(.arrayFromSequence)
        case "$sSa9repeating5countSayxGx_SitcfC":
            self = .adapter(.arrayRepeat(hasMetatype: true))
        case "$ss13repeatElement_5counts8RepeatedVyxGx_SitlF":
            self = .adapter(.arrayRepeat(hasMetatype: false))
        case "$sSlsE9dropFirsty11SubSequenceQzSiF":
            self = .adapter(.subsequence(.dropFirst))
        case "$sSKsE8dropLasty11SubSequenceQzSiF":
            self = .adapter(.subsequence(.dropLast))
        case "$sSlsE6prefixy11SubSequenceQzSiF":
            self = .adapter(.subsequence(.prefix))
        case "$sSKsE6suffixy11SubSequenceQzSiF":
            self = .adapter(.subsequence(.suffix))
        case "$sSlsE6prefix4upTo11SubSequenceQz5IndexQz_tF":
            self = .adapter(.subsequence(.prefixUpTo))
        case "$sSlsE6prefix7through11SubSequenceQz5IndexQz_tF":
            self = .adapter(.subsequence(.prefixThrough))
        case "$sSlsE6suffix4from11SubSequenceQz5IndexQz_tF":
            self = .adapter(.subsequence(.suffixFrom))
        case "$sSays10ArraySliceVyxGSnySiGcig":
            self = .adapter(.rangeSlice)
        case "$ss3zipys12Zip2SequenceVyxq_Gx_q_tSTRzSTR_r0_lF":
            self = .adapter(.zip)
        case "$sSTsST7ElementRpzrlE6joineds15FlattenSequenceVyxGyF":
            self = .adapter(.joined(hasSeparator: false))
        case "$sSTsST7ElementRpzrlE6joined9separators14JoinedSequenceVyxGqd___tSTRd__AA_AAQZAARtd__lF":
            self = .adapter(.joined(hasSeparator: true))
        default:
            return nil
        }
    }
}
}
