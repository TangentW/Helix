extension CanonicalSIL {
enum ValueMutationIntrinsic: Equatable {
    case logicalToggle
    case exchange

    init?(mangledName: String) {
        switch mangledName {
        case "$sSb6toggleyyF":
            self = .logicalToggle
        case "$ss4swapyyxz_xztlF":
            self = .exchange
        default:
            return nil
        }
    }
}
}
