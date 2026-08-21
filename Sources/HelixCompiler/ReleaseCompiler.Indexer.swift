import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

extension ReleaseCompiler {
public struct DeclarationCandidate: Codable, Hashable, Sendable {
    public var moduleName: String
    public var sourceFileLogicalID: String
    public var canonicalDeclaration: String
    public var mangledName: String
    public var role: Core.FunctionRole
    public var loweredSignature: Core.LoweredSignature
    public var parameterTypes: [Bytecode.ValueType]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: Bytecode.ValueType
    public var interface: ReleaseCompiler.DeclarationInterface
    public var canonicalSILBody: String
    public var implementationFingerprint: Core.Digest?
    public var effects: Core.Effects
    public var isAsync: Bool
    public var hasInOut: Bool
    public var isGeneric: Bool
    public var isNoncopyable: Bool
    public var hasTypedThrows: Bool
    public var hasCompleteDynamicCoverage: Bool
    public var forcedPatchability: InterfaceArchive.Patchability?

    public init(
        moduleName: String,
        sourceFileLogicalID: String,
        canonicalDeclaration: String,
        mangledName: String,
        role: Core.FunctionRole,
        loweredSignature: Core.LoweredSignature,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: Bytecode.ValueType,
        interface: ReleaseCompiler.DeclarationInterface,
        canonicalSILBody: String,
        implementationFingerprint: Core.Digest? = nil,
        effects: Core.Effects = .init(),
        isAsync: Bool = false,
        hasInOut: Bool = false,
        isGeneric: Bool = false,
        isNoncopyable: Bool = false,
        hasTypedThrows: Bool = false,
        hasCompleteDynamicCoverage: Bool = true,
        forcedPatchability: InterfaceArchive.Patchability? = nil
    ) {
        self.moduleName = moduleName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.canonicalDeclaration = canonicalDeclaration
        self.mangledName = mangledName
        self.role = role
        self.loweredSignature = loweredSignature
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions
            ?? Array(repeating: .owned, count: parameterTypes.count)
        self.resultType = resultType
        self.interface = interface
        self.canonicalSILBody = canonicalSILBody
        self.implementationFingerprint = implementationFingerprint
        self.effects = effects
        self.isAsync = isAsync
        self.hasInOut = hasInOut
        self.isGeneric = isGeneric
        self.isNoncopyable = isNoncopyable
        self.hasTypedThrows = hasTypedThrows
        self.hasCompleteDynamicCoverage = hasCompleteDynamicCoverage
        self.forcedPatchability = forcedPatchability
    }
}

public struct IndexRequest: Sendable {
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var compatibility: Core.Compatibility
    public var configuration: PatchConfiguration.Document
    public var sources: [InterfaceArchive.SourceRecord]
    public var declarations: [ReleaseCompiler.DeclarationCandidate]
    public var nativeImportCandidates: [InterfaceArchive.NativeImportRecord]
    public var nativeTypes: [InterfaceArchive.TypeRecord]
    public var capabilities: Set<Core.Capability>

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        compatibility: Core.Compatibility,
        configuration: PatchConfiguration.Document,
        sources: [InterfaceArchive.SourceRecord],
        declarations: [ReleaseCompiler.DeclarationCandidate],
        nativeImportCandidates: [InterfaceArchive.NativeImportRecord] = [],
        nativeTypes: [InterfaceArchive.TypeRecord] = [],
        capabilities: Set<Core.Capability> = [.baselineV1]
    ) {
        self.metadata = metadata
        self.compatibility = compatibility
        self.configuration = configuration
        self.sources = sources
        self.declarations = declarations
        self.nativeImportCandidates = nativeImportCandidates
        self.nativeTypes = nativeTypes
        self.capabilities = capabilities
    }
}

public struct IndexReport: Sendable {
    public var archive: InterfaceArchive.Archive
    public var diagnostics: [Core.Diagnostic]
    public var eligibleCount: Int
    public var rejectedCount: Int
    public var emittedImportCount: Int
}

public struct Indexer: Sendable {
    public init() {}

