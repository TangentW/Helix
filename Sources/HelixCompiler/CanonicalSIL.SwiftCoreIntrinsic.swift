import HelixBytecode

extension CanonicalSIL {
enum SwiftCoreIntrinsic: Equatable {
    case scalar(CanonicalSIL.ScalarIntrinsic)
    case collection(CanonicalSIL.CollectionIntrinsic)
    case higherOrder(CanonicalSIL.HigherOrderIntrinsic)
    case algebraic(CanonicalSIL.AlgebraicIntrinsic)
    case minimum
    case maximum
    case absoluteValue
    case stringLiteral
    case characterLiteral
    case stringEqual
    case stringLess
    case stringConcat
    case stringAppend
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
    case collectionMakeIterator(CanonicalSIL.CollectionIntrinsic.IteratorShape)
    case indexingIteratorNext(CanonicalSIL.CollectionIntrinsic.IteratorShape)
    case progressionConstructor(CanonicalSIL.Progression.Family)
    case progressionMakeIterator(CanonicalSIL.Progression.Family)
    case progressionIteratorNext(CanonicalSIL.Progression.Family)
    case rangeContains(CanonicalSIL.Progression.Family)
    case dictionaryCount
    case dictionaryIsEmpty
    case dictionarySubscriptGet
    case dictionarySubscriptSet
    case dictionaryRemoveValue
    case dictionaryLiteral
    case dictionaryMakeIterator
    case dictionaryIteratorNext
    case setCount
    case setIsEmpty
    case setEmpty
    case setContains
    case setInsert
    case setUpdate
    case setRemove
    case setPopFirst
    case setRemoveFirst
    case setReserveCapacity
    case setLiteral
    case setSequenceInit
    case setMakeIterator
    case setIteratorNext
    case setAlgebra(Bytecode.SetAlgebraOperation)
    case setFormAlgebra(Bytecode.SetAlgebraOperation)
    case setRelation(Bytecode.SetRelationOperation)
    case setRemoveAll
    case allocateUninitializedArray
    case finalizeUninitializedArray
    case assertionFailure

