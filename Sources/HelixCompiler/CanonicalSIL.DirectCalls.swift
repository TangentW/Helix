import HelixBytecode
import HelixCore

extension CanonicalSIL {
/// A statically resolved Swift call target. Helix never performs symbol lookup
/// on-device; the release archive freezes every mapping before patch creation.
public struct DirectCallBinding: Hashable, Sendable {
    public enum ABIAdapter: Hashable, Sendable {
        case direct
        case mutatingValueReceiver
    }

    public enum Target: Hashable, Sendable {
        case function(Bytecode.FunctionID)
        case entry(Core.EntryIndex)
        case nativeImport(Bytecode.ImportRequirement)
    }

    public var mangledName: String
    public var parameterTypes: [Bytecode.ValueType]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: Bytecode.ValueType
    public var effects: Core.Effects
    public var target: Target
    public var abiAdapter: ABIAdapter

    public init(
        mangledName: String,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        target: Target,
        abiAdapter: ABIAdapter = .direct
    ) {
        self.mangledName = mangledName
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions ?? parameterTypes.map { type in
            if case .address = type { return .inout }
            return .owned
        }
        self.resultType = resultType
        self.effects = effects
        self.target = target
        self.abiAdapter = abiAdapter
    }
}

public struct UnavailableDirectCall: Hashable, Sendable {
    public var mangledName: String
    public var canonicalCallee: String
    public var reason: String

    public init(mangledName: String, canonicalCallee: String, reason: String) {
        self.mangledName = mangledName
        self.canonicalCallee = canonicalCallee
        self.reason = reason
    }
}

public struct DirectCallTable: Sendable {
    private var bindings: [String: CanonicalSIL.DirectCallBinding]
    private var unavailableCalls: [String: CanonicalSIL.UnavailableDirectCall]

    public static let empty = CanonicalSIL.DirectCallTable(
        unchecked: [:],
        unavailableCalls: [:]
    )

    public init(
        _ values: [CanonicalSIL.DirectCallBinding],
        unavailable: [CanonicalSIL.UnavailableDirectCall] = []
    ) throws {
        var result: [String: CanonicalSIL.DirectCallBinding] = [:]
        for value in values {
            guard !value.mangledName.isEmpty,
                  result.updateValue(value, forKey: value.mangledName) == nil
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "duplicate or empty direct-call symbol \(value.mangledName)"
                )
            }
            if case let .nativeImport(requirement) = value.target,
               requirement.effects != value.effects {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native import \(requirement.id) effect descriptor disagrees with its call binding"
                )
            }
        }
        var unavailableBySymbol: [String: CanonicalSIL.UnavailableDirectCall] = [:]
        for item in unavailable {
            guard !item.mangledName.isEmpty,
                  !item.canonicalCallee.isEmpty,
                  !item.reason.isEmpty,
                  result[item.mangledName] == nil,
                  unavailableBySymbol.updateValue(item, forKey: item.mangledName) == nil
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "duplicate, bound, or incomplete unavailable direct-call symbol "
                        + item.mangledName
                )
            }
        }
        self.init(unchecked: result, unavailableCalls: unavailableBySymbol)
    }

    func binding(for mangledName: String) -> CanonicalSIL.DirectCallBinding? {
        bindings[mangledName]
    }

    var boundSymbols: Set<String> {
        Set(bindings.keys)
    }

    var functionIDs: Set<Bytecode.FunctionID> {
        Set(bindings.values.compactMap { binding in
            guard case let .function(id) = binding.target else { return nil }
            return id
        })
    }

    func adding(
        _ additionalBindings: [CanonicalSIL.DirectCallBinding]
    ) throws -> CanonicalSIL.DirectCallTable {
        try CanonicalSIL.DirectCallTable(
            Array(bindings.values) + additionalBindings,
            unavailable: Array(unavailableCalls.values)
        )
    }

    func referencesInoutCallee(in body: String) -> Bool {
        bindings.values.contains { binding in
            binding.parameterConventions.contains(.inout)
                && body.contains("function_ref @\(binding.mangledName)")
        }
    }

    func unavailableCall(
        for mangledName: String
    ) -> CanonicalSIL.UnavailableDirectCall? {
        unavailableCalls[mangledName]
    }

    func importRequirements(
        referencedBy functions: [IntermediateRepresentation.Function]
    ) throws -> [Bytecode.ImportRequirement] {
        let referencedIDs = Set(functions.flatMap { function in
            function.blocks.flatMap { block in
                block.instructions.compactMap { instruction -> Core.NativeImportID? in
                    switch instruction {
                    case let .nativeApply(_, id, _),
                         let .nativeTryApply(id, _, _, _):
                        id
                    default:
                        nil
                    }
                }
            }
        })
        var byID: [Core.NativeImportID: Bytecode.ImportRequirement] = [:]
        for binding in bindings.values {
            guard case let .nativeImport(requirement) = binding.target,
                  referencedIDs.contains(requirement.id)
            else { continue }
            if let existing = byID[requirement.id], existing != requirement {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native import ID \(requirement.id) has conflicting descriptors"
                )
            }
            byID[requirement.id] = requirement
        }
        guard Set(byID.keys) == referencedIDs else {
            throw CanonicalSIL.LoweringError.invalidCallTable(
                "a lowered native call has no frozen import requirement"
            )
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private init(
        unchecked bindings: [String: CanonicalSIL.DirectCallBinding],
        unavailableCalls: [String: CanonicalSIL.UnavailableDirectCall]
    ) {
        self.bindings = bindings
        self.unavailableCalls = unavailableCalls
    }
}
}
