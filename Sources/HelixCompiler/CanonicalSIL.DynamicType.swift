import HelixBytecode

extension CanonicalSIL {
/// Builds the closed source-level identity carried by VM-owned `Any` values.
/// Parsing is intentionally limited to types whose complete dynamic-cast
/// semantics are represented by HLBC; normalized compiler-only views and
/// arbitrary nominal spellings remain fail-closed.
enum DynamicType {
    static func parse(
        _ raw: String,
        resolveStorage: (String) throws -> Bytecode.ValueType
    ) throws -> Bytecode.DynamicType {
        let spelling = CanonicalSIL.SwiftTypeIdentity.normalized(raw)
        let storageType = CanonicalSIL.ValueRepresentation.storable(
            try resolveStorage(raw)
        )
        switch inspectStorage(storageType) {
        case .containsClosure:
            throw CanonicalSIL.LoweringError.unsupportedType(
                "VM-owned Any cannot carry closure dynamic type \(spelling)"
            )
        case .overdeep:
            throw CanonicalSIL.LoweringError.unsupportedType(
                "VM-owned Any dynamic type exceeds the supported nesting depth"
            )
        case .clear:
            break
        }
        let dynamicType = try parseNormalized(
            spelling,
            resolveStorage: resolveStorage,
            depth: 0
        )
        guard dynamicType.isAnyPayloadOrExistentialV1,
              dynamicType.storageType == storageType
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "VM-owned Any dynamic type \(spelling)"
            )
        }
        return dynamicType
    }

    private static func parseNormalized(
        _ spelling: String,
        resolveStorage: (String) throws -> Bytecode.ValueType,
        depth: Int
    ) throws -> Bytecode.DynamicType {
        guard depth <= Bytecode.DynamicType.maximumNestingDepthV1 else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "VM-owned Any dynamic type exceeds the supported nesting depth"
            )
        }
        switch spelling {
        case "Any": return .any
        case "Bool": return .bool
        case "Int": return .integer(.int)
        case "Int8": return .integer(.int8)
        case "Int16": return .integer(.int16)
        case "Int32": return .integer(.int32)
        case "Int64": return .integer(.int64)
        case "UInt": return .integer(.uint)
        case "UInt8": return .integer(.uint8)
        case "UInt16": return .integer(.uint16)
        case "UInt32": return .integer(.uint32)
        case "UInt64": return .integer(.uint64)
        case "Float", "Float32": return .floatingPoint(.float)
        case "Double", "Float64": return .floatingPoint(.double)
        case "CGFloat", "CoreGraphics.CGFloat", "CoreFoundation.CGFloat":
            return .floatingPoint(.cgFloat)
        case "String": return .string
        case "Character": return .character
        case "Substring": return .substring
        default:
            break
        }

        if let generic = CanonicalSIL.SwiftTypeIdentity.genericType(spelling) {
            switch generic.name {
            case "Optional" where generic.arguments.count == 1:
                return .optional(
                    try parseNormalized(
                        generic.arguments[0],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    )
                )
            case "Array" where generic.arguments.count == 1:
                return .array(
                    try parseNormalized(
                        generic.arguments[0],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    )
                )
            case "ArraySlice" where generic.arguments.count == 1:
                return .arraySlice(
                    try parseNormalized(
                        generic.arguments[0],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    )
                )
            case "Set" where generic.arguments.count == 1:
                return .set(
                    try parseNormalized(
                        generic.arguments[0],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    )
                )
            case "Dictionary" where generic.arguments.count == 2:
                return .dictionary(
                    key: try parseNormalized(
                        generic.arguments[0],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    ),
                    value: try parseNormalized(
                        generic.arguments[1],
                        resolveStorage: resolveStorage,
                        depth: depth + 1
                    )
                )
            default:
                break
            }
        }

        if let elements = tupleElements(spelling), !elements.isEmpty {
            return .tuple(
                try elements.map {
                    .init(
                        label: $0.label,
                        type: try parseNormalized(
                            $0.type,
                            resolveStorage: resolveStorage,
                            depth: depth + 1
                        )
                    )
                }
            )
        }

        let storage = CanonicalSIL.ValueRepresentation.storable(
            try resolveStorage(spelling)
        )
        if case let .local(key) = storage {
            return .local(key)
        }
        if case let .native(id) = storage {
            return .native(id)
        }
        if case .closure = storage {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "VM-owned Any cannot carry closure dynamic type \(spelling)"
            )
        }

        throw CanonicalSIL.LoweringError.unsupportedType(
            "VM-owned Any dynamic type \(spelling)"
        )
    }

    private static func tupleElements(
        _ spelling: String
    ) -> [(label: String?, type: String)]? {
        guard spelling.first == "(", spelling.last == ")" else {
            return nil
        }
        let body = String(spelling.dropFirst().dropLast())
        guard !body.isEmpty else { return [] }
        return splitTopLevel(body, separator: ",").map { component in
            guard let separator = firstTopLevelColon(in: component) else {
                return (nil, component)
            }
            let label = String(component[..<separator])
            let type = String(component[component.index(after: separator)...])
            return (label == "_" ? nil : label, type)
        }
    }

    private static func firstTopLevelColon(
        in value: String
    ) -> String.Index? {
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            case ":" where depth == 0: return index
            default: break
            }
            guard depth >= 0 else { return nil }
        }
        return nil
    }

    private static func splitTopLevel(
        _ value: String,
        separator: Character
    ) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            default: break
            }
            if value[index] == separator, depth == 0 {
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            }
        }
        result.append(String(value[start...]))
        return result
    }

    private enum StorageInspection {
        case clear
        case containsClosure
        case overdeep

        static func combining(
            _ lhs: Self,
            _ rhs: @autoclosure () -> Self
        ) -> Self {
            switch lhs {
            case .containsClosure, .overdeep:
                return lhs
            case .clear:
                return rhs()
            }
        }
    }

    private static func inspectStorage(
        _ type: Bytecode.ValueType,
        depth: Int = 0
    ) -> StorageInspection {
        guard depth <= Bytecode.DynamicType.maximumNestingDepthV1 else {
            return .overdeep
        }
        switch type {
        case .closure:
            return .containsClosure
        case let .optional(wrapped), let .array(wrapped), let .set(wrapped),
             let .nonOwningReference(_, wrapped):
            return inspectStorage(wrapped, depth: depth + 1)
        case let .dictionary(key, value):
            return StorageInspection.combining(
                inspectStorage(key, depth: depth + 1),
                inspectStorage(value, depth: depth + 1)
            )
        case let .tuple(elements):
            return elements.reduce(.clear) { result, element in
                StorageInspection.combining(
                    result,
                    inspectStorage(element, depth: depth + 1)
                )
            }
        case .void, .never, .bool, .integer, .float, .string, .any, .native,
             .local, .error, .address, .mutableCell, .arrayState,
             .dictionaryState:
            return .clear
        }
    }
}
}