    init?(mangledName: String) {
        if let scalar = CanonicalSIL.ScalarIntrinsic(mangledName: mangledName) {
            self = .scalar(scalar)
            return
        }
        if let collection = CanonicalSIL.CollectionIntrinsic(
            mangledName: mangledName
        ) {
            self = .collection(collection)
            return
        }
        switch mangledName {
        case "$sSlsE3mapySayqd__Gqd__7ElementQzqd_0_YKXEqd_0_YKs5ErrorRd_0_r0_lF":
            self = .higherOrder(.map)
        case "$ss14_ArrayProtocolPsE6filterySay7ElementQzGSbAEKXEKF":
            self = .higherOrder(.filter)
        case "$sSTsE10compactMapySayqd__Gqd__Sg7ElementQzKXEKlF":
            self = .higherOrder(.compactMap)
        case "$sSTsE6reduceyqd__qd___qd__qd___7ElementQztKXEtKlF":
            self = .higherOrder(.reduce)
        case "$sSTsE7forEachyyy7ElementQzKXEKF":
            self = .higherOrder(.forEach)
        case "$sSTsE5first5where7ElementQzSgSbADKXE_tKF":
            self = .higherOrder(.firstWhere)
        case "$sSTsE8contains5whereS2b7ElementQzKXE_tKF":
            self = .higherOrder(.containsWhere)
        case "$sSTsE10allSatisfyyS2b7ElementQzKXEKF":
            self = .higherOrder(.allSatisfy)
        case "$sSq3mapyqd_0_Sgqd_0_xqd__YKXEqd__YKs5ErrorRd__Ri_d_0_r0_lF":
            self = .algebraic(.optional(.map))
        case "$sSq7flatMapyqd_0_SgABxqd__YKXEqd__YKs5ErrorRd__Ri_d_0_r0_lF":
            self = .algebraic(.optional(.flatMap))
        case "$ss6ResultO3mapyAByqd__q_Gqd__xXERi_d__lF":
            self = .algebraic(
                .result(case: .success, transformation: .map)
            )
        case "$ss6ResultOsRi_zRi0_zrlE8mapErroryAByxqd__Gqd__q_XEs0C0Rd__lF":
            self = .algebraic(
                .result(case: .failure, transformation: .map)
            )
        case "$ss6ResultO7flatMapyAByqd__q_GADxXERi_d__lF":
            self = .algebraic(
                .result(case: .success, transformation: .flatMap)
            )
        case "$ss6ResultOsRi_zrlE12flatMapErroryAByxqd__GADq_XEs0D0Rd__lF":
            self = .algebraic(
                .result(case: .failure, transformation: .flatMap)
            )
        case "$ss6ResultOsRi_zRi0_zrlE3getxyq_YKF":
            self = .algebraic(.resultGet)
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
        case "$sSS2peoiyySSz_SStFZ": self = .stringAppend
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
            self = .collectionMakeIterator(.collection)
        case "$ss18ReversedCollectionV12makeIteratorAB0D0Vyx_GyF":
            self = .collectionMakeIterator(.reversed)
        case "$ss18EnumeratedSequenceV12makeIteratorAB0D0Vyx_GyF":
            self = .collectionMakeIterator(.enumerated)
        case "$ss12Zip2SequenceV12makeIteratorAB0D0Vyxq__GyF":
            self = .collectionMakeIterator(.zipped)
        case "$ss15FlattenSequenceV12makeIteratorAB0D0Vyx_GyF":
            self = .collectionMakeIterator(.flattened)
        case "$ss14JoinedSequenceV12makeIteratorAB0D0Vyx_GyF":
            self = .collectionMakeIterator(.joined)
        case "$ss16IndexingIteratorV4next7ElementQzSgyF":
            self = .indexingIteratorNext(.collection)
        case "$ss18ReversedCollectionV8IteratorV4next7ElementQzSgyF":
            self = .indexingIteratorNext(.reversed)
        case "$ss18EnumeratedSequenceV8IteratorV4nextSi6offset_7ElementQz7elementtSgyF":
            self = .indexingIteratorNext(.enumerated)
        case "$ss12Zip2SequenceV8IteratorV4next7ElementQz_AFQy_tSgyF":
            self = .indexingIteratorNext(.zipped)
        case "$ss15FlattenSequenceV8IteratorV4next7Element_AFQZSgyF":
            self = .indexingIteratorNext(.flattened)
        case "$ss14JoinedSequenceV8IteratorV4next7Element_AFQZSgyF":
            self = .indexingIteratorNext(.joined)
        case "$ss6stride4from2to2bys8StrideToVyxGx_x0E0QztSxRzlF":
            self = .progressionConstructor(.strideTo)
        case "$ss6stride4from7through2bys13StrideThroughVyxGx_x0E0QztSxRzlF":
            self = .progressionConstructor(.strideThrough)
        case "$ss8StrideToV12makeIterators0abD0VyxGyF":
            self = .progressionMakeIterator(.strideTo)
        case "$ss13StrideThroughV12makeIterators0abD0VyxGyF":
            self = .progressionMakeIterator(.strideThrough)
        case "$ss16StrideToIteratorV4nextxSgyF":
            self = .progressionIteratorNext(.strideTo)
        case "$ss21StrideThroughIteratorV4nextxSgyF":
            self = .progressionIteratorNext(.strideThrough)
        case "$sSn8containsySbxF": self = .rangeContains(.range)
        case "$sSN8containsySbxF": self = .rangeContains(.closedRange)
        case "$sSD5countSivg": self = .dictionaryCount
        case "$sSD7isEmptySbvg": self = .dictionaryIsEmpty
        case "$sSDyq_Sgxcig": self = .dictionarySubscriptGet
        case "$sSDyq_Sgxcis": self = .dictionarySubscriptSet
        case "$sSD11removeValue6forKeyq_Sgx_tF": self = .dictionaryRemoveValue
        case "$sSD17dictionaryLiteralSDyxq_Gx_q_td_tcfC": self = .dictionaryLiteral
        case "$sSD12makeIteratorSD0B0Vyxq__GyF": self = .dictionaryMakeIterator
        case "$sSD8IteratorV4nextx3key_q_5valuetSgyF": self = .dictionaryIteratorNext
        case "$sSh5countSivg": self = .setCount
        case "$sSh7isEmptySbvg": self = .setIsEmpty
        case "$sS2hyxGycfC": self = .setEmpty
        case "$sSh8containsySbxF": self = .setContains
        case "$sSh6insertySb8inserted_x17memberAfterInserttxnF": self = .setInsert
        case "$sSh6update4withxSgxn_tF": self = .setUpdate
        case "$sSh6removeyxSgxF": self = .setRemove
        case "$sSh8popFirstxSgyF": self = .setPopFirst
        case "$sSh11removeFirstxyF": self = .setRemoveFirst
        case "$sSh15reserveCapacityyySiF": self = .setReserveCapacity
        case "$sSh12arrayLiteralShyxGxd_tcfC": self = .setLiteral
        case "$sShyShyxGqd__nc7ElementQyd__RszSTRd__lufC": self = .setSequenceInit
        case "$sSh12makeIteratorSh0B0Vyx_GyF": self = .setMakeIterator
        case "$sSh8IteratorV4nextxSgyF": self = .setIteratorNext
        case "$sSh5unionyShyxGqd__n7ElementQyd__RszSTRd__lF":
            self = .setAlgebra(.union)
        case "$sSh12intersectionyShyxGABF": self = .setAlgebra(.intersection)
        case "$sSh11subtractingyShyxGABF": self = .setAlgebra(.subtracting)
        case "$sSh19symmetricDifferenceyShyxGqd__n7ElementQyd__RszSTRd__lF":
            self = .setAlgebra(.symmetricDifference)
        case "$sSh9formUnionyyqd__n7ElementQyd__RszSTRd__lF":
            self = .setFormAlgebra(.union)
        case "$sSh16formIntersectionyyqd__7ElementQyd__RszSTRd__lF":
            self = .setFormAlgebra(.intersection)
        case "$sSh8subtractyyShyxGF": self = .setFormAlgebra(.subtracting)
        case "$sSh8subtractyyqd__7ElementQyd__RszSTRd__lF":
            self = .setFormAlgebra(.subtracting)
        case "$sSh23formSymmetricDifferenceyyShyxGnF":
            self = .setFormAlgebra(.symmetricDifference)
        case "$sSh23formSymmetricDifferenceyyqd__n7ElementQyd__RszSTRd__lF":
            self = .setFormAlgebra(.symmetricDifference)
        case "$sSh2eeoiySbShyxG_ABtFZ": self = .setRelation(.equal)
        case "$sSh8isSubset2ofSbShyxG_tF": self = .setRelation(.subset)
        case "$sSh14isStrictSubset2ofSbShyxG_tF": self = .setRelation(.strictSubset)
        case "$sSh10isSuperset2ofSbShyxG_tF": self = .setRelation(.superset)
        case "$sSh16isStrictSuperset2ofSbShyxG_tF": self = .setRelation(.strictSuperset)
        case "$sSh10isDisjoint4withSbShyxG_tF": self = .setRelation(.disjoint)
        case "$sSh9removeAll15keepingCapacityySb_tF": self = .setRemoveAll
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
