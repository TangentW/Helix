extension CanonicalSIL {
enum RangeIntrinsic: Equatable {
    case overlaps
    case clamped

    init?(mangledName: String) {
        switch mangledName {
        case "$sSn8overlapsySbSnyxGF":
            self = .overlaps
        case "$sSn7clamped2toSnyxGAC_tF":
            self = .clamped
        default:
            return nil
        }
    }
}
}
