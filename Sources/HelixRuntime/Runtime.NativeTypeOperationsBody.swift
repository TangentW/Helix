import HelixVM

extension Runtime {
/// Retained box exported by a trusted development Adapter image.
///
/// `VM.NativeTypeOperations` is a value containing concrete Swift closures;
/// retaining this box keeps both those closures and their mapped image alive
/// for the process lifetime after the C factory boundary returns.
public final class NativeTypeOperationsBody: Sendable {
    public let operations: VM.NativeTypeOperations

    public init(_ operations: VM.NativeTypeOperations) {
        self.operations = operations
    }

    public static func takeRetained(
        _ pointer: UnsafeMutableRawPointer?
    ) throws -> Runtime.NativeTypeOperationsBody {
        guard let pointer else {
            throw VM.RuntimeTrap.nativeFailure(
                "development Adapter returned no native TypeOps"
            )
        }
        return Unmanaged<Runtime.NativeTypeOperationsBody>
            .fromOpaque(pointer).takeRetainedValue()
    }
}
}