    public func index(_ request: ReleaseCompiler.IndexRequest) throws -> ReleaseCompiler.IndexReport {
        do {
            try request.configuration.validate()
        } catch {
            throw ReleaseCompiler.IndexError.invalidInput(String(describing: error))
        }
        guard Set(request.sources.map(\.logicalPath)).count == request.sources.count else {
            throw ReleaseCompiler.IndexError.invalidInput("duplicate logical source path")
        }

        var records: [InterfaceArchive.FunctionRecord] = []
        var diagnostics: [Core.Diagnostic] = []
        let mainActorNativeTypeIDs = Set(
            request.nativeTypes.filter(\.requiresMainActor).map(\.id)
        )
        for declaration in request.declarations {
            guard declaration.isAsync == declaration.effects.isAsync,
                  declaration.isAsync == declaration.loweredSignature.isAsync,
                  declaration.effects.mayThrow == declaration.loweredSignature.isThrowing
            else {
                throw ReleaseCompiler.IndexError.invalidInput(
                    "declaration async/throwing metadata is inconsistent"
                )
            }
            let referencesGeneratedImplementation =
                ReleaseCompiler.ImplementationFingerprint
                    .referencedSymbols(in: declaration.canonicalSILBody)
                    .contains(where: ReleaseCompiler.ImplementationFingerprint
                        .isCompilerGeneratedSymbol)
            guard !referencesGeneratedImplementation
                    || declaration.implementationFingerprint != nil
            else {
                throw ReleaseCompiler.IndexError.invalidInput(
                    "compiler-generated dependencies require a transitive implementation fingerprint"
                )
            }
            let bodyFingerprint = declaration.implementationFingerprint
                ?? ReleaseCompiler.ImplementationFingerprint.compute(
                    symbol: declaration.mangledName,
                    loweredType: declaration.interface.loweredSILType,
                    body: declaration.canonicalSILBody
                )
            let key = try Core.FunctionKey.derive(
                namespace: request.metadata.shellNamespaceID,
                module: declaration.moduleName,
                sourceFileLogicalID: declaration.sourceFileLogicalID,
                canonicalDeclaration: declaration.canonicalDeclaration,
                loweredSignature: declaration.loweredSignature,
                role: declaration.role
            )
            let patchability = eligibility(
                of: declaration,
                configuration: request.configuration,
                mainActorNativeTypeIDs: mainActorNativeTypeIDs
            )
            if !patchability.isEligible {
                diagnostics.append(
                    .init(
                        code: patchability.reasonCode ?? "HLXIDX999",
                        severity: .note,
                        message: "\(declaration.canonicalDeclaration): \(patchability.explanation ?? "not patchable")",
                        location: .init(file: declaration.sourceFileLogicalID, line: 1, column: 1)
                    )
                )
            }
            records.append(
                .init(
                    key: key,
                    entryIndex: nil,
                    moduleName: declaration.moduleName,
                    sourceFileLogicalID: declaration.sourceFileLogicalID,
                    canonicalDeclaration: declaration.canonicalDeclaration,
                    mangledName: declaration.mangledName,
                    role: declaration.role,
                    loweredSignature: declaration.loweredSignature,
                    parameterTypes: declaration.parameterTypes,
                    parameterConventions: declaration.parameterConventions,
                    resultType: declaration.resultType,
                    effects: declaration.effects,
                    interfaceFingerprint: try declaration.interface.fingerprint(),
                    bodyFingerprint: bodyFingerprint,
                    patchability: patchability
                )
            )
        }
        guard Set(records.map(\.key)).count == records.count,
              Set(records.map(\.mangledName)).count == records.count
        else {
            throw ReleaseCompiler.IndexError.invalidInput("duplicate function key or mangled name")
        }

        let eligibleKeys = records.filter(\.patchability.isEligible).map(\.key).sorted {
            $0.rawValue < $1.rawValue
        }
        let entryByKey = Dictionary(uniqueKeysWithValues: eligibleKeys.enumerated().map {
            ($0.element, Core.EntryIndex(rawValue: UInt32($0.offset)))
        })
        for index in records.indices {
            if let entry = entryByKey[records[index].key] {
                records[index].entryIndex = entry
                records[index].bridgeSymbol = "hlx_entry_\(entry.rawValue)_\(records[index].key.rawValue.hex.prefix(12))"
            }
        }

        let allowList = Set(
            request.configuration.modules[
                request.metadata.frontendInvocation.moduleName
            ]?.nativeImports.allow ?? []
        )
        var imports = request.nativeImportCandidates
        for index in imports.indices {
            imports[index].isEmittedToDevice = imports[index].isEmittedToDevice
                && allowList.contains(imports[index].canonicalCallee)
            imports[index].id = nil
        }
        let emittedKeys = imports.filter(\.isEmittedToDevice).map(\.key).sorted {
            $0.rawValue < $1.rawValue
        }
        let importIDByKey = Dictionary(uniqueKeysWithValues: emittedKeys.enumerated().map {
            ($0.element, Core.NativeImportID(rawValue: UInt32($0.offset)))
        })
        for index in imports.indices where imports[index].isEmittedToDevice {
            imports[index].id = importIDByKey[imports[index].key]
        }

        var capabilities = request.capabilities
        // Patch-local features may first appear after the Shell is released.
        // Advertising VM-only capabilities up front does not widen native ABI.
        capabilities.formUnion([
            .baselineV1,
            .stringsV1,
            .collectionsV1,
            .localNominalsV1,
            .structuredErrorsV1,
            .addressValuesV1,
            .borrowCallsV1,
            .closureValuesV1,
            .escapingClosureValuesV1,
            .mutableCapturesV1,
            .nonOwningReferencesV1,
            .compilerSpecializationsV1,
            .anyValuesV1,
            .localClassesV1,
            .hostedObjectiveCClassesV1,
        ])
        if records.contains(where: {
            $0.patchability.isEligible && $0.effects.isAsync
        }) {
            capabilities.insert(.asyncLeafEntriesV1)
        }
        if imports.contains(where: \.isEmittedToDevice) { capabilities.insert(.nativeImportsV1) }
        if request.nativeTypes.contains(where: \.isEmittedToDevice) { capabilities.insert(.nativeTypesV1) }
        if records.contains(where: { $0.effects.mayThrow })
            || imports.contains(where: { $0.isEmittedToDevice && $0.effects.mayThrow }) {
            capabilities.insert(.untypedThrowsV1)
        }
        if records.contains(where: { $0.effects.requiresMainActor })
            || imports.contains(where: { $0.isEmittedToDevice && $0.effects.requiresMainActor }) {
            capabilities.insert(.mainActorSyncV1)
        }

        var metadata = request.metadata
        var baselineHasher = Core.StableHasher(domain: "HLXI.SourceBaseline.v1")
        for source in request.sources.sorted(by: { $0.logicalPath < $1.logicalPath }) {
            baselineHasher.append(source.logicalPath)
            baselineHasher.append(source.contentHash)
        }
        metadata.sourceBaselineHash = baselineHasher.finalize()

        let eligibleCount = records.filter(\.patchability.isEligible).count
        let archive = try InterfaceArchive.Archive.make(
            metadata: metadata,
            compatibility: request.compatibility,
            capabilities: capabilities,
            sources: request.sources,
            functions: records,
            nativeImports: imports,
            nativeTypes: request.nativeTypes,
            bridgeRegistrationCount: UInt32(eligibleCount)
        )
        return .init(
            archive: archive,
            diagnostics: diagnostics,
            eligibleCount: eligibleCount,
            rejectedCount: records.count - eligibleCount,
            emittedImportCount: imports.filter(\.isEmittedToDevice).count
        )
    }

