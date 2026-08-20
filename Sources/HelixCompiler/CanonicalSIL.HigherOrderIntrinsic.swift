import HelixBytecode

extension CanonicalSIL {
enum HigherOrderIntrinsic: Equatable {
    enum FilterResult: Equatable {
        case array
        case set
        case dictionary
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
    case minimumBy
    case maximumBy

    var usesElementBuilder: Bool {
        switch self {
        case .map, .flatMap, .filter(_), .compactMap, .mapValues,
             .compactMapValues, .prefixWhile, .dropWhile:
            true
        case .reduce, .reduceInto, .forEach, .firstWhere, .lastWhere,
             .firstIndexWhere, .lastIndexWhere, .containsWhere,
             .allSatisfy, .minimumBy, .maximumBy:
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
             .lastIndexWhere, .containsWhere, .allSatisfy:
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
             .firstIndexWhere, .containsWhere, .allSatisfy,
             .minimumBy, .maximumBy:
            .forward
        }
    }

    var isComparatorSelection: Bool {
        self == .minimumBy || self == .maximumBy
    }
}
}
