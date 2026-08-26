extension Bytecode {
/// Reusable Objective-C Block entry shapes compiled into Runtime. This is an
/// ABI-shape matrix, not an API allowlist: every cataloged method with the same
/// callable shape shares the same native trampoline.
public enum ObjectiveCBlockABI {}
}

extension Bytecode.ObjectiveCBlockABI {
public static func supports(_ signature: Bytecode.ClosureSignature) -> Bool {
    guard signature.isNativeBridgeCallback else { return false }
    let parameters = signature.parameters
    switch signature.result {
    case .void:
        if parameters.isEmpty || parameters == [.bool]
            || parameters == [.int64] || parameters == [.float(bitWidth: 64)] {
            return true
        }
        if parameters.count == 1, isObject(parameters[0]) { return true }
        if parameters.count == 2,
           (parameters[0] == .bool && isObject(parameters[1])
                || isObject(parameters[0]) && parameters[1] == .bool)
        {
            return true
        }
        return (parameters.count == 2 || parameters.count == 3)
            && parameters.allSatisfy(isObject)
    case .bool:
        return parameters.isEmpty
            || parameters.count == 1 && isObject(parameters[0])
            || parameters.count == 2 && parameters.allSatisfy(isObject)
    case .integer(bitWidth: 64, signed: true):
        return parameters.count == 2 && parameters.allSatisfy(isObject)
    default:
        return false
    }
}

private static func isObject(_ type: Bytecode.ValueType) -> Bool {
    switch type {
    case .native, .string, .error:
        true
    case let .optional(wrapped):
        isObject(wrapped)
    default:
        false
    }
}
}
