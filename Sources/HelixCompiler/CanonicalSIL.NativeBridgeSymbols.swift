import HelixCore

extension CanonicalSIL {
/// Stable pseudo-symbols for compiler operations materialized as NativeImports.
/// They are frozen into the Shell just like real SIL symbols and never resolved
/// dynamically on the device.
public enum NativeBridgeSymbols {
    private static let foreignCallPrefix = "$hlx_native_foreign_"
    private static let foreignDeclarationMarker = "_decl_"

    public enum ForeignDispatch: String, Codable, Hashable, Sendable {
        case ordinary
        case superclass
    }

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
        dispatch: ForeignDispatch = .ordinary,
        genericArguments: [String] = []
    ) -> String {
        var hasher = Core.StableHasher(domain: "HLX.NativeForeignCall.v1")
        hasher.append(reference)
        hasher.append(loweredType)
        hasher.append(dispatch.rawValue)
        if !genericArguments.isEmpty {
            hasher.append("generic-specialization")
            for argument in genericArguments {
                hasher.append(argument.filter { !$0.isWhitespace })
            }
        }
        return "$hlx_native_foreign_" + hasher.finalize().hex
    }

    /// Qualifies a textual SIL foreign-call shape with the exact Clang
    /// declaration selected by the typed frontend. SIL printing can erase the
    /// distinction between Objective-C methods that share one Swift base name
    /// and physical ABI but use different selectors, so the raw pseudo-symbol
    /// alone is not sufficient compilation authority.
    public static func declarationQualifiedForeignCall(
        symbol: String,
        declarationUSR: String
    ) -> String {
        guard isUnqualifiedForeignCall(symbol),
              declarationUSR.hasPrefix("c:objc(")
        else { return symbol }
        var hasher = Core.StableHasher(
            domain: "HLX.NativeForeignDeclaration.v1"
        )
        hasher.append(declarationUSR)
        return symbol + foreignDeclarationMarker + hasher.finalize().hex
    }

    public static func isDeclarationQualifiedForeignCall(
        _ symbol: String
    ) -> Bool {
        guard symbol.hasPrefix(foreignCallPrefix),
              let marker = symbol.range(of: foreignDeclarationMarker),
              marker.lowerBound > symbol.startIndex
        else { return false }
        let digestStart = symbol.index(
            symbol.startIndex,
            offsetBy: foreignCallPrefix.count
        )
        let rawDigest = symbol[digestStart..<marker.lowerBound]
        let declarationDigest = symbol[marker.upperBound...]
        return rawDigest.count == 64
            && declarationDigest.count == 64
            && rawDigest.allSatisfy { $0.isLowercaseHexDigit }
            && declarationDigest.allSatisfy { $0.isLowercaseHexDigit }
    }

    private static func isUnqualifiedForeignCall(_ symbol: String) -> Bool {
        guard symbol.hasPrefix(foreignCallPrefix) else { return false }
        let digest = symbol.dropFirst(foreignCallPrefix.count)
        return digest.count == 64
            && digest.allSatisfy { $0.isLowercaseHexDigit }
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

private extension Character {
    var isLowercaseHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
}
