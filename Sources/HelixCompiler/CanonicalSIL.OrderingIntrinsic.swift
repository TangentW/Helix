extension CanonicalSIL {
/// Array ordering operations share one lowering family even though Swift
/// exposes them across Sequence and MutableCollection protocol extensions.
enum OrderingIntrinsic: Equatable {
    case sorted
    case sortedBy
    case sort
    case sortBy

    var usesClosure: Bool {
        switch self {
        case .sorted, .sort: false
        case .sortedBy, .sortBy: true
        }
    }

    var mutatesSource: Bool {
        switch self {
        case .sorted, .sortedBy: false
        case .sort, .sortBy: true
        }
    }
}
}
