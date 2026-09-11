import HelixBytecode
import HelixCore
import HelixInterface

extension CanonicalSIL {
/// A statically resolved Swift call target. Helix never performs symbol lookup
/// on-device; the release archive freezes every mapping before patch creation.
public struct DirectCallBinding: Hashable, Sendable {
    public enum ABIAdapter: Hashable, Sendable {
        case direct
        case mutatingValueReceiver
        /// A compiler-generated `(Root, KeyPath<Root, Value>) -> Value`
        /// thunk whose proven static KeyPath capture is erased before HLBC.
        /// The identity is build-time-only and never enters the wire format.
        case staticKeyPathProjection(identity: String)
    }

    public enum Target: Hashable, Sendable {
        case function(Bytecode.FunctionID)
        case entry(Core.EntryIndex)
        case nativeImport(Bytecode.ImportRequirement)
    }

    public var mangledName: String
    public var parameterTypes: [Bytecode.ValueType]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var parameterProjection: InterfaceArchive.NativeImportParameterProjection
    public var resultType: Bytecode.ValueType
    public var effects: Core.Effects
    public var target: Target
    public var abiAdapter: ABIAdapter
    var genericSpecialization: CanonicalSIL.GenericFunction.Specialization?

    public init(
        mangledName: String,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        parameterProjection: InterfaceArchive.NativeImportParameterProjection? = nil,
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        target: Target,
        abiAdapter: ABIAdapter = .direct
    ) {
        self.init(
            mangledName: mangledName,
            parameterTypes: parameterTypes,
            parameterConventions: parameterConventions,
            parameterProjection: parameterProjection,
            resultType: resultType,
            effects: effects,
            target: target,
            abiAdapter: abiAdapter,
            genericSpecialization: nil
        )
    }

