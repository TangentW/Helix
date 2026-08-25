import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

public enum PatchCompiler {}

extension PatchCompiler {
public struct Request: Sendable {
    public var canonicalSIL: String
    public var mangledName: String
    public var displayName: String
    public var functionID: Bytecode.FunctionID
    public var functionKey: Core.FunctionKey
    public var entryIndex: Core.EntryIndex
    public var shellInterfaceHash: Core.Digest
    public var compatibility: Core.Compatibility
    public var requestedResources: Core.ResourceLimits
    public var directCalls: CanonicalSIL.DirectCallTable
    public var nativeTypes: [String: Core.TypeID]
    /// Compiler-proven alternate Swift/SIL spellings, grouped so ambiguous
    /// aliases can be omitted instead of guessed.
    public var nativeTypeAliases: [String: Set<Core.TypeID>]
    public var nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind]
    /// Frozen native types whose values and hosted subclasses are MainActor-bound.
    public var mainActorNativeTypes: Set<Core.TypeID>
    public var frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord]
    /// SIL symbols that already belong to the finalized Shell. Hosted callback
    /// discovery must never reinterpret one of these declarations as a newly
    /// introduced patch-local class method.
    public var shellDeclarationSymbols: Set<String>
    public var effects: Core.Effects?
    /// Restrictions that apply only to the selected root. Newly discovered
    /// helpers retain their own ordinary Swift property-access semantics.
    public var nativePropertyAccessPolicy: CanonicalSIL.NativePropertyAccessPolicy
    /// The only source path permitted in emitted HLBC diagnostics. When nil,
    /// the compiler drops all source locations instead of retaining host paths.
    public var sourceFileLogicalID: String?

    public init(
        canonicalSIL: String,
        mangledName: String,
        displayName: String,
        functionID: Bytecode.FunctionID = .init(rawValue: 0),
        functionKey: Core.FunctionKey,
        entryIndex: Core.EntryIndex,
        shellInterfaceHash: Core.Digest,
        compatibility: Core.Compatibility,
        requestedResources: Core.ResourceLimits = .init(),
        directCalls: CanonicalSIL.DirectCallTable = .empty,
        nativeTypes: [String: Core.TypeID] = [:],
        nativeTypeAliases: [String: Set<Core.TypeID>] = [:],
        nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:],
        mainActorNativeTypes: Set<Core.TypeID> = [],
        frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord] = [],
        shellDeclarationSymbols: Set<String> = [],
        effects: Core.Effects? = nil,
        nativePropertyAccessPolicy: CanonicalSIL.NativePropertyAccessPolicy = .unrestricted,
        sourceFileLogicalID: String? = nil
    ) {
        self.canonicalSIL = canonicalSIL
        self.mangledName = mangledName
        self.displayName = displayName
        self.functionID = functionID
        self.functionKey = functionKey
        self.entryIndex = entryIndex
        self.shellInterfaceHash = shellInterfaceHash
        self.compatibility = compatibility
        self.requestedResources = requestedResources
        self.directCalls = directCalls
        self.nativeTypes = nativeTypes
        self.nativeTypeAliases = nativeTypeAliases
        self.nativeTypeKinds = nativeTypeKinds
        self.mainActorNativeTypes = mainActorNativeTypes
        self.frozenValueTypes = frozenValueTypes
        self.shellDeclarationSymbols = shellDeclarationSymbols
        self.effects = effects
        self.nativePropertyAccessPolicy = nativePropertyAccessPolicy
        self.sourceFileLogicalID = sourceFileLogicalID
    }
}

public struct Result: Sendable {
    public var module: Bytecode.Module
    public var bytecode: Data
    public var disassembly: String
    public var bodyFingerprint: Core.Digest
}

public struct Driver: Sendable {
    public init() {}

