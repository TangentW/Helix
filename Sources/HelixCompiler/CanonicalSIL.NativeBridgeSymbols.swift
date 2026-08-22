import HelixCore

extension CanonicalSIL {
/// Stable pseudo-symbols for compiler operations materialized as NativeImports.
/// They are frozen into the Shell just like real SIL symbols and never resolved
/// dynamically on the device.
public enum NativeBridgeSymbols {
    public static func rawValueInitializer(for type: Core.TypeID) -> String {
        "$hlx_native_raw_init_\(type.rawValue.hex)"
    }

    public static func upcast(from source: Core.TypeID, to target: Core.TypeID) -> String {
        "$hlx_native_upcast_\(source.rawValue.hex)_\(target.rawValue.hex)"
    }

    public static func anyObjectBridge(to target: Core.TypeID) -> String {
        "$hlx_native_any_object_bridge_\(target.rawValue.hex)"
    }

    /// Identifies one exact imported Objective-C dispatch shape. A selector
    /// alone is insufficient because Clang importers may expose overloads with
    /// the same SIL member reference but different lowered ABI signatures.
    public static func foreignCall(
        reference: String,
        loweredType: String,
        genericArguments: [String] = []
    ) -> String {
        var hasher = Core.StableHasher(domain: "HLX.NativeForeignCall.v1")
        hasher.append(reference)
        hasher.append(loweredType)
        if !genericArguments.isEmpty {
            hasher.append("generic-specialization")
            for argument in genericArguments {
                hasher.append(argument.filter { !$0.isWhitespace })
            }
        }
        return "$hlx_native_foreign_" + hasher.finalize().hex
    }

    public static let optionSetArrayLiteralUSR =
        "s:s10SetAlgebraPs7ElementQz012ArrayLiteralC0RtzrlE05arrayE0xAFd_tcfc"
    public static let optionSetArrayLiteralSILSymbol =
        "$ss10SetAlgebraPs7ElementQz012ArrayLiteralC0RtzrlE05arrayE0xAFd_tcfC"

    public static func optionSetArrayLiteralInitializer(
        for type: Core.TypeID
    ) -> String {
        "$hlx_native_option_set_literal_\(type.rawValue.hex)"
    }

    public static func selectorInitializer(for type: Core.TypeID) -> String {
        "$hlx_native_selector_init_\(type.rawValue.hex)"
    }

    public static func importedGlobal(symbol: String, loweredType: String) -> String {
        var hasher = Core.StableHasher(domain: "HLX.NativeImportedGlobal.v1")
        hasher.append(symbol)
        hasher.append(loweredType)
        return "$hlx_native_global_" + hasher.finalize().hex
    }
}
}
