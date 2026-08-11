import HelixCore

extension CanonicalSIL {
/// Stable synthetic symbols used to bind class storage projections to exact
/// getter and setter NativeImports. They are build-time identities only and
/// are never resolved through `dlsym` or the Swift runtime.
public enum NativePropertySymbol {
    public static func getter(ownerType: String, property: String) -> String {
        symbol(operation: "get", ownerType: ownerType, property: property)
    }

    public static func setter(ownerType: String, property: String) -> String {
        symbol(operation: "set", ownerType: ownerType, property: property)
    }

    private static func symbol(
        operation: String,
        ownerType: String,
        property: String
    ) -> String {
        let identity = Core.Digest.sha256(
            "HLX.NativeProperty.v1:\(ownerType).\(property)"
        )
        return "$hlx_property_\(operation)_\(identity.hex)"
    }
}
}
