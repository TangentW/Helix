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

    /// Array-backed structural edits share value-semantic VM primitives. The
    /// cases describe frontend call shapes only; lowering does not specialize
    /// behavior by element type.
    enum ArrayEdit: Equatable {
        case concatenating
        case concatenateInPlace
        case appendContents
        case insertElement
        case insertContents
        case replaceSubrange
        case removeAt
        case removeFirst
        case removeLast
        case removeFirstCount
        case removeLastCount
        case removeSubrange
        case removeAll
        case swapAt
        case reserveCapacity

        func resolveSpecialization(
            _ specializations: [Bytecode.ValueType]
        ) throws -> (array: Bytecode.ValueType, element: Bytecode.ValueType) {
            let array: Bytecode.ValueType
            switch self {
            case .concatenating, .concatenateInPlace, .insertElement,
                 .removeAt, .removeAll, .reserveCapacity:
                guard specializations.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array edit has unsupported specializations"
                    )
                }
                array = .array(
                    CanonicalSIL.ValueRepresentation.storable(
                        specializations[0]
                    )
                )
            case .appendContents, .replaceSubrange:
                guard specializations.count == 2,
                      case let .array(sourceElement) = specializations[1],
                      sourceElement == CanonicalSIL.ValueRepresentation.storable(
                        specializations[0]
                      )
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Array edit requires a matching Array-backed collection"
                    )
                }
                array = .array(sourceElement)
            case .insertContents:
                guard specializations.count == 2,
                      case let .array(element) = specializations[0],
                      specializations[1] == .array(element)
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "insert(contentsOf:at:) requires matching Array-backed collections"
                    )
                }
                array = .array(element)
            case .removeFirst, .removeLast, .removeFirstCount,
                 .removeLastCount, .removeSubrange, .swapAt:
                guard specializations.count == 1,
                      case .array = specializations[0]
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "RangeReplaceableCollection edit requires an Array-backed specialization"
                    )
                }
                array = specializations[0]
            }
            guard case let .array(element) = array else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Array edit specialization is not an Array"
                )
            }
            return (array, element)
        }
    }

    case equality(EqualityContainer)
    case search(Bytecode.ArraySearchOperation)
    case extremum(Bytecode.ArrayExtremumOperation)
    case relation(Bytecode.ArrayRelationOperation)
    case arrayIndex(ArrayIndexOperation)
    case adapter(Adapter)
    case arrayEdit(ArrayEdit)

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
        case "$sSa1poiySayxGAB_ABtFZ":
            self = .arrayEdit(.concatenating)
        case "$sSa2peoiyySayxGz_ABtFZ":
            self = .arrayEdit(.concatenateInPlace)
        case "$sSa6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF":
            self = .arrayEdit(.appendContents)
        case "$sSa6insert_2atyxn_SitF":
            self = .arrayEdit(.insertElement)
        case "$sSmsE6insert10contentsOf2atyqd__n_5IndexQztSlRd__7ElementQyd__AFRtzlF":
            self = .arrayEdit(.insertContents)
        case "$sSa15replaceSubrange_4withySnySiG_qd__nt7ElementQyd__RszSlRd__lF":
            self = .arrayEdit(.replaceSubrange)
        case "$sSa6remove2atxSi_tF":
            self = .arrayEdit(.removeAt)
        case "$sSmsE11removeFirst7ElementQzyF":
            self = .arrayEdit(.removeFirst)
        case "$sSmsSKRzrlE10removeLast7ElementSTQzyF":
            self = .arrayEdit(.removeLast)
        case "$sSmsE11removeFirstyySiF":
            self = .arrayEdit(.removeFirstCount)
        case "$sSmsSKRzrlE10removeLastyySiF":
            self = .arrayEdit(.removeLastCount)
        case "$sSmsE14removeSubrangeyySny5IndexQzGF":
            self = .arrayEdit(.removeSubrange)
        case "$sSa9removeAll15keepingCapacityySb_tF":
            self = .arrayEdit(.removeAll)
        case "$sSMsE6swapAtyy5IndexQz_ACtF":
            self = .arrayEdit(.swapAt)
        case "$sSa15reserveCapacityyySiF":
            self = .arrayEdit(.reserveCapacity)
        default:
            return nil
        }
    }
}
}
