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
        var bindingsBySymbol: [String: CanonicalSIL.DirectCallBinding] = [:]
        var unavailableBySymbol: [String: CanonicalSIL.UnavailableDirectCall] = [:]

        for function in archive.functions {
            let conventions = function.parameterConventions
            if let localID = localFunctionIDs[function.key] {
                let loweredTypes = zip(function.parameterTypes, conventions).map {
                    type, convention in
                    convention == .inout ? .address(type) : type
                }
                bindingsBySymbol[function.mangledName] = .init(
                    mangledName: function.mangledName,
                    parameterTypes: loweredTypes,
                    parameterConventions: conventions,
                    resultType: function.resultType,
                    effects: function.effects,
                    target: .function(localID)
                )
                continue
            }
            guard function.patchability.isEligible else { continue }
            guard let entry = function.entryIndex else {
                throw PatchCompiler.ArchiveError.ineligibleFunction(
                    function.key,
                    reason: "eligible function has no allocated Shell entry"
                )
            }
            bindingsBySymbol[function.mangledName] = .init(
                mangledName: function.mangledName,
                parameterTypes: function.parameterTypes,
                resultType: function.resultType,
                effects: function.effects,
                target: .entry(entry)
            )
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
            for mangledName in item.silMangledNames {
                // A patchable Shell entry is generation-aware and therefore
                // takes precedence over an optional native-original binding.
                guard bindingsBySymbol[mangledName] == nil else { continue }
                let abiAdapter: CanonicalSIL.DirectCallBinding.ABIAdapter =
                    switch item.abiAdapter {
                    case .direct: .direct
                    case .mutatingValueReceiver: .mutatingValueReceiver
                    }
                bindingsBySymbol[mangledName] = .init(
                    mangledName: mangledName,
                    parameterTypes: item.parameterTypes,
                    resultType: item.resultType,
                    effects: item.effects,
                    target: .nativeImport(requirement),
                    abiAdapter: abiAdapter
                )
            }
        }
        for item in archive.nativeImports where !item.isEmittedToDevice {
            for mangledName in item.silMangledNames where bindingsBySymbol[mangledName] == nil {
                unavailableBySymbol[mangledName] = .init(
                    mangledName: mangledName,
                    canonicalCallee: item.canonicalCallee,
                    reason: "the operation was cataloged but not allowlisted into this Shell; "
                        + "add \(item.canonicalCallee) to nativeImports.allow and ship a new Shell"
                )
            }
        }
        for binding in additionalBindings {
            guard bindingsBySymbol.updateValue(
                binding,
                forKey: binding.mangledName
            ) == nil else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "additional direct-call symbol duplicates an archived binding "
                        + binding.mangledName
                )
            }
        }
        return try CanonicalSIL.DirectCallTable(
            bindingsBySymbol.values.sorted { $0.mangledName < $1.mangledName },
            unavailable: unavailableBySymbol.values.sorted {
                $0.mangledName < $1.mangledName
            }
        )
    }
}
}
