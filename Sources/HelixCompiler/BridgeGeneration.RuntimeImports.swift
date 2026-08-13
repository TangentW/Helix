extension BridgeGeneration {
/// Runtime imports emitted into hidden Bridge sources.
///
/// Swift Package Manager exposes Helix as leaf modules, while CocoaPods exposes
/// one aggregate App-facing module. Generated source selects the available
/// shape at compile time so the Bridge stays invisible to application code.
package enum RuntimeImports {
    package static let production = """
    #if canImport(HelixBytecode) && canImport(HelixCore) && canImport(HelixPatch) && canImport(HelixRuntime) && canImport(HelixVerifier) && canImport(HelixVM)
    import HelixBytecode
    import HelixCore
    import HelixPatch
    import HelixRuntime
    import HelixVerifier
    import HelixVM
    #elseif canImport(HelixDevAppRuntime)
    import HelixDevAppRuntime
    #elseif canImport(HelixAppRuntime)
    import HelixAppRuntime
    #else
    #error("Link HelixAppRuntime or HelixDevAppRuntime before compiling the generated Helix Bridge")
    #endif
    """

    package static let development = """
    #if canImport(HelixCore) && canImport(HelixDevProtocol) && canImport(HelixDevRuntime)
    import HelixCore
    import HelixDevProtocol
    import HelixDevRuntime
    #elseif canImport(HelixDevAppRuntime)
    import HelixDevAppRuntime
    #else
    #error("Link HelixDevAppRuntime before compiling the generated Helix development contract")
    #endif
    """

    package static var productionLines: [String] {
        production.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
}
