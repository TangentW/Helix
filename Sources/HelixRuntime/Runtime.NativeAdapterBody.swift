import HelixBytecode
import HelixCore
import HelixVM

extension Runtime {
/// Project-independent executable body exported by a trusted Swift Adapter
/// Pack. Release-specific IDs and execution policy stay in the main Bridge so
/// one compiled Pack can be shared across applications.
public final class NativeAdapterBody: Sendable {
    public typealias Invocation = @Sendable (
        [VM.Value],
        VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult

    private let invocation: Invocation

    public init(invoke: @escaping Invocation) {
        invocation = invoke
    }

    public func makeInvoker(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        contract: Core.NativeImportContract
    ) -> any VM.NativeInvoker {
        let body = self
        return VM.ClosureNativeInvoker(
            id: id,
            key: key,
            parameterTypes: parameterTypes,
            resultType: resultType,
            effects: effects,
            contract: contract,
            invoke: { arguments, context in
                try body.invocation(arguments, context)
            }
        )
    }

    public static func takeRetained(
        _ pointer: UnsafeMutableRawPointer?
    ) throws -> Runtime.NativeAdapterBody {
        guard let pointer else {
            throw VM.RuntimeTrap.nativeFailure(
                "linked Swift Adapter Pack returned no invocation body"
            )
        }
        return Unmanaged<Runtime.NativeAdapterBody>
            .fromOpaque(pointer).takeRetainedValue()
    }
}

public final class AsyncNativeAdapterBody: Sendable {
    public typealias Invocation = @Sendable (
        [VM.Value],
        VM.NativeInvocationContext
    ) async throws -> VM.NativeInvocationResult

    private let invocation: Invocation

    public init(invoke: @escaping Invocation) {
        invocation = invoke
    }

    public func makeInvoker(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        contract: Core.NativeImportContract
    ) -> any VM.AsyncNativeInvoker {
        let body = self
        return VM.ClosureAsyncNativeInvoker(
            id: id,
            key: key,
            parameterTypes: parameterTypes,
            resultType: resultType,
            effects: effects,
            contract: contract,
            invoke: { arguments, context in
                try await body.invocation(arguments, context)
            }
        )
    }

    public static func takeRetained(
        _ pointer: UnsafeMutableRawPointer?
    ) throws -> Runtime.AsyncNativeAdapterBody {
        guard let pointer else {
            throw VM.RuntimeTrap.nativeFailure(
                "linked async Swift Adapter Pack returned no invocation body"
            )
        }
        return Unmanaged<Runtime.AsyncNativeAdapterBody>
            .fromOpaque(pointer).takeRetainedValue()
    }
}
}
