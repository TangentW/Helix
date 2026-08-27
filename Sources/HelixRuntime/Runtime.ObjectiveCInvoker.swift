import Foundation
import HelixObjectiveCRuntimeSupport
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
#endif

extension Runtime {
/// One catalog-restricted Objective-C entry point shared by every supported
/// selector. The Objective-C shim owns ABI validation and exception capture;
/// this layer owns typed VM projection, resource limits, and callbacks.
public struct ObjectiveCInvoker: VM.NativeInvoker {
    public let id: Core.NativeImportID
    public let key: Core.NativeCall.Key
    public let parameterTypes: [Bytecode.ValueType]
    public let resultType: Bytecode.ValueType
    public let effects: Core.Effects
    public let contract: Core.NativeImportContract

    let descriptor: Core.NativeCall.Descriptor
    let environment: Runtime.NativeEnvironment
    let constructionFailure: String?

    public init(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        environment: Runtime.NativeEnvironment = .current
    ) {
        self.id = id
        self.key = key
        self.descriptor = descriptor
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
            contract: contract
        )
    }

    /// Builds the shared Objective-C execution path directly from the exact
    /// descriptor already authenticated by the Shell.
    public init(shellImport: Verification.ResolvedNativeImport) {
        self.init(
            id: shellImport.id,
            key: shellImport.key,
            descriptor: shellImport.descriptor,
            parameterTypes: shellImport.parameterTypes,
            resultType: shellImport.resultType,
            effects: shellImport.effects,
            contract: shellImport.contract
        )
    }

    public func invoke(
        arguments: [VM.Value],
        context: VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult {
        guard let objectiveC = descriptor.objectiveC,
              constructionFailure == nil
        else {
            throw VM.RuntimeTrap.nativeFailure(
                constructionFailure ?? "Objective-C descriptor metadata is missing"
            )
        }
        guard arguments.count == parameterTypes.count,
              zip(arguments, parameterTypes).allSatisfy({ $0.0.matches($0.1) })
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C invocation arguments disagree with verified types"
            )
        }
        try checkAvailability()
        if effects.requiresMainActor {
            return try context.withMainActor {
                try invoke(
                    arguments: arguments,
                    objectiveC: objectiveC,
                    context: context
                )
            }
        }
        try context.checkpoint(workUnits: UInt64(
            descriptor.physicalSignature.parameters.count + 1
        ))
        return try invoke(
            arguments: arguments,
            objectiveC: objectiveC,
            context: context
        )
    }
}
}

