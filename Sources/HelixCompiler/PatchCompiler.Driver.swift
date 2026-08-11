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
    public var effects: Core.Effects?
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
        effects: Core.Effects? = nil,
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
        self.effects = effects
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
            request.nativeTypes
        )
        guard let silFunction = file.function(mangledName: request.mangledName) else {
            throw CanonicalSIL.LoweringError.functionSelection("function @\(request.mangledName) was not found")
        }
        var hlir = try CanonicalSIL.Lowerer(
            typeEnvironment: typeEnvironment
        ).lower(
            silFunction,
            displayName: request.displayName,
            directCalls: request.directCalls,
            expectedEffects: request.effects
        )
        hlir = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
            hlir,
            logicalPaths: request.sourceFileLogicalID.map { [$0] } ?? []
        )
        let imports = try request.directCalls.importRequirements(referencedBy: [hlir])
        let localTypes = try typeEnvironment.definitions(referencedBy: [hlir])
        let function = IntermediateRepresentation.ToBytecode.lower(hlir, id: request.functionID)
        let module = Bytecode.Module(
            name: request.displayName,
            shellInterfaceHash: request.shellInterfaceHash,
            compatibility: request.compatibility,
            capabilities: CompilerCapabilities.infer(
                for: [hlir],
                imports: imports,
                localTypes: localTypes
            ),
            requestedResources: request.requestedResources,
            localTypes: localTypes,
            functions: [function],
            entries: [
                .init(
                    entryIndex: request.entryIndex,
                    functionKey: request.functionKey,
                    functionID: request.functionID
                ),
            ],
            imports: imports,
            sourceMap: IntermediateRepresentation.ToBytecode.sourceMap(
                hlir,
                id: request.functionID
            )
        )
        let bytecode = try Bytecode.Encoder.encode(module)
        return PatchCompiler.Result(
            module: module,
            bytecode: bytecode,
            disassembly: Bytecode.Disassembler.disassemble(module),
            bodyFingerprint: ReleaseCompiler.BodyFingerprint.compute(silFunction.body)
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
                effects: record.effects,
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
        case let .interfaceChanged(key): "function \(key) changed its frozen HLXI interface"
        }
    }
}
}
