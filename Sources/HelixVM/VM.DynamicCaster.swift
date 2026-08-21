#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
struct DynamicCaster {
    let budget: VM.InvocationBudget

    func cast(
        _ value: VM.Value,
        from sourceType: Bytecode.ValueType,
        to targetType: Bytecode.ValueType
    ) throws -> VM.Value? {
        try cast(value, from: sourceType, to: targetType, depth: 0)
    }

    private func cast(
        _ value: VM.Value,
        from sourceType: Bytecode.ValueType,
        to targetType: Bytecode.ValueType,
        depth: Int
    ) throws -> VM.Value? {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try budget.consumeWork(units: 1)

        if sourceType == targetType {
            return value
        }

        if sourceType == .any {
            guard case let .any(erased) = value,
                  erased.concreteType.isAnyPayloadV1
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: value.type)
            }
            return try cast(
                erased.payload,
                from: erased.concreteType,
                to: targetType,
                depth: depth + 1
            )
        }

        if targetType == .any {
            guard sourceType.isAnyPayloadV1 else { return nil }
            try budget.consumeAggregateStorage(elementCount: 1)
            return .any(.init(concreteType: sourceType, payload: value))
        }

        // Swift first attempts Optional injection. This preserves one level for
        // casts such as Int? -> Int?? instead of prematurely unwrapping source.
        if case let .optional(targetWrapped) = targetType,
           let converted = try cast(
               value,
               from: sourceType,
               to: targetWrapped,
               depth: depth + 1
           ) {
            try budget.consumeAggregateStorage(elementCount: 1)
            return .optional(converted)
        }

        if case let .optional(sourceWrapped) = sourceType {
            guard case let .optional(payload) = value else {
                throw VM.RuntimeTrap.typeMismatch(expected: sourceType, actual: value.type)
            }
            if let payload {
                return try cast(
                    payload,
                    from: sourceWrapped,
                    to: targetType,
                    depth: depth + 1
                )
            }
            if case .optional = targetType {
                // A dynamically typed nil can cast to any Optional target.
                try budget.consumeAggregateStorage(elementCount: 0)
                return .optional(nil)
            }
            return nil
        }

        switch (sourceType, targetType) {
        case let (.tuple(sourceTypes), .tuple(targetTypes)):
            guard case let .tuple(values) = value,
                  values.count == sourceTypes.count,
                  sourceTypes.count == targetTypes.count
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: sourceType, actual: value.type)
            }
            try budget.consumeAggregateStorage(elementCount: values.count)
            var converted: [VM.Value] = []
            converted.reserveCapacity(values.count)
            for ((element, source), target) in zip(
                zip(values, sourceTypes),
                targetTypes
            ) {
                guard let result = try cast(
                    element,
                    from: source,
                    to: target,
                    depth: depth + 1
                ) else {
                    return nil
                }
                converted.append(result)
            }
            return .tuple(converted)

        case let (.array(sourceElement), .array(targetElement)):
            guard case let .array(storage) = value,
                  storage.elementType == sourceElement
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: sourceType, actual: value.type)
            }
            try budget.consumeAggregateStorage(
                elementCount: storage.elements.count
            )
            var converted: [VM.Value] = []
            converted.reserveCapacity(storage.elements.count)
            for element in storage.elements {
                guard let result = try cast(
                    element,
                    from: sourceElement,
                    to: targetElement,
                    depth: depth + 1
                ) else {
                    return nil
                }
                converted.append(result)
            }
            return .array(
                converted,
                elementType: targetElement,
                indexBase: storage.indexBase
            )

        case let (
            .dictionary(sourceKey, sourceValue),
            .dictionary(targetKey, targetValue)
        ):
            guard case let .dictionary(entries, actualKey, actualValue) = value,
                  actualKey == sourceKey,
                  actualValue == sourceValue
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: sourceType, actual: value.type)
            }
            let storedElements = entries.count.multipliedReportingOverflow(by: 2)
            guard !storedElements.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            try budget.consumeAggregateStorage(elementCount: storedElements.partialValue)
            var converted: [VM.DictionaryEntry] = []
            converted.reserveCapacity(entries.count)
            var keys = Set<VM.HashableValue>()
            keys.reserveCapacity(entries.count)
            for entry in entries {
                guard let key = try cast(
                    entry.key,
                    from: sourceKey,
                    to: targetKey,
                    depth: depth + 1
                ), let item = try cast(
                    entry.value,
                    from: sourceValue,
                    to: targetValue,
                    depth: depth + 1
                ) else {
                    return nil
                }
                guard keys.insert(.init(value: key)).inserted else {
                    return nil
                }
                converted.append(.init(key: key, value: item))
            }
            return .dictionary(
                converted,
                keyType: targetKey,
                valueType: targetValue
            )

        default:
            return nil
        }
    }
}
}
