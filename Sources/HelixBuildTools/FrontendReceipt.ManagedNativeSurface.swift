import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
enum ManagedNativeSurface {}
}

extension FrontendReceipt.ManagedNativeSurface {
    struct Expansion: Sendable {
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
        var modulesByDeclarationUSR: [String: String]
        var metrics: Metrics
    }

    struct ModuleResolution: Sendable {
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var modulesByDeclarationUSR: [String: String]
        var metrics: Metrics
    }

    struct Metrics: Sendable {
        var moduleCount: UInt64 = 0
        var candidateCount: UInt64 = 0
        var symbolGraphCacheHitCount: UInt64 = 0
        var symbolGraphCacheMissCount: UInt64 = 0
        var probeCacheHitCount: UInt64 = 0
        var probeCacheMissCount: UInt64 = 0
        var cachedRejectionCount: UInt64 = 0
        var probeAttemptCount: UInt64 = 0
        var failedProbeCount: UInt64 = 0
        var rejectedSingletonCount: UInt64 = 0
        var generatedProbeSourceBytes: UInt64 = 0
    }

    private struct OwnerSurface: Sendable {
        var moduleName: String
        var preciseIdentifier: String
        var kindIdentifier: String
        var hasInhabitedValue: Bool
        var swiftPath: String
        var runtimeName: String?
        var genericParameters: [String]
        var requiresMainActor: Bool
        var members: [SwiftFrontend.SymbolGraph.Symbol]
    }

    private struct OwnerSpecialization {
        var probeType: String
        var substitutions: [String: String]
    }

    private struct OwnerMatch: Sendable {
        var score: Int
        var surface: OwnerSurface
    }

    private struct TypeResolution: Sendable {
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var ownerSurfacesByIndex: [Int: OwnerSurface]
        var ownerSurfacesByModule: [String: [OwnerSurface]]
        var modulesByDeclarationUSR: [String: String]
        var metrics: Metrics
    }

    private struct Candidate: Codable, Hashable, Sendable {
        var preciseIdentifier: String
        var moduleName: String
        var probeOwnerType: String
        var ownerType: String
        var dispatch: NativeImportDiscovery.Dispatch
        var memberName: String
        var argumentLabels: [String]
        var parameterTypes: [String]
        var resultType: String
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
        var allowsMainActorInference: Bool
        var mayThrow: Bool
    }

