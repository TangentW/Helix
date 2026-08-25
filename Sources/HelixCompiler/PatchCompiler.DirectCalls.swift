import HelixBytecode
import HelixCore
import HelixInterface

extension PatchCompiler {
enum DirectCalls {
    static func make(
        archive: InterfaceArchive.Archive,
        localFunctionIDs: [Core.FunctionKey: Bytecode.FunctionID],
        additionalBindings: [CanonicalSIL.DirectCallBinding] = []
    ) throws -> CanonicalSIL.DirectCallTable {
        var bindings: [CanonicalSIL.DirectCallBinding] = []
        var functionSymbols = Set<String>()
        var emittedNativeSymbols = Set<String>()
        var unavailableBySymbol: [String: CanonicalSIL.UnavailableDirectCall] = [:]

        for function in archive.functions {
            let conventions = function.parameterConventions
            if let localID = localFunctionIDs[function.key] {
                let loweredTypes = zip(function.parameterTypes, conventions).map {
                    type, convention in
                    convention == .inout ? .address(type) : type
                }
                guard functionSymbols.insert(function.mangledName).inserted else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "archive contains duplicate function symbol "
                            + function.mangledName
                    )
                }
                bindings.append(.init(
                    mangledName: function.mangledName,
                    parameterTypes: loweredTypes,
                    parameterConventions: conventions,
                    resultType: function.resultType,
                    effects: function.effects,
                    target: .function(localID)
                ))
                continue
            }
            guard function.patchability.isEligible else { continue }
            guard let entry = function.entryIndex else {
                throw PatchCompiler.ArchiveError.ineligibleFunction(
                    function.key,
                    reason: "eligible function has no allocated Shell entry"
                )
            }
            guard functionSymbols.insert(function.mangledName).inserted else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "archive contains duplicate function symbol "
                        + function.mangledName
                )
            }
            bindings.append(.init(
                mangledName: function.mangledName,
                parameterTypes: function.parameterTypes,
                parameterConventions: function.parameterConventions,
                resultType: function.resultType,
                effects: function.effects,
                target: .entry(entry)
            ))
        }

        for item in archive.nativeImports where item.isEmittedToDevice {
            guard let id = item.id else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "emitted native import \(item.canonicalCallee) has no ID"
                )
            }
            let requirement = Bytecode.ImportRequirement(
                id: id,
                key: item.key,
                signature: item.signature,
                effects: item.effects,
                contract: item.contract,
                requiredCapability: item.capability
            )
            let callbackLifetimeByParameter = Dictionary(
                uniqueKeysWithValues: item.contract.callbacks.map {
                    (Int($0.parameterIndex), $0.lifetime)
                }
            )
            let parameterConventions = item.parameterTypes.indices.map { index in
                callbackLifetimeByParameter[index] == .nonescaping
                    ? Bytecode.ParameterConvention.borrowed : .owned
            }
            for mangledName in item.silMangledNames {
                // A patchable Shell entry is generation-aware and therefore
                // takes precedence over an optional native-original binding.
                guard !functionSymbols.contains(mangledName) else { continue }
                let abiAdapter: CanonicalSIL.DirectCallBinding.ABIAdapter =
                    switch item.abiAdapter {
                    case .direct: .direct
                    case .mutatingValueReceiver: .mutatingValueReceiver
                    }
                bindings.append(.init(
                    mangledName: mangledName,
                    parameterTypes: item.parameterTypes,
                    parameterConventions: parameterConventions,
                    parameterProjection: item.parameterProjection,
                    resultType: item.resultType,
                    effects: item.effects,
                    target: .nativeImport(requirement),
                    abiAdapter: abiAdapter
                ))
                emittedNativeSymbols.insert(mangledName)
            }
        }
        for item in archive.nativeImports where !item.isEmittedToDevice {
            for mangledName in item.silMangledNames
            where !functionSymbols.contains(mangledName)
                && !emittedNativeSymbols.contains(mangledName)
                && unavailableBySymbol[mangledName] == nil {
                unavailableBySymbol[mangledName] = .init(
                    mangledName: mangledName,
                    canonicalCallee: item.canonicalCallee,
                    reason: "the operation was cataloged but not selected for this Shell; "
                        + "add \(item.canonicalCallee) to nativeImports.allow and ship a new Shell"
                )
            }
        }
        for binding in additionalBindings {
            guard !functionSymbols.contains(binding.mangledName),
                  !emittedNativeSymbols.contains(binding.mangledName)
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "additional direct-call symbol duplicates an archived binding "
                    + binding.mangledName
                )
            }
            bindings.append(binding)
            functionSymbols.insert(binding.mangledName)
        }
        return try CanonicalSIL.DirectCallTable(
            bindings.sorted {
                if $0.mangledName != $1.mangledName {
                    return $0.mangledName < $1.mangledName
                }
                return $0.parameterProjection.logicalParameterIndices
                    .lexicographicallyPrecedes(
                        $1.parameterProjection.logicalParameterIndices
                    )
            },
            unavailable: unavailableBySymbol.values.sorted {
                $0.mangledName < $1.mangledName
            }
        )
    }
}
}