    public func compile(_ request: PatchCompiler.Request) throws -> PatchCompiler.Result {
        let file = try CanonicalSIL.File(text: request.canonicalSIL)
        let typeEnvironment = try file.typeEnvironment.includingNativeTypes(
            request.nativeTypes,
            aliases: request.nativeTypeAliases,
            kinds: request.nativeTypeKinds,
            requiresMainActor: request.mainActorNativeTypes
        )
        try typeEnvironment.validateFrozenValueTypes(request.frozenValueTypes)
        guard let silFunction = file.function(mangledName: request.mangledName) else {
            throw CanonicalSIL.LoweringError.functionSelection("function @\(request.mangledName) was not found")
        }
        guard !CanonicalSIL.ProtocolExistential.Identity
            .containsProtocolExistential(
                in: silFunction.loweredType
            ) else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "protocol existential Shell root \(request.displayName)"
            )
        }
        let imagePlan = try PatchCompiler.ImageFunctions.makePlan(
            file: file,
            root: silFunction,
            rootID: request.functionID,
            typeEnvironment: typeEnvironment,
            directCalls: request.directCalls,
            executionEffectEnvelope: request.effects ?? .init(),
            shellDeclarationSymbols: request.shellDeclarationSymbols
        )
        var root = try CanonicalSIL.Lowerer(
            typeEnvironment: typeEnvironment,
            file: file
        ).lower(
            silFunction,
            displayName: request.displayName,
            directCalls: imagePlan.directCalls,
            expectedEffects: request.effects,
            nativePropertyAccessPolicy: request.nativePropertyAccessPolicy
        )
        root = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
            root,
            logicalPaths: request.sourceFileLogicalID.map { [$0] } ?? []
        )
        var loweredByID: [(
            id: Bytecode.FunctionID,
            function: IntermediateRepresentation.Function
        )] = [(request.functionID, root)]
        for item in imagePlan.functions {
            var lowered = try CanonicalSIL.Lowerer(
                typeEnvironment: typeEnvironment,
                file: file
            ).lower(
                item.function,
                displayName: item.symbol,
                kind: item.kind,
                directCalls: imagePlan.directCalls,
                expectedEffects: item.signature.effects,
                expectedResultType: item.signature.result
            )
            let actualParameters = lowered.parameterRegisters.compactMap { register in
                lowered.registerTypes.indices.contains(Int(register.rawValue))
                    ? lowered.registerTypes[Int(register.rawValue)]
                    : nil
            }
            guard actualParameters.count == lowered.parameterRegisters.count,
                  actualParameters == item.signature.parameters,
                  lowered.parameterConventions == item.signature.parameterConventions,
                  lowered.resultType == item.signature.result,
                  lowered.thrownType == item.signature.thrownType,
                  lowered.effects == item.signature.effects
            else {
                throw PatchCompiler.CompilationError.generatedFunctionUnsupported(
                    item.symbol,
                    reason: "lowering changed its discovered concrete signature"
                )
            }
            lowered = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
                lowered,
                logicalPaths: request.sourceFileLogicalID.map { [$0] } ?? []
            )
            loweredByID.append((item.id, lowered))
        }
        loweredByID.sort { $0.id < $1.id }
        let loweredFunctions = loweredByID.map(\.function)
        let imports = try imagePlan.directCalls.importRequirements(
            referencedBy: loweredFunctions
        )
        let entryParameterConventions = try imagePlan.directCalls
            .entryParameterConventions(referencedBy: loweredFunctions)
        let localTypes = try typeEnvironment.definitions(
            referencedBy: loweredFunctions,
            hostedMethods: imagePlan.hostedMethods
        )
        let functions = loweredByID.map {
            IntermediateRepresentation.ToBytecode.lower($0.function, id: $0.id)
        }
        let module = Bytecode.Module(
            name: request.displayName,
            shellInterfaceHash: request.shellInterfaceHash,
            compatibility: request.compatibility,
            capabilities: CompilerCapabilities.infer(
                for: loweredFunctions,
                imports: imports,
                entryParameterConventions: entryParameterConventions,
                localTypes: localTypes
            ),
            requestedResources: request.requestedResources,
            localTypes: localTypes,
            functions: functions,
            entries: [
                .init(
                    entryIndex: request.entryIndex,
                    functionKey: request.functionKey,
                    functionID: request.functionID
                ),
            ],
            imports: imports,
            sourceMap: loweredByID.flatMap {
                IntermediateRepresentation.ToBytecode.sourceMap($0.function, id: $0.id)
            }
        )
        let bytecode = try Bytecode.Encoder.encode(module)
        return PatchCompiler.Result(
            module: module,
            bytecode: bytecode,
            disassembly: Bytecode.Disassembler.disassemble(module),
            bodyFingerprint: ReleaseCompiler.ImplementationFingerprint.compute(
                root: silFunction,
                in: file,
                archivedSymbols: [silFunction.mangledName],
                imageLocalSymbols: Set(imagePlan.functions.map(\.symbol))
            )
        )
    }

    public func compile(
        canonicalSIL: String,
        functionKey: Core.FunctionKey,
        currentInterface: ReleaseCompiler.DeclarationInterface,
        archive: InterfaceArchive.Archive,
        requestedResources: Core.ResourceLimits = .init()
    ) throws -> PatchCompiler.Result {
        try archive.validate()
        guard let record = archive.functions.first(where: { $0.key == functionKey }) else {
            throw PatchCompiler.ArchiveError.unknownFunction(functionKey)
        }
        guard record.patchability.isEligible, let entry = record.entryIndex else {
            throw PatchCompiler.ArchiveError.ineligibleFunction(
                functionKey,
                reason: record.patchability.explanation ?? "not patchable"
            )
        }
        guard try currentInterface.fingerprint() == record.interfaceFingerprint else {
            throw PatchCompiler.ArchiveError.interfaceChanged(functionKey)
        }
        let functionID = Bytecode.FunctionID(rawValue: 0)
        let directCalls = try PatchCompiler.DirectCalls.make(
            archive: archive,
            localFunctionIDs: [functionKey: functionID]
        )
        return try compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: record.mangledName,
                displayName: record.canonicalDeclaration,
                functionID: functionID,
                functionKey: record.key,
                entryIndex: entry,
                shellInterfaceHash: archive.shellInterfaceHash,
                compatibility: archive.compatibility,
                requestedResources: requestedResources,
                directCalls: directCalls,
                nativeTypes: Dictionary(
                    uniqueKeysWithValues: archive.nativeTypes
                        .filter(\.isEmittedToDevice)
                        .map { ($0.canonicalName, $0.id) }
                ),
                nativeTypeKinds: Dictionary(
                    uniqueKeysWithValues: archive.nativeTypes
                        .filter(\.isEmittedToDevice)
                        .map { ($0.id, $0.kind) }
                ),
                mainActorNativeTypes: Set(
                    archive.nativeTypes
                        .filter { $0.isEmittedToDevice && $0.requiresMainActor }
                        .map(\.id)
                ),
                frozenValueTypes: archive.frozenValueTypes,
                shellDeclarationSymbols: Set(archive.functions.map(\.mangledName)),
                effects: record.effects,
                nativePropertyAccessPolicy: .forRoot(record),
                sourceFileLogicalID: record.sourceFileLogicalID
            )
        )
    }
}

public enum ArchiveError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFunction(Core.FunctionKey)
    case ineligibleFunction(Core.FunctionKey, reason: String)
    case interfaceChanged(Core.FunctionKey)

    public var description: String {
        switch self {
        case let .unknownFunction(key): "function \(key) is absent from HLXI"
        case let .ineligibleFunction(key, reason): "function \(key) is not patchable: \(reason)"
        case let .interfaceChanged(key): "function \(key) changed its captured HLXI interface"
        }
    }
}
}
