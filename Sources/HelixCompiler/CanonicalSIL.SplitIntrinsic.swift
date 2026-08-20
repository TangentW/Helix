extension CanonicalSIL {
/// The two `Collection.split` entry points share one state-machine lowering;
/// only the source of the separator decision differs.
enum SplitIntrinsic: Equatable {
    case separator
    case predicate

    var usesClosure: Bool {
        switch self {
        case .separator: false
        case .predicate: true
        }
    }
}
}
