import HelixBytecode

extension CanonicalSIL {
/// Common collection operations classified by semantic shape instead of by
/// one concrete element type. Element-sequence operations may also accept
/// finite concrete progressions through the shared Sequence specialization;
/// index-sensitive operations retain their stricter Collection constraints.
enum CollectionIntrinsic: Equatable {
    struct Query: Equatable {
        enum Operation: Equatable {
            case count
            case underestimatedCount
            case isEmpty
            case first
            case last
        }

        /// Describes how a stdlib entry point carries its concrete source in
        /// generic substitutions. This is frontend ABI shape, not runtime
        /// behavior; every shape resolves to the same Sequence specialization.
        enum Source: Equatable {
            case collection
            case stringCharacters
            case arrayBackedElement
            case dictionaryKeyValue
            case setElement
            /// `Zip2Sequence` carries its concrete sources as separate
            /// substitutions, while lowering stores the materialized tuple
            /// sequence in represented Array storage.
            case zipped
            case progressionElement(CanonicalSIL.Progression.Family)
        }

        var operation: Operation
        var source: Source

        /// Some concrete stdlib adapters expose a semantic Collection query
        /// as a stored-field projection rather than a callable getter. Keep
        /// that frontend spelling at the same query-classification boundary.
        static func storedProjection(
            owner: String,
            field: String
        ) -> Operation? {
            switch (owner, field) {
            case ("Repeated", "count"), ("Swift.Repeated", "count"):
                .count
            default:
                nil
            }
        }
    }

    enum ExtremumOperation: Equatable {
        case minimum
        case maximum
    }

    enum RelationOperation: Equatable {
        case elementsEqual
        case startsWith
        case lexicographicallyPrecedes
    }

    enum EqualityContainer: Equatable {
        case array
        case dictionary
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
        case sliceFromBounds
        case subsequence(Bytecode.ArraySubsequenceOperation)
        case rangeSlice
        case rangeExpressionSlice
        case fullRangeSlice
        case zip
        case joined(hasSeparator: Bool)
    }

    /// Identifies the concrete destination carried by a stdlib
    /// RangeReplaceableCollection entry point. This preserves logical wrapper
    /// identity even when multiple Swift collections share one HLBC storage
    /// representation.
    enum RangeReplaceableDestination: Equatable {
        /// The first generic substitution is the concrete collection `Self`.
        case genericSelf
        /// A concrete Array entry point substitutes only `Element`.
        case array
        /// A concrete ArraySlice entry point substitutes only `Element`.
        case arraySlice
        /// A concrete String entry point has no destination substitution.
        case string
        /// A concrete Substring entry point has no destination substitution.
        case substring
    }

    /// Variable-length mutations classified by the frontend specialization
    /// that identifies `Self`. Their implementation is shared by every
    /// collection with a complete represented storage model.
    struct RangeReplaceableEdit: Equatable {
        enum Operation: Equatable {
            case removeFirst
            case removeLast
            case removeFirstCount
            case removeLastCount
            case popLast
            case removeAll
            case reserveCapacity
        }

        var operation: Operation
        var destination: RangeReplaceableDestination
    }

    /// Element and finite-Sequence appends share one semantic plan across
    /// every represented RangeReplaceableCollection. These cases describe
    /// frontend ABI shape only; lowering is driven by the resolved storage and
    /// element types.
    struct RangeReplaceableAppend: Equatable {
        enum ContentsSource: Equatable {
            /// The next generic substitution is the concrete Sequence source.
            case genericArgument
            /// The source has the same logical collection type as the
            /// destination, as in concrete String or Array `+=`.
            case destination
            /// A concrete source is fixed by the frontend entry point.
            case fixed(RangeReplaceableDestination)
        }

        enum Input: Equatable {
            case element
            case contents(ContentsSource)
        }

        enum CallShape: Equatable {
            case method
            case additionAssignment
        }

        var destination: RangeReplaceableDestination
        var input: Input
        var callShape: CallShape
    }

    /// Array-backed structural edits share value-semantic VM primitives. The
    /// cases describe frontend call shapes only; lowering does not specialize
    /// behavior by element type.
    enum ArrayEdit: Equatable {
        case concatenating
        case insertElement
        case insertContents
        case replaceSubrange
        case removeAt
        case removeSubrange
        case reverse
        case swapAt

