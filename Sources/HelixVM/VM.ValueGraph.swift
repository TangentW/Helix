extension VM {
/// Bounded traversal of runtime-owned value graphs used by lifetime checks.
/// Reference-backed storage is visited by identity so recursive captures remain
/// finite without weakening aggregate, cell, or object inspection.
enum ValueGraph {}
}

extension VM.ValueGraph {
    static func containsClosureScope(
        in value: VM.Value,
        matching predicate: (VM.ClosureScope) -> Bool,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        var visitedReferences = Set<ObjectIdentifier>()
        return try inspect(
            value,
            matching: predicate,
            budget: budget,
            depth: 0,
            visitedReferences: &visitedReferences
        )
    }

    static func containsClosureScope(
        in cell: VM.MemoryCell,
        matching predicate: (VM.ClosureScope) -> Bool,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        var visitedReferences = Set<ObjectIdentifier>()
        return try inspect(
            cell,
            matching: predicate,
            budget: budget,
            depth: 0,
            visitedReferences: &visitedReferences
        )
    }

    private static func inspect(
        _ cell: VM.MemoryCell,
        matching predicate: (VM.ClosureScope) -> Bool,
        budget: VM.InvocationBudget,
        depth: Int,
        visitedReferences: inout Set<ObjectIdentifier>
    ) throws -> Bool {
        guard visitedReferences.insert(ObjectIdentifier(cell)).inserted else {
            return false
        }
        for value in cell.initializedValuesForInspection() {
            if try inspect(
                value,
                matching: predicate,
                budget: budget,
                depth: depth + 1,
                visitedReferences: &visitedReferences
            ) {
                return true
            }
        }
        return false
    }

    private static func inspect(
        _ value: VM.Value,
        matching predicate: (VM.ClosureScope) -> Bool,
        budget: VM.InvocationBudget,
        depth: Int,
        visitedReferences: inout Set<ObjectIdentifier>
    ) throws -> Bool {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try budget.consumeWork(units: 1)
        switch value {
        case let .closure(closure):
            if let scope = closure.dynamicScope, predicate(scope) {
                return true
            }
            for capture in closure.captures {
                if try inspect(
                    capture,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .any(erased):
            return try inspect(
                erased.payload,
                matching: predicate,
                budget: budget,
                depth: depth + 1,
                visitedReferences: &visitedReferences
            )
        case let .tuple(elements):
            for element in elements {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .array(storage):
            for element in storage.elements {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                if try inspect(
                    entry.key,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) || inspect(
                    entry.value,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .set(set):
            for element in set.elements {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .optional(.some(wrapped)):
            return try inspect(
                wrapped,
                matching: predicate,
                budget: budget,
                depth: depth + 1,
                visitedReferences: &visitedReferences
            )
        case let .structure(_, fields):
            for field in fields {
                if try inspect(
                    field,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .enumeration(_, _, payload):
            if let payload {
                return try inspect(
                    payload,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                )
            }
        case let .object(object):
            let identity = ObjectIdentifier(object.storage)
            guard visitedReferences.insert(identity).inserted else {
                return false
            }
            try budget.consumeWork(
                units: UInt64(object.storage.fieldCount)
            )
            for field in object.storage.initializedValuesForInspection() {
                if try inspect(
                    field,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .error(error):
            if let payload = error.payload {
                return try inspect(
                    payload,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                )
            }
        case let .address(address):
            return try inspect(
                address.cell,
                matching: predicate,
                budget: budget,
                depth: depth,
                visitedReferences: &visitedReferences
            )
        case let .mutableCell(cell):
            return try inspect(
                cell.storageForInspection,
                matching: predicate,
                budget: budget,
                depth: depth,
                visitedReferences: &visitedReferences
            )
        case let .nonOwningReference(reference):
            guard let object = reference.referentForInspection()
                    as? VM.ObjectReference
            else { break }
            return try inspect(
                .object(object),
                matching: predicate,
                budget: budget,
                depth: depth + 1,
                visitedReferences: &visitedReferences
            )
        case let .arrayBuilder(builder):
            for element in builder.valuesForInspection() {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .arrayMutationState(state):
            for element in state.valuesForInspection() {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .dictionaryBuilder(builder):
            for value in builder.valuesForInspection() {
                if try inspect(
                    value,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .arraySortState(state):
            for element in state.valuesForInspection() {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case let .arraySplitState(state):
            for element in state.valuesForInspection() {
                if try inspect(
                    element,
                    matching: predicate,
                    budget: budget,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
        case .optional(nil), .native, .bool, .integer, .float, .string:
            break
        }
        return false
    }
}
