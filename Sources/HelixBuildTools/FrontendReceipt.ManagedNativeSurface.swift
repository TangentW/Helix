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
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
        var mayThrow: Bool
    }

    private struct SymbolGraphCacheKey: Codable, Sendable {
        var schemaVersion: UInt16 = 1
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
        var importedModules: [String]
        var requiresMainActor: Bool
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
            importedModules = candidate.importedModules.sorted()
            requiresMainActor = candidate.requiresMainActor
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
        var transformPipelineHash: Core.Digest
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

    private struct DecodedProbePayload: Sendable {
        var types: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
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
        for index in importedTypes.indices.sorted(by: {
            importedTypes[$0].canonicalName < importedTypes[$1].canonicalName
        }) {
            guard let surface = resolution.ownerSurfacesByIndex[index] else {
                continue
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
        enrichedTypes = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: enrichedTypes,
            operationTypes: signatureTypes
        )
        return Expansion(
            importedTypes: enrichedTypes,
            operations: try FrontendReceipt.Adapter()
                .mergeImportedOperations(probedSurface.operations),
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
        var importedTypes = try FrontendReceipt.Adapter()
            .mergeImportedNativeTypes(
                discoveredTypes: [],
                operationTypes: typedSurfaces.map(\.1)
            )
        var candidates = typedSurfaces.flatMap { surface, importedType in
            makeCandidates(surface: surface, importedType: importedType)
        }
        candidates += globalCandidates(
            in: graph,
            minimumOS: minimumOS,
            sourceFileLogicalID: sourceFileLogicalID
        )
        candidates = Array(Set(candidates)).sorted(by: candidateOrdering)
        guard candidates.count <= 250_000 else {
            throw FrontendReceipt.Error.frontendFailed(
                "native API Catalog exceeds the 250000-operation bound"
            )
        }
        metrics.candidateCount = UInt64(candidates.count)
        let probedSurface = try probe(
            candidates,
            importedTypes: importedTypes,
            minimumOS: minimumOS,
            frontend: frontend,
            invocation: invocation,
            // The enclosing whole-Catalog cache already owns this exact
            // module identity. Per-candidate filesystem lookups would add one
            // lock and manifest read for every public API without enabling
            // reuse across a changed module identity.
            cache: nil,
            compilerFingerprint: nil,
            compilerInputHash: nil,
            metrics: &metrics
        )
        let signatureTypes = enrichSignatureTypes(
            probedSurface.types,
            ownerSurfacesByModule: [moduleName: surfaces]
        )
        importedTypes = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: importedTypes,
            operationTypes: signatureTypes
        )
        let operations = try FrontendReceipt.Adapter().mergeImportedOperations(
            probedSurface.operations.map { operation in
                var dormant = operation
                dormant.isEmittedToDevice = false
                return dormant
            }
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
                swiftPath: owner.pathComponents.joined(separator: "."),
                runtimeName: clangRuntimeName(precise),
                genericParameters: genericParameters,
                requiresMainActor: requiresMainActor(owner),
                members: (membersByOwner[precise] ?? []).sorted {
                    ($0.pathComponents.joined(separator: "\u{0}"),
                     $0.identifier.precise)
                        < ($1.pathComponents.joined(separator: "\u{0}"),
                           $1.identifier.precise)
                }
            )
        }
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
        case "swift.enum", "swift.struct":
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
        let isClangImported = surface.preciseIdentifier.hasPrefix("c:")
        let canonical = isClangImported ? surface.swiftPath : qualified
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
                  signature.parameterTypes.allSatisfy(
                      FrontendReceipt.SwiftTypeSpelling.isGeneratedType
                  )
            else { return nil }
            let actor = requiresMainActor(symbol)
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
                sourceFileLogicalID: sourceFileLogicalID,
                importedModules: [graph.module.name],
                requiresMainActor: actor,
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
            result.canonicalName = surface.swiftPath
            result.swiftType = surface.swiftPath
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
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedType.importedModules,
                requiresMainActor: surface.requiresMainActor,
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
        func candidate(
            dispatch: NativeImportDiscovery.Dispatch,
            memberName: String,
            labels: [String] = [],
            parameterTypes: [String] = [],
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
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedType.importedModules,
                requiresMainActor: requiresActor,
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
                memberName: memberName
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
                    parameterTypes: [isolatedType]
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
            mayThrow: symbol.declarationFragments.contains(where: {
                $0.kind == "keyword"
                    && ($0.spelling == "throws" || $0.spelling == "rethrows")
            })
        )
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
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count
                ? starts[offset + 1] : fragments.endIndex
            return fragments[start..<end].compactMap {
                $0.kind == "attribute"
                    ? normalizedAttribute($0.spelling) : nil
            }
        }
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
                let cachedOperations = validatedPayload.operations.map {
                    restoring($0, for: candidate)
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
            let candidateOperations = measured.operations.filter {
                $0.candidate == miss.candidate
            }.map {
                normalizingForCache($0.operation, candidate: miss.candidate)
            }
            let candidateTypes = Array(Set(measured.types.compactMap {
                $0.candidate == miss.candidate
                    ? ProbeNativeType($0.type) : nil
            })).sorted(by: probeTypeOrdering)
            let encoded = try Core.CanonicalJSON.encode(
                ProbeCachePayload(
                    candidate: ProbeCandidate(miss.candidate),
                    types: candidateTypes,
                    operations: candidateOperations
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
            operations += validatedPayload.operations.map {
                restoring($0, for: miss.candidate)
            }
        }
        return .init(types: types, operations: operations)
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
                transformPipelineHash: ShellBuild.transformPipelineHash,
                compilerFingerprint: compilerFingerprint,
                compilerInputHash: compilerInputHash,
                invocation: invocation,
                minimumOS: minimumOS,
                candidate: ProbeCandidate(candidate),
                importedTypeBoundaryHash: importedTypeBoundaryHash
            )
        )
    }

    private static func decodeProbePayload(
        _ data: Data,
        candidate: Candidate
    ) throws -> DecodedProbePayload {
        let payload = try JSONDecoder().decode(ProbeCachePayload.self, from: data)
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
            if !operation(value, matches: candidate) {
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
        if try Core.CanonicalJSON.encode(payload) != data {
            invalidFacts.append("canonical encoding")
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
        matches candidate: Candidate
    ) -> Bool {
        let expectedParameterCount = candidate.parameterTypes.count
            + (isInstanceDispatch(candidate.dispatch) ? 1 : 0)
        let declarationMatches: Bool
        if candidate.preciseIdentifier.hasSuffix(
            "#zero-argument-construction"
        ) {
            declarationMatches = operation.ownerType == candidate.ownerType
                && operation.dispatch == .initializer
                && operation.argumentLabels.isEmpty
        } else if operation.objectiveC != nil {
            // Inherited methods are invoked through the candidate receiver but
            // belong to the compiler-resolved declaring type. Their exact USR,
            // not receiver spelling equality, authenticates the cached fact.
            declarationMatches = operation.declarationUSR
                == candidate.preciseIdentifier
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
            && operation.requiresMainActor == candidate.requiresMainActor
            && operation.mayThrow == candidate.mayThrow
    }

    private static func restoring(
        _ operation: FrontendReceipt.Adapter.ImportedOperation,
        for candidate: Candidate
    ) -> FrontendReceipt.Adapter.ImportedOperation {
        var result = operation
        result.sourceFileLogicalID = candidate.sourceFileLogicalID
        result.importedModules = candidate.importedModules
        return result
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
                metrics.rejectedSingletonCount += 1
                return .init(
                    types: [],
                    operations: [],
                    cacheableCandidates: isDeterministicProbeRejection(
                        status: status,
                        diagnostics: diagnostics
                    ) ? Set(candidates) : []
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

    private static func measure(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation,
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

        let sourceURL = directory.appendingPathComponent("ManagedNativeSurface.swift")
        let source = renderSource(candidates)
        let contents = Data(source.utf8)
        metrics.generatedProbeSourceBytes += UInt64(contents.count)
        guard contents.count <= 8 * 1_024 * 1_024 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed native probe source exceeds 8 MiB"
            )
        }
        try contents.write(to: sourceURL, options: .atomic)
        let astOutput = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(astOutput)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL,
            invocationObserver: frontend.invocationObserver
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let canonicalSIL = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "HelixManagedNative/ManagedNativeSurface.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let resolver = FrontendReceipt.SILFunctionResolver(file: silFile)
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
            silFile: silFile
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
            // The compiler-resolved declaration owner is authoritative. A
            // probe may be invoked through a subclass or type alias while the
            // member is declared by a generic superclass; replacing that
            // owner with the probe receiver would manufacture a different
            // logical ABI for the same SIL symbol.
            measured.parameterSwiftTypes = operation.parameterSwiftTypes.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: swiftAliases
                )
            }
            measured.invocationParameterSwiftTypes = operation
                .invocationParameterSwiftTypes?.map {
                    FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                        in: $0,
                        aliases: swiftAliases
                    )
                }
            for index in candidate.parameterTypes.indices
            where measured.parameterSwiftTypes.indices.contains(index) {
                let formal = FrontendReceipt.SwiftTypeSpelling
                    .replacingNominalAliases(
                        in: candidate.parameterTypes[index],
                        aliases: swiftAliases
                    )
                if let boundary = FrontendReceipt.FunctionTypeSpelling
                    .callbackBoundary(in: formal) {
                    measured.parameterSwiftTypes[index] = boundary.declaredSpelling
                    if measured.invocationParameterSwiftTypes != nil {
                        measured.invocationParameterSwiftTypes?[index] =
                            boundary.declaredSpelling
                    }
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
                    in: operation.resultSwiftType,
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
            "ambiguous use of",
            "cannot assign to property",
            "cannot call value of non-function type",
            "cannot convert return expression",
            "cannot convert value",
            "cannot infer contextual base",
            "cannot invoke initializer",
            "extra argument",
            "generic parameter ",
            "get-only property",
            "has no member",
            "inaccessible due to",
            "incorrect argument label",
            "instance member ",
            "is unavailable",
            "missing argument",
            "no exact matches in call",
            "requires that",
            "static member ",
            "type of expression is ambiguous",
        ]
        let errors = diagnostics.split(whereSeparator: \.isNewline).compactMap {
            line -> String? in
            let value = line.lowercased()
            guard let marker = value.range(of: "error:") else { return nil }
            return String(value[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !errors.isEmpty && errors.allSatisfy { error in
            stableSemanticFragments.contains { error.contains($0) }
        }
    }

    private static func renderSource(_ candidates: [Candidate]) -> String {
        let imports = Set(candidates.map(\.moduleName)).sorted().map { "import \($0)" }
        let declarations = candidates.enumerated().flatMap { index, candidate in
            [renderProbe(index: index, candidate: candidate)]
                + propertySelectorProbe(index: index, candidate: candidate)
        }
        return (imports + [""] + declarations + [""]).joined(separator: "\n")
    }

    private static func renderProbe(index: Int, candidate: Candidate) -> String {
        let isolation = candidate.requiresMainActor ? "@MainActor " : ""
        let throwing = candidate.mayThrow ? " throws" : ""
        let tryPrefix = candidate.mayThrow ? "try " : ""
        let owner = escapedNominalType(candidate.probeOwnerType)
        let member = escapedIdentifier(candidate.memberName)
        var parameters: [String] = []
        if isInstanceDispatch(candidate.dispatch) {
            parameters.append("_ receiver: \(owner)")
        }
        parameters += candidate.parameterTypes.enumerated().map {
            "_ argument\($0.offset): \($0.element)"
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
        return "\(isolation)private func helixManagedNativeProbe\(index)("
            + "\(parameters.joined(separator: ", ")))\(throwing) {"
            + "\(mutableReceiver)\n    _ = \(tryPrefix)\(call)\n}"
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

    /// Keeps a candidate cache entry independent of the probe batch that
    /// happened to contain it. Only native types named by that candidate's
    /// callable signature are persisted with the operation.
    private static func signatureTypes(
        index: FrontendReceipt.ImportedTypeIndex,
        operation: FrontendReceipt.Adapter.ImportedOperation,
        candidate: Candidate
    ) -> [FrontendReceipt.Adapter.ImportedNativeType] {
        let spellings = [
            operation.ownerType,
            operation.resultSwiftType,
            candidate.ownerType,
            candidate.probeOwnerType,
        ] + operation.parameterSwiftTypes
            + (operation.invocationParameterSwiftTypes ?? [])
            + (operation.physicalParameterSwiftTypes ?? [])
            + candidate.parameterTypes
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
            ) {
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
        let swift = values.filter { $0.domain == "Swift" }
        guard !swift.contains(where: {
            $0.isUnconditionallyUnavailable == true
                || $0.isUnconditionallyDeprecated == true
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
