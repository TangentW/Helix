import HelixCRuntimeSupport
import HelixBytecode
import HelixCore
import HelixVM

extension Runtime.CInvoker {
/// Rejects a descriptor or function address that the finite C trampoline
/// matrix cannot execute. Development activation uses this before publication.
public func validateConfiguration() throws {
    if let constructionFailure {
        throw VM.RuntimeTrap.nativeFailure(constructionFailure)
    }
}

/// Rechecks the bound function pointer, ABI matrix, and device availability.
public func validateRuntimeABI() throws {
    try validateConfiguration()
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

static func validate(
    key: Core.NativeCall.Key,
    descriptor: Core.NativeCall.Descriptor,
    parameterTypes: [Bytecode.ValueType],
    resultType: Bytecode.ValueType,
    effects: Core.Effects,
    contract: Core.NativeImportContract,
    functionAddress: UInt
) -> String? {
    do {
        try descriptor.validate(contract: contract)
        guard functionAddress != 0,
              descriptor.target.backend == .cFunction,
              try Core.NativeCall.Key.derive(descriptor: descriptor) == key,
              descriptor.effects == effects,
              descriptor.logicalSignature.parameters.count
                == parameterTypes.count,
              supports(
                  descriptor.physicalSignature,
                  parameterTypes: parameterTypes,
                  resultType: resultType
              )
        else {
            return "C invoker identity, function address, or verified types disagree"
        }
        let strings = descriptor.physicalSignature.parameters.compactMap {
            $0.type.encoding.map(Runtime.NativeABIValue.CString.init)
        }
        guard strings.count == descriptor.physicalSignature.parameters.count
        else { return "C invoker parameter encoding is incomplete" }
        let result = Runtime.NativeABIValue.CString(
            descriptor.physicalSignature.result.encoding ?? "v"
        )
        let pointers: [UnsafePointer<CChar>?] = strings.map {
            UnsafePointer($0.pointer)
        }
        let encodingOwners = strings + [result]
        // Unsafe pointers do not retain the CString allocations. Preserve the
        // owners explicitly across the C trampoline query under optimization.
        let supported = withExtendedLifetime(encodingOwners) {
            pointers.withUnsafeBufferPointer {
                helix_runtime_c_signature_is_supported(
                    $0.baseAddress,
                    $0.count,
                    result.pointer
                )
            }
        }
        return supported ? nil : "C invoker has no AOT trampoline for the cataloged ABI shape"
    } catch {
        return "C invoker descriptor is invalid: \(error)"
    }
}

private static func supports(
    _ signature: Core.NativeCall.PhysicalSignature,
    parameterTypes: [Bytecode.ValueType],
    resultType: Bytecode.ValueType
) -> Bool {
    guard signature.callingConvention == .c,
          signature.parameters.count == parameterTypes.count
    else { return false }
    for (index, pair) in zip(signature.parameters, parameterTypes).enumerated() {
        let (parameter, logical) = pair
        guard parameter.source == .argument(UInt16(index)),
              parameter.convention == .direct,
              supports(type: parameter.type, logical: logical, allowsVoid: false)
        else { return false }
    }
    return signature.resultConvention == .direct
        && signature.errorConvention == .none
        && supports(type: signature.result, logical: resultType, allowsVoid: true)
}

private static func supports(
    type: Core.NativeCall.ABIType,
    logical: Bytecode.ValueType,
    allowsVoid: Bool
) -> Bool {
    switch type.kind {
    case .void:
        return allowsVoid && logical == .void
    case .boolean:
        return logical == .bool && type.size == 1
    case .signedInteger, .unsignedInteger:
        guard case let .integer(width, signed) = logical,
              let size = type.size
        else { return false }
        return width == size * 8
            && signed == (type.kind == .signedInteger)
    case .floatingPoint:
        guard case let .float(width) = logical, let size = type.size else {
            return false
        }
        return width == size * 8
    case .structure:
        if case .native = logical { return true }
        return false
    case .bridgeValue, .object, .classObject, .selector, .block, .pointer:
        return false
    }
}
}
