import HelixVM

extension Runtime {
/// Immutable native execution tables pinned to one materialized generation.
///
/// Production generations normally use the Engine's linked baseline. A trusted
/// development transaction may instead attach a full baseline-plus-session
/// snapshot. This keeps a callback created by an older generation bound to the
/// exact invokers it was verified against while later sessions continue to grow.
public struct NativeCapabilities: Sendable {
    public var nativeCatalog: VM.NativeCatalog
    public var asyncNativeCatalog: VM.AsyncNativeCatalog
    public var nativeTypeCatalog: VM.NativeTypeCatalog

    public init(
        nativeCatalog: VM.NativeCatalog,
        asyncNativeCatalog: VM.AsyncNativeCatalog,
        nativeTypeCatalog: VM.NativeTypeCatalog
    ) {
        self.nativeCatalog = nativeCatalog
        self.asyncNativeCatalog = asyncNativeCatalog
        self.nativeTypeCatalog = nativeTypeCatalog
    }

    public func appending(
        nativeInvokers: [any VM.NativeInvoker] = [],
        asyncNativeInvokers: [any VM.AsyncNativeInvoker] = [],
        nativeTypeOperations: [VM.NativeTypeOperations] = []
    ) throws -> Runtime.NativeCapabilities {
        try .init(
            nativeCatalog: nativeCatalog.appending(nativeInvokers),
            asyncNativeCatalog: asyncNativeCatalog.appending(
                asyncNativeInvokers
            ),
            nativeTypeCatalog: nativeTypeCatalog.appending(
                nativeTypeOperations
            )
        )
    }
}
}
