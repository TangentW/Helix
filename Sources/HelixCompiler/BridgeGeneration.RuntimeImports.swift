extension BridgeGeneration {
/// Runtime imports emitted into hidden Bridge sources.
///
/// Hub exposes one production module plus one configuration-scoped development
/// module. The leaf-module form is used only by the compiler's isolated source
/// validation; it is not an alternative application integration contract.
package enum RuntimeImports {
    package static let production = """
    #if canImport(HelixBytecode) && canImport(HelixCore) && canImport(HelixPatch) && canImport(HelixRuntime) && canImport(HelixVerifier) && canImport(HelixVM)
    import HelixBytecode
    import HelixCore
    import HelixPatch
    import HelixRuntime
    import HelixVerifier
    import HelixVM
    #elseif canImport(HelixAppIntegration)
    import HelixAppIntegration
    #else
    #error("HelixAppIntegration is unavailable to the generated Helix Bridge")
    #endif
    """

    package static let development = """
    #if canImport(HelixCore) && canImport(HelixDevProtocol) && canImport(HelixDevRuntime)
    import HelixCore
    import HelixDevProtocol
    import HelixDevRuntime
    #elseif canImport(HelixDevSupport)
    import HelixDevSupport
    #else
    #error("Helix Debug support is unavailable to the generated development contract")
    #endif
    """

    package static var productionLines: [String] {
        production.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
}