        func resolveSpecialization(
            _ specializations: [Bytecode.ValueType]
        ) throws -> (array: Bytecode.ValueType, element: Bytecode.ValueType) {
            let array: Bytecode.ValueType
            switch self {
            case .concatenating, .insertElement, .removeAt:
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
            case .replaceSubrange:
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
            case .removeSubrange, .reverse, .swapAt:
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
    case query(Query)
    case search(Bytecode.ArraySearchOperation)
    case extremum(ExtremumOperation)
    case relation(RelationOperation)
    case collectionIndex(CanonicalSIL.CollectionIndex.Intrinsic)
    case adapter(Adapter)
    case rangeReplaceableEdit(RangeReplaceableEdit)
    case rangeReplaceableAppend(RangeReplaceableAppend)
    case arrayEdit(ArrayEdit)

    init?(mangledName: String) {
        switch mangledName {
        case "$sSS5countSivg":
            self = .query(.init(operation: .count, source: .stringCharacters))
        case "$sSS7isEmptySbvg":
            self = .query(.init(operation: .isEmpty, source: .stringCharacters))
        case "$sSa5countSivg":
            self = .query(.init(operation: .count, source: .arrayBackedElement))
        case "$ss10ArraySliceV5countSivg":
            self = .query(.init(operation: .count, source: .arrayBackedElement))
        case "$sSlsE5countSivg":
            self = .query(.init(operation: .count, source: .collection))
        case "$sSlsE19underestimatedCountSivg":
            self = .query(
                .init(operation: .underestimatedCount, source: .collection)
            )
        case "$ss12Zip2SequenceV19underestimatedCountSivg":
            self = .query(
                .init(operation: .underestimatedCount, source: .zipped)
            )
        case "$ss8StrideToV19underestimatedCountSivg":
            self = .query(
                .init(
                    operation: .underestimatedCount,
                    source: .progressionElement(.strideTo)
                )
            )
        case "$ss13StrideThroughV19underestimatedCountSivg":
            self = .query(
                .init(
                    operation: .underestimatedCount,
                    source: .progressionElement(.strideThrough)
                )
            )
        case "$sSD5countSivg":
            self = .query(.init(operation: .count, source: .dictionaryKeyValue))
        case "$sSh5countSivg":
            self = .query(.init(operation: .count, source: .setElement))
        case "$sSlsE7isEmptySbvg":
            self = .query(.init(operation: .isEmpty, source: .collection))
        case "$sSn7isEmptySbvg":
            self = .query(
                .init(
                    operation: .isEmpty,
                    source: .progressionElement(.range)
                )
            )
        case "$sSN7isEmptySbvg":
            self = .query(
                .init(
                    operation: .isEmpty,
                    source: .progressionElement(.closedRange)
                )
            )
        case "$sSD7isEmptySbvg":
            self = .query(
                .init(operation: .isEmpty, source: .dictionaryKeyValue)
            )
        case "$sSh7isEmptySbvg":
            self = .query(.init(operation: .isEmpty, source: .setElement))
        case "$sSlsE5first7ElementQzSgvg":
            self = .query(.init(operation: .first, source: .collection))
        case "$sSKsE4last7ElementQzSgvg":
            self = .query(.init(operation: .last, source: .collection))
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
        case "$sSa10startIndexSivg", "$ss8RepeatedV10startIndexSivg":
            self = .collectionIndex(
                .init(operation: .start, source: .arrayElement)
            )
        case "$ss10ArraySliceV10startIndexSivg":
            self = .collectionIndex(
                .init(operation: .start, source: .arraySliceElement)
            )
        case "$ss5SliceV10startIndex0C0Qzvg":
            self = .collectionIndex(
                .init(operation: .start, source: .sliceBase)
            )
        case "$sSa8endIndexSivg", "$ss8RepeatedV8endIndexSivg":
            self = .collectionIndex(
                .init(operation: .end, source: .arrayElement)
            )
        case "$ss10ArraySliceV8endIndexSivg":
            self = .collectionIndex(
                .init(operation: .end, source: .arraySliceElement)
            )
        case "$ss5SliceV8endIndex0C0Qzvg":
            self = .collectionIndex(
                .init(operation: .end, source: .sliceBase)
            )
        case "$sSa8distance4from2toS2i_SitF":
            self = .collectionIndex(
                .init(operation: .distance, source: .arrayElement)
            )
        case "$ss10ArraySliceV8distance4from2toS2i_SitF":
            self = .collectionIndex(
                .init(operation: .distance, source: .arraySliceElement)
            )
        case "$ss5SliceV8distance4from2toSi5IndexQz_AGtF":
            self = .collectionIndex(
                .init(operation: .distance, source: .sliceBase)
            )
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE8distance4from2toSiAB_ABtF":
            self = .collectionIndex(
                .init(operation: .distance, source: .genericCollection)
            )
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE7indicesACvg":
            self = .collectionIndex(
                .init(operation: .indices, source: .genericCollection)
            )
        case "$ss5SliceV7indices7IndicesQzvg":
            self = .collectionIndex(
                .init(operation: .indices, source: .sliceBase)
            )
        case "$sSa5index5afterS2i_tF":
            self = .collectionIndex(
                .init(operation: .after, source: .arrayElement)
            )
        case "$ss10ArraySliceV5index5afterS2i_tF":
            self = .collectionIndex(
                .init(operation: .after, source: .arraySliceElement)
            )
        case "$ss5SliceV5index5after5IndexQzAF_tF":
            self = .collectionIndex(
                .init(operation: .after, source: .sliceBase)
            )
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE5index5afterA2B_tF":
            self = .collectionIndex(
                .init(operation: .after, source: .genericCollection)
            )
        case "$sSa5index6beforeS2i_tF":
            self = .collectionIndex(
                .init(operation: .before, source: .arrayElement)
            )
        case "$ss10ArraySliceV5index6beforeS2i_tF":
            self = .collectionIndex(
                .init(operation: .before, source: .arraySliceElement)
            )
        case "$ss5SliceVsSKRzrlE5index6before5IndexQzAF_tF":
            self = .collectionIndex(
                .init(operation: .before, source: .sliceBase)
            )
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE5index6beforeA2B_tF":
            self = .collectionIndex(
                .init(operation: .before, source: .genericCollection)
            )
        case "$sSa5index_8offsetByS2i_SitF":
            self = .collectionIndex(
                .init(operation: .offsetBy, source: .arrayElement)
            )
        case "$ss10ArraySliceV5index_8offsetByS2i_SitF":
            self = .collectionIndex(
                .init(operation: .offsetBy, source: .arraySliceElement)
            )
        case "$ss5SliceV5index_8offsetBy5IndexQzAF_SitF":
            self = .collectionIndex(
                .init(operation: .offsetBy, source: .sliceBase)
            )
        case "$sSksSx5IndexRpzSnyABG7IndicesRtzSiAA_6StrideRTzrlE5index_8offsetByA2B_SitF":
            self = .collectionIndex(
                .init(operation: .offsetBy, source: .genericCollection)
            )
        case "$sSa5index_8offsetBy07limitedC0SiSgSi_S2itF":
            self = .collectionIndex(
                .init(operation: .offsetByLimited, source: .arrayElement)
            )
        case "$ss10ArraySliceV5index_8offsetBy07limitedE0SiSgSi_S2itF":
            self = .collectionIndex(
                .init(operation: .offsetByLimited, source: .arraySliceElement)
            )
        case "$ss5SliceV5index_8offsetBy07limitedD05IndexQzSgAG_SiAGtF":
            self = .collectionIndex(
                .init(operation: .offsetByLimited, source: .sliceBase)
            )
        case "$sSksE5index_8offsetBy07limitedC05IndexQzSgAE_SiAEtF":
            self = .collectionIndex(
                .init(operation: .offsetByLimited, source: .genericCollection)
            )
        case "$sSa9formIndex5afterySiz_tF":
            self = .collectionIndex(
                .init(operation: .formAfter, source: .arrayElement)
            )
        case "$ss10ArraySliceV9formIndex5afterySiz_tF":
            self = .collectionIndex(
                .init(operation: .formAfter, source: .arraySliceElement)
            )
        case "$ss5SliceV9formIndex5aftery0C0Qzz_tF":
            self = .collectionIndex(
                .init(operation: .formAfter, source: .sliceBase)
            )
        case "$sSlsE9formIndex5aftery0B0Qzz_tF":
            self = .collectionIndex(
                .init(operation: .formAfter, source: .genericCollection)
            )
        case "$sSa9formIndex6beforeySiz_tF":
            self = .collectionIndex(
                .init(operation: .formBefore, source: .arrayElement)
            )
        case "$ss10ArraySliceV9formIndex6beforeySiz_tF":
            self = .collectionIndex(
                .init(operation: .formBefore, source: .arraySliceElement)
            )
        case "$ss5SliceVsSKRzrlE9formIndex6beforey0C0Qzz_tF":
            self = .collectionIndex(
                .init(operation: .formBefore, source: .sliceBase)
            )
        case "$sSKsE9formIndex6beforey0B0Qzz_tF":
            self = .collectionIndex(
                .init(operation: .formBefore, source: .genericCollection)
            )
        case "$sSlsE9formIndex_8offsetByy0B0Qzz_SitF":
            self = .collectionIndex(
                .init(operation: .formOffsetBy, source: .genericCollection)
            )
        case "$sSlsE9formIndex_8offsetBy07limitedD0Sb0B0Qzz_SiAEtF":
            self = .collectionIndex(
                .init(
                    operation: .formOffsetByLimited,
                    source: .genericCollection
                )
            )
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
        case "$ss5SliceV4base6boundsAByxGx_Sny5IndexQzGtcfC":
            self = .adapter(.sliceFromBounds)
        case "$sSlsE9dropFirsty11SubSequenceQzSiF":
            self = .adapter(.subsequence(.dropFirst))
        case "$sSlsE8dropLasty11SubSequenceQzSiF",
             "$sSKsE8dropLasty11SubSequenceQzSiF":
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
        case "$sSays10ArraySliceVyxGSnySiGcig",
             "$ss10ArraySliceVyAByxGSnySiGcig":
            self = .adapter(.rangeSlice)
        case "$sSMsEy11SubSequenceQzqd__cSXRd__5BoundQyd__5IndexRtzluig":
            self = .adapter(.rangeExpressionSlice)
        case
            CanonicalSIL.RangeExpression.unboundedCollectionSubscriptMangledName,
            CanonicalSIL.RangeExpression
                .unboundedMutableCollectionSubscriptMangledName:
            self = .adapter(.fullRangeSlice)
        case "$ss3zipys12Zip2SequenceVyxq_Gx_q_tSTRzSTR_r0_lF":
            self = .adapter(.zip)
        case "$sSTsST7ElementRpzrlE6joineds15FlattenSequenceVyxGyF":
            self = .adapter(.joined(hasSeparator: false))
        case "$sSTsST7ElementRpzrlE6joined9separators14JoinedSequenceVyxGqd___tSTRd__AA_AAQZAARtd__lF":
            self = .adapter(.joined(hasSeparator: true))
        case "$sSa1poiySayxGAB_ABtFZ":
            self = .arrayEdit(.concatenating)
        case "$sSS6appendyySJF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .string,
                    input: .element,
                    callShape: .method
                )
            )
        case "$sSS6appendyySSF", "$sSS6append10contentsOfySS_tF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .string,
                    input: .contents(.destination),
                    callShape: .method
                )
            )
        case "$sSS6append10contentsOfySs_tF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .string,
                    input: .contents(.fixed(.substring)),
                    callShape: .method
                )
            )
        case "$sSS6append10contentsOfyx_tSTRzSJ7ElementRtzlF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .string,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            )
        case "$sSs6append10contentsOfyx_tSTRzSJ7ElementRtzlF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .substring,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            )
        case "$sSmsE6appendyy7ElementQznF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .genericSelf,
                    input: .element,
                    callShape: .method
                )
            )
        case "$sSmsE6append10contentsOfyqd__n_tSTRd__7ElementQyd__ACRtzlF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .genericSelf,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            )
        case "$sSa6appendyyxnF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .array,
                    input: .element,
                    callShape: .method
                )
            )
        case "$ss10ArraySliceV6appendyyxnF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .arraySlice,
                    input: .element,
                    callShape: .method
                )
            )
        case "$sSa6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .array,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            )
        case "$ss10ArraySliceV6append10contentsOfyqd__n_t7ElementQyd__RszSTRd__lF":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .arraySlice,
                    input: .contents(.genericArgument),
                    callShape: .method
                )
            )
        case "$sSS2peoiyySSz_SStFZ":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .string,
                    input: .contents(.destination),
                    callShape: .additionAssignment
                )
            )
        case "$sSa2peoiyySayxGz_ABtFZ":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .array,
                    input: .contents(.destination),
                    callShape: .additionAssignment
                )
            )
        case "$sSmsE2peoiyyxz_qd__tSTRd__7ElementQyd__ABRtzlFZ":
            self = .rangeReplaceableAppend(
                .init(
                    destination: .genericSelf,
                    input: .contents(.genericArgument),
                    callShape: .additionAssignment
                )
            )
        case "$sSa6insert_2atyxn_SitF":
            self = .arrayEdit(.insertElement)
        case "$sSmsE6insert10contentsOf2atyqd__n_5IndexQztSlRd__7ElementQyd__AFRtzlF":
            self = .arrayEdit(.insertContents)
        case "$sSa15replaceSubrange_4withySnySiG_qd__nt7ElementQyd__RszSlRd__lF",
             "$ss10ArraySliceV15replaceSubrange_4withySnySiG_qd__nt7ElementQyd__RszSlRd__lF":
            self = .arrayEdit(.replaceSubrange)
        case "$sSa6remove2atxSi_tF":
            self = .arrayEdit(.removeAt)
        case "$sSmsE11removeFirst7ElementQzyF",
             "$sSms11SubSequenceQzRszrlE11removeFirst7ElementQzyF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeFirst, destination: .genericSelf)
            )
        case "$sSmsSKRzrlE10removeLast7ElementSTQzyF",
             "$sSmsSKRz11SubSequenceSlQzRszrlE10removeLast7ElementSTQzyF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeLast, destination: .genericSelf)
            )
        case "$sSmsE11removeFirstyySiF",
             "$sSms11SubSequenceQzRszrlE11removeFirstyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeFirstCount, destination: .genericSelf)
            )
        case "$sSmsSKRzrlE10removeLastyySiF",
             "$sSmsSKRz11SubSequenceSlQzRszrlE10removeLastyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeLastCount, destination: .genericSelf)
            )
        case "$sSmsSKRzrlE7popLast7ElementSTQzSgyF",
             "$sSmsSKRz11SubSequenceSlQzRszrlE7popLast7ElementSTQzSgyF":
            self = .rangeReplaceableEdit(
                .init(operation: .popLast, destination: .genericSelf)
            )
        case "$sSmsE14removeSubrangeyySny5IndexQzGF":
            self = .arrayEdit(.removeSubrange)
        case "$sSa9removeAll15keepingCapacityySb_tF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeAll, destination: .array)
            )
        case "$ss10ArraySliceV9removeAll15keepingCapacityySb_tF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeAll, destination: .arraySlice)
            )
        case "$sSS9removeAll15keepingCapacityySb_tF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeAll, destination: .string)
            )
        case "$sSmsE9removeAll15keepingCapacityySb_tF":
            self = .rangeReplaceableEdit(
                .init(operation: .removeAll, destination: .genericSelf)
            )
        case "$sSMsSKRzrlE7reverseyyF":
            self = .arrayEdit(.reverse)
        case "$sSMsE6swapAtyy5IndexQz_ACtF":
            self = .arrayEdit(.swapAt)
        case "$sSa15reserveCapacityyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .reserveCapacity, destination: .array)
            )
        case "$ss10ArraySliceV15reserveCapacityyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .reserveCapacity, destination: .arraySlice)
            )
        case "$sSS15reserveCapacityyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .reserveCapacity, destination: .string)
            )
        case "$sSmsE15reserveCapacityyySiF":
            self = .rangeReplaceableEdit(
                .init(operation: .reserveCapacity, destination: .genericSelf)
            )
        default:
            return nil
        }
    }
}
}
