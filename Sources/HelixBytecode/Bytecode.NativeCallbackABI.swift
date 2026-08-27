extension Bytecode {
/// Variance admitted only where a NativeImport contract explicitly declares
/// a callback parameter. The concrete closure keeps its stricter MainActor
/// requirement, so native execution can never erase actor isolation.
public enum NativeCallbackABI {
    public static func argumentsAreCompatible(
        actual: [Bytecode.ValueType],
        boundary: [Bytecode.ValueType],
        callbackParameterIndices: Set<Int>
    ) -> Bool {
        guard actual.count == boundary.count else { return false }
        return zip(actual, boundary).enumerated().allSatisfy {
            index, pair in
            pair.0 == pair.1
                || callbackParameterIndices.contains(index)
                    && isMainActorRestriction(pair.0, of: pair.1)
        }
    }

    public static func isMainActorRestriction(
        _ actual: Bytecode.ValueType,
        of boundary: Bytecode.ValueType
    ) -> Bool {
        switch (actual, boundary) {
        case let (.closure(actual), .closure(boundary)):
            actual.isMainActorRestriction(of: boundary)
        case let (.optional(actual), .optional(boundary)):
            isMainActorRestriction(actual, of: boundary)
        default:
            false
        }
    }
}
}