    private func eligibility(
        of candidate: ReleaseCompiler.DeclarationCandidate,
        configuration: PatchConfiguration.Document,
        mainActorNativeTypeIDs: Set<Core.TypeID>
    ) -> InterfaceArchive.Patchability {
        if let forced = candidate.forcedPatchability { return forced }
        guard let module = configuration.modules[candidate.moduleName] else {
            return .rejected("HLXIDX001", explanation: "module is absent from HelixPatchable.yml")
        }
        guard module.includes(logicalPath: candidate.sourceFileLogicalID) else {
            return .rejected("HLXIDX002", explanation: "source is outside the module include set")
        }
        if !module.entrypoints.allows(accessLevel: candidate.interface.accessLevel) {
            return .rejected(
                "HLXIDX003",
                explanation: "entrypoint visibility excludes this declaration"
            )
        }
        if candidate.role == .initializer || candidate.role == .deinitializer {
            return .rejected("HLXIDX004", explanation: "initializer/deinitializer roots are not supported in HLBC v1")
        }
        if candidate.isAsync {
            do {
                try CanonicalSIL.AsyncLeaf.validate(
                    .init(
                        mangledName: candidate.mangledName,
                        loweredType: candidate.interface.loweredSILType,
                        body: candidate.canonicalSILBody
                    ),
                    effects: candidate.effects
                )
            } catch {
                return .rejected(
                    "HLXIDX005",
                    explanation: "async root is outside the non-suspending leaf profile: \(error)"
                )
            }
        }
        if candidate.hasInOut {
            return .rejected("HLXIDX006", explanation: "inout/borrowing/consuming roots are not supported in HLBC v1")
        }
        if candidate.isGeneric || candidate.interface.genericSignature != nil {
            return .rejected("HLXIDX007", explanation: "generic roots are not supported in HLBC v1")
        }
        if candidate.isNoncopyable {
            return .rejected("HLXIDX008", explanation: "noncopyable values are not supported in HLBC v1")
        }
        if candidate.hasTypedThrows {
            return .rejected("HLXIDX009", explanation: "typed throws/rethrows are not supported in HLBC v1")
        }
        if !candidate.hasCompleteDynamicCoverage {
            return .rejected("HLXIDX010", explanation: "one or more call sites contain an inlined copy")
        }
        if (candidate.parameterTypes + [candidate.resultType]).contains(where: containsClosure) {
            return .rejected(
                "HLXIDX022",
                explanation: "closure-valued declarations are patch-local helpers and cannot be Shell roots"
            )
        }
        if !candidate.parameterTypes.allSatisfy({ isSupportedType($0, allowVoid: false) })
            || !isSupportedType(candidate.resultType, allowVoid: true) {
            return .rejected("HLXIDX011", explanation: "lowered signature contains an unsupported value type")
        }
        if !candidate.effects.requiresMainActor,
           (candidate.parameterTypes + [candidate.resultType]).contains(where: {
               containsNativeType($0, ids: mainActorNativeTypeIDs)
           }) {
            return .rejected(
                "HLXIDX021",
                explanation: "a MainActor native type requires a MainActor function"
            )
        }
        return .eligible
    }

