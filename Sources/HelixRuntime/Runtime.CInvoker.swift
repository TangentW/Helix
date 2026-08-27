import Foundation
import HelixCRuntimeSupport
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Reusable invoker for compiler-bound C function pointers. A finite AOT
/// trampoline matrix executes common scalar and Apple geometry ABI shapes;
/// unsupported shapes retain their exact Swift Adapter.
public struct CInvoker: VM.NativeInvoker {
    public let id: Core.NativeImportID
    public let key: Core.NativeCall.Key
    public let parameterTypes: [Bytecode.ValueType]
    public let resultType: Bytecode.ValueType
    public let effects: Core.Effects
    public let contract: Core.NativeImportContract

    let descriptor: Core.NativeCall.Descriptor
    let functionAddress: UInt
    let environment: Runtime.NativeEnvironment
    let constructionFailure: String?

    public init(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        function: UnsafeRawPointer,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        environment: Runtime.NativeEnvironment = .current
    ) {
        self.id = id
        self.key = key
        self.descriptor = descriptor
        functionAddress = UInt(bitPattern: function)
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.effects = effects
        self.contract = contract
        self.environment = environment
        constructionFailure = Self.validate(
            key: key,
            descriptor: descriptor,
            parameterTypes: parameterTypes,
            resultType: resultType,
            effects: effects,
            contract: contract,
            functionAddress: functionAddress
        )
    }

    public func invoke(
        arguments: [VM.Value],
        context: VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult {
        guard constructionFailure == nil else {
            throw VM.RuntimeTrap.nativeFailure(constructionFailure!)
        }
        guard VM.NativeInvocationABI.argumentsAreCompatible(
            arguments,
            with: parameterTypes,
            callbackParameterIndices: Set(
                contract.callbacks.map { Int($0.parameterIndex) }
            )
        )
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "C invocation arguments disagree with verified types"
            )
        }
        try checkAvailability()
        if effects.requiresMainActor {
            return try context.withMainActor {
                try invokeNative(arguments: arguments, context: context)
            }
        }
        try context.checkpoint(workUnits: UInt64(arguments.count + 1))
        return try invokeNative(arguments: arguments, context: context)
    }
}
}

extension Runtime.CInvoker {
private func checkAvailability() throws {
    guard let item = descriptor.availability.first(where: {
        $0.platform == environment.platform
    }) else { return }
    guard !item.isUnavailable,
          item.introduced.map({ environment.version >= $0 }) ?? true,
          item.obsoleted.map({ environment.version < $0 }) ?? true
    else {
        throw VM.RuntimeTrap.nativeFailure(
            "\(descriptor.canonicalCallee) is unavailable on "
                + "\(environment.platform) \(environment.version) [\(key)]"
        )
    }
}

private func invokeNative(
    arguments: [VM.Value],
    context: VM.NativeInvocationContext
) throws -> VM.NativeInvocationResult {
    let signature = descriptor.physicalSignature
    let temporaryByteCount = signature.parameters.reduce(
        UInt64(signature.result.size ?? 0)
    ) { $0 + UInt64($1.type.size ?? 0) }
        + UInt64(signature.parameters.compactMap(\.type.encoding)
            .reduce(0) { $0 + $1.utf8.count + 1 })
        + UInt64((signature.result.encoding ?? "v").utf8.count + 1)
    let byteCeiling = min(
        context.resourceLimits.maxNativeOwnedBytes,
        UInt64(1 * 1_024 * 1_024)
    )
    guard temporaryByteCount <= byteCeiling else {
        throw VM.RuntimeTrap.nativeFailure(
            "C temporary ABI storage exceeds its invocation limit"
        )
    }
    try context.checkpoint(
        workUnits: UInt64(signature.parameters.count + 1)
            + temporaryByteCount / 64
    )

    let storage = try zip(arguments, signature.parameters).map {
        try Runtime.NativeABIValue.encode(
            $0.0,
            as: $0.1.type,
            catalog: context.nativeTypeCatalog
        )
    }
    let encodings = signature.parameters.map {
        Runtime.NativeABIValue.CString($0.type.encoding!)
    }
    let cArguments = zip(storage, encodings).map { value, encoding in
        HelixRuntimeCArgument(
            encoding: UnsafePointer(encoding.pointer),
            bytes: UnsafeRawPointer(value.pointer),
            byte_count: value.byteCount
        )
    }
    let resultSize = Int(signature.result.size ?? 0)
    let resultStorage = Runtime.NativeABIValue.Allocation(
        byteCount: resultSize,
        alignment: Int(signature.result.alignment ?? 1)
    )
    let resultEncoding = Runtime.NativeABIValue.CString(
        signature.result.encoding ?? "v"
    )
    guard let function = UnsafeRawPointer(bitPattern: functionAddress) else {
        throw VM.RuntimeTrap.nativeFailure(
            "C function address became invalid [\(key)]"
        )
    }
    var nativeResult = HelixRuntimeCResult()
    let succeeded = cArguments.withUnsafeBufferPointer { buffer in
        helix_runtime_c_invoke(
            function,
            buffer.baseAddress,
            buffer.count,
            resultEncoding.pointer,
            resultStorage.pointer,
            resultStorage.byteCount,
            &nativeResult
        )
    }
    guard succeeded, nativeResult.status == HelixRuntimeCStatusSuccess else {
        throw VM.RuntimeTrap.nativeFailure(
            "\(message(from: &nativeResult)) [\(key)]"
        )
    }
    let expectedResultSize = resultType == .void ? 0 : resultSize
    guard nativeResult.result_byte_count == expectedResultSize,
          nativeResult.result_byte_count <= resultStorage.byteCount
    else {
        throw VM.RuntimeTrap.nativeFailure(
            "C result storage disagrees with its cataloged ABI [\(key)]"
        )
    }
    try context.checkResultEncodingDeadline()
    let bytes = Data(
        bytes: resultStorage.pointer,
        count: nativeResult.result_byte_count
    )
    return .returned(try Runtime.NativeABIValue.decode(
        bytes,
        physical: signature.result,
        logical: resultType,
        catalog: context.nativeTypeCatalog
    ))
}

private func message(from result: inout HelixRuntimeCResult) -> String {
    withUnsafePointer(to: &result.message) { pointer in
        pointer.withMemoryRebound(
            to: CChar.self,
            capacity: Int(HelixRuntimeCMessageCapacity)
        ) {
            String(cString: $0)
        }
    }
}
}
