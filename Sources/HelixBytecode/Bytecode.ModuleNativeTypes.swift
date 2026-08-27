import HelixCore

extension Bytecode.Module {
    /// Every native type identity encoded directly in this HLBC image. Native
    /// import signatures live in the signed capability records and are joined
    /// by the caller; this projection covers the module's own value graph.
    public var referencedNativeTypeIDs: Set<Core.TypeID> {
        var result = Set<Core.TypeID>()

        func collect(_ type: Bytecode.ValueType) {
            result.formUnion(type.referencedNativeTypeIDs)
        }

        func collect(_ dynamicType: Bytecode.DynamicType) {
            collect(dynamicType.storageType)
        }

        for definition in localTypes {
            switch definition.kind {
            case let .structure(fields):
                fields.forEach { collect($0.type) }
            case let .enumeration(cases):
                cases.compactMap(\.payloadType).forEach(collect)
            case let .class(fields, hostedSuperclass, _):
                fields.forEach { collect($0.type) }
                if let hostedSuperclass {
                    result.insert(hostedSuperclass.typeID)
                }
            }
        }

        for function in functions {
            collect(function.resultType)
            if let thrownType = function.thrownType {
                collect(thrownType)
            }
            function.registerTypes.forEach(collect)
            function.stackSlotTypes.forEach(collect)
            for instruction in function.blocks.flatMap(\.instructions) {
                switch instruction {
                case let .eraseToAny(_, _, dynamicType),
                     let .checkedCastAny(_, _, dynamicType),
                     let .forceCastAny(_, _, dynamicType):
                    collect(dynamicType)
                case let .checkedCastExistential(_, _, acceptedTypes),
                     let .forceCastExistential(_, _, acceptedTypes):
                    acceptedTypes.types.forEach(collect)
                case let .existentialApply(_, _, _, dispatch),
                     let .existentialTryApply(_, _, dispatch, _, _):
                    dispatch.targets.forEach { collect($0.dynamicType) }
                default:
                    break
                }
            }
        }
        return result
    }
}
