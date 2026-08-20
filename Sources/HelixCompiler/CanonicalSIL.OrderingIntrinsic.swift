extension CanonicalSIL {
/// Sequence ordering operations share one lowering family. Nonmutating forms
/// accept every represented managed Collection; mutating forms remain limited
/// to zero-based Array storage.
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
