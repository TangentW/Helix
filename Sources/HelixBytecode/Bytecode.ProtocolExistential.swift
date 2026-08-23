extension Bytecode {
/// One concrete image-local target in a compiler-closed existential dispatch.
/// The source protocol identity remains a compiler fact; HLBC retains only the
/// represented dynamic type and the already-linked function identity.
public struct ExistentialDispatchTarget: Codable, Hashable, Sendable {
    public var dynamicType: Bytecode.DynamicType
    public var function: Bytecode.FunctionID

    public init(
        dynamicType: Bytecode.DynamicType,
        function: Bytecode.FunctionID
    ) {
        self.dynamicType = dynamicType
        self.function = function
    }
}

/// A bounded, deterministic dispatch plan for one opened existential call.
/// `receiverParameterIndex` names the concrete receiver slot in every target;
/// the remaining target ABI must be identical and is verifier-enforced.
public struct ExistentialDispatchTable: Codable, Hashable, Sendable {
    public static let maximumTargetCountV1 = 4_096

    public var receiverParameterIndex: UInt32
    public var targets: [Bytecode.ExistentialDispatchTarget]

    public init(
        receiverParameterIndex: UInt32,
        targets: [Bytecode.ExistentialDispatchTarget]
    ) {
        self.receiverParameterIndex = receiverParameterIndex
        self.targets = targets
    }
}

/// Exact represented types accepted by a compiler-closed protocol cast.
/// An empty set is meaningful for a checked cast that can never succeed.
public struct ExistentialTypeSet: Codable, Hashable, Sendable {
    public static let maximumTypeCountV1 = 4_096

    public var types: [Bytecode.DynamicType]

    public init(types: [Bytecode.DynamicType]) {
        self.types = types
    }
}
}
