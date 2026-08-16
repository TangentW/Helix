extension CanonicalSIL {
enum HigherOrderIntrinsic: Equatable {
    case map
    case flatMap
    case filter
    case compactMap
    case prefixWhile
    case dropWhile
    case reduce
    case forEach
    case firstWhere
    case firstIndexWhere
    case containsWhere
    case allSatisfy

    var usesArrayBuilder: Bool {
        switch self {
        case .map, .flatMap, .filter, .compactMap, .prefixWhile, .dropWhile:
            true
        case .reduce, .forEach, .firstWhere, .firstIndexWhere,
             .containsWhere, .allSatisfy:
            false
        }
    }

    /// The original element must survive an owned closure argument when the
    /// operation uses it again after the closure returns.
    var retainsInputAfterCall: Bool {
        switch self {
        case .filter, .firstWhere, .prefixWhile, .dropWhile:
            true
        case .map, .flatMap, .compactMap, .reduce, .forEach,
             .firstIndexWhere, .containsWhere, .allSatisfy:
            false
        }
    }
}
}