extension Runtime.ObjectiveCInvoker {
    func checkAvailability() throws {
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

    func invoke(
        arguments: [VM.Value],
        objectiveC: Core.NativeCall.ObjectiveCMetadata,
        context: VM.NativeInvocationContext
    ) throws -> VM.NativeInvocationResult {
        let receiver = try receiverObject(
            arguments: arguments,
            catalog: context.nativeTypeCatalog
        )
        let metadataStrings = descriptor.physicalSignature.parameters.compactMap {
            $0.type.encoding
        } + [
            objectiveC.runtimeClassName,
            objectiveC.dispatchClassName,
            descriptor.target.entryPoint,
            objectiveC.lexicalSuperclassName,
            descriptor.physicalSignature.result.encoding,
        ].compactMap { $0 }
        let temporaryByteCount = descriptor.physicalSignature.parameters.reduce(
            UInt64(descriptor.physicalSignature.result.size ?? 0)
        ) { total, parameter in
            total + UInt64(parameter.type.size ?? 0)
        } + metadataStrings.reduce(0) {
            $0 + UInt64($1.utf8.count + 1)
        }
        let byteCeiling = min(
            context.resourceLimits.maxNativeOwnedBytes,
            UInt64(1 * 1_024 * 1_024)
        )
        guard temporaryByteCount <= byteCeiling else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C temporary ABI storage exceeds its invocation limit"
            )
        }
        try context.checkpoint(
            workUnits: UInt64(
                descriptor.physicalSignature.parameters.count + 1
            ) + temporaryByteCount / 64
        )
        var prepared: [PreparedArgument] = []
        prepared.reserveCapacity(descriptor.physicalSignature.parameters.count)
        for parameter in descriptor.physicalSignature.parameters {
            let value: VM.Value?
            switch parameter.source.kind {
            case .argument:
                guard let index = parameter.source.logicalArgumentIndex else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Objective-C argument projection has no logical index"
                    )
                }
                value = arguments[Int(index)]
            case .optionalNone:
                value = .optional(nil)
            case .errorOut:
                value = nil
            case .defaultGenerator:
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C generic invocation cannot execute a Swift default generator"
                )
            }
            let item = try prepare(
                value,
                parameter: parameter,
                context: context
            )
            prepared.append(item)
        }

        let resultSize = Int(descriptor.physicalSignature.result.size ?? 0)
        let resultAlignment = Int(descriptor.physicalSignature.result.alignment ?? 1)
        let resultAllocation = Allocation(
            byteCount: resultSize,
            alignment: resultAlignment
        )
        let strings = prepared.map { CStringAllocation($0.encoding) }
        let runtimeClass = CStringAllocation(objectiveC.runtimeClassName)
        let dispatchClass = objectiveC.dispatchClassName.map(
            CStringAllocation.init
        )
        let selector = CStringAllocation(descriptor.target.entryPoint)
        let lexicalSuperclass = objectiveC.lexicalSuperclassName.map(
            CStringAllocation.init
        )
        let resultEncoding = CStringAllocation(
            descriptor.physicalSignature.result.encoding ?? "v"
        )
        let cArguments = zip(prepared, strings).map { item, string in
            HelixRuntimeObjectiveCArgument(
                encoding: UnsafePointer(string.pointer),
                bytes: item.bytes.map { UnsafeRawPointer($0.pointer) },
                byte_count: item.bytes?.byteCount ?? 0,
                object: item.object.map {
                    Unmanaged.passUnretained($0).toOpaque()
                },
                kind: item.kind
            )
        }
        var nativeResult = HelixRuntimeObjectiveCResult()
        let dispatch: HelixRuntimeObjectiveCDispatch = switch descriptor.target.dispatch {
        case .instance: HelixRuntimeObjectiveCDispatchInstance
        case .static: HelixRuntimeObjectiveCDispatchClass
        case .initializer: HelixRuntimeObjectiveCDispatchInitializer
        case .global:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C message cannot use global dispatch"
            )
        }
        let resultKind: HelixRuntimeObjectiveCResultKind = switch
            descriptor.physicalSignature.result.kind
        {
        case .void: HelixRuntimeObjectiveCResultVoid
        case .object, .classObject, .block: HelixRuntimeObjectiveCResultObject
        default: HelixRuntimeObjectiveCResultBytes
        }
        let returnsRetained = descriptor.physicalSignature.resultConvention
            == .directOwned
        let succeeded = cArguments.withUnsafeBufferPointer { buffer in
            helix_runtime_objective_c_invoke(
                runtimeClass.pointer,
                dispatchClass?.pointer,
                selector.pointer,
                lexicalSuperclass?.pointer,
                dispatch,
                returnsRetained,
                receiver.map { Unmanaged.passUnretained($0).toOpaque() },
                buffer.baseAddress,
                buffer.count,
                resultEncoding.pointer,
                resultKind,
                resultAllocation.pointer,
                resultAllocation.byteCount,
                &nativeResult
            )
        }
        let nativeError: NSError? = nativeResult.retained_error.map {
            Unmanaged<NSError>.fromOpaque($0).takeRetainedValue()
        }
        let nativeObject: AnyObject? = nativeResult.retained_object.map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        guard succeeded,
              nativeResult.status == HelixRuntimeObjectiveCStatusSuccess
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "\(message(from: &nativeResult)) [\(key)]"
            )
        }
        let expectedResultByteCount = resultKind
            == HelixRuntimeObjectiveCResultBytes ? resultSize : 0
        guard nativeResult.result_byte_count == expectedResultByteCount,
              nativeResult.result_byte_count <= resultAllocation.byteCount
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C result storage disagrees with its cataloged ABI [\(key)]"
            )
        }
        try context.checkResultEncodingDeadline()
        let resultBytes = Data(
            bytes: resultAllocation.pointer,
            count: Int(nativeResult.result_byte_count)
        )
        if descriptor.physicalSignature.errorConvention == .nsErrorOut {
            guard objectiveC.errorFailure == .falseBoolean,
                  let succeeded = decodeBoolean(resultBytes)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C NSError result has an unsupported sentinel"
                )
            }
            if !succeeded {
                return .businessError(nativeError.map(Self.errorMessage)
                    ?? "Objective-C operation failed without an NSError")
            }
            if resultType == .void {
                return .returned(nil)
            }
        }
        let result = try decodeResult(
            bytes: resultBytes,
            object: nativeObject,
            catalog: context.nativeTypeCatalog
        )
        return .returned(result)
    }

    func message(
        from result: inout HelixRuntimeObjectiveCResult
    ) -> String {
        withUnsafePointer(to: &result.message) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(HelixRuntimeObjectiveCMessageCapacity)
            ) {
                String(cString: $0)
            }
        }
    }

    final class CStringAllocation: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<CChar>
        private let count: Int

        init(_ value: String) {
            let bytes = Array(value.utf8CString)
            count = bytes.count
            pointer = .allocate(capacity: bytes.count)
            bytes.withUnsafeBufferPointer {
                pointer.initialize(from: $0.baseAddress!, count: $0.count)
            }
        }

        deinit {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
    }
}
