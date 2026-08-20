extension CanonicalSIL {
/// Dictionary construction and merging share one semantic shape: choose a
/// seed, traverse represented elements, invoke a concrete callback when the
/// operation requires it, and update one verified accumulator.
struct DictionaryAccumulationIntrinsic: Equatable {
    enum Source: Equatable {
        case dictionaryPairs
        case sequencePairs
        case sequenceElements
    }

    enum Seed: Equatable {
        case ownedDictionary
        case inoutDictionary
        case empty
    }

    enum Callback: Equatable {
        case combineValues
        case classifyElement
    }

    var source: Source
    var seed: Seed
    var callback: Callback

    private init(source: Source, seed: Seed, callback: Callback) {
        self.source = source
        self.seed = seed
        self.callback = callback
    }

    init?(mangledName: String) {
        switch mangledName {
        case "$sSD7merging_16uniquingKeysWithSDyxq_GACn_q_q__q_tKXEtKF":
            self.init(
                source: .dictionaryPairs,
                seed: .ownedDictionary,
                callback: .combineValues
            )
        case "$sSD7merging_16uniquingKeysWithSDyxq_Gqd__n_q_q__q_tKXEtKSTRd__x_q_t7ElementRtd__lF":
            self.init(
                source: .sequencePairs,
                seed: .ownedDictionary,
                callback: .combineValues
            )
        case "$sSD5merge_16uniquingKeysWithySDyxq_Gn_q_q__q_tKXEtKF":
            self.init(
                source: .dictionaryPairs,
                seed: .inoutDictionary,
                callback: .combineValues
            )
        case "$sSD5merge_16uniquingKeysWithyqd__n_q_q__q_tKXEtKSTRd__x_q_t7ElementRtd__lF":
            self.init(
                source: .sequencePairs,
                seed: .inoutDictionary,
                callback: .combineValues
            )
        case "$sSD_16uniquingKeysWithSDyxq_Gqd__n_q_q__q_tKXEtKcSTRd__x_q_t7ElementRtd__lufC":
            self.init(
                source: .sequencePairs,
                seed: .empty,
                callback: .combineValues
            )
        case "$sSD8grouping2bySDyxSay7ElementQyd__GGqd__n_xADKXEtKcAERs_STRd__lufC":
            self.init(
                source: .sequenceElements,
                seed: .empty,
                callback: .classifyElement
            )
        default:
            return nil
        }
    }
}
}
