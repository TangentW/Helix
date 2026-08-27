import HelixBytecode

extension VM {
/// Runtime value-shape validation for a frozen NativeImport boundary.
public enum NativeInvocationABI {
    package static func argumentsAreCompatible(
        _ arguments: [VM.Value],
        with boundary: [Bytecode.ValueType],
        callbackParameterIndices: Set<Int>
    ) -> Bool {
        guard arguments.count == boundary.count else { return false }
        return zip(arguments, boundary).enumerated().allSatisfy {
            index, pair in
            pair.0.matches(pair.1)
                || callbackParameterIndices.contains(index)
                    && Bytecode.NativeCallbackABI.isMainActorRestriction(
                        pair.0.type,
                        of: pair.1
                    )
        }
    }
}
}
