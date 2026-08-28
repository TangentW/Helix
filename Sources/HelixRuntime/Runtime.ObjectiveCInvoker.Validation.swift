import HelixBytecode
import HelixCore
import HelixObjectiveCRuntimeSupport
import HelixVM

extension Runtime.ObjectiveCInvoker {
    /// Rejects a descriptor that cannot be executed by the generic invoker.
    /// Development activation calls this before publishing a generation so an
    /// unsupported ABI shape cannot become a deferred first-call failure.
    public func validateConfiguration() throws {
        if let constructionFailure {
            throw VM.RuntimeTrap.nativeFailure(constructionFailure)
        }
    }

    /// Rechecks the linked OS class, selector, and exact type encodings before
    /// a production capability table is accepted.
    public func validateRuntimeABI() throws {
        try validateConfiguration()
        try checkAvailability()
        guard let objectiveC = descriptor.objectiveC else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C descriptor metadata is missing"
            )
        }
        let encodings = descriptor.physicalSignature.parameters.map {
            Runtime.ObjectiveCInvoker.CStringAllocation($0.type.encoding!)
        }
        let pointers: [UnsafePointer<CChar>?] = encodings.map {
            UnsafePointer($0.pointer)
        }
        let declaration = Runtime.ObjectiveCInvoker.CStringAllocation(
            objectiveC.runtimeClassName
        )
        let dispatchClass = objectiveC.dispatchClassName.map(
            Runtime.ObjectiveCInvoker.CStringAllocation.init
        )
        let selector = Runtime.ObjectiveCInvoker.CStringAllocation(
            descriptor.target.entryPoint
        )
        let lexicalSuperclass = objectiveC.lexicalSuperclassName.map(
            Runtime.ObjectiveCInvoker.CStringAllocation.init
        )
        let resultEncoding = Runtime.ObjectiveCInvoker.CStringAllocation(
            descriptor.physicalSignature.result.encoding ?? "v"
        )
        let dispatch: HelixRuntimeObjectiveCDispatch = switch
            descriptor.target.dispatch
        {
        case .instance: HelixRuntimeObjectiveCDispatchInstance
        case .static: HelixRuntimeObjectiveCDispatchClass
        case .initializer: HelixRuntimeObjectiveCDispatchInitializer
        case .global:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C message cannot use global dispatch"
            )
        }
        var nativeResult = HelixRuntimeObjectiveCResult()
        let stringOwners = encodings + [
            declaration, dispatchClass, selector, lexicalSuperclass,
            resultEncoding,
        ].compactMap { $0 }
        // Unsafe pointers do not retain the allocations they address. Keep
        // every encoding and metadata owner alive through the foreign call.
        let succeeded = withExtendedLifetime(stringOwners) {
            pointers.withUnsafeBufferPointer { buffer in
                helix_runtime_objective_c_validate(
                    declaration.pointer,
                    dispatchClass?.pointer,
                    selector.pointer,
                    lexicalSuperclass?.pointer,
                    dispatch,
                    objectiveC.implementationLookup
                        == .dynamicObjectWhenDeclarationMissing,
                    buffer.baseAddress,
                    buffer.count,
                    resultEncoding.pointer,
                    &nativeResult
                )
            }
        }
        guard succeeded,
              nativeResult.status == HelixRuntimeObjectiveCStatusSuccess
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "\(message(from: &nativeResult)) [\(key)]"
            )
        }
    }

    static func validate(
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        contract: Core.NativeImportContract
    ) -> String? {
        do {
            try descriptor.validate(contract: contract)
            guard descriptor.target.backend == .objectiveCMessage,
                  try Core.NativeCall.Key.derive(descriptor: descriptor) == key,
                  descriptor.loweredSignature.parameters.count
                    == parameterTypes.count,
                  descriptor.effects == effects
            else {
                return "Objective-C invoker identity or verified types disagree"
            }
            guard supportsPhysicalSignature(
                descriptor.physicalSignature,
                parameterTypes: parameterTypes,
                resultType: resultType
            ) else {
                return "Objective-C invoker does not support the cataloged ABI shape"
            }
            return nil
        } catch {
            return "Objective-C invoker descriptor is invalid: \(error)"
        }
    }

    private static func supportsPhysicalSignature(
        _ signature: Core.NativeCall.PhysicalSignature,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType
    ) -> Bool {
        guard signature.parameters.allSatisfy({ parameter in
            supports(parameter: parameter, logicalTypes: parameterTypes)
        }) else { return false }
        let result = signature.result
        if signature.errorConvention == .nsErrorOut {
            return result.kind == .boolean
                && resultType == .void
                && signature.resultConvention == .direct
        }
        switch result.kind {
        case .void:
            return resultType == .void
                && signature.resultConvention == .direct
        case .object:
            return supportsObject(
                logicalType: resultType,
                nullable: result.isNullable,
                allowsSwiftAnyErasure: false
            ) && [.direct, .directOwned, .directUnowned, .autoreleased]
                .contains(signature.resultConvention)
        case .boolean:
            return resultType == .bool
                && signature.resultConvention == .direct
        case .signedInteger, .unsignedInteger:
            guard case let .integer(bitWidth, signed) = resultType,
                  let size = result.size
            else { return false }
            return bitWidth == size * 8
                && signed == (result.kind == .signedInteger)
                && signature.resultConvention == .direct
        case .floatingPoint:
            guard case let .float(bitWidth) = resultType,
                  let size = result.size
            else { return false }
            return bitWidth == size * 8
                && signature.resultConvention == .direct
        case .structure:
            guard case .native = resultType else { return false }
            return signature.resultConvention == .direct
        case .bridgeValue, .classObject, .selector, .block, .pointer:
            return false
        }
    }

    private static func supports(
        parameter: Core.NativeCall.ABIParameter,
        logicalTypes: [Bytecode.ValueType]
    ) -> Bool {
        if parameter.source.kind == .errorOut {
            return parameter.type.kind == .pointer
                && parameter.type.encoding == "^@"
                && parameter.convention == .indirectOut
        }
        guard parameter.convention == .direct else { return false }
        if parameter.source.kind == .optionalNone {
            return parameter.type.isNullable
                && (parameter.type.kind == .object
                    || parameter.type.kind == .block)
        }
        guard parameter.source.kind == .argument,
              let index = parameter.source.logicalArgumentIndex,
              logicalTypes.indices.contains(Int(index))
        else { return false }
        let logicalType = logicalTypes[Int(index)]
        switch parameter.type.kind {
        case .object:
            return supportsObject(
                logicalType: logicalType,
                nullable: parameter.type.isNullable,
                allowsSwiftAnyErasure: true
            )
        case .block:
            guard let shape = logicalType.directClosureShape else {
                return false
            }
            return shape.isOptional == parameter.type.isNullable
                && Bytecode.ObjectiveCBlockABI.supports(shape.signature)
        case .boolean:
            return logicalType == .bool
        case .signedInteger, .unsignedInteger:
            guard case let .integer(bitWidth, signed) = logicalType,
                  let size = parameter.type.size
            else { return false }
            return bitWidth == size * 8
                && signed == (parameter.type.kind == .signedInteger)
        case .floatingPoint:
            guard case let .float(bitWidth) = logicalType,
                  let size = parameter.type.size
            else { return false }
            return bitWidth == size * 8
        case .structure:
            if case .native = logicalType { return true }
            return false
        case .void, .bridgeValue, .classObject, .selector, .pointer:
            return false
        }
    }

    private static func supportsObject(
        logicalType: Bytecode.ValueType,
        nullable: Bool,
        allowsSwiftAnyErasure: Bool
    ) -> Bool {
        switch logicalType {
        case .string, .error, .native:
            return !nullable
        case .any:
            return allowsSwiftAnyErasure && !nullable
        case let .optional(wrapped):
            return nullable && supportsObject(
                logicalType: wrapped,
                nullable: false,
                allowsSwiftAnyErasure: allowsSwiftAnyErasure
            )
        default:
            return false
        }
    }
}