    init(
        mangledName: String,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        parameterProjection: InterfaceArchive.NativeImportParameterProjection? = nil,
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        target: Target,
        abiAdapter: ABIAdapter = .direct,
        genericSpecialization: CanonicalSIL.GenericFunction.Specialization?
    ) {
        self.mangledName = mangledName
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions ?? parameterTypes.map { type in
            if case .address = type { return .inout }
            return .owned
        }
        self.parameterProjection = parameterProjection
            ?? .identity(parameterCount: parameterTypes.count)
        self.resultType = resultType
        self.effects = effects
        self.target = target
        self.abiAdapter = abiAdapter
        self.genericSpecialization = genericSpecialization
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
    private var bindings: [String: [CanonicalSIL.DirectCallBinding]]
    private var unavailableCalls: [String: CanonicalSIL.UnavailableDirectCall]
    private var declarationReferences: CanonicalSIL.DeclarationReferenceMap

    public static let empty = CanonicalSIL.DirectCallTable(
        unchecked: [:],
        unavailableCalls: [:]
    )

    public init(
        _ values: [CanonicalSIL.DirectCallBinding],
        unavailable: [CanonicalSIL.UnavailableDirectCall] = []
    ) throws {
        var result: [String: [CanonicalSIL.DirectCallBinding]] = [:]
        for value in values {
            guard !value.mangledName.isEmpty,
                  value.parameterConventions.count == value.parameterTypes.count
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "empty or convention-mismatched direct-call symbol "
                    + value.mangledName
                )
            }
            if let specialization = value.genericSpecialization {
                let reparsedArguments = try? CanonicalSIL.GenericFunction
                    .arguments(in: specialization.arguments.joined(separator: ", "))
                guard case .function = value.target,
                      value.abiAdapter == .direct,
                      value.parameterProjection == .identity(
                        parameterCount: value.parameterTypes.count
                      ),
                      reparsedArguments == specialization.arguments,
                      !specialization.concreteLoweredType.isEmpty,
                      !CanonicalSIL.GenericFunction.isGeneric(
                        loweredType: specialization.concreteLoweredType
                      )
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "generic specialization @\(value.mangledName) has an invalid concrete binding"
                    )
                }
            }
            if case let .nativeImport(requirement) = value.target {
                guard requirement.effects == value.effects else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native import \(requirement.id) effect descriptor disagrees with its call binding"
                    )
                }
                do {
                    try requirement.contract.validate(effects: value.effects)
                } catch {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native import \(requirement.id) has an invalid contract: \(error)"
                    )
                }
                var callbackIndices = Set<Int>()
                for callback in requirement.contract.callbacks {
                    let index = Int(callback.parameterIndex)
                    let expectedConvention: Bytecode.ParameterConvention =
                        callback.lifetime == .nonescaping
                            ? .borrowed : .owned
                    guard value.parameterTypes.indices.contains(index),
                          callbackIndices.insert(index).inserted,
                          value.parameterConventions[index]
                            == expectedConvention,
                          let shape = value.parameterTypes[index]
                            .directClosureShape,
                          shape.signature.isNativeBridgeCallback,
                          !(shape.isOptional
                            && callback.lifetime == .nonescaping)
                    else {
                        throw CanonicalSIL.LoweringError.invalidCallTable(
                            "native import \(requirement.id) callback index or shape is invalid"
                        )
                    }
                }
                guard value.parameterTypes.enumerated().allSatisfy({
                    index, type in
                    callbackIndices.contains(index) || !type.containsClosureValue
                }), value.parameterConventions.enumerated().allSatisfy({
                    index, convention in
                    callbackIndices.contains(index) || convention == .owned
                }) else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native import \(requirement.id) has an undeclared callback or invalid value convention"
                    )
                }
            }
            guard value.parameterProjection.isValid(
                logicalParameterCount: value.parameterTypes.count
            ) else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "direct-call @\(value.mangledName) has an invalid physical parameter projection"
                )
            }
            if value.parameterProjection != .identity(parameterCount: value.parameterTypes.count) {
                guard case .nativeImport = value.target else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "non-NativeImport @\(value.mangledName) changes physical parameter order or count"
                    )
                }
            }
            if case let .staticKeyPathProjection(identity) = value.abiAdapter {
                guard !identity.isEmpty,
                      value.parameterTypes.count == 1,
                      value.parameterConventions.count == 1,
                      value.resultType != .void,
                      !value.effects.mayThrow,
                      !value.effects.isAsync,
                      case .function = value.target
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "static KeyPath projection @\(value.mangledName) has an invalid logical ABI"
                    )
                }
            }
            if let existing = result[value.mangledName] {
                let validNativeVariants: Bool = if case .nativeImport = value.target {
                    existing.allSatisfy { binding in
                        guard case .nativeImport = binding.target else {
                            return false
                        }
                        return Self.nativeVariantsArePhysicallyCompatible(
                            binding,
                            value
                        )
                    }
                } else {
                    false
                }
                let validGenericSpecializations: Bool = if
                    case .function = value.target,
                    let specialization = value.genericSpecialization
                {
                    existing.allSatisfy { binding in
                        guard case .function = binding.target,
                              let existingSpecialization = binding.genericSpecialization
                        else { return false }
                        return existingSpecialization.arguments
                            != specialization.arguments
                    }
                } else {
                    false
                }
                guard validNativeVariants || validGenericSpecializations
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "duplicate or physically inconsistent direct-call symbol "
                            + value.mangledName
                    )
                }
            }
            result[value.mangledName, default: []].append(value)
        }
        for symbol in Array(result.keys) {
            result[symbol]?.sort(by: Self.bindingOrder)
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
        guard let variants = bindings[mangledName], variants.count == 1 else {
            return nil
        }
        return variants[0]
    }

    func bindings(
        for mangledName: String
    ) -> [CanonicalSIL.DirectCallBinding] {
        bindings[mangledName] ?? []
    }

    func hasBinding(for mangledName: String) -> Bool {
        bindings[mangledName] != nil
    }

    var boundSymbols: Set<String> {
        Set(bindings.keys)
    }

    var functionIDs: Set<Bytecode.FunctionID> {
        Set(bindings.values.flatMap { $0 }.compactMap { binding in
            guard case let .function(id) = binding.target else { return nil }
            return id
        })
    }

    var nativeDefaultArgumentGeneratorSymbols: Set<String> {
        Set(bindings.values.flatMap { $0 }.flatMap { binding -> [String] in
            guard case .nativeImport = binding.target else { return [] }
            return binding.parameterProjection.defaultArguments.compactMap {
                argument in
                argument.origin == .externalGenerator
                    ? argument.generatorSymbol : nil
            }
        })
    }

    func adding(
        _ additionalBindings: [CanonicalSIL.DirectCallBinding]
    ) throws -> CanonicalSIL.DirectCallTable {
        var result = try CanonicalSIL.DirectCallTable(
            bindings.values.flatMap { $0 } + additionalBindings,
            unavailable: Array(unavailableCalls.values)
        )
        result.declarationReferences = declarationReferences
        return result
    }

    var requiresDeclarationReferences: Bool {
        bindings.keys.contains(where:
            CanonicalSIL.NativeBridgeSymbols
                .isDeclarationQualifiedForeignCall
        ) || unavailableCalls.keys.contains(where:
            CanonicalSIL.NativeBridgeSymbols
                .isDeclarationQualifiedForeignCall
        )
    }

    func includingDeclarationReferences(
        _ references: CanonicalSIL.DeclarationReferenceMap
    ) -> CanonicalSIL.DirectCallTable {
        var result = self
        result.declarationReferences = references
        return result
    }

    func resolvedForeignSymbol(
        _ symbol: String,
        at location: Core.SourceLocation?
    ) -> String {
        if let usr = declarationReferences.usr(at: location) {
            let qualified = CanonicalSIL.NativeBridgeSymbols
                .declarationQualifiedForeignCall(
                    symbol: symbol,
                    declarationUSR: usr
                )
            if bindings[qualified] != nil
                || unavailableCalls[qualified] != nil
            {
                return qualified
            }
        }
        return symbol
    }

    func referencesInoutCallee(in body: String) -> Bool {
        bindings.values.flatMap { $0 }.contains { binding in
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
                         let .nativeTryApply(id, _, _, _),
                         let .makeClosure(_, .nativeImport(id), _, _):
                        id
                    default:
                        nil
                    }
                }
            }
        })
        var byID: [Core.NativeImportID: Bytecode.ImportRequirement] = [:]
        for binding in bindings.values.flatMap({ $0 }) {
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
                "a lowered native call has no captured import requirement"
            )
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    func entryParameterConventions(
        referencedBy functions: [IntermediateRepresentation.Function]
    ) throws -> [Core.EntryIndex: [Bytecode.ParameterConvention]] {
        let referencedEntries = Set(functions.flatMap { function in
            function.blocks.flatMap { block in
                block.instructions.compactMap { instruction -> Core.EntryIndex? in
                    switch instruction {
                    case let .entryApply(_, entry, _),
                         let .entryTryApply(entry, _, _, _),
                         let .makeClosure(_, .entry(entry), _, _):
                        entry
                    default:
                        nil
                    }
                }
            }
        })
        var byEntry: [
            Core.EntryIndex: [Bytecode.ParameterConvention]
        ] = [:]
        for binding in bindings.values.flatMap({ $0 }) {
            guard case let .entry(entry) = binding.target,
                  referencedEntries.contains(entry)
            else { continue }
            if let existing = byEntry[entry],
               existing != binding.parameterConventions {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "Shell entry \(entry) has conflicting parameter conventions"
                )
            }
            byEntry[entry] = binding.parameterConventions
        }
        guard Set(byEntry.keys) == referencedEntries else {
            throw CanonicalSIL.LoweringError.invalidCallTable(
                "a lowered Shell entry call has no captured ownership ABI"
            )
        }
        return byEntry
    }

    private init(
        unchecked bindings: [String: [CanonicalSIL.DirectCallBinding]],
        unavailableCalls: [String: CanonicalSIL.UnavailableDirectCall]
    ) {
        self.bindings = bindings
        self.unavailableCalls = unavailableCalls
        declarationReferences = .empty
    }

    private static func bindingOrder(
        _ lhs: CanonicalSIL.DirectCallBinding,
        _ rhs: CanonicalSIL.DirectCallBinding
    ) -> Bool {
        let left = lhs.parameterProjection.logicalParameterIndices
        let right = rhs.parameterProjection.logicalParameterIndices
        if left != right { return left.lexicographicallyPrecedes(right) }
        let leftSpecialization = lhs.genericSpecialization?.arguments ?? []
        let rightSpecialization = rhs.genericSpecialization?.arguments ?? []
        if leftSpecialization != rightSpecialization {
            return leftSpecialization.lexicographicallyPrecedes(
                rightSpecialization
            )
        }
        if case let .nativeImport(leftRequirement) = lhs.target,
           case let .nativeImport(rightRequirement) = rhs.target,
           leftRequirement.key != rightRequirement.key {
            return leftRequirement.key.description
                < rightRequirement.key.description
        }
        return false
    }

    private static func nativeVariantsArePhysicallyCompatible(
        _ lhs: CanonicalSIL.DirectCallBinding,
        _ rhs: CanonicalSIL.DirectCallBinding
    ) -> Bool {
        guard case let .nativeImport(lhsRequirement) = lhs.target,
              case let .nativeImport(rhsRequirement) = rhs.target,
              lhs.parameterProjection.physicalParameterCount
                == rhs.parameterProjection.physicalParameterCount,
              lhs.effects == rhs.effects,
              lhs.abiAdapter == rhs.abiAdapter,
              lhsRequirement.requiredCapability
                == rhsRequirement.requiredCapability
        else { return false }

        var lhsBaseContract = lhsRequirement.contract
        var rhsBaseContract = rhsRequirement.contract
        lhsBaseContract.callbacks = []
        rhsBaseContract.callbacks = []
        guard lhsBaseContract == rhsBaseContract else { return false }

        let lhsProjection = lhs.parameterProjection.logicalParameterIndices
        let rhsProjection = rhs.parameterProjection.logicalParameterIndices
        if lhsProjection == rhsProjection {
            // A generic protocol-extension function can retain one symbol and
            // one physical projection for several concrete NativeCallKeys. Its
            // apply substitution produces a concrete function type, which the
            // lowerer uses to select exactly one distinct logical signature.
            return lhs.parameterProjection == rhs.parameterProjection
                && lhs.parameterConventions == rhs.parameterConventions
                && lhsRequirement.contract.callbacks
                    == rhsRequirement.contract.callbacks
                && (lhs.parameterTypes != rhs.parameterTypes
                    || lhs.resultType != rhs.resultType)
        }

        guard lhs.resultType == rhs.resultType else { return false }

        let lhsParameterTypes = Dictionary(uniqueKeysWithValues: zip(
            lhsProjection,
            lhs.parameterTypes
        ))
        let rhsParameterTypes = Dictionary(uniqueKeysWithValues: zip(
            rhsProjection,
            rhs.parameterTypes
        ))
        let lhsConventions = Dictionary(uniqueKeysWithValues: zip(
            lhs.parameterProjection.logicalParameterIndices,
            lhs.parameterConventions
        ))
        let rhsConventions = Dictionary(uniqueKeysWithValues: zip(
            rhs.parameterProjection.logicalParameterIndices,
            rhs.parameterConventions
        ))
        for index in Set(lhsParameterTypes.keys).intersection(
            rhsParameterTypes.keys
        ) {
            guard lhsParameterTypes[index] == rhsParameterTypes[index],
                  lhsConventions[index] == rhsConventions[index]
            else {
                return false
            }
        }

        let lhsDefaults = Dictionary(uniqueKeysWithValues:
            lhs.parameterProjection.defaultArguments.map {
                ($0.physicalParameterIndex, $0)
            }
        )
        let rhsDefaults = Dictionary(uniqueKeysWithValues:
            rhs.parameterProjection.defaultArguments.map {
                ($0.physicalParameterIndex, $0)
            }
        )
        for index in Set(lhsDefaults.keys).intersection(rhsDefaults.keys) {
            guard lhsDefaults[index] == rhsDefaults[index] else { return false }
        }

        func callbackLifetimes(
            _ binding: CanonicalSIL.DirectCallBinding,
            _ requirement: Bytecode.ImportRequirement
        ) -> [UInt16: Core.NativeImportCallbackLifetime] {
            Dictionary(uniqueKeysWithValues: requirement.contract.callbacks.map {
                callback in
                let logicalIndex = Int(callback.parameterIndex)
                return (
                    binding.parameterProjection
                        .logicalParameterIndices[logicalIndex],
                    callback.lifetime
                )
            })
        }
        let lhsCallbacks = callbackLifetimes(lhs, lhsRequirement)
        let rhsCallbacks = callbackLifetimes(rhs, rhsRequirement)
        for index in Set(lhsCallbacks.keys).intersection(rhsCallbacks.keys) {
            guard lhsCallbacks[index] == rhsCallbacks[index] else {
                return false
            }
        }
        return true
    }
}
}