    private func containsNativeType(
        _ type: Bytecode.ValueType,
        ids: Set<Core.TypeID>
    ) -> Bool {
        switch type {
        case let .native(id): ids.contains(id)
        case let .array(element), let .optional(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element),
             let .arrayState(_, element):
            containsNativeType(element, ids: ids)
        case let .dictionary(key, value):
            containsNativeType(key, ids: ids) || containsNativeType(value, ids: ids)
        case let .dictionaryState(key, value):
            containsNativeType(key, ids: ids) || containsNativeType(value, ids: ids)
        case let .tuple(elements):
            elements.contains { containsNativeType($0, ids: ids) }
        case let .closure(signature):
            (signature.parameters + [signature.result]).contains {
                containsNativeType($0, ids: ids)
            }
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error:
            false
        }
    }

    private func isSupportedType(_ type: Bytecode.ValueType, allowVoid: Bool) -> Bool {
        switch type {
        case .void: allowVoid
        case .never: false
        case .address, .mutableCell, .nonOwningReference, .arrayState,
             .dictionaryState,
             .closure: false
        case .bool, .integer, .float, .string, .any, .native: true
        case .local, .error: false
        case let .tuple(elements):
            elements.count <= 64 && elements.allSatisfy { isSupportedType($0, allowVoid: false) }
        case let .optional(wrapped):
            isSupportedType(wrapped, allowVoid: false)
        case let .array(element):
            isSupportedType(element, allowVoid: false)
        case let .dictionary(key, value):
            key.isVMHashable
                && isSupportedType(value, allowVoid: false)
        case let .set(element):
            element.isVMHashable && isSupportedType(element, allowVoid: false)
        }
    }

    private func containsClosure(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .closure:
            true
        case let .array(element), let .optional(element), let .set(element),
             let .address(element):
            containsClosure(element)
        case let .dictionary(key, value):
            containsClosure(key) || containsClosure(value)
        case let .tuple(elements):
            elements.contains(where: containsClosure)
        default:
            false
        }
    }

}

public enum IndexError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)

    public var description: String {
        switch self {
        case let .invalidInput(reason): "release index failed: \(reason)"
        }
    }
}
}
