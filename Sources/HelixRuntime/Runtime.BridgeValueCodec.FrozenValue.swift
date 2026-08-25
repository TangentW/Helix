import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime.BridgeValueCodec {
/// Encodes one frozen Shell struct after validating its complete logical field
/// shape. Swift layout and metadata never cross the boundary.
public static func encodeStructure(
    type: Bytecode.LocalTypeKey,
    fieldTypes: [Bytecode.ValueType],
    fields: [VM.Value]
) throws -> VM.Value {
    guard fields.count == fieldTypes.count else {
        throw Runtime.BridgeInputError.invalidContainerCount
    }
    for (field, expectedType) in zip(fields, fieldTypes) {
        guard field.matches(expectedType) else {
            throw Runtime.BridgeInputError.encodedTypeMismatch(
                expected: expectedType.description,
                actual: field.type.description
            )
        }
    }
    return .structure(type: type, fields: fields)
}

/// Decodes one frozen Shell struct and verifies its identity, arity, and every
/// logical field type before generated code reconstructs the Swift value.
public static func decodeStructure(
    _ value: VM.Value,
    type: Bytecode.LocalTypeKey,
    fieldTypes: [Bytecode.ValueType]
) throws -> [VM.Value] {
    guard case let .structure(actualType, fields) = value,
          actualType == type
    else {
        throw VM.RuntimeTrap.typeMismatch(expected: .local(type), actual: value.type)
    }
    guard fields.count == fieldTypes.count else {
        throw VM.RuntimeTrap.nativeFailure(
            "indexed Shell struct field count does not match its verified definition"
        )
    }
    for (field, expectedType) in zip(fields, fieldTypes) {
        guard field.matches(expectedType) else {
            throw VM.RuntimeTrap.typeMismatch(expected: expectedType, actual: field.type)
        }
    }
    return fields
}

/// Encodes one frozen Shell enum after validating the selected case payload.
public static func encodeEnumeration(
    type: Bytecode.LocalTypeKey,
    caseIndex: UInt32,
    payloadType: Bytecode.ValueType?,
    payload: VM.Value?
) throws -> VM.Value {
    guard (payloadType != nil) == (payload != nil) else {
        throw Runtime.BridgeInputError.invalidContainerCount
    }
    if let payloadType, let payload, !payload.matches(payloadType) {
        throw Runtime.BridgeInputError.encodedTypeMismatch(
            expected: payloadType.description,
            actual: payload.type.description
        )
    }
    return .enumeration(type: type, caseIndex: caseIndex, payload: payload)
}

/// Decodes one frozen Shell enum and verifies that the case and payload agree
/// with its frozen logical definition.
public static func decodeEnumeration(
    _ value: VM.Value,
    type: Bytecode.LocalTypeKey,
    payloadTypes: [Bytecode.ValueType?]
) throws -> (caseIndex: UInt32, payload: VM.Value?) {
    guard case let .enumeration(actualType, caseIndex, payload) = value,
          actualType == type
    else {
        throw VM.RuntimeTrap.typeMismatch(expected: .local(type), actual: value.type)
    }
    guard let index = Int(exactly: caseIndex), index < payloadTypes.count else {
        throw VM.RuntimeTrap.nativeFailure(
            "indexed Shell enum case index is outside its verified definition"
        )
    }
    let expectedType = payloadTypes[index]
    guard (expectedType != nil) == (payload != nil) else {
        throw VM.RuntimeTrap.nativeFailure(
            "indexed Shell enum payload presence does not match its verified case"
        )
    }
    if let expectedType, let payload, !payload.matches(expectedType) {
        throw VM.RuntimeTrap.typeMismatch(expected: expectedType, actual: payload.type)
    }
    return (caseIndex, payload)
}
}
