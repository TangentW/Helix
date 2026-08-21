#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM.Value {
/// Validates both the physical HLBC shape and the source-level invariants of a
/// value carried through `Any`.
public func matches(_ expected: Bytecode.DynamicType) -> Bool {
    expected.isAnyPayloadOrExistentialV1
        && matchesDynamicType(expected, depth: 0)
}

func matchesDynamicType(
    _ expected: Bytecode.DynamicType,
    depth: Int
) -> Bool {
    guard depth <= VM.ValueLimits.maximumNestingDepth else { return false }
    switch (self, expected) {
    case (.bool, .bool):
        return true
    case (.integer(_), let .integer(identity)):
        return type == identity.storageType
    case (.float(_), let .floatingPoint(identity)):
        return type == identity.storageType
    case (.string, .string):
        return true
    case let (.string(value), .character):
        return value.count == 1
    case let (.array(storage), .substring):
        return storage.indexBase == 0
            && storage.elementType == .string
            && storage.elements.allSatisfy {
                $0.matchesDynamicType(.character, depth: depth + 1)
            }
    case let (.structure(actual, _), .local(expected)),
         let (.enumeration(actual, _, _), .local(expected)):
        return actual == expected
    case let (.object(object), .local(expected)):
        return object.typeKey == expected
    case let (.any(erased), .any):
        return erased.dynamicType.isAnyPayloadV1
            && erased.payload.matchesDynamicType(
                erased.dynamicType,
                depth: depth + 1
            )
    case let (.optional(payload), .optional(wrapped)):
        return payload?.matchesDynamicType(wrapped, depth: depth + 1) ?? true
    case let (.array(storage), .array(element)):
        return storage.indexBase == 0
            && storage.elementType == element.storageType
            && storage.elements.allSatisfy {
                $0.matchesDynamicType(element, depth: depth + 1)
            }
    case let (.array(storage), .arraySlice(element)):
        return storage.elementType == element.storageType
            && storage.elements.allSatisfy {
                $0.matchesDynamicType(element, depth: depth + 1)
            }
    case let (
        .dictionary(entries, actualKey, actualValue),
        .dictionary(key, value)
    ):
        return actualKey == key.storageType
            && actualValue == value.storageType
            && entries.allSatisfy {
                $0.key.matchesDynamicType(key, depth: depth + 1)
                    && $0.value.matchesDynamicType(value, depth: depth + 1)
            }
    case let (.set(storage), .set(element)):
        return element.hasVMDefinedHashableSemantics
            && storage.elementType == element.storageType
            && storage.elements.allSatisfy {
                $0.matchesDynamicType(element, depth: depth + 1)
            }
    case let (.tuple(values), .tuple(elements)):
        return values.count == elements.count
            && zip(values, elements).allSatisfy {
                $0.matchesDynamicType($1.type, depth: depth + 1)
            }
    default:
        return false
    }
}
}
