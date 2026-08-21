#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
struct DynamicCaster {
    let budget: VM.InvocationBudget

    func cast(
        _ value: VM.Value,
        from sourceType: Bytecode.DynamicType,
        to targetType: Bytecode.DynamicType
    ) throws -> VM.Value? {
        guard sourceType.isAnyPayloadOrExistentialV1,
              targetType.isAnyCastTargetV1
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .never,
                actual: value.type
            )
        }
        return try cast(
            value,
            from: sourceType,
            to: targetType,
            depth: 0
        )
    }

    private func cast(
        _ value: VM.Value,
        from sourceType: Bytecode.DynamicType,
        to targetType: Bytecode.DynamicType,
        depth: Int
    ) throws -> VM.Value? {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try budget.consumeWork(units: 1)

        // Existential payloads are validated when they enter the VM or are
        // created by erase_to_any. Dynamic descriptors are immutable, so an
        // exact identity test is O(1), like Swift metadata identity, and does
        // not rescan a potentially large collection on every `is`/cast.
        if sourceType == targetType { return value }

        if sourceType == .any {
            guard case let .any(erased) = value,
                  erased.dynamicType.isAnyPayloadV1
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .any,
                    actual: value.type
                )
            }
            return try cast(
                erased.payload,
                from: erased.dynamicType,
                to: targetType,
                depth: depth + 1
            )
        }

        if targetType == .any {
            guard sourceType.isAnyPayloadV1 else { return nil }
            try budget.consumeAggregateStorage(elementCount: 1)
            return .any(.init(dynamicType: sourceType, payload: value))
        }

        // Swift attempts Optional injection before source unwrapping. This
        // preserves one level for casts such as Int? -> Int??.
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
                throw VM.RuntimeTrap.typeMismatch(
                    expected: sourceType.storageType,
                    actual: value.type
                )
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
                // A dynamically typed nil casts to every Optional target.
                try budget.consumeAggregateStorage(elementCount: 0)
                return .optional(nil)
            }
            return nil
        }

        switch (sourceType, targetType) {
        case let (.tuple(sourceElements), .tuple(targetElements)):
            guard case let .tuple(values) = value,
                  values.count == sourceElements.count,
                  sourceElements.count == targetElements.count
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: sourceType.storageType,
                    actual: value.type
                )
            }
            guard zip(sourceElements, targetElements).allSatisfy({
                labelsAreCastCompatible($0.label, $1.label)
            }) else {
                return nil
            }
            try budget.consumeAggregateStorage(elementCount: values.count)
            var converted: [VM.Value] = []
            converted.reserveCapacity(values.count)
            for ((element, source), target) in zip(
                zip(values, sourceElements),
                targetElements
            ) {
                guard let result = try cast(
                    element,
                    from: source.type,
                    to: target.type,
                    depth: depth + 1
                ) else {
                    return nil
                }
                converted.append(result)
            }
            return .tuple(converted)

        case let (.array(sourceElement), .array(targetElement)):
            guard case let .array(storage) = value,
                  storage.indexBase == 0,
                  storage.elementType == sourceElement.storageType
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: sourceType.storageType,
                    actual: value.type
                )
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
                elementType: targetElement.storageType
            )

        case let (
            .dictionary(sourceKey, sourceValue),
            .dictionary(targetKey, targetValue)
        ):
            guard case let .dictionary(entries, actualKey, actualValue) = value,
                  actualKey == sourceKey.storageType,
                  actualValue == sourceValue.storageType
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: sourceType.storageType,
                    actual: value.type
                )
            }
            let storedElements = entries.count.multipliedReportingOverflow(by: 2)
            guard !storedElements.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            try budget.consumeAggregateStorage(
                elementCount: storedElements.partialValue
            )
            // Duplicate detection builds a transient hash index in addition
            // to the retained converted Dictionary storage.
            return try budget.withTemporaryAggregateStorage(
                elementCount: entries.count
            ) { () throws -> VM.Value? in
                var converted: [VM.DictionaryEntry] = []
                converted.reserveCapacity(entries.count)
                var keys = UniquenessIndex(
                    capacity: entries.count,
                    budget: budget
                )
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
                    guard try keys.insert(key) else {
                        throw VM.RuntimeTrap.dynamicCastProducedDuplicateDictionaryKey
                    }
                    converted.append(.init(key: key, value: item))
                }
                return .dictionary(
                    converted,
                    keyType: targetKey.storageType,
                    valueType: targetValue.storageType
                )
            }

        case let (.set(sourceElement), .set(targetElement)):
            guard case let .set(storage) = value,
                  storage.elementType == sourceElement.storageType,
                  targetElement.hasVMDefinedHashableSemantics
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: sourceType.storageType,
                    actual: value.type
                )
            }
            try budget.consumeAggregateStorage(
                elementCount: storage.elements.count
            )
            // Account for the transient uniqueness index separately from the
            // retained Set element storage.
            return try budget.withTemporaryAggregateStorage(
                elementCount: storage.elements.count
            ) { () throws -> VM.Value? in
                var converted: [VM.Value] = []
                converted.reserveCapacity(storage.elements.count)
                var elements = UniquenessIndex(
                    capacity: storage.elements.count,
                    budget: budget
                )
                for element in storage.elements {
                    guard let result = try cast(
                        element,
                        from: sourceElement,
                        to: targetElement,
                        depth: depth + 1
                    ) else {
                        return nil
                    }
                    guard try elements.insert(result) else {
                        throw VM.RuntimeTrap.dynamicCastProducedDuplicateSetElement
                    }
                    converted.append(result)
                }
                return .set(
                    .init(
                        uncheckedElements: converted,
                        elementType: targetElement.storageType
                    )
                )
            }

        default:
            return nil
        }
    }

    private func labelsAreCastCompatible(
        _ source: String?,
        _ target: String?
    ) -> Bool {
        source == nil || target == nil || source == target
    }

    /// Hash buckets keep the common path linear while making every recursive
    /// collision comparison visible to the invocation budget.
    private struct UniquenessIndex {
        let budget: VM.InvocationBudget
        var buckets: [UInt64: [VM.Value]]

        init(capacity: Int, budget: VM.InvocationBudget) {
            self.budget = budget
            buckets = [:]
            buckets.reserveCapacity(capacity)
        }

        mutating func insert(_ value: VM.Value) throws -> Bool {
            try budget.consumeValueTraversal(value)
            let fingerprint = VM.HashableValue.deterministicFingerprint(value)
            if let candidates = buckets[fingerprint] {
                for candidate in candidates {
                    if try budget.valuesEqual(candidate, value) {
                        return false
                    }
                }
            }
            buckets[fingerprint, default: []].append(value)
            return true
        }
    }
}
}
