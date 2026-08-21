import Foundation

extension Core {
/// The lifetime a NativeImport is permitted to give one VM closure.
public enum NativeImportCallbackLifetime: String, Codable, Hashable, Sendable,
    CaseIterable
{
    /// The callback is valid only until the importing native operation returns.
    case nonescaping
    /// The callback may be retained and invoked after the importing operation returns.
    case escaping
}

/// Identifies a callback-bearing NativeImport parameter and its lifetime contract.
///
/// Callback parameters are sparse because ordinary frozen-value parameters remain
/// the common case. The parameter index is part of the native import identity so
/// generated adapters cannot silently strengthen a nonescaping lifetime.
public struct NativeImportCallback: Codable, Hashable, Sendable, Comparable {
    public var parameterIndex: UInt16
    public var lifetime: Core.NativeImportCallbackLifetime

    public init(
        parameterIndex: UInt16,
        lifetime: Core.NativeImportCallbackLifetime
    ) {
        self.parameterIndex = parameterIndex
        self.lifetime = lifetime
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parameterIndex < rhs.parameterIndex
    }
}
}
