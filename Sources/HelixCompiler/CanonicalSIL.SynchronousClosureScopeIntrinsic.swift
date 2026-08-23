extension CanonicalSIL {
/// Standard-library operations whose semantics are a synchronous invocation
/// of one closure while another value or lifetime rule remains in scope.
/// Their generic Swift bodies are compiler implementation details, so Helix
/// lowers the semantic operation instead of freezing a runtime symbol.
enum SynchronousClosureScopeIntrinsic: Equatable {
    case extendedLifetime

    init?(mangledName: String) {
        guard mangledName
            == "$ss20withExtendedLifetimeyq0_x_q0_yq_YKXEtq_YKs5ErrorR_Ri_zRi0_zRi_0_r1_lF"
        else {
            return nil
        }
        self = .extendedLifetime
    }
}
}
