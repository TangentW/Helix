import HelixBytecode

extension CanonicalSIL {
enum HigherOrderIntrinsic: Equatable {
    enum FilterResult: Equatable {
        case array
        case set
        case dictionary
        /// RangeReplaceableCollection.filter returns Self. The concrete
        /// representation decides how the shared element builder is finalized.
        case rangeReplaceableCollection
    }

    case map
    case flatMap
    case filter(FilterResult)
    case compactMap
    case mapValues
    case compactMapValues
    case prefixWhile
    case dropWhile
    case reduce
    case reduceInto
    case forEach
    case firstWhere
    case lastWhere
    case firstIndexWhere
    case lastIndexWhere
    case containsWhere
    case allSatisfy
    case countWhere
    case minimumBy
    case maximumBy

    var usesElementBuilder: Bool {
        switch self {
        case .map, .flatMap, .filter(_), .compactMap, .mapValues,
             .compactMapValues, .prefixWhile, .dropWhile:
            true
        case .reduce, .reduceInto, .forEach, .firstWhere, .lastWhere,
             .firstIndexWhere, .lastIndexWhere, .containsWhere,
             .allSatisfy, .countWhere, .minimumBy, .maximumBy:
            false
        }
    }

    /// The original element must survive an owned closure argument when the
    /// operation uses it again after the closure returns.
    var retainsInputAfterCall: Bool {
        switch self {
        case .filter(_), .firstWhere, .lastWhere, .prefixWhile, .dropWhile,
             .minimumBy, .maximumBy:
            true
        case .map, .flatMap, .compactMap, .mapValues, .compactMapValues,
             .reduce, .reduceInto, .forEach, .firstIndexWhere,
             .lastIndexWhere, .containsWhere, .allSatisfy, .countWhere:
            false
        }
    }

    var traversalDirection: Bytecode.CollectionTraversalDirection {
        switch self {
        case .lastWhere, .lastIndexWhere:
            .reverse
        case .map, .flatMap, .filter(_), .compactMap, .mapValues,
             .compactMapValues, .prefixWhile, .dropWhile, .reduce,
             .reduceInto, .forEach, .firstWhere,
             .firstIndexWhere, .containsWhere, .allSatisfy, .countWhere,
             .minimumBy, .maximumBy:
            .forward
        }
    }

    var isComparatorSelection: Bool {
        self == .minimumBy || self == .maximumBy
    }

    /// Newer typed-throws stdlib entry points carry their concrete error type
    /// as an explicit substitution. Older rethrows entry points do not.
    var explicitErrorGenericIndex: Int? {
        switch self {
        case .map: 2
        case .countWhere: 1
        case .flatMap, .filter(_), .compactMap, .mapValues,
             .compactMapValues, .prefixWhile, .dropWhile, .reduce,
             .reduceInto, .forEach, .firstWhere, .lastWhere,
             .firstIndexWhere, .lastIndexWhere, .containsWhere,
             .allSatisfy, .minimumBy, .maximumBy:
            nil
        }
    }
}
}
