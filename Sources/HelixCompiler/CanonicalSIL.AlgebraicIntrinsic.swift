extension CanonicalSIL {
enum AlgebraicIntrinsic: Equatable {
    enum Transformation: Equatable {
        /// The closure produces a payload that is wrapped in the selected case.
        case map

        /// The closure produces the complete output container.
        case flatMap
    }

    enum ResultCase: String, Equatable {
        case success
        case failure

        var opposite: Self {
            switch self {
            case .success: .failure
            case .failure: .success
            }
        }
    }

    /// Optional transformations always select `.some`; `.none` passes through.
    case optional(Transformation)

    /// Result transformations select one payload case and pass the other through.
    case result(case: ResultCase, transformation: Transformation)

    /// Projects `.success` to the normal edge and `.failure` to the error edge.
    case resultGet
}
}
