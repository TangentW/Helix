#if canImport(HelixCore)
import HelixInterface
#endif

extension Verification.ShellInterface {
    public init(archive: InterfaceArchive.Archive) throws {
        try archive.validate()
        try self.init(
            interfaceHash: archive.shellInterfaceHash,
            compatibility: archive.compatibility,
            capabilities: Set(archive.capabilities),
            entries: archive.functions.compactMap { function in
                guard function.patchability.isEligible, let index = function.entryIndex else { return nil }
                return Verification.ResolvedEntry(
                    index: index,
                    key: function.key,
                    parameterTypes: function.parameterTypes,
                    resultType: function.resultType,
                    effects: function.effects,
                    fallbackAllowed: function.fallbackAllowed
                )
            },
            imports: archive.nativeImports.compactMap { item in
                guard item.isEmittedToDevice, let id = item.id else { return nil }
                return Verification.ResolvedNativeImport(
                    id: id,
                    key: item.key,
                    parameterTypes: item.parameterTypes,
                    resultType: item.resultType,
                    signature: item.signature,
                    effects: item.effects,
                    contract: item.contract,
                    capability: item.capability
                )
            },
            types: archive.nativeTypes.compactMap { item in
                guard item.isEmittedToDevice else { return nil }
                let kind: Verification.NativeTypeKind = switch item.kind {
                case .value: .value
                case .reference: .reference
                case .enumeration: .enumeration
                }
                return Verification.ResolvedNativeType(
                    id: item.id,
                    canonicalName: item.canonicalName,
                    kind: kind,
                    layoutFingerprint: item.layoutFingerprint,
                    isCopyable: item.isCopyable,
                    requiresMainActor: item.requiresMainActor,
                    estimatedSize: item.estimatedSize
                )
            }
        )
    }
}
