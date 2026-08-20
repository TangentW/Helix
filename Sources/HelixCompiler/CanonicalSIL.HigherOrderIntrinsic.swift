import HelixBytecode

extension CanonicalSIL {
enum HigherOrderIntrinsic: Equatable {
    case map
    case flatMap
    case filter
    case compactMap
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

    var usesArrayBuilder: Bool {
        switch self {
        case .map, .flatMap, .filter, .compactMap, .prefixWhile, .dropWhile:
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
        case .filter, .firstWhere, .lastWhere, .prefixWhile, .dropWhile,
             .minimumBy, .maximumBy:
            true
        case .map, .flatMap, .compactMap, .reduce, .reduceInto, .forEach,
             .firstIndexWhere, .lastIndexWhere, .containsWhere,
             .allSatisfy:
            false
        }
    }

    var traversalDirection: Bytecode.CollectionTraversalDirection {
        switch self {
        case .lastWhere, .lastIndexWhere:
            .reverse
        case .map, .flatMap, .filter, .compactMap, .prefixWhile,
             .dropWhile, .reduce, .reduceInto, .forEach, .firstWhere,
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