    private struct SymbolGraphCacheKey: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var symbolGraphPipelineHash: Core.Digest
        var compilerFingerprint: String
        var compilerInputHash: Core.Digest
        var moduleName: String
        var invocation: InterfaceArchive.FrontendInvocation
    }

    private struct SymbolGraphCachePayload: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var document: SwiftFrontend.SymbolGraph.Document
    }

    private struct ProbeCandidate: Codable, Hashable, Sendable {
        var preciseIdentifier: String
        var moduleName: String
        var probeOwnerType: String
        var ownerType: String
        var dispatch: NativeImportDiscovery.Dispatch
        var memberName: String
        var argumentLabels: [String]
        var parameterTypes: [String]
        var resultType: String
        var importedModules: [String]
        var requiresMainActor: Bool
        var allowsMainActorInference: Bool
        var mayThrow: Bool

        init(_ candidate: Candidate) {
            preciseIdentifier = candidate.preciseIdentifier
            moduleName = candidate.moduleName
            probeOwnerType = candidate.probeOwnerType
            ownerType = candidate.ownerType
            dispatch = candidate.dispatch
            memberName = candidate.memberName
            argumentLabels = candidate.argumentLabels
            parameterTypes = candidate.parameterTypes
            resultType = candidate.resultType
            importedModules = candidate.importedModules.sorted()
            requiresMainActor = candidate.requiresMainActor
            allowsMainActorInference = candidate.allowsMainActorInference
            mayThrow = candidate.mayThrow
        }
    }

    private struct ProbeNativeType: Codable, Hashable, Sendable {
        var canonicalName: String
        var swiftType: String
        var kind: InterfaceArchive.TypeKind
        var aliases: [String]
        var representation: FrontendReceipt.Adapter.ImportedNativeType.Representation
        var importedModules: [String]
        var nativeModuleName: String?
        var objectiveCModuleName: String?
        var objectiveCRuntimeName: String?
        var requiresMainActor: Bool
        var isolationEvidence: FrontendReceipt.Adapter.ImportedIsolationEvidence

        init(_ type: FrontendReceipt.Adapter.ImportedNativeType) {
            canonicalName = type.canonicalName
            swiftType = type.swiftType
            kind = type.kind
            aliases = type.aliases.sorted()
            representation = type.representation
            importedModules = Array(Set(type.importedModules)).sorted()
            nativeModuleName = type.nativeModuleName
            objectiveCModuleName = type.objectiveCModuleName
            objectiveCRuntimeName = type.objectiveCRuntimeName
            requiresMainActor = type.requiresMainActor
            isolationEvidence = type.isolationEvidence
        }

        func restoring(
            sourceFileLogicalID: String
        ) -> FrontendReceipt.Adapter.ImportedNativeType {
            .init(
                canonicalName: canonicalName,
                swiftType: swiftType,
                kind: kind,
                aliases: aliases,
                representation: representation,
                sourceFileLogicalID: sourceFileLogicalID,
                importedModules: importedModules,
                nativeModuleName: nativeModuleName,
                objectiveCModuleName: objectiveCModuleName,
                objectiveCRuntimeName: objectiveCRuntimeName,
                requiresMainActor: requiresMainActor,
                isolationEvidence: isolationEvidence
            )
        }
    }

    private struct ProbeCacheKey: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var compilerProbePipelineHash: Core.Digest
        var compilerFingerprint: String
        var compilerInputHash: Core.Digest
        var invocation: InterfaceArchive.FrontendInvocation
        var minimumOS: Core.SemanticVersion
        var candidate: ProbeCandidate
        var importedTypeBoundaryHash: Core.Digest
    }

    private struct ProbeCachePayload: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var candidate: ProbeCandidate
        var types: [ProbeNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
    }

    private struct ProbeBatchCacheKey: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var compilerProbePipelineHash: Core.Digest
        var compilerFingerprint: String
        var compilerInputHash: Core.Digest
        var invocation: InterfaceArchive.FrontendInvocation
        var minimumOS: Core.SemanticVersion
        var candidates: [ProbeCandidate]
        var importedTypeBoundaryHash: Core.Digest
    }

    private struct ProbeBatchCachePayload: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var candidates: [ProbeCandidate]
        var results: [ProbeCachePayload]
    }

    private struct DecodedProbePayload: Sendable {
        var types: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
    }

    private struct DecodedProbeBatch: Sendable {
        var result: ProbeResult
        var rejectionCount: UInt64
    }

    private struct MeasuredType: Sendable {
        var candidate: Candidate
        var type: FrontendReceipt.Adapter.ImportedNativeType
    }

    private struct MeasuredOperation: Sendable {
        var candidate: Candidate
        var operation: FrontendReceipt.Adapter.ImportedOperation
    }

    private struct ProbeResult: Sendable {
        var types: [MeasuredType]
        var operations: [MeasuredOperation]
        var cacheableCandidates: Set<Candidate>

        static let empty = ProbeResult(
            types: [],
            operations: [],
            cacheableCandidates: []
        )

        static func + (lhs: ProbeResult, rhs: ProbeResult) -> ProbeResult {
            .init(
                types: lhs.types + rhs.types,
                operations: lhs.operations + rhs.operations,
                cacheableCandidates: lhs.cacheableCandidates
                    .union(rhs.cacheableCandidates)
            )
        }
    }

    private enum UncacheableProbeBatch: Swift.Error {
        case result(ProbeResult)
    }

    private struct ProbedSurface: Sendable {
        var types: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
    }

    private final class ProbeWorkQueue: @unchecked Sendable {
        struct Outcome {
            var result: ProbeResult?
            var error: (any Swift.Error)?
            var metrics: Metrics
        }

        private let lock = NSLock()
        private var nextIndex = 0
        private var outcomes: [Outcome?]

        // The lock owns both work allocation and the complete cross-thread
        // handoff. The existential Error is consumed only after
        // concurrentPerform has joined every worker.

        init(count: Int) {
            outcomes = Array(repeating: nil, count: count)
        }

        func claim() -> Int? {
            lock.withLock {
                guard nextIndex < outcomes.count else { return nil }
                defer { nextIndex += 1 }
                return nextIndex
            }
        }

        func publish(_ outcome: Outcome, at index: Int) {
            lock.withLock {
                precondition(outcomes.indices.contains(index))
                precondition(outcomes[index] == nil)
                outcomes[index] = outcome
            }
        }

        func outcome(at index: Int) -> Outcome {
            lock.withLock {
                precondition(outcomes.indices.contains(index))
                return outcomes[index]!
            }
        }
    }

    private enum CacheLookupMiss: Swift.Error {
        case missing
    }

    /// Expands members rooted in types already proven by the source module.
    /// Native types required by an accepted member signature join that same
    /// boundary. The captured frontend remains the authority for Swift
    /// spelling, isolation, and the exact callable ABI.
    static func expand(
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        declarationUSRs: Set<String> = [],
        candidateModules: Set<String> = [],
        cache: BuildCache.Store? = nil,
        compilerFingerprint: String? = nil,
        compilerInputHash: Core.Digest? = nil
    ) throws -> Expansion {
        let resolution = try resolveImportedTypeSurfaces(
            importedTypes: importedTypes,
            minimumOS: minimumOS,
            frontend: frontend,
            invocation: invocation,
            cache: cache,
            compilerFingerprint: compilerFingerprint,
            compilerInputHash: compilerInputHash,
            requiredRuntimeNames: nil,
            requiredDeclarationUSRs: declarationUSRs,
            additionalModuleNames: candidateModules,
            includesMembers: true
        )
        var metrics = resolution.metrics
        var enrichedTypes = resolution.importedTypes
        var candidates: [Candidate] = []
        var uninhabitedCanonicalNames = Set<String>()
        for index in importedTypes.indices.sorted(by: {
            importedTypes[$0].canonicalName < importedTypes[$1].canonicalName
        }) {
            guard let surface = resolution.ownerSurfacesByIndex[index] else {
                continue
            }
            if !surface.hasInhabitedValue {
                uninhabitedCanonicalNames.insert(
                    enrichedTypes[index].canonicalName
                )
            }
            candidates += makeCandidates(
                surface: surface,
                importedType: enrichedTypes[index]
            )
        }
        enrichedTypes = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: [],
            operationTypes: enrichedTypes
        )
        candidates = Array(Set(candidates)).sorted(by: candidateOrdering)
        let boundaryTypeIndex = FrontendReceipt.ImportedTypeIndex(
            types: enrichedTypes
        )
        let nominatedCount = candidates.count
        candidates = candidates.filter {
            !crossesUninhabitedBoundary(
                $0,
                typeIndex: boundaryTypeIndex,
                uninhabitedCanonicalNames: uninhabitedCanonicalNames
            )
        }
        metrics.rejectedSingletonCount += UInt64(
            nominatedCount - candidates.count
        )
        enrichedTypes.removeAll {
            uninhabitedCanonicalNames.contains($0.canonicalName)
        }
        guard candidates.count <= 4_096 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native surface exceeds the 4096-operation audit bound"
            )
        }

        metrics.candidateCount = UInt64(candidates.count)
        let probedSurface = try probe(
            candidates,
            importedTypes: enrichedTypes,
            minimumOS: minimumOS,
            frontend: frontend,
            invocation: invocation,
            cache: cache,
            compilerFingerprint: compilerFingerprint,
            compilerInputHash: compilerInputHash,
            metrics: &metrics
        )
        let signatureTypes = enrichSignatureTypes(
            probedSurface.types,
            ownerSurfacesByModule: resolution.ownerSurfacesByModule
        )
        let canonicalSurface = try canonicalizingCompilerNominalAliases(
            importedTypes: enrichedTypes + signatureTypes,
            operations: probedSurface.operations
        )
        enrichedTypes = canonicalSurface.importedTypes
        return Expansion(
            importedTypes: enrichedTypes,
            operations: try canonicalizedOperations(
                canonicalSurface.operations,
                importedTypes: enrichedTypes
            ),
            modulesByDeclarationUSR: resolution.modulesByDeclarationUSR,
            metrics: metrics
        )
    }

    /// Measures every concrete public owner and global function exported by
    /// one imported module. Its source and cache identities contain only
    /// module facts, so unrelated applications can reuse the result.
    static func catalog(
        moduleName: String,
        sourceFileLogicalID: String,
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store? = nil,
        compilerFingerprint: String? = nil,
        moduleInputHash: Core.Digest? = nil
    ) throws -> Expansion {
        guard isProbeIdentifier(moduleName),
              !sourceFileLogicalID.isEmpty,
              sourceFileLogicalID.utf8.count <= 4_096,
              !sourceFileLogicalID.unicodeScalars.contains(where: {
                  $0.value == 0
              })
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "native API Catalog module identity is invalid"
            )
        }
        var metrics = Metrics(moduleCount: 1)
        let graph = try symbolGraph(
            moduleName: moduleName,
            frontend: frontend,
            invocation: invocation,
            cache: cache,
            compilerFingerprint: compilerFingerprint,
            compilerInputHash: moduleInputHash,
            metrics: &metrics
        )
        let surfaces = ownerSurfaces(
            in: graph,
            minimumOS: minimumOS,
            includesMembers: true
        )
        let typedSurfaces = surfaces.compactMap { surface in
            catalogImportedType(
                surface: surface,
                sourceFileLogicalID: sourceFileLogicalID
            ).map { (surface, $0) }
        }
        let probeImportedTypes = try FrontendReceipt.Adapter()
            .mergeImportedNativeTypes(
                discoveredTypes: [],
                operationTypes: typedSurfaces.map(\.1)
            )
        let uninhabitedCanonicalNames = Set(typedSurfaces.compactMap {
            surface, importedType in
            surface.hasInhabitedValue ? nil : importedType.canonicalName
        })
        var candidates = typedSurfaces.flatMap { surface, importedType in
            makeCandidates(surface: surface, importedType: importedType)
        }
        candidates += globalCandidates(
            in: graph,
            minimumOS: minimumOS,
            sourceFileLogicalID: sourceFileLogicalID
        )
        candidates = Array(Set(candidates)).sorted(by: candidateOrdering)
        let boundaryTypeIndex = FrontendReceipt.ImportedTypeIndex(
            types: probeImportedTypes
        )
        let nominatedCount = candidates.count
        candidates = candidates.filter {
            !crossesUninhabitedBoundary(
                $0,
                typeIndex: boundaryTypeIndex,
                uninhabitedCanonicalNames: uninhabitedCanonicalNames
            )
        }
        metrics.rejectedSingletonCount += UInt64(
            nominatedCount - candidates.count
        )
        guard candidates.count <= 250_000 else {
            throw FrontendReceipt.Error.frontendFailed(
                "native API Catalog exceeds the 250000-operation bound"
            )
        }
        metrics.candidateCount = UInt64(candidates.count)
        let probedSurface = try probeCatalog(
            candidates,
            importedTypes: probeImportedTypes,
            minimumOS: minimumOS,
            frontend: frontend,
            invocation: invocation,
            cache: cache,
            compilerFingerprint: compilerFingerprint,
            compilerInputHash: moduleInputHash,
            metrics: &metrics
        )
        let signatureTypes = enrichSignatureTypes(
            probedSurface.types,
            ownerSurfacesByModule: [moduleName: surfaces]
        )
        let canonicalSurface = try canonicalizingCompilerNominalAliases(
            importedTypes: probeImportedTypes.filter {
                !uninhabitedCanonicalNames.contains($0.canonicalName)
            } + signatureTypes,
            operations: probedSurface.operations
        )
        let importedTypes = canonicalSurface.importedTypes.map { type in
            var type = type
            // Module ownership is temporary authority while measurement
            // reconciles weaker probe observations. The persisted projection
            // is module-relative; CatalogSurface restores ownership when a
            // consumer binds the snapshot.
            type.nativeModuleName = nil
            return type
        }
        let operations = try canonicalizedOperations(
            canonicalSurface.operations.map { operation in
                var dormant = operation
                dormant.isEmittedToDevice = false
                return dormant
            },
            importedTypes: importedTypes
        )
        var modulesByDeclarationUSR: [String: String] = [:]
        for operation in operations {
            guard let usr = operation.declarationUSR else { continue }
            if let existing = modulesByDeclarationUSR[usr],
               existing != moduleName {
                throw FrontendReceipt.Error.invalidRequest(
                    "native API Catalog declaration has conflicting modules"
                )
            }
            modulesByDeclarationUSR[usr] = moduleName
        }
        return .init(
            importedTypes: importedTypes,
            operations: operations,
            modulesByDeclarationUSR: modulesByDeclarationUSR,
            metrics: metrics
        )
    }

    /// A successfully typechecked Swift initializer proves that its declaring
    /// owner and result are the same nominal identity. Swift overlays can print
    /// those two positions differently (including renamed nested types), so
    /// reconcile the compiler spellings before assigning native TypeIDs.
    static func canonicalizingCompilerNominalAliases(
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        operations: [FrontendReceipt.Adapter.ImportedOperation]
    ) throws -> (
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        operations: [FrontendReceipt.Adapter.ImportedOperation]
    ) {
        let aliases = try compilerNominalAliases(in: operations)
        guard !aliases.isEmpty else {
            return (
                try FrontendReceipt.Adapter().mergeImportedNativeTypes(
                    discoveredTypes: [],
                    operationTypes: importedTypes
                ),
                operations
            )
        }
        let normalizedTypes = importedTypes.map { original in
            var type = original
            let canonicalName = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: original.canonicalName,
                    aliases: aliases
                )
            let swiftType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: original.swiftType,
                    aliases: aliases
                )
            // Objective-C references intentionally use their runtime class
            // name as canonical identity even when generated Swift uses a
            // module-qualified overlay spelling. Pure Swift reference types
            // have no runtime-class identity and follow the compiler alias.
            if original.objectiveCRuntimeName == nil {
                type.canonicalName = canonicalName
            }
            type.swiftType = swiftType
            let priorNames = [original.canonicalName, original.swiftType]
                + original.aliases
            let rewrittenNames = priorNames.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: aliases
                )
            }
            type.aliases = Array(Set(priorNames + rewrittenNames)).filter {
                $0 != type.canonicalName && $0 != type.swiftType
            }.sorted()
            return type
        }
        let adapter = FrontendReceipt.Adapter()
        return (
            try adapter.mergeImportedNativeTypes(
                discoveredTypes: [],
                operationTypes: normalizedTypes
            ),
            operations.map {
                adapter.applyingSwiftTypeAliases($0, aliases: aliases)
            }
        )
    }

    private static func compilerNominalAliases(
        in operations: [FrontendReceipt.Adapter.ImportedOperation]
    ) throws -> [String: String] {
        var targetsBySource: [String: Set<String>] = [:]
        var modulesBySource: [String: Set<String>] = [:]
        for operation in operations {
            guard operation.dispatch == .initializer,
                  operation.compilerOperation == nil,
                  operation.objectiveC == nil,
                  operation.c == nil,
                  operation.declarationUSR?.hasPrefix("s:") == true,
                  isPlainNominal(operation.ownerType),
                  isPlainNominal(operation.resultSwiftType),
                  operation.ownerType != operation.resultSwiftType
            else { continue }
            targetsBySource[operation.ownerType, default: []]
                .insert(operation.resultSwiftType)
            modulesBySource[operation.ownerType, default: []]
                .formUnion(operation.importedModules)
        }
        var raw: [String: String] = [:]
        func recordAlias(_ source: String, target: String) throws {
            if let existing = raw[source], existing != target {
                throw FrontendReceipt.Error.invalidRequest(
                    "compiler-proven native nominal alias \(source) has conflicting targets"
                )
            }
            raw[source] = target
        }
        for source in targetsBySource.keys.sorted() {
            let targets = targetsBySource[source] ?? []
            guard targets.count == 1, let target = targets.first else {
                throw FrontendReceipt.Error.invalidRequest(
                    "compiler-proven native nominal alias \(source) has conflicting targets"
                )
            }
            try recordAlias(source, target: target)
            if let module = target.split(separator: ".").first.map(String.init),
               modulesBySource[source]?.contains(module) == true,
               !source.hasPrefix(module + ".") {
                let qualifiedSource = module + "." + source
                if qualifiedSource != target {
                    try recordAlias(qualifiedSource, target: target)
                }
            }
        }
        guard !raw.isEmpty else { return [:] }

        func resolvedTarget(source: String, target: String) throws -> String {
            var current = target
            var visited = Set([source])
            for _ in 0...raw.count {
                guard visited.insert(current).inserted else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "compiler-proven native nominal aliases contain a cycle at \(source)"
                    )
                }
                let next = FrontendReceipt.SwiftTypeSpelling
                    .replacingNominalAliases(in: current, aliases: raw)
                if next == current { return current }
                current = next
            }
            throw FrontendReceipt.Error.invalidRequest(
                "compiler-proven native nominal aliases do not converge at \(source)"
            )
        }

        var resolved: [String: String] = [:]
        for source in raw.keys.sorted() {
            resolved[source] = try resolvedTarget(
                source: source,
                target: raw[source] ?? source
            )
        }
        for source in raw.keys.sorted() {
            var strictPrefixes = raw
            strictPrefixes.removeValue(forKey: source)
            let inherited = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: source,
                    aliases: strictPrefixes
                )
            guard inherited != source else { continue }
            let inheritedTarget = try resolvedTarget(
                source: source,
                target: inherited
            )
            guard inheritedTarget == resolved[source] else {
                throw FrontendReceipt.Error.invalidRequest(
                    "compiler-proven native nominal alias \(source) conflicts with its enclosing type"
                )
            }
        }
        return resolved.filter { $0.key != $0.value }
    }

    private static func isPlainNominal(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == raw
            && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(value)
            && FrontendReceipt.SwiftTypeSpelling.nominalTokens(in: value)
                == [value]
    }

    /// Probe batches are independent cache units. Apply aliases again after
    /// their native type evidence has been merged so an operation measured in
    /// one batch can use an identity proven by another batch in the module.
    static func canonicalizedOperations(
        _ operations: [FrontendReceipt.Adapter.ImportedOperation],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        let adapter = FrontendReceipt.Adapter()
        let aliases = try adapter.makeImportedSwiftTypeAliases(importedTypes)
        return try adapter.mergeImportedOperations(operations.map {
            adapter.applyingSwiftTypeAliases($0, aliases: aliases)
        })
    }

    /// Resolves only the declaring modules needed by source-observed foreign
    /// declarations. It reuses the same content-addressed Symbol Graph cache
    /// as managed native expansion, but does not nominate or compile API probes.
    static func resolveDeclarationModules(
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        runtimeNames: Set<String>,
        declarationUSRs: Set<String>,
        candidateModules: Set<String> = [],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store? = nil,
        compilerFingerprint: String? = nil,
        compilerInputHash: Core.Digest? = nil
    ) throws -> ModuleResolution {
        let resolution = try resolveImportedTypeSurfaces(
            importedTypes: importedTypes,
            minimumOS: minimumOS,
            frontend: frontend,
            invocation: invocation,
            cache: cache,
            compilerFingerprint: compilerFingerprint,
            compilerInputHash: compilerInputHash,
            requiredRuntimeNames: runtimeNames,
            requiredDeclarationUSRs: declarationUSRs,
            additionalModuleNames: candidateModules,
            includesMembers: false
        )
        return .init(
            importedTypes: try FrontendReceipt.Adapter()
                .mergeImportedNativeTypes(
                    discoveredTypes: [],
                    operationTypes: resolution.importedTypes
                ),
            modulesByDeclarationUSR: resolution.modulesByDeclarationUSR,
            metrics: resolution.metrics
        )
    }

    private static func resolveImportedTypeSurfaces(
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store?,
        compilerFingerprint: String?,
        compilerInputHash: Core.Digest?,
        requiredRuntimeNames: Set<String>?,
        requiredDeclarationUSRs: Set<String>,
        additionalModuleNames: Set<String>,
        includesMembers: Bool
    ) throws -> TypeResolution {
        let selectedIndices = importedTypes.indices.filter { index in
            guard let requiredRuntimeNames else { return true }
            let type = importedTypes[index]
            return !requiredRuntimeNames.isDisjoint(with: Set(
                [type.canonicalName, type.swiftType] + type.aliases
            ).map {
                normalizedTypeName($0, moduleName: nil)
                    .split(separator: ".").last.map(String.init) ?? $0
            })
        }
        let importedModules = selectedIndices.reduce(into: [String]()) {
            $0.append(contentsOf: importedTypes[$1].importedModules)
        }
        let moduleNames = Set(importedModules.compactMap {
            $0.split(separator: ".").first.map(String.init)
        }).union(additionalModuleNames.compactMap {
            $0.split(separator: ".").first.map(String.init)
        }).sorted()
        guard moduleNames.count <= 32 else {
            throw FrontendReceipt.Error.frontendFailed(
                "native declaration module resolution exceeds the 32-module audit bound"
            )
        }

        var metrics = Metrics(moduleCount: UInt64(moduleNames.count))
        var matchesByType: [Int: [OwnerMatch]] = [:]
        var ownerSurfacesByModule: [String: [OwnerSurface]] = [:]
        var modulesByDeclarationUSR: [String: Set<String>] = [:]
        for moduleName in moduleNames where isProbeIdentifier(moduleName) {
            let graph = try symbolGraph(
                moduleName: moduleName,
                frontend: frontend,
                invocation: invocation,
                cache: cache,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                metrics: &metrics
            )
            let surfaces = ownerSurfaces(
                in: graph,
                minimumOS: minimumOS,
                includesMembers: includesMembers
            )
            ownerSurfacesByModule[moduleName] = surfaces
            for symbol in graph.symbols
            where requiredDeclarationUSRs.contains(symbol.identifier.precise) {
                modulesByDeclarationUSR[
                    symbol.identifier.precise,
                    default: []
                ].insert(moduleName)
            }
            for index in selectedIndices where importedTypes[index]
                .importedModules.contains(where: {
                    $0.split(separator: ".").first == Substring(moduleName)
                }) {
                guard let match = bestOwnerMatch(
                    for: importedTypes[index],
                    in: surfaces
                ) else { continue }
                matchesByType[index, default: []].append(match)
            }
        }

        var enrichedTypes = importedTypes
        var ownerSurfacesByIndex: [Int: OwnerSurface] = [:]
        for index in selectedIndices {
            guard let matches = matchesByType[index],
                  let selected = uniqueBestMatch(matches)
            else { continue }
            enrichedTypes[index] = enrich(
                importedTypes[index],
                with: selected.surface
            )
            ownerSurfacesByIndex[index] = selected.surface
        }
        return .init(
            importedTypes: enrichedTypes,
            ownerSurfacesByIndex: ownerSurfacesByIndex,
            ownerSurfacesByModule: ownerSurfacesByModule,
            modulesByDeclarationUSR: Dictionary(
                uniqueKeysWithValues: modulesByDeclarationUSR.compactMap {
                    usr, modules in
                    guard modules.count == 1, let module = modules.first else {
                        return nil
                    }
                    return (usr, module)
                }
            ),
            metrics: metrics
        )
    }

    private static func symbolGraph(
        moduleName: String,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store?,
        compilerFingerprint: String?,
        compilerInputHash: Core.Digest?,
        metrics: inout Metrics
    ) throws -> SwiftFrontend.SymbolGraph.Document {
        guard let cache, let compilerFingerprint, let compilerInputHash else {
            return try frontend.emitSymbolGraph(
                moduleName: moduleName,
                invocation: invocation
            )
        }
        let key = try BuildCache.key(
            domain: "HLX.BuildCache.SymbolGraph.v1",
            value: SymbolGraphCacheKey(
                symbolGraphPipelineHash:
                    NativeAPICatalog.Pipeline.symbolGraphPipelineHash,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                moduleName: moduleName,
                invocation: invocation
            )
        )
        var validatedDocument: SwiftFrontend.SymbolGraph.Document?
        let cached = try cache.value(
            namespace: .symbolGraph,
            key: key,
            maximumBytes: 96 * 1_024 * 1_024,
            validate: {
                validatedDocument = try decodeSymbolGraphPayload(
                    $0,
                    expectedModuleName: moduleName
                )
            }
        ) {
            let document = try frontend.emitSymbolGraph(
                moduleName: moduleName,
                invocation: invocation
            )
            return try Core.CanonicalJSON.encode(
                SymbolGraphCachePayload(document: document)
            )
        }
        if cached.source == .hit {
            metrics.symbolGraphCacheHitCount += 1
        } else {
            metrics.symbolGraphCacheMissCount += 1
        }
        guard let validatedDocument else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native symbol graph cache was not validated"
            )
        }
        return validatedDocument
    }

    private static func decodeSymbolGraphPayload(
        _ data: Data,
        expectedModuleName: String
    ) throws -> SwiftFrontend.SymbolGraph.Document {
        let payload = try JSONDecoder().decode(
            SymbolGraphCachePayload.self,
            from: data
        )
        guard payload.schemaVersion == 1,
              try Core.CanonicalJSON.encode(payload) == data
        else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native symbol graph cache payload is invalid"
            )
        }
        try payload.document.validate(expectedModuleName: expectedModuleName)
        return payload.document
    }

    private static func ownerSurfaces(
        in graph: SwiftFrontend.SymbolGraph.Document,
        minimumOS: Core.SemanticVersion,
        includesMembers: Bool
    ) -> [OwnerSurface] {
        let typeKinds: Set<String> = [
            "swift.class", "swift.enum", "swift.struct", "swift.typealias",
        ]
        let memberKinds: Set<String> = [
            "swift.init", "swift.method", "swift.property",
            "swift.type.method", "swift.type.property",
        ]
        let mainActorTypeIdentifiers = inheritedMainActorTypeIdentifiers(
            in: graph
        )
        var owners: [String: SwiftFrontend.SymbolGraph.Symbol] = [:]
        var ambiguousOwners = Set<String>()
        for symbol in graph.symbols {
            guard typeKinds.contains(symbol.kind.identifier),
                  !symbol.pathComponents.isEmpty,
                  symbol.pathComponents.allSatisfy(isProbeIdentifier),
                  isAvailable(symbol, minimumOS: minimumOS)
            else { continue }
            if owners[symbol.identifier.precise] != nil {
                ambiguousOwners.insert(symbol.identifier.precise)
            } else {
                owners[symbol.identifier.precise] = symbol
            }
        }
        for precise in ambiguousOwners { owners.removeValue(forKey: precise) }
        var memberOwner: [String: String] = [:]
        var ambiguousMembers = Set<String>()
        for relationship in graph.relationships
        where includesMembers && relationship.kind == "memberOf" {
            if let existing = memberOwner[relationship.source],
               existing != relationship.target {
                ambiguousMembers.insert(relationship.source)
            } else {
                memberOwner[relationship.source] = relationship.target
            }
        }
        for precise in ambiguousMembers { memberOwner.removeValue(forKey: precise) }
        var membersByOwner: [String: [SwiftFrontend.SymbolGraph.Symbol]] = [:]
        for symbol in graph.symbols
        where includesMembers && memberKinds.contains(symbol.kind.identifier) {
            guard symbol.accessLevel == "public" || symbol.accessLevel == "open",
                  let owner = memberOwner[symbol.identifier.precise],
                  owners[owner] != nil,
                  symbol.pathComponents.count >= 2,
                  isAvailable(symbol, minimumOS: minimumOS),
                  !symbol.declarationFragments.contains(where: {
                      $0.spelling == "async"
                  })
            else { continue }
            membersByOwner[owner, default: []].append(symbol)
        }
        let enumCaseIdentifiers = Set(graph.symbols.compactMap { symbol in
            symbol.kind.identifier == "swift.enum.case"
                ? symbol.identifier.precise : nil
        })
        let inhabitedEnums = Set(graph.relationships.compactMap { relationship in
            relationship.kind == "memberOf"
                && enumCaseIdentifiers.contains(relationship.source)
                ? relationship.target : nil
        })
        return owners.keys.sorted().compactMap { precise -> OwnerSurface? in
            guard let owner = owners[precise] else { return nil }
            var genericParameters: [String] = []
            for parameter in owner.declarationFragments.compactMap({
                $0.kind == "genericParameter" ? $0.spelling : nil
            }) where isProbeIdentifier(parameter)
                && !genericParameters.contains(parameter) {
                genericParameters.append(parameter)
            }
            guard genericParameters.count <= 16 else { return nil }
            return OwnerSurface(
                moduleName: graph.module.name,
                preciseIdentifier: precise,
                kindIdentifier: owner.kind.identifier,
                hasInhabitedValue: owner.kind.identifier != "swift.enum"
                    || inhabitedEnums.contains(precise),
                swiftPath: owner.pathComponents.joined(separator: "."),
                runtimeName: clangRuntimeName(precise),
                genericParameters: genericParameters,
                requiresMainActor: mainActorTypeIdentifiers.contains(precise),
                members: (membersByOwner[precise] ?? []).sorted {
                    ($0.pathComponents.joined(separator: "\u{0}"),
                     $0.identifier.precise)
                        < ($1.pathComponents.joined(separator: "\u{0}"),
                           $1.identifier.precise)
                }
            )
        }
    }

    /// Symbol Graphs record a global actor on its declaring superclass but do
    /// not necessarily repeat that attribute on subclasses. Swift still
    /// inherits the isolation, so derive the transitive same-module closure
    /// before nominating member probes.
    static func inheritedMainActorTypeIdentifiers(
        in graph: SwiftFrontend.SymbolGraph.Document
    ) -> Set<String> {
        let typeIdentifiers = Set(graph.symbols.compactMap { symbol in
            switch symbol.kind.identifier {
            case "swift.class", "swift.enum", "swift.struct":
                symbol.identifier.precise
            default:
                nil
            }
        })
        var isolated = Set(graph.symbols.compactMap { symbol in
            typeIdentifiers.contains(symbol.identifier.precise)
                && requiresMainActor(symbol)
                ? symbol.identifier.precise : nil
        })
        var childrenByParent: [String: Set<String>] = [:]
        for relationship in graph.relationships
        where relationship.kind == "inheritsFrom"
            && typeIdentifiers.contains(relationship.source)
            && typeIdentifiers.contains(relationship.target) {
            childrenByParent[relationship.target, default: []]
                .insert(relationship.source)
        }
        var pending = isolated.sorted()
        var next = 0
        while pending.indices.contains(next) {
            let parent = pending[next]
            next += 1
            for child in (childrenByParent[parent] ?? []).sorted()
            where isolated.insert(child).inserted {
                pending.append(child)
            }
        }
        return isolated
    }

    private static func catalogImportedType(
        surface: OwnerSurface,
        sourceFileLogicalID: String
    ) -> FrontendReceipt.Adapter.ImportedNativeType? {
        guard surface.genericParameters.isEmpty else { return nil }
        let representation: FrontendReceipt.Adapter.ImportedNativeType
            .Representation
        let kind: InterfaceArchive.TypeKind
        switch surface.kindIdentifier {
        case "swift.class":
            representation = .reference
            kind = .reference
        case "swift.enum":
            representation = .opaqueValue
            kind = .enumeration
        case "swift.struct":
            representation = .opaqueValue
            kind = .value
        case "swift.typealias":
            // A Symbol Graph does not prove whether a typealias is a pointer,
            // reference, scalar, or resilient value. A later exact signature
            // probe may still discover it, but the alias cannot seed an owner.
            return nil
        default:
            return nil
        }
        let qualified = "\(surface.moduleName).\(surface.swiftPath)"
        // Objective-C classes share one process-wide runtime identity. Clang
        // value types do not: Swift can import equally named structs or enums
        // from different modules and disambiguate them with `Module.Type`.
        // Preserve that module boundary in TypeID derivation while retaining
        // the source spelling as a lookup alias.
        let canonical = surface.preciseIdentifier.hasPrefix("c:objc(cs)")
            ? surface.swiftPath : qualified
        let runtimeAliases = surface.runtimeName.map {
            [$0, "__C.\($0)"]
        } ?? []
        return .init(
            canonicalName: canonical,
            swiftType: canonical,
            kind: kind,
            aliases: Array(Set(
                [surface.swiftPath, qualified] + runtimeAliases
            )).sorted(),
            representation: representation,
            sourceFileLogicalID: sourceFileLogicalID,
            importedModules: [surface.moduleName],
            nativeModuleName: surface.moduleName,
            objectiveCModuleName: surface.runtimeName == nil
                ? nil : surface.moduleName,
            objectiveCRuntimeName: representation == .reference
                    && surface.preciseIdentifier.hasPrefix("c:objc(cs)")
                ? surface.runtimeName : nil,
            requiresMainActor: surface.requiresMainActor,
            isolationEvidence: .importedDeclaration
        )
    }

    private static func globalCandidates(
        in graph: SwiftFrontend.SymbolGraph.Document,
        minimumOS: Core.SemanticVersion,
        sourceFileLogicalID: String
    ) -> [Candidate] {
        graph.symbols.compactMap { symbol in
            guard symbol.kind.identifier == "swift.func",
                  symbol.accessLevel == "public" || symbol.accessLevel == "open",
                  isAvailable(symbol, minimumOS: minimumOS),
                  !symbol.declarationFragments.contains(where: {
                      $0.kind == "genericParameter" || $0.spelling == "async"
                  }),
                  let signature = callableSignature(symbol),
                  isProbeIdentifier(signature.baseName),
                  (signature.parameterTypes + [signature.resultType]).allSatisfy(
                      FrontendReceipt.SwiftTypeSpelling.isGeneratedType
                  )
            else { return nil }
            let actor = requiresMainActor(symbol)
            let isNonisolated = symbol.declarationFragments.contains {
                $0.spelling == "nonisolated"
            }
            let importedModules = Array(Set(
                [graph.module.name] + referencedSwiftModules(in: symbol)
            )).sorted()
            return Candidate(
                preciseIdentifier: symbol.identifier.precise,
                moduleName: graph.module.name,
                probeOwnerType: graph.module.name,
                ownerType: graph.module.name,
                dispatch: .globalFunction,
                memberName: signature.baseName,
                argumentLabels: signature.argumentLabels,
                parameterTypes: signature.parameterTypes.map {
                    inheritedCallbackType($0, requiresMainActor: actor)
                },
                resultType: inheritedCallbackType(
                    signature.resultType,
                    requiresMainActor: actor
                ),
                sourceFileLogicalID: sourceFileLogicalID,
                importedModules: importedModules,
                requiresMainActor: actor,
                allowsMainActorInference: !actor && !isNonisolated,
                mayThrow: signature.mayThrow
            )
        }
    }

    private static func bestOwnerMatch(
        for type: FrontendReceipt.Adapter.ImportedNativeType,
        in surfaces: [OwnerSurface]
    ) -> OwnerMatch? {
        let scored = surfaces.compactMap { surface -> OwnerMatch? in
            let score = matchScore(type, surface: surface)
            return score == 0 ? nil : .init(
                score: score,
                surface: surface
            )
        }
        return uniqueBestMatch(scored)
    }

    private static func uniqueBestMatch(_ matches: [OwnerMatch]) -> OwnerMatch? {
        guard let maximum = matches.map(\.score).max() else { return nil }
        let best = matches.filter { $0.score == maximum }
        let identities = Set(best.map {
            [$0.surface.moduleName, $0.surface.preciseIdentifier]
                .joined(separator: "|")
        })
        guard identities.count == 1 else { return nil }
        return best.sorted {
            ($0.surface.moduleName, $0.surface.preciseIdentifier)
                < ($1.surface.moduleName, $1.surface.preciseIdentifier)
        }.first
    }

    private static func matchScore(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        surface: OwnerSurface
    ) -> Int {
        let rawNames = Set(
            [type.canonicalName, type.swiftType] + type.aliases
        )
        if let runtimeName = surface.runtimeName,
           rawNames.contains(runtimeName) || rawNames.contains("__C.\(runtimeName)") {
            return 400
        }
        let qualified = "\(surface.moduleName).\(surface.swiftPath)"
        if rawNames.contains(qualified) { return 300 }
        let normalized = Set(rawNames.map {
            normalizedTypeName($0, moduleName: surface.moduleName)
        })
        if normalized.contains(surface.swiftPath) { return 200 }
        if !surface.swiftPath.contains("."), normalized.contains(where: {
            !$0.contains(".") && $0 == surface.swiftPath
        }) {
            return 100
        }
        return 0
    }

    private static func enrich(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        with surface: OwnerSurface
    ) -> FrontendReceipt.Adapter.ImportedNativeType {
        var result = type
        result.requiresMainActor = surface.requiresMainActor
        result.isolationEvidence = .importedDeclaration
        if surface.runtimeName != nil {
            result.objectiveCModuleName = surface.moduleName
        }
        if result.kind == .reference,
           surface.preciseIdentifier.hasPrefix("c:objc(cs)") {
            result.objectiveCRuntimeName = surface.runtimeName
        }
        // An unspecialized generic SDK spelling is not an alias of any one
        // concrete frozen specialization. Adding it to every specialization
        // would make later type resolution ambiguous.
        guard surface.genericParameters.isEmpty else { return result }
        let qualified = "\(surface.moduleName).\(surface.swiftPath)"
        result.aliases = Array(Set(
            result.aliases + [result.canonicalName, result.swiftType,
                              surface.swiftPath, qualified]
                + [surface.runtimeName].compactMap { $0 }
                + (surface.runtimeName.map { ["__C.\($0)"] } ?? [])
        )).sorted()
        if let runtimeName = surface.runtimeName,
           normalizedTypeName(result.canonicalName, moduleName: nil) == runtimeName,
           runtimeName != surface.swiftPath {
            let canonical = surface.preciseIdentifier.hasPrefix("c:objc(cs)")
                ? surface.swiftPath
                : "\(surface.moduleName).\(surface.swiftPath)"
            result.canonicalName = canonical
            result.swiftType = canonical
        }
        return result
    }

    /// Probe functions inherit the candidate's isolation, so their Typed AST
    /// cannot decide whether another nominal in the signature is itself actor
    /// isolated. Reapply declaration metadata from the already loaded module
    /// graphs before publishing those types.
    private static func enrichSignatureTypes(
        _ types: [FrontendReceipt.Adapter.ImportedNativeType],
        ownerSurfacesByModule: [String: [OwnerSurface]]
    ) -> [FrontendReceipt.Adapter.ImportedNativeType] {
        types.map { type in
            let modules = Set(type.importedModules.compactMap {
                $0.split(separator: ".").first.map(String.init)
            })
            let matches = modules.flatMap { module in
                (ownerSurfacesByModule[module] ?? []).compactMap {
                    surface -> OwnerMatch? in
                    let score = matchScore(type, surface: surface)
                    return score == 0 ? nil : .init(
                        score: score,
                        surface: surface
                    )
                }
            }
            guard let match = uniqueBestMatch(matches) else { return type }
            return enrich(type, with: match.surface)
        }
    }

    private static func makeCandidates(
        surface: OwnerSurface,
        importedType: FrontendReceipt.Adapter.ImportedNativeType
    ) -> [Candidate] {
        guard let specialization = ownerSpecialization(
            surface: surface,
            importedType: importedType
        ) else { return [] }
        var candidates = surface.members.flatMap { member in
            makeCandidates(
                member: member,
                surface: surface,
                importedType: importedType,
                specialization: specialization
            )
        }
        // Imported SDK types can inherit or synthesize `init()` without a
        // corresponding member in the symbol graph. The exact frontend probe
        // below remains authoritative, so this nomination broadens no boundary
        // when zero-argument construction is unavailable.
        if !candidates.contains(where: {
            $0.dispatch == .initializer
                && $0.argumentLabels.isEmpty
                && $0.parameterTypes.isEmpty
        }) {
            candidates.append(Candidate(
                preciseIdentifier: surface.preciseIdentifier
                    + "#zero-argument-construction",
                moduleName: surface.moduleName,
                probeOwnerType: specialization.probeType,
                ownerType: importedType.swiftType,
                dispatch: .initializer,
                memberName: "init",
                argumentLabels: [],
                parameterTypes: [],
                resultType: specialization.probeType,
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedType.importedModules,
                requiresMainActor: surface.requiresMainActor,
                allowsMainActorInference: !surface.requiresMainActor,
                mayThrow: false
            ))
        }
        return candidates
    }

    private static func makeCandidates(
        member: SwiftFrontend.SymbolGraph.Symbol,
        surface: OwnerSurface,
        importedType: FrontendReceipt.Adapter.ImportedNativeType,
        specialization: OwnerSpecialization
    ) -> [Candidate] {
        let isNonisolated = member.declarationFragments.contains {
            $0.spelling == "nonisolated"
        }
        let requiresActor = !isNonisolated && (
            surface.requiresMainActor || requiresMainActor(member)
        )
        let importedModules = Array(Set(
            importedType.importedModules + referencedSwiftModules(in: member)
        )).sorted()
        func candidate(
            dispatch: NativeImportDiscovery.Dispatch,
            memberName: String,
            labels: [String] = [],
            parameterTypes: [String] = [],
            resultType: String,
            mayThrow: Bool = false
        ) -> Candidate {
            Candidate(
                preciseIdentifier: member.identifier.precise,
                moduleName: surface.moduleName,
                probeOwnerType: specialization.probeType,
                ownerType: importedType.swiftType,
                dispatch: dispatch,
                memberName: memberName,
                argumentLabels: labels,
                parameterTypes: parameterTypes,
                resultType: resultType,
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedModules,
                requiresMainActor: requiresActor,
                allowsMainActorInference: !requiresActor && !isNonisolated,
                mayThrow: mayThrow
            )
        }

        switch member.kind.identifier {
        case "swift.type.property", "swift.property":
            guard let memberName = member.pathComponents.last,
                  isProbeIdentifier(memberName),
                  !member.declarationFragments.contains(where: {
                      $0.spelling == "async" || $0.spelling == "throws"
                          || $0.spelling == "rethrows"
                  }),
                  let declaredType = propertyType(member)
            else { return [] }
            let type = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: declaredType,
                    aliases: specialization.substitutions
                )
            let isolatedType = inheritedCallbackType(
                type,
                requiresMainActor: requiresActor
            )
            guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                isolatedType
            )
            else { return [] }
            let isStatic = member.kind.identifier == "swift.type.property"
            var values = [candidate(
                dispatch: isStatic ? .staticGetter : .instanceGetter,
                memberName: memberName,
                resultType: isolatedType
            )]
            if member.declarationFragments.contains(where: {
                $0.kind == "keyword" && $0.spelling == "set"
            }) {
                let setter: NativeImportDiscovery.Dispatch
                if isStatic {
                    setter = .staticSetter
                } else {
                    setter = importedType.representation == .reference
                        ? .instanceSetter : .instanceValueSetter
                }
                values.append(candidate(
                    dispatch: setter,
                    memberName: memberName,
                    labels: ["_"],
                    parameterTypes: [isolatedType],
                    resultType: "Swift.Void"
                ))
            }
            return values
        case "swift.init", "swift.method", "swift.type.method":
            guard !member.declarationFragments.contains(where: {
                $0.kind == "genericParameter"
                    || $0.spelling == "mutating"
                    || $0.spelling == "consuming"
            }), let signature = callableSignature(member)
            else { return [] }
            let parameterTypes = signature.parameterTypes.map { type in
                let substituted = FrontendReceipt.SwiftTypeSpelling
                    .replacingNominalAliases(
                        in: type,
                        aliases: specialization.substitutions
                    )
                return inheritedCallbackType(
                    substituted,
                    requiresMainActor: requiresActor
                )
            }
            guard parameterTypes.allSatisfy(
                FrontendReceipt.SwiftTypeSpelling.isGeneratedType
            ) else { return [] }
            let resultType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: signature.resultType,
                    aliases: specialization.substitutions
                )
            let isolatedResultType = inheritedCallbackType(
                resultType,
                requiresMainActor: requiresActor
            )
            guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                isolatedResultType
            ) else { return [] }
            let dispatch: NativeImportDiscovery.Dispatch = switch member.kind.identifier {
            case "swift.init": .initializer
            case "swift.type.method": .staticMethod
            default: .instanceMethod
            }
            return [candidate(
                dispatch: dispatch,
                memberName: dispatch == .initializer ? "init" : signature.baseName,
                labels: signature.argumentLabels,
                parameterTypes: parameterTypes,
                resultType: dispatch == .initializer
                    ? specialization.probeType : isolatedResultType,
                mayThrow: signature.mayThrow
            )]
        default:
            return []
        }
    }

    private static func inheritedCallbackType(
        _ type: String,
        requiresMainActor: Bool
    ) -> String {
        guard requiresMainActor,
              FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                  in: type
              ) != nil
        else { return type }
        // The callback parser has already accepted the spelling, so failure
        // here can only be a conflicting unsupported global actor. Preserve
        // that spelling and let the exact frontend probe reject it.
        return FrontendReceipt.FunctionTypeSpelling
            .applyingInheritedGlobalActor("MainActor", to: type) ?? type
    }

    private struct CallableSignature {
        var baseName: String
        var argumentLabels: [String]
        var parameterTypes: [String]
        var resultType: String
        var mayThrow: Bool
    }

    private static func callableSignature(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> CallableSignature? {
        let declaration = symbol.declarationFragments.map(\.spelling).joined()
        let compactDeclaration = declaration.filter { !$0.isWhitespace }
        guard !compactDeclaration.contains("throws("),
              !compactDeclaration.contains("init?(") && !compactDeclaration.contains("init!("),
              !symbol.declarationFragments.contains(where: {
                  $0.kind == "genericParameter" || $0.spelling == "async"
              })
        else { return nil }
        let labels = symbol.declarationFragments.compactMap { fragment in
            fragment.kind == "externalParam" ? fragment.spelling : nil
        }
        let parameters = symbol.functionSignature?.parameters ?? []
        guard let declarationAttributes = parameterAttributes(
            in: symbol.declarationFragments,
            count: parameters.count
        ) else { return nil }
        guard labels.count == parameters.count,
              labels.allSatisfy({ $0 == "_" || isProbeIdentifier($0) }),
              parameters.count <= 16
        else { return nil }
        let parameterTypes = zip(parameters, declarationAttributes).compactMap {
            parameterType($0.0, declarationAttributes: $0.1)
        }
        guard parameterTypes.count == parameters.count else { return nil }
        let baseName: String
        if symbol.kind.identifier == "swift.init" {
            baseName = "init"
        } else {
            guard let name = symbol.declarationFragments.first(where: {
                $0.kind == "identifier"
            })?.spelling, isProbeIdentifier(name)
            else { return nil }
            baseName = name
        }
        return .init(
            baseName: baseName,
            argumentLabels: labels,
            parameterTypes: parameterTypes,
            resultType: functionResultType(symbol),
            mayThrow: symbol.declarationFragments.contains(where: {
                $0.kind == "keyword"
                    && ($0.spelling == "throws" || $0.spelling == "rethrows")
            })
        )
    }

    private static func functionResultType(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> String {
        let value = symbol.functionSignature?.returns?
            .map(\.spelling).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == "Void" ? "Swift.Void" : value
    }

    private static func parameterType(
        _ parameter: SwiftFrontend.SymbolGraph.Parameter,
        declarationAttributes: [String]
    ) -> String? {
        let value = parameter.declarationFragments.map(\.spelling).joined()
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let measuredType = value[value.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var measuredAttributes = parameter.declarationFragments.compactMap {
            $0.kind == "attribute" ? normalizedAttribute($0.spelling) : nil
        }
        var recoveredAttributes: [String] = []
        for attribute in declarationAttributes {
            if let index = measuredAttributes.firstIndex(of: attribute) {
                measuredAttributes.remove(at: index)
            } else {
                recoveredAttributes.append(attribute)
            }
        }
        // `@escaping` and `@autoclosure` are declaration-parameter
        // conventions, so symbol-graph function signatures may omit them even
        // though the full declaration retains them. Other missing attributes
        // could alter the callable ABI and therefore remain fail-closed.
        guard recoveredAttributes.allSatisfy({
            $0 == "@escaping" || $0 == "@autoclosure"
        }) else { return nil }
        let type = (recoveredAttributes + [measuredType])
            .joined(separator: " ")
        guard type.utf8.count <= 16 * 1_024,
              FrontendReceipt.SwiftTypeSpelling.isGeneratedType(type),
              type != "Self", !type.hasPrefix("Self.")
        else { return nil }
        return type
    }

    private static func parameterAttributes(
        in fragments: [SwiftFrontend.SymbolGraph.Fragment],
        count: Int
    ) -> [[String]]? {
        let starts = fragments.indices.filter {
            fragments[$0].kind == "externalParam"
        }
        guard starts.count == count else { return nil }
        var result: [[String]] = []
        result.reserveCapacity(starts.count)
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count
                ? starts[offset + 1] : fragments.endIndex
            let declaration = fragments[start..<end]
            // Native invokers currently exchange immutable BridgeValue slots;
            // they cannot commit Swift `inout` writeback to a VM address. Do
            // not mis-probe such declarations as ordinary value parameters.
            guard !declaration.contains(where: {
                $0.kind == "keyword" && $0.spelling == "inout"
            }) else { return nil }
            result.append(declaration.compactMap {
                $0.kind == "attribute"
                    ? normalizedAttribute($0.spelling) : nil
            })
        }
        return result
    }

    private static func normalizedAttribute(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func propertyType(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> String? {
        let value = symbol.declarationFragments.map(\.spelling).joined()
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let remainder = value[value.index(after: separator)...]
        let end = remainder.range(of: " {")?.lowerBound ?? remainder.endIndex
        let type = remainder[..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? nil : type
    }

    /// Catalog construction can fail after frontend measurement while its
    /// projection is being validated. Checkpoint bounded groups so that a
    /// retry reuses successful and deterministic-rejection measurements
    /// without creating one filesystem entry for every public declaration.
    private static func probeCatalog(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store?,
        compilerFingerprint: String?,
        compilerInputHash: Core.Digest?,
        metrics: inout Metrics
    ) throws -> ProbedSurface {
        guard let cache, let compilerFingerprint, let compilerInputHash else {
            let measured = try probeUncached(
                candidates,
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            )
            return .init(
                types: measured.types.map(\.type),
                operations: measured.operations.map(\.operation)
            )
        }

        let cacheTypes = Array(Set(importedTypes.map(ProbeNativeType.init)))
            .sorted(by: probeTypeOrdering)
        let importedTypeBoundaryHash = try BuildCache.key(
            domain: "HLX.BuildCache.ManagedProbeTypes.v1",
            value: cacheTypes
        )
        let batches = stride(from: 0, to: candidates.count, by: 256).map {
            start in
            Array(candidates[start..<min(start + 256, candidates.count)])
        }
        guard !batches.isEmpty else { return .init(types: [], operations: []) }

        let measured: ProbeResult
        if batches.count == 1 {
            measured = try probeCatalogBatch(
                batches[0],
                importedTypes: importedTypes,
                minimumOS: minimumOS,
                frontend: frontend,
                invocation: invocation,
                cache: cache,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                importedTypeBoundaryHash: importedTypeBoundaryHash,
                metrics: &metrics
            )
        } else {
            let work = ProbeWorkQueue(count: batches.count)
            DispatchQueue.concurrentPerform(iterations: min(4, batches.count)) { _ in
                while let index = work.claim() {
                    autoreleasepool {
                        var localMetrics = Metrics()
                        do {
                            work.publish(.init(
                                result: try probeCatalogBatch(
                                    batches[index],
                                    importedTypes: importedTypes,
                                    minimumOS: minimumOS,
                                    frontend: frontend,
                                    invocation: invocation,
                                    cache: cache,
                                    compilerFingerprint: compilerFingerprint,
                                    compilerInputHash: compilerInputHash,
                                    importedTypeBoundaryHash:
                                        importedTypeBoundaryHash,
                                    metrics: &localMetrics
                                ),
                                error: nil,
                                metrics: localMetrics
                            ), at: index)
                        } catch {
                            work.publish(.init(
                                result: nil,
                                error: error,
                                metrics: localMetrics
                            ), at: index)
                        }
                    }
                }
            }
            var combined = ProbeResult.empty
            for index in batches.indices {
                let outcome = work.outcome(at: index)
                mergeAllProbeMetrics(outcome.metrics, into: &metrics)
                if let error = outcome.error { throw error }
                guard let result = outcome.result else {
                    throw FrontendReceipt.Error.frontendFailed(
                        "managed native Catalog probe batch produced no result"
                    )
                }
                combined = combined + result
            }
            measured = combined
        }
        return .init(
            types: measured.types.map(\.type),
            operations: measured.operations.map(\.operation)
        )
    }

    private static func probeCatalogBatch(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store,
        compilerFingerprint: String,
        compilerInputHash: Core.Digest,
        importedTypeBoundaryHash: Core.Digest,
        metrics: inout Metrics
    ) throws -> ProbeResult {
        let candidateIdentities = candidates.map(ProbeCandidate.init)
        let key = try BuildCache.key(
            domain: "HLX.BuildCache.ManagedProbeBatch.v1",
            value: ProbeBatchCacheKey(
                compilerProbePipelineHash:
                    NativeAPICatalog.Pipeline.compilerProbePipelineHash,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                invocation: invocation,
                minimumOS: minimumOS,
                candidates: candidateIdentities,
                importedTypeBoundaryHash: importedTypeBoundaryHash
            )
        )
        var decoded: DecodedProbeBatch?
        var generatedMetrics = Metrics()
        do {
            let value = try cache.value(
                namespace: .managedProbeBatch,
                key: key,
                maximumBytes: 128 * 1_024 * 1_024,
                validate: {
                    decoded = try decodeProbeBatchPayload(
                        $0,
                        candidates: candidates
                    )
                }
            ) {
                let measured = try probeBatch(
                    candidates,
                    importedTypes: importedTypes,
                    frontend: frontend,
                    invocation: invocation,
                    metrics: &generatedMetrics
                )
                guard measured.cacheableCandidates == Set(candidates) else {
                    throw UncacheableProbeBatch.result(measured)
                }
                return try Core.CanonicalJSON.encode(ProbeBatchCachePayload(
                    candidates: candidateIdentities,
                    results: try candidates.map {
                        try probeCachePayload(candidate: $0, measured: measured)
                    }
                ))
            }
            guard let decoded else {
                throw FrontendReceipt.Error.frontendFailed(
                    "managed native Catalog probe cache was not validated"
                )
            }
            if value.source == .hit {
                metrics.probeCacheHitCount += UInt64(candidates.count)
                metrics.cachedRejectionCount += decoded.rejectionCount
            } else {
                metrics.probeCacheMissCount += UInt64(candidates.count)
                mergeProbeMetrics(generatedMetrics, into: &metrics)
            }
            return decoded.result
        } catch UncacheableProbeBatch.result(let measured) {
            metrics.probeCacheMissCount += UInt64(candidates.count)
            mergeProbeMetrics(generatedMetrics, into: &metrics)
            return measured
        }
    }

    private static func probe(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        cache: BuildCache.Store?,
        compilerFingerprint: String?,
        compilerInputHash: Core.Digest?,
        metrics: inout Metrics
    ) throws -> ProbedSurface {
        guard let cache, let compilerFingerprint, let compilerInputHash else {
            let measured = try probeUncached(
                candidates,
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            )
            return .init(
                types: measured.types.map(\.type),
                operations: measured.operations.map(\.operation)
            )
        }

        let cacheTypes = Array(Set(importedTypes.map(ProbeNativeType.init)))
            .sorted(by: probeTypeOrdering)
        let importedTypeBoundaryHash = try BuildCache.key(
            domain: "HLX.BuildCache.ManagedProbeTypes.v1",
            value: cacheTypes
        )
        var types: [FrontendReceipt.Adapter.ImportedNativeType] = []
        var operations: [FrontendReceipt.Adapter.ImportedOperation] = []
        var misses: [(candidate: Candidate, key: Core.Digest)] = []
        for candidate in candidates {
            let key = try probeCacheKey(
                candidate: candidate,
                minimumOS: minimumOS,
                invocation: invocation,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                importedTypeBoundaryHash: importedTypeBoundaryHash
            )
            do {
                var validatedPayload: DecodedProbePayload?
                _ = try cache.value(
                    namespace: .managedProbe,
                    key: key,
                    maximumBytes: 4 * 1_024 * 1_024,
                    validate: {
                        validatedPayload = try decodeProbePayload(
                            $0,
                            candidate: candidate
                        )
                    }
                ) {
                    throw CacheLookupMiss.missing
                }
                guard let validatedPayload else {
                    throw FrontendReceipt.Error.frontendFailed(
                        "managed native probe cache was not validated"
                    )
                }
                let cachedOperations = try validatedPayload.operations.map {
                    try restoring($0, for: candidate)
                }
                metrics.probeCacheHitCount += 1
                if cachedOperations.isEmpty {
                    metrics.cachedRejectionCount += 1
                }
                types += validatedPayload.types
                operations += cachedOperations
            } catch CacheLookupMiss.missing {
                metrics.probeCacheMissCount += 1
                misses.append((candidate, key))
            }
        }
        guard !misses.isEmpty else {
            return .init(types: types, operations: operations)
        }

        let measured = try probeUncached(
            misses.map(\.candidate),
            importedTypes: importedTypes,
            frontend: frontend,
            invocation: invocation,
            metrics: &metrics
        )
        for miss in misses {
            guard measured.cacheableCandidates.contains(miss.candidate) else {
                continue
            }
            let encoded = try Core.CanonicalJSON.encode(
                try probeCachePayload(
                    candidate: miss.candidate,
                    measured: measured
                )
            )
            var validatedPayload: DecodedProbePayload?
            _ = try cache.value(
                namespace: .managedProbe,
                key: miss.key,
                maximumBytes: 4 * 1_024 * 1_024,
                validate: {
                    validatedPayload = try decodeProbePayload(
                        $0,
                        candidate: miss.candidate
                    )
                }
            ) { encoded }
            guard let validatedPayload else {
                throw FrontendReceipt.Error.frontendFailed(
                    "managed native probe cache was not validated"
                )
            }
            types += validatedPayload.types
            operations += try validatedPayload.operations.map {
                try restoring($0, for: miss.candidate)
            }
        }
        return .init(types: types, operations: operations)
    }

    private static func mergeAllProbeMetrics(
        _ source: Metrics,
        into destination: inout Metrics
    ) {
        destination.probeCacheHitCount += source.probeCacheHitCount
        destination.probeCacheMissCount += source.probeCacheMissCount
        destination.cachedRejectionCount += source.cachedRejectionCount
        mergeProbeMetrics(source, into: &destination)
    }

    private static func probeUncached(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        metrics: inout Metrics
    ) throws -> ProbeResult {
        let batches = stride(from: 0, to: candidates.count, by: 256).map {
            start in
            Array(candidates[start..<min(start + 256, candidates.count)])
        }
        guard batches.count > 1 else {
            guard let batch = batches.first else { return .empty }
            return try probeBatch(
                batch,
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            )
        }

        let work = ProbeWorkQueue(count: batches.count)
        let workerCount = min(4, batches.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while let index = work.claim() {
                autoreleasepool {
                    var localMetrics = Metrics()
                    do {
                        let result = try probeBatch(
                            batches[index],
                            importedTypes: importedTypes,
                            frontend: frontend,
                            invocation: invocation,
                            metrics: &localMetrics
                        )
                        work.publish(.init(
                            result: result,
                            error: nil,
                            metrics: localMetrics
                        ), at: index)
                    } catch {
                        work.publish(.init(
                            result: nil,
                            error: error,
                            metrics: localMetrics
                        ), at: index)
                    }
                }
            }
        }

        var result = ProbeResult.empty
        for index in batches.indices {
            let outcome = work.outcome(at: index)
            mergeProbeMetrics(outcome.metrics, into: &metrics)
            if let error = outcome.error { throw error }
            guard let batchResult = outcome.result else {
                throw FrontendReceipt.Error.frontendFailed(
                    "managed native probe batch produced no result"
                )
            }
            result = result + batchResult
        }
        return result
    }

    private static func mergeProbeMetrics(
        _ source: Metrics,
        into destination: inout Metrics
    ) {
        destination.probeAttemptCount += source.probeAttemptCount
        destination.failedProbeCount += source.failedProbeCount
        destination.rejectedSingletonCount += source.rejectedSingletonCount
        destination.generatedProbeSourceBytes += source.generatedProbeSourceBytes
    }

    private static func probeCacheKey(
        candidate: Candidate,
        minimumOS: Core.SemanticVersion,
        invocation: InterfaceArchive.FrontendInvocation,
        compilerFingerprint: String,
        compilerInputHash: Core.Digest,
        importedTypeBoundaryHash: Core.Digest
    ) throws -> Core.Digest {
        try BuildCache.key(
            domain: "HLX.BuildCache.ManagedProbe.v1",
            value: ProbeCacheKey(
                compilerProbePipelineHash:
                    NativeAPICatalog.Pipeline.compilerProbePipelineHash,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                invocation: invocation,
                minimumOS: minimumOS,
                candidate: ProbeCandidate(candidate),
                importedTypeBoundaryHash: importedTypeBoundaryHash
            )
        )
    }

    private static func probeCachePayload(
        candidate: Candidate,
        measured: ProbeResult
    ) throws -> ProbeCachePayload {
        let operations = try FrontendReceipt.Adapter().mergeImportedOperations(
            measured.operations.compactMap {
                $0.candidate == candidate
                    ? normalizingForCache($0.operation, candidate: candidate)
                    : nil
            }
        )
        let types = Array(Set(measured.types.compactMap {
            $0.candidate == candidate ? ProbeNativeType($0.type) : nil
        })).sorted(by: probeTypeOrdering)
        return .init(
            candidate: ProbeCandidate(candidate),
            types: types,
            operations: operations
        )
    }

    private static func decodeProbeBatchPayload(
        _ data: Data,
        candidates: [Candidate]
    ) throws -> DecodedProbeBatch {
        let payload = try JSONDecoder().decode(
            ProbeBatchCachePayload.self,
            from: data
        )
        guard payload.schemaVersion == 1,
              candidates.count <= 256,
              payload.candidates == candidates.map(ProbeCandidate.init),
              payload.results.count == candidates.count,
              try Core.CanonicalJSON.encode(payload) == data
        else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native Catalog probe cache payload is invalid"
            )
        }
        var result = ProbeResult.empty
        var rejectionCount: UInt64 = 0
        for (candidate, cached) in zip(candidates, payload.results) {
            let decoded = try decodeProbePayload(cached, candidate: candidate)
            if decoded.operations.isEmpty { rejectionCount += 1 }
            result.types += decoded.types.map {
                MeasuredType(candidate: candidate, type: $0)
            }
            result.operations += try decoded.operations.map {
                MeasuredOperation(
                    candidate: candidate,
                    operation: try restoring($0, for: candidate)
                )
            }
        }
        result.cacheableCandidates = Set(candidates)
        return .init(result: result, rejectionCount: rejectionCount)
    }

    private static func decodeProbePayload(
        _ data: Data,
        candidate: Candidate
    ) throws -> DecodedProbePayload {
        let payload = try JSONDecoder().decode(ProbeCachePayload.self, from: data)
        guard try Core.CanonicalJSON.encode(payload) == data else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native probe cache payload has noncanonical encoding"
            )
        }
        return try decodeProbePayload(payload, candidate: candidate)
    }

    private static func decodeProbePayload(
        _ payload: ProbeCachePayload,
        candidate: Candidate
    ) throws -> DecodedProbePayload {
        var invalidFacts: [String] = []
        if payload.schemaVersion != 1 { invalidFacts.append("schema") }
        if payload.candidate != ProbeCandidate(candidate) {
            invalidFacts.append("candidate identity")
        }
        if payload.types.count > 256 { invalidFacts.append("type count") }
        if payload.types != Array(Set(payload.types)).sorted(
            by: probeTypeOrdering
        ) {
            invalidFacts.append("type ordering")
        }
        for value in payload.types {
            if value.aliases != Array(Set(value.aliases)).sorted() {
                invalidFacts.append("type aliases")
            }
            if value.importedModules != candidate.importedModules.sorted() {
                invalidFacts.append("type import modules")
            }
        }
        if payload.operations.count > 4 { invalidFacts.append("operation count") }
        for value in payload.operations {
            if !operation(
                value,
                matches: candidate,
                probeTypes: payload.types
            ) {
                invalidFacts.append(
                    "operation \(value.ownerType).\(value.baseName)"
                        + " dispatch=\(value.dispatch.rawValue)"
                        + " labels=\(value.argumentLabels)"
                        + " parameters=\(value.parameterSwiftTypes)"
                        + " mainActor=\(value.requiresMainActor)"
                        + " throws=\(value.mayThrow)"
                        + " usr=\(value.declarationUSR ?? "none")"
                        + "; expected dispatch=\(candidate.dispatch.rawValue)"
                        + " labels=\(candidate.argumentLabels)"
                        + " parameterCount=\(candidate.parameterTypes.count)"
                        + " mainActor=\(candidate.requiresMainActor)"
                        + " throws=\(candidate.mayThrow)"
                        + " usr=\(candidate.preciseIdentifier)"
                )
            }
            if !value.sourceFileLogicalID.isEmpty {
                invalidFacts.append("source identity")
            }
            if value.importedModules != candidate.importedModules.sorted() {
                invalidFacts.append("import modules")
            }
            if !value.witnessFunctions.isEmpty {
                invalidFacts.append("witness functions")
            }
        }
        guard invalidFacts.isEmpty else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native probe cache payload is invalid for "
                    + "\(candidate.moduleName).\(candidate.ownerType)."
                    + "\(candidate.memberName): "
                    + invalidFacts.joined(separator: ", ")
            )
        }
        let types = payload.types.map {
            $0.restoring(sourceFileLogicalID: candidate.sourceFileLogicalID)
        }
        _ = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: [],
            operationTypes: types
        )
        return .init(types: types, operations: payload.operations)
    }

    private static func probeTypeOrdering(
        _ lhs: ProbeNativeType,
        _ rhs: ProbeNativeType
    ) -> Bool {
        if lhs.canonicalName != rhs.canonicalName {
            return lhs.canonicalName < rhs.canonicalName
        }
        if lhs.swiftType != rhs.swiftType { return lhs.swiftType < rhs.swiftType }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.representation != rhs.representation {
            return lhs.representation.rawValue < rhs.representation.rawValue
        }
        if lhs.aliases != rhs.aliases {
            return lhs.aliases.lexicographicallyPrecedes(rhs.aliases)
        }
        if lhs.importedModules != rhs.importedModules {
            return lhs.importedModules.lexicographicallyPrecedes(
                rhs.importedModules
            )
        }
        if lhs.objectiveCModuleName != rhs.objectiveCModuleName {
            return (lhs.objectiveCModuleName ?? "")
                < (rhs.objectiveCModuleName ?? "")
        }
        if lhs.objectiveCRuntimeName != rhs.objectiveCRuntimeName {
            return (lhs.objectiveCRuntimeName ?? "")
                < (rhs.objectiveCRuntimeName ?? "")
        }
        return !lhs.requiresMainActor && rhs.requiresMainActor
    }

    private static func normalizingForCache(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        candidate: Candidate
    ) -> FrontendReceipt.Adapter.ImportedOperation {
        var result = operation
        result.sourceFileLogicalID = ""
        result.importedModules = candidate.importedModules.sorted()
        // Probe witness names contain the temporary batch index. They have
        // served their measurement purpose and are not a reusable API fact.
        result.witnessFunctions = []
        return result
    }

    private static func operation(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        matches candidate: Candidate,
        probeTypes: [ProbeNativeType]
    ) -> Bool {
        let expectedParameterCount = candidate.parameterTypes.count
            + (isInstanceDispatch(candidate.dispatch) ? 1 : 0)
        let declarationMatches: Bool
        if candidate.preciseIdentifier.hasSuffix(
            "#zero-argument-construction"
        ) {
            let nominalUSR = String(candidate.preciseIdentifier.dropLast(
                "#zero-argument-construction".count
            ))
            declarationMatches = operation.declarationUSR != nil
                && (operation.declarationUSR?.hasPrefix(nominalUSR) == true
                    || probeTypes.contains { type in
                        probeType(type, recognizes: operation.ownerType)
                            && probeType(
                                type,
                                recognizes: operation.resultSwiftType
                            )
                            && [
                                candidate.ownerType,
                                candidate.probeOwnerType,
                                candidate.resultType,
                            ].contains { probeType(type, recognizes: $0) }
                    })
        } else if operation.objectiveC != nil {
            // Inherited methods are invoked through the candidate receiver but
            // belong to the compiler-resolved declaring type. Their exact USR,
            // not receiver spelling equality, authenticates the cached fact.
            declarationMatches = operation.declarationUSR
                == candidate.preciseIdentifier
                || synthesizedObjectiveCInitializer(
                    operation,
                    matches: candidate,
                    probeTypes: probeTypes
                )
        } else {
            // Swift protocol extensions and imported newtype wrappers may
            // resolve a candidate member to a different generic declaration
            // USR and overlay owner. The probe witness already pairs the exact
            // candidate with this operation; validate its complete callable
            // shape below instead of requiring textual identity equality.
            declarationMatches = true
        }
        return operation.dispatch == candidate.dispatch
            && declarationMatches
            && operation.baseName == candidate.memberName
            && operation.argumentLabels == candidate.argumentLabels
            && operation.parameterSwiftTypes.count == expectedParameterCount
            && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                operation.ownerType
            )
            && operation.parameterSwiftTypes.allSatisfy(
                FrontendReceipt.SwiftTypeSpelling.isGeneratedType
            )
            && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                operation.resultSwiftType
            )
            && (operation.requiresMainActor == candidate.requiresMainActor
                || (candidate.allowsMainActorInference
                    && operation.requiresMainActor))
            && operation.mayThrow == candidate.mayThrow
    }

    private static func synthesizedObjectiveCInitializer(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        matches candidate: Candidate,
        probeTypes: [ProbeNativeType]
    ) -> Bool {
        guard candidate.preciseIdentifier.contains("::SYNTHESIZED::"),
              candidate.dispatch == .initializer,
              candidate.memberName == "init",
              candidate.argumentLabels.isEmpty,
              let evidence = operation.objectiveC,
              evidence.methodFamily == .initializer,
              evidence.selector == "init",
              evidence.selectorIsExact,
              let dispatchClass = evidence.dispatchClassName
        else { return false }
        let receiverNames = [
            candidate.ownerType,
            candidate.probeOwnerType,
            operation.ownerType,
            operation.resultSwiftType,
        ]
        return receiverNames.contains {
            normalizedTypeName($0, moduleName: candidate.moduleName)
                .split(separator: ".").last.map(String.init) == dispatchClass
        } && probeTypes.contains { type in
            receiverNames.contains { probeType(type, recognizes: $0) }
                && probeType(type, recognizes: dispatchClass)
        }
    }

    private static func probeType(
        _ type: ProbeNativeType,
        recognizes spelling: String
    ) -> Bool {
        var names = Set([type.canonicalName, type.swiftType] + type.aliases)
        if let runtimeName = type.objectiveCRuntimeName {
            names.insert(runtimeName)
            names.insert("__C.\(runtimeName)")
        }
        let relativeNames = names
        for module in type.importedModules {
            for name in relativeNames where !name.hasPrefix(module + ".") {
                names.insert(module + "." + name)
            }
        }
        return names.contains(spelling)
    }

    private static func restoring(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        for candidate: Candidate
    ) throws -> FrontendReceipt.Adapter.ImportedOperation {
        guard var result = applyingCandidateLogicalSignature(
            operation,
            candidate: candidate
        ) else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native probe result has no complete logical signature for "
                    + "\(candidate.moduleName).\(candidate.ownerType)."
                    + candidate.memberName
            )
        }
        result.sourceFileLogicalID = candidate.sourceFileLogicalID
        result.importedModules = candidate.importedModules
        return result
    }

    /// Symbol Graph parameters describe the source-facing Swift API, while the
    /// measured operation supplies exact SIL/Objective-C physical evidence.
    /// Preserve compiler-measured closure attributes, but never promote a
    /// bridged physical nominal such as NSString into the logical signature.
    private static func applyingCandidateLogicalSignature(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        candidate: Candidate
    ) -> FrontendReceipt.Adapter.ImportedOperation? {
        // Clang-imported C typedefs frequently surface as source aliases for a
        // scalar ABI (for example CFTimeInterval/Double). The exact compiler
        // and Clang evidence is the callable logical boundary Helix supports;
        // replacing it with an opaque Symbol Graph alias would discard a valid
        // generic C invocation.
        guard operation.c == nil else { return operation }
        let receiverCount = isInstanceDispatch(candidate.dispatch) ? 1 : 0
        guard operation.parameterSwiftTypes.count
                == candidate.parameterTypes.count + receiverCount
        else { return nil }
        var result = operation
        var parameters = candidate.parameterTypes.indices.map { index in
            let logical = candidate.parameterTypes[index]
            let measured = operation.parameterSwiftTypes[index]
            if let invocation = operation.invocationParameterSwiftTypes,
               invocation.indices.contains(index),
               invocation[index] != measured {
                // A prior compiler/foreign-boundary pass deliberately erased
                // the logical ABI while retaining the narrower type used by
                // generated Swift. Symbol Graph syntax must not undo that
                // invocation adapter (for example protocol -> AnyObject).
                return measured
            }
            return FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: measured
            )
                == nil ? sourceFacingType(
                    logical: logical,
                    measured: measured,
                    moduleName: candidate.moduleName
                ) : measured
        }
        if receiverCount == 1, let receiver = operation.parameterSwiftTypes.last {
            parameters.append(receiver)
        }
        result.parameterSwiftTypes = parameters
        if let invocation = operation.invocationParameterSwiftTypes {
            result.invocationParameterSwiftTypes = invocation == parameters
                ? nil : invocation
        }
        if candidate.dispatch != .instanceValueSetter,
           FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
               in: operation.resultSwiftType
           ) == nil {
            result.resultSwiftType = sourceFacingType(
                logical: candidate.resultType,
                measured: operation.resultSwiftType,
                moduleName: candidate.moduleName
            )
        }
        return result
    }

    static func sourceFacingType(
        logical: String,
        measured: String,
        moduleName: String
    ) -> String {
        let canonicalLogical = FrontendReceipt.SwiftTypeSpelling
            .catalogAuthorityMatchIdentity(logical)
        let canonicalMeasured = FrontendReceipt.SwiftTypeSpelling
            .canonicalABIIdentity(measured)
        func moduleRelativeIdentity(_ value: String) -> String {
            let prefix = moduleName + "."
            let aliases = Dictionary(uniqueKeysWithValues: Set(
                FrontendReceipt.SwiftTypeSpelling.nominalTokens(in: value)
                    .filter { $0.hasPrefix(prefix) }
            ).map { token in
                (token, String(token.dropFirst(prefix.count)))
            })
            return FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                in: value,
                aliases: aliases
            )
        }
        if moduleRelativeIdentity(canonicalLogical)
            == moduleRelativeIdentity(canonicalMeasured) {
            return canonicalMeasured
        }
        if FrontendReceipt.ValueTypeParser.parse(
            canonicalLogical,
            allowVoid: true
        ) == nil,
           FrontendReceipt.ValueTypeParser.parse(
               canonicalMeasured,
               allowVoid: true
           ) != nil {
            return canonicalMeasured
        }
        return canonicalLogical
    }

    private static func probeBatch(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        metrics: inout Metrics
    ) throws -> ProbeResult {
        guard !candidates.isEmpty else { return .empty }
        do {
            return try measure(
                candidates,
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            )
        } catch let error as SwiftFrontend.Error {
            guard case let .compilationFailed(status, diagnostics) = error else {
                throw error
            }
            metrics.failedProbeCount += 1
            guard candidates.count > 1 else {
                let candidate = candidates[0]
                let escapingParameters = escapingProbeParameterIndices(
                    status: status,
                    diagnostics: diagnostics,
                    candidate: candidate
                )
                let inferMainActor = candidate.allowsMainActorInference
                    && isMainActorInferenceFailure(
                        status: status,
                        diagnostics: diagnostics
                    )
                if !escapingParameters.isEmpty || inferMainActor {
                    return try probeSingleton(
                        candidate,
                        forcingEscaping: escapingParameters,
                        inferringMainActor: inferMainActor,
                        importedTypes: importedTypes,
                        frontend: frontend,
                        invocation: invocation,
                        metrics: &metrics
                    )
                }
                metrics.rejectedSingletonCount += 1
                guard isDeterministicProbeRejection(
                    status: status,
                    diagnostics: diagnostics
                ) else {
                    // A transient compiler/toolchain failure is not evidence
                    // that this API is unsupported. Propagate it so the
                    // module Catalog cannot publish and cache a silent hole.
                    throw error
                }
                return .init(
                    types: [],
                    operations: [],
                    cacheableCandidates: Set(candidates)
                )
            }
            let middle = candidates.count / 2
            return try probeBatch(
                Array(candidates[..<middle]),
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            ) + probeBatch(
                Array(candidates[middle...]),
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation,
                metrics: &metrics
            )
        }
    }

    private static func probeSingleton(
        _ candidate: Candidate,
        forcingEscaping initialParameters: Set<Int>,
        inferringMainActor initiallyInferringMainActor: Bool = false,
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        metrics: inout Metrics
    ) throws -> ProbeResult {
        var escapingParameters = initialParameters
        var inferringMainActor = initiallyInferringMainActor
        var probeCandidate = inferringMainActor
            ? mainActorProbeCandidate(candidate) : candidate
        while true {
            do {
                let measured = try measure(
                    [probeCandidate],
                    importedTypes: importedTypes,
                    frontend: frontend,
                    invocation: invocation,
                    forcedEscapingParameters: [0: escapingParameters],
                    metrics: &metrics
                )
                return rebinding(
                    measured,
                    from: probeCandidate,
                    to: candidate
                )
            } catch let error as SwiftFrontend.Error {
                guard case let .compilationFailed(status, diagnostics) = error
                else { throw error }
                metrics.failedProbeCount += 1
                let discovered = escapingProbeParameterIndices(
                    status: status,
                    diagnostics: diagnostics,
                    candidate: candidate
                )
                if !discovered.isSubset(of: escapingParameters) {
                    escapingParameters.formUnion(discovered)
                    continue
                }
                if !inferringMainActor,
                   candidate.allowsMainActorInference,
                   isMainActorInferenceFailure(
                       status: status,
                       diagnostics: diagnostics
                   ) {
                    inferringMainActor = true
                    probeCandidate = mainActorProbeCandidate(candidate)
                    continue
                }
                metrics.rejectedSingletonCount += 1
                guard isDeterministicProbeRejection(
                    status: status,
                    diagnostics: diagnostics
                ) else { throw error }
                return .init(
                    types: [],
                    operations: [],
                    cacheableCandidates: [candidate]
                )
            }
        }
    }

    private static func mainActorProbeCandidate(
        _ candidate: Candidate
    ) -> Candidate {
        var result = candidate
        result.parameterTypes = result.parameterTypes.map {
            inheritedCallbackType($0, requiresMainActor: true)
        }
        result.resultType = inheritedCallbackType(
            result.resultType,
            requiresMainActor: true
        )
        result.requiresMainActor = true
        result.allowsMainActorInference = false
        return result
    }

    private static func rebinding(
        _ result: ProbeResult,
        from measuredCandidate: Candidate,
        to sourceCandidate: Candidate
    ) -> ProbeResult {
        guard measuredCandidate != sourceCandidate else { return result }
        return .init(
            types: result.types.map {
                var value = $0
                if value.candidate == measuredCandidate {
                    value.candidate = sourceCandidate
                }
                return value
            },
            operations: result.operations.map {
                var value = $0
                if value.candidate == measuredCandidate {
                    value.candidate = sourceCandidate
                }
                return value
            },
            cacheableCandidates: Set(result.cacheableCandidates.map {
                $0 == measuredCandidate ? sourceCandidate : $0
            })
        )
    }

    private static func measure(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
        forcedEscapingParameters: [Int: Set<Int>] = [:],
        metrics: inout Metrics
    ) throws -> ProbeResult {
        metrics.probeAttemptCount += 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-native-surface-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let storageURL = directory.appendingPathComponent(
            "ManagedNativeStorage.swift"
        )
        let storageSource = renderStorageSource(candidates)
        let storageContents = Data(storageSource.utf8)
        let sourceURL = directory.appendingPathComponent("ManagedNativeSurface.swift")
        let source = renderSource(
            candidates,
            forcedEscapingParameters: forcedEscapingParameters
        )
        let contents = Data(source.utf8)
        metrics.generatedProbeSourceBytes += UInt64(
            storageContents.count + contents.count
        )
        guard storageContents.count + contents.count <= 8 * 1_024 * 1_024 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native probe source exceeds 8 MiB"
            )
        }
        try storageContents.write(to: storageURL, options: .atomic)
        try contents.write(to: sourceURL, options: .atomic)

        var storageInvocation = invocation
        storageInvocation.semanticArguments.removeAll {
            $0 == "-warnings-as-errors" || $0 == "-suppress-warnings"
        }
        _ = try frontend.typecheckDiagnostics(
            sourceFiles: [storageURL],
            invocation: storageInvocation
        )

        var probeInvocation = invocation
        probeInvocation.semanticArguments.removeAll {
            $0 == "-warnings-as-errors"
        }
        let astOutput = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: probeInvocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(astOutput)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL,
            invocationObserver: frontend.invocationObserver
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let canonicalSIL = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: probeInvocation
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "HelixManagedNative/ManagedNativeSurface.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let resolver = try FrontendReceipt.SILFunctionResolver(file: silFile).resolvingCollisions(using: .init(
            compilerURL: frontend.compilerURL, invocationObserver: frontend.invocationObserver))
        var candidatesByWitness: [String: Candidate] = [:]
        var propertySelectorsByCandidate: [
            Candidate: Set<FrontendReceipt.ObjectiveCABI.PropertySelector>
        ] = [:]
        var ambiguousWitnesses = Set<String>()
        let measuredDocuments = try documents.compactMap { document ->
            FrontendReceipt.TypedAST.Object? in
            guard let items = document["items"] as? [Any] else { return nil }
            var measuredItems: [Any] = []
            for value in items {
                guard let item = value as? [String: Any],
                      item["_kind"] as? String == "func_decl",
                      let usr = item["usr"] as? String,
                      usr.hasPrefix("s:")
                else {
                    measuredItems.append(value)
                    continue
                }
                let name = FrontendReceipt.Adapter().baseName(in: item)
                if let name,
                   name.hasPrefix("helixManagedNativeSelector"),
                   let index = Int(name.dropFirst(
                       "helixManagedNativeSelector".count
                   )),
                   candidates.indices.contains(index) {
                    propertySelectorsByCandidate[candidates[index], default: []]
                        .formUnion(
                            FrontendReceipt.ObjectiveCABI.propertySelectors(
                                in: item
                            )
                        )
                    continue
                }
                guard let function = try resolver.function(
                    for: item,
                    source: state,
                    baseName: name
                ) else {
                    // The compiler may eliminate an unreferenced private probe.
                    continue
                }
                measuredItems.append(value)
                guard let name,
                      name.hasPrefix("helixManagedNativeProbe"),
                      let index = Int(name.dropFirst("helixManagedNativeProbe".count)),
                      candidates.indices.contains(index)
                else { continue }
                let candidate = candidates[index]
                if let existing = candidatesByWitness[function.mangledName],
                   existing != candidate {
                    ambiguousWitnesses.insert(function.mangledName)
                } else {
                    candidatesByWitness[function.mangledName] = candidate
                }
            }
            var filtered = document
            filtered["items"] = measuredItems
            return filtered
        }
        for witness in ambiguousWitnesses {
            candidatesByWitness.removeValue(forKey: witness)
        }
        let surface = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: measuredDocuments,
            sourcesByPhysicalPath: [
                sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
            ],
            moduleName: invocation.moduleName,
            demangled: demangled,
            silFile: silFile,
            compilerURL: frontend.compilerURL
        )
        let measuredImportedTypes = try FrontendReceipt.Adapter()
            .mergeImportedNativeTypes(
                discoveredTypes: importedTypes,
                operationTypes: surface.types
            )
        let nativeTypes = placeholderNativeTypes(measuredImportedTypes)
        let swiftAliases = try FrontendReceipt.Adapter()
            .makeImportedSwiftTypeAliases(importedTypes)
        let signatureTypeIndex = FrontendReceipt.ImportedTypeIndex(
            types: measuredImportedTypes
        )
        let operations = surface.operations.compactMap {
            operation -> MeasuredOperation? in
            let matching = Set(operation.witnessFunctions.compactMap {
                candidatesByWitness[$0]
            })
            guard matching.count == 1,
                  let candidate = matching.first,
                  operation.dispatch == candidate.dispatch,
                  operation.baseName == candidate.memberName,
                  operation.argumentLabels == candidate.argumentLabels,
                  operation.mayThrow == candidate.mayThrow
            else { return nil }
            var measured = operation
            if var evidence = measured.objectiveC,
               let property = evidence.property {
                let selectors = propertySelectorsByCandidate[candidate]?
                    .filter {
                        $0.declarationUSR == evidence.declarationUSR
                            && $0.accessor == property.accessor
                    } ?? []
                if selectors.count == 1, let selector = selectors.first {
                    evidence.selector = selector.selector
                    evidence.selectorIsExact = true
                    measured.objectiveC = evidence
                }
            }
            if !FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                measured.ownerType
            ) {
                // Imported protocol-extension witnesses can be printed as a
                // compiler diagnostic placeholder such as "related decl"
                // rather than a legal Swift type. The exact declaration USR
                // and the successfully typechecked concrete probe receiver
                // together are sufficient to restore only that unusable
                // spelling; valid generic declaring owners stay untouched.
                guard measured.declarationUSR == candidate.preciseIdentifier,
                      FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                          candidate.ownerType
                      )
                else { return nil }
                measured.ownerType = candidate.ownerType
            }
            // The compiler-resolved declaration owner is authoritative. A
            // probe may be invoked through a subclass or type alias while the
            // member is declared by a generic superclass; replacing that
            // owner with the probe receiver would manufacture a different
            // logical ABI for the same SIL symbol. Compiler-proven nominal
            // aliases still describe that same owner identity and must use
            // the generated Swift spelling shared by parameters and results.
            measured.ownerType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: measured.ownerType,
                    aliases: swiftAliases
                )
            guard let logical = applyingCandidateLogicalSignature(
                measured,
                candidate: candidate
            ) else { return nil }
            measured = logical
            measured.parameterSwiftTypes = measured.parameterSwiftTypes.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: swiftAliases
                )
            }
            measured.invocationParameterSwiftTypes = measured
                .invocationParameterSwiftTypes?.map {
                    FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                        in: $0,
                        aliases: swiftAliases
                    )
                }
            if isSetterDispatch(candidate.dispatch),
               measured.parameterSwiftTypes.first.flatMap({
                   FrontendReceipt.FunctionTypeSpelling.callbackBoundary(in: $0)
               }) != nil {
                guard let storedParameters = FrontendReceipt
                    .FunctionTypeSpelling.applyingAuthoritativeLifetimes(
                        [0: .escaping],
                        to: measured.parameterSwiftTypes
                    )
                else { return nil }
                measured.parameterSwiftTypes = storedParameters
                if let invocationParameters = measured
                    .invocationParameterSwiftTypes {
                    guard let storedInvocationParameters = FrontendReceipt
                        .FunctionTypeSpelling.applyingAuthoritativeLifetimes(
                            [0: .escaping],
                            to: invocationParameters
                        )
                    else { return nil }
                    measured.invocationParameterSwiftTypes =
                        storedInvocationParameters
                }
            }
            if candidate.requiresMainActor {
                measured.parameterSwiftTypes = measured.parameterSwiftTypes.map {
                    inheritedCallbackType(
                        $0,
                        requiresMainActor: true
                    )
                }
                measured.invocationParameterSwiftTypes = measured
                    .invocationParameterSwiftTypes?.map {
                        inheritedCallbackType(
                            $0,
                            requiresMainActor: true
                        )
                    }
            }
            measured.resultSwiftType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: measured.resultSwiftType,
                    aliases: swiftAliases
                )
            let parameters = measured.parameterSwiftTypes.compactMap {
                FrontendReceipt.ValueTypeParser.parse(
                    $0,
                    allowVoid: false,
                    nativeTypes: nativeTypes
                )
            }
            guard parameters.count == measured.parameterSwiftTypes.count,
                  FrontendReceipt.NativeBridgeProfile.callbacks(
                      parameterSpellings: measured.parameterSwiftTypes,
                      parameterTypes: parameters
                  ) != nil,
                  let result = FrontendReceipt.ValueTypeParser.parse(
                      measured.resultSwiftType,
                      allowVoid: true,
                      nativeTypes: nativeTypes
                  ),
                  FrontendReceipt.NativeBridgeProfile.isResult(result)
            else { return nil }
            measured.sourceFileLogicalID = candidate.sourceFileLogicalID
            measured.importedModules = candidate.importedModules
            // The Symbol Graph was extracted from this exact module. Prefer
            // that provenance over class-name prefix heuristics used while
            // reading a source call that may import several frameworks.
            measured.objectiveC?.moduleName = candidate.moduleName
            measured.c?.moduleName = candidate.moduleName
            // Isolation belongs to the imported declaration. A nonisolated
            // member may accept or return an actor-isolated nominal value
            // without making the call itself actor-isolated.
            measured.requiresMainActor = candidate.requiresMainActor
            measured.isolationEvidence = .importedDeclaration
            return MeasuredOperation(candidate: candidate, operation: measured)
        }
        let types = operations.flatMap { measured in
            signatureTypes(
                index: signatureTypeIndex,
                operation: measured.operation,
                candidate: measured.candidate
            ).map {
                MeasuredType(candidate: measured.candidate, type: $0)
            }
        }
        return .init(
            types: types,
            operations: operations,
            cacheableCandidates: Set(candidates)
        )
    }

    static func isDeterministicProbeRejection(
        status: Int32,
        diagnostics: String
    ) -> Bool {
        guard status == 1 else { return false }
        let stableSemanticFragments = [
            "a c function pointer can only be formed",
            "ambiguous use of",
            "cannot assign to property",
            "cannot call value of non-function type",
            "cannot be constructed because it has no accessible initializers",
            "cannot convert return expression",
            "cannot convert value",
            "cannot infer contextual base",
            "cannot invoke initializer",
            "cannot reference class method",
            "cannot reference instance method",
            "extra argument",
            "generic parameter ",
            "get-only property",
            "has no member",
            "has been replaced by",
            "has been renamed to",
            "inaccessible due to",
            "incorrect argument label",
            "instance member ",
            "is unavailable",
            "is only available in",
            "is not concurrency-safe because it involves shared mutable state",
            "missing argument",
            "no exact matches in call",
            "reference to generic type",
            "requires that",
            "static member ",
            "type of expression is ambiguous",
            "will never be executed",
        ]
        let errors = compilerErrorMessages(diagnostics)
        return !errors.isEmpty && errors.allSatisfy { error in
            let unresolvedContextualName = (
                error.hasPrefix("cannot find '")
                    || error.hasPrefix("cannot find type '")
            ) && error.contains("' in scope")
            return unresolvedContextualName
                || stableSemanticFragments.contains { error.contains($0) }
        }
    }

    static func isMainActorInferenceFailure(
        status: Int32,
        diagnostics: String
    ) -> Bool {
        guard status == 1 else { return false }
        return diagnostics.lowercased().split(whereSeparator: \.isNewline)
            .contains { line in
                line.contains("main actor-isolated")
                    && (line.contains("[#actorisolatedcall]")
                        || line.contains(
                            "main actor isolation inferred from inheritance"
                        )
                        || line.contains("synchronous nonisolated context")
                        || line.contains("nonisolated context")
                        || line.contains("risks causing data races"))
            }
    }

    private static func compilerErrorMessages(_ diagnostics: String) -> [String] {
        diagnostics.split(whereSeparator: \.isNewline).compactMap {
            line -> String? in
            let value = line.lowercased().trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let message: Substring
            if value.hasPrefix("error:") {
                message = value.dropFirst("error:".count)
            } else if value.hasPrefix("fatal error:") {
                message = value.dropFirst("fatal error:".count)
            } else if value.hasPrefix("llvm error:") {
                message = value.dropFirst("llvm error:".count)
            } else if let marker = value.range(of: ": error:") {
                message = value[marker.upperBound...]
            } else {
                return nil
            }
            return String(message).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
    }

    private static func escapingProbeParameterIndices(
        status: Int32,
        diagnostics: String,
        candidate: Candidate
    ) -> Set<Int> {
        guard status == 1 else { return [] }
        let parameterMarker = "non-escaping parameter 'argument"
        return Set(compilerErrorMessages(diagnostics).compactMap { error in
            guard let marker = error.range(of: parameterMarker),
                  error.contains("@escaping")
                    || error.contains("may allow it to escape")
                    || error.hasPrefix("escaping closure captures")
            else { return nil }
            let suffix = error[marker.upperBound...]
            guard let quote = suffix.firstIndex(of: "'"),
                  let index = Int(suffix[..<quote]),
                  candidate.parameterTypes.indices.contains(index)
            else { return nil }
            return index
        })
    }

    private static func renderSource(
        _ candidates: [Candidate],
        forcedEscapingParameters: [Int: Set<Int>] = [:]
    ) -> String {
        let imports = Set(candidates.flatMap {
            [$0.moduleName] + $0.importedModules
        }).sorted().map { "import \($0)" }
        let declarations = candidates.enumerated().flatMap { index, candidate in
            [renderProbe(
                index: index,
                candidate: candidate,
                forcedEscapingParameters: forcedEscapingParameters[index] ?? []
            )] + propertySelectorProbe(index: index, candidate: candidate)
        }
        return (imports + [""] + declarations + [""])
            .joined(separator: "\n")
    }

    private static func renderStorageSource(_ candidates: [Candidate]) -> String {
        let imports = Set(candidates.flatMap {
            [$0.moduleName] + $0.importedModules
        }).sorted().map { "import \($0)" }
        let helpers = """
        private func helixManagedNativeRequiresStorable<T>(_: T.Type) {}
        """
        let declarations = candidates.enumerated().map { index, candidate in
            renderStorageProbe(index: index, candidate: candidate)
        }
        return (imports + ["", helpers, ""] + declarations + [""])
            .joined(separator: "\n")
    }

    private static func renderStorageProbe(
        index: Int,
        candidate: Candidate
    ) -> String {
        let owner = escapedNominalType(candidate.probeOwnerType)
        let boundaryTypes = (isInstanceDispatch(candidate.dispatch)
            ? [owner] : []) + candidate.parameterTypes + [candidate.resultType]
        let checks = Set(boundaryTypes.map(storableProbeType)).sorted().flatMap {
            type in
            [
                "    helixManagedNativeRequiresStorable((\(type)).self)",
            ]
        }.joined(separator: "\n")
        return "private func helixManagedNativeStorageProbe\(index)() {\n"
            + "\(checks)\n}"
    }

    private static func renderProbe(
        index: Int,
        candidate: Candidate,
        forcedEscapingParameters: Set<Int> = []
    ) -> String {
        let isolation = candidate.requiresMainActor ? "@MainActor " : ""
        let throwing = candidate.mayThrow ? " throws" : ""
        let tryPrefix = candidate.mayThrow ? "try " : ""
        let owner = escapedNominalType(candidate.probeOwnerType)
        let member = escapedIdentifier(candidate.memberName)
        var parameters: [String] = []
        if isInstanceDispatch(candidate.dispatch) {
            parameters.append("_ receiver: \(owner)")
        }
        parameters += candidate.parameterTypes.enumerated().map { item in
            let type = probeParameterType(
                item.element,
                forceEscaping: forcedEscapingParameters.contains(item.offset)
            )
            return "_ argument\(item.offset): \(type)"
        }
        let arguments = zip(
            candidate.argumentLabels,
            candidate.parameterTypes.indices
        ).map { label, offset in
            label == "_" ? "argument\(offset)" : "\(escapedIdentifier(label)): argument\(offset)"
        }.joined(separator: ", ")
        let call: String = switch candidate.dispatch {
        case .globalFunction:
            "\(escapedIdentifier(candidate.moduleName)).\(member)(\(arguments))"
        case .initializer:
            "\(owner)(\(arguments))"
        case .staticMethod:
            "\(owner).\(member)(\(arguments))"
        case .instanceMethod:
            "receiver.\(member)(\(arguments))"
        case .staticGetter:
            "\(owner).\(member)"
        case .staticSetter:
            "\(owner).\(member) = argument0"
        case .instanceGetter:
            "receiver.\(member)"
        case .instanceSetter:
            "receiver.\(member) = argument0"
        case .instanceValueSetter:
            "mutableReceiver.\(member) = argument0"
        case .nativeUpcast, .anyObjectBridge:
            preconditionFailure("managed member probe has invalid dispatch")
        }
        let mutableReceiver = candidate.dispatch == .instanceValueSetter
            ? "\n    var mutableReceiver = receiver" : ""
        let callStatement = storableProbeType(candidate.resultType) == "Swift.Void"
            ? "\(tryPrefix)\(call)" : "_ = \(tryPrefix)\(call)"
        return "\(isolation)private func helixManagedNativeProbe\(index)("
            + "\(parameters.joined(separator: ", ")))\(throwing) {"
            + "\(mutableReceiver)\n"
            + "    \(callStatement)\n}"
    }

    static func storableProbeType(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["@autoclosure ", "borrowing ", "consuming ", "isolated "]
        where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value == "()" || value == "Void" { return "Swift.Void" }
        if value.hasSuffix("!") {
            value = String(value.dropLast()) + "?"
        }
        guard let callback = FrontendReceipt.FunctionTypeSpelling
            .callbackBoundary(in: value)
        else { return value }
        return callback.isOptional
            ? "Swift.Optional<\(callback.function.generatedSpelling)>"
            : callback.function.generatedSpelling
    }

    private static func probeParameterType(
        _ raw: String,
        forceEscaping: Bool
    ) -> String {
        guard var callback = FrontendReceipt.FunctionTypeSpelling
            .callbackBoundary(in: raw),
              !callback.isOptional
        else {
            return forceEscaping ? "@escaping \(raw)" : raw
        }
        // An escaping value may be passed to either an escaping or a
        // nonescaping parameter. This lets the call compile without guessing
        // the SDK declaration's lifetime from an incomplete Symbol Graph;
        // the callee's canonical SIL parameter remains authoritative and is
        // recorded by ImportedOperations.
        callback.function.attributes.isEscaping = true
        return callback.declaredSpelling
    }

    private static func propertySelectorProbe(
        index: Int,
        candidate: Candidate
    ) -> [String] {
        guard candidate.preciseIdentifier.hasPrefix("c:objc(cs)"),
              candidate.preciseIdentifier.contains("(py)")
                || candidate.preciseIdentifier.contains("(cpy)")
        else { return [] }
        let accessor: String
        switch candidate.dispatch {
        case .instanceGetter, .staticGetter:
            accessor = "getter"
        case .instanceSetter, .staticSetter:
            accessor = "setter"
        case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
             .anyObjectBridge, .instanceMethod, .instanceValueSetter:
            return []
        }
        let owner = escapedNominalType(candidate.probeOwnerType)
        let member = escapedIdentifier(candidate.memberName)
        return [
            "private func helixManagedNativeSelector\(index)() {\n"
                + "    _ = #selector(\(accessor): \(owner).\(member))\n}"
        ]
    }

    private static func isInstanceDispatch(
        _ dispatch: NativeImportDiscovery.Dispatch
    ) -> Bool {
        switch dispatch {
        case .instanceMethod, .instanceGetter, .instanceSetter,
             .instanceValueSetter: true
        case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
             .anyObjectBridge,
             .staticGetter, .staticSetter: false
        }
    }

    private static func isSetterDispatch(
        _ dispatch: NativeImportDiscovery.Dispatch
    ) -> Bool {
        switch dispatch {
        case .staticSetter, .instanceSetter, .instanceValueSetter:
            true
        case .globalFunction, .initializer, .staticMethod, .instanceMethod,
             .staticGetter, .instanceGetter, .nativeUpcast, .anyObjectBridge:
            false
        }
    }

    private static func crossesUninhabitedBoundary(
        _ candidate: Candidate,
        typeIndex: FrontendReceipt.ImportedTypeIndex,
        uninhabitedCanonicalNames: Set<String>
    ) -> Bool {
        guard !uninhabitedCanonicalNames.isEmpty else { return false }
        var spellings = candidate.parameterTypes + [candidate.resultType]
        if isInstanceDispatch(candidate.dispatch) {
            spellings += [candidate.ownerType, candidate.probeOwnerType]
        }
        return typeIndex.matching(spellings: spellings).contains {
            uninhabitedCanonicalNames.contains($0.canonicalName)
        }
    }

    /// Keeps a candidate cache entry independent of the probe batch that
    /// happened to contain it. Only native types named by that candidate's
    /// callable signature are persisted with the operation.
    private static func signatureTypes(
        index: FrontendReceipt.ImportedTypeIndex,
        operation: FrontendReceipt.Adapter.ImportedOperation,
        candidate: Candidate
    ) -> [FrontendReceipt.Adapter.ImportedNativeType] {
        var spellings = [
            operation.resultSwiftType,
        ] + operation.parameterSwiftTypes
            + (operation.invocationParameterSwiftTypes ?? [])
            + (operation.physicalParameterSwiftTypes ?? [])
            + candidate.parameterTypes
        if isInstanceDispatch(candidate.dispatch) {
            spellings += [
                operation.ownerType,
                candidate.ownerType,
                candidate.probeOwnerType,
            ]
        }
        return index.matching(spellings: spellings).map { original in
            var type = original
            type.sourceFileLogicalID = candidate.sourceFileLogicalID
            // The generated source imports the union for its whole batch.
            // Candidate provenance is stable across batch partitioning.
            type.importedModules = Array(Set(candidate.importedModules)).sorted()
            type.aliases = Array(Set(type.aliases)).sorted()
            return type
        }.sorted {
            ($0.canonicalName, $0.swiftType)
                < ($1.canonicalName, $1.swiftType)
        }
    }

    private static func placeholderNativeTypes(
        _ types: [FrontendReceipt.Adapter.ImportedNativeType]
    ) -> [String: Core.TypeID] {
        var result: [String: Core.TypeID] = [:]
        for type in types {
            let placeholder = Core.TypeID(rawValue: .sha256(
                "managed-debug-type-probe:\(type.canonicalName)"
            ))
            for name in Set(
                [type.canonicalName, type.swiftType, "__C.\(type.canonicalName)"]
                    + type.aliases
            ) where !FrontendReceipt.ValueTypeParser
                .isBuiltinValueSpelling(name) {
                result[name] = placeholder
            }
        }
        return result
    }

    private static func ownerSpecialization(
        surface: OwnerSurface,
        importedType: FrontendReceipt.Adapter.ImportedNativeType
    ) -> OwnerSpecialization? {
        guard !surface.genericParameters.isEmpty else {
            return OwnerSpecialization(
                probeType: surface.swiftPath,
                substitutions: [:]
            )
        }
        let spellings = [importedType.swiftType, importedType.canonicalName]
            + importedType.aliases
        for spelling in spellings {
            guard let arguments = genericArguments(
                in: spelling,
                ownerPath: surface.swiftPath,
                moduleName: surface.moduleName
            ), arguments.count == surface.genericParameters.count
            else { continue }
            return OwnerSpecialization(
                probeType: spelling,
                substitutions: Dictionary(
                    uniqueKeysWithValues: zip(
                        surface.genericParameters,
                        arguments
                    )
                )
            )
        }
        return nil
    }

    private static func genericArguments(
        in raw: String,
        ownerPath: String,
        moduleName: String
    ) -> [String]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(value),
              normalizedTypeName(value, moduleName: moduleName) == ownerPath,
              let open = value.firstIndex(of: "<"),
              value.last == ">"
        else { return nil }
        let body = value[
            value.index(after: open)..<value.index(before: value.endIndex)
        ]
        var arguments: [String] = []
        var start = body.startIndex
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        for index in body.indices {
            switch body[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > body.startIndex
                    ? body[body.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
            guard angleDepth >= 0,
                  parenthesisDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            if body[index] == ",",
               angleDepth == 0,
               parenthesisDepth == 0,
               bracketDepth == 0 {
                let argument = body[start..<index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                    argument
                ) else { return nil }
                arguments.append(argument)
                start = body.index(after: index)
            }
        }
        guard angleDepth == 0,
              parenthesisDepth == 0,
              bracketDepth == 0
        else { return nil }
        let tail = body[start...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(tail)
        else { return nil }
        arguments.append(tail)
        return arguments
    }

    private static func normalizedTypeName(
        _ raw: String,
        moduleName: String?
    ) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("?") { value.removeLast() }
        if value.hasPrefix("__C.") { value.removeFirst("__C.".count) }
        if let moduleName, value.hasPrefix("\(moduleName).") {
            value.removeFirst(moduleName.count + 1)
        }
        if let generic = value.firstIndex(of: "<") {
            value = String(value[..<generic])
        }
        return value
    }

    private static func clangRuntimeName(_ preciseIdentifier: String) -> String? {
        for marker in [
            "c:objc(cs)", "c:objc(pl)",
            "c:@T@", "c:@E@", "c:@S@", "c:@U@",
        ]
        where preciseIdentifier.hasPrefix(marker) {
            let name = String(preciseIdentifier.dropFirst(marker.count))
            return isProbeIdentifier(name) ? name : nil
        }
        return nil
    }

    private static func requiresMainActor(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> Bool {
        symbol.declarationFragments.contains {
            $0.preciseIdentifier == "s:ScM" && $0.spelling == "MainActor"
        }
    }

    private static func referencedSwiftModules(
        in symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> [String] {
        Array(Set(symbol.declarationFragments.compactMap {
            $0.preciseIdentifier.flatMap(swiftModuleName)
        })).sorted()
    }

    static func swiftModuleName(inPreciseIdentifier precise: String) -> String? {
        guard precise.hasPrefix("s:") else { return nil }
        let suffix = precise.utf8.dropFirst(2)
        let lengthBytes = suffix.prefix { byte in
            byte >= Character("0").asciiValue!
                && byte <= Character("9").asciiValue!
        }
        guard !lengthBytes.isEmpty,
              lengthBytes.count <= 3,
              let length = Int(String(decoding: lengthBytes, as: UTF8.self)),
              length > 0,
              length <= 128
        else { return nil }
        let nameBytes = suffix.dropFirst(lengthBytes.count).prefix(length)
        guard nameBytes.count == length else { return nil }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard isProbeIdentifier(name),
              !["Builtin", "Swift", "_Concurrency"].contains(name)
        else { return nil }
        return name
    }

    private static func isAvailable(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol,
        minimumOS: Core.SemanticVersion
    ) -> Bool {
        supportsAvailability(
            symbol.availability ?? [],
            minimumOS: minimumOS
        )
    }

    static func supportsAvailability(
        _ values: [SwiftFrontend.SymbolGraph.Availability],
        minimumOS: Core.SemanticVersion
    ) -> Bool {
        let compilerWide = values.filter {
            $0.domain == "Swift" || $0.domain == "*"
        }
        guard !compilerWide.contains(where: {
            $0.isUnconditionallyUnavailable == true
                || $0.isUnconditionallyDeprecated == true
                || $0.deprecated != nil
                || $0.obsoleted != nil
        }) else { return false }
        let ios = values.filter { $0.domain == "iOS" }
        // Generated bridges compile against the captured current SDK with the
        // host project's warning policy. Deprecated and obsoleted declarations
        // are therefore not stable candidates even when the Shell minimum OS
        // predates those releases.
        guard !ios.contains(where: {
            $0.isUnconditionallyUnavailable == true
                || $0.isUnconditionallyDeprecated == true
                || $0.deprecated != nil
                || $0.obsoleted != nil
        }) else { return false }
        let required = (
            Int(minimumOS.major), Int(minimumOS.minor), Int(minimumOS.patch)
        )
        if ios.contains(where: {
            guard let introduced = $0.introduced else { return false }
            return (introduced.major, introduced.minor, introduced.patch) > required
        }) {
            return false
        }
        return true
    }

    private static func escapedNominalType(_ value: String) -> String {
        var result = ""
        var identifier = ""
        func appendIdentifier() {
            guard !identifier.isEmpty else { return }
            result += escapedIdentifier(identifier)
            identifier.removeAll(keepingCapacity: true)
        }
        for character in value {
            if character == "_" || character.isLetter || character.isNumber {
                identifier.append(character)
            } else {
                appendIdentifier()
                result.append(character)
            }
        }
        appendIdentifier()
        return result
    }

    private static func escapedIdentifier(_ value: String) -> String {
        "`\(value)`"
    }

    private static func isProbeIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 512
            && FrontendReceipt.Adapter.isSwiftIdentifier(value)
    }

    private static func candidateOrdering(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = [
            lhs.moduleName, lhs.ownerType, lhs.dispatch.rawValue, lhs.memberName,
            lhs.argumentLabels.joined(separator: ":"),
            lhs.parameterTypes.joined(separator: ","), lhs.preciseIdentifier,
            lhs.sourceFileLogicalID,
        ]
        let right = [
            rhs.moduleName, rhs.ownerType, rhs.dispatch.rawValue, rhs.memberName,
            rhs.argumentLabels.joined(separator: ":"),
            rhs.parameterTypes.joined(separator: ","), rhs.preciseIdentifier,
            rhs.sourceFileLogicalID,
        ]
        return left.lexicographicallyPrecedes(right)
    }
}
