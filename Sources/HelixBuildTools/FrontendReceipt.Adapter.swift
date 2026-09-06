import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface

extension FrontendReceipt {
public struct Adapter: Sendable {
    public init() {}

    public func generate(_ request: FrontendReceipt.Request) throws -> FrontendReceipt.Output {
        try generate(
            request,
            cache: nil,
            toolchain: nil,
            compilerInputHash: nil,
            expectedImports: nil,
            expectedSources: nil
        )
    }

    func generate(
        _ request: FrontendReceipt.Request,
        cache: BuildCache.Store?,
        toolchain suppliedToolchain: ReleaseCompiler.ToolchainIdentity?,
        compilerInputHash: Core.Digest?,
        expectedImports: FrontendReceipt.SourceImports.Result? = nil,
        expectedSources: [ShellBuildReceipt.Source]? = nil,
        checkpoints: FrontendReceipt.CompilerCheckpoints.Context? = nil,
        diagnostics: FrontendReceipt.DiagnosticSession? = nil
    ) throws -> FrontendReceipt.Output {
        let session = diagnostics ?? FrontendReceipt.DiagnosticSession(collectFailures: false)
        let performance = session.performance
        let analysis = try analyze(request, toolchain: suppliedToolchain, expectedImports: expectedImports,
                                   expectedSources: expectedSources, checkpoints: checkpoints, session: session)
        let sourceStates = analysis.sourceStates
        let toolchain = analysis.toolchain
        let frontend = SwiftFrontend.Driver(compilerURL: request.compilerURL, invocationObserver: performance.subprocessObserver)
        let documents = analysis.documents
        let importedModules = analysis.importedModules
        let demangled = analysis.demangled
        let silFile = analysis.silFile
        let operationSILFile = analysis.operationSILFile
        let moduleName = request.metadata.frontendInvocation.moduleName
        let effectiveConfiguration = analysis.effectiveConfiguration
        let sourceByPhysicalPath = Dictionary(uniqueKeysWithValues: sourceStates.map { ($0.url.path, $0) })
        let sourceNominals = analysis.sourceNominals
        let sourceNominalsByName = SourceNominalIndex(sourceNominals)
        let sourceNominalAliasIndex = SourceNominalAliasIndex(sourceNominals: sourceNominals, moduleName: moduleName)
        let discoveredImportedTypes = analysis.discoveredImportedTypes
        var importedOperationSurface = analysis.importedOperationSurface
        let sourceObservedImportedTypeNames = Set((discoveredImportedTypes + importedOperationSurface.types)
            .flatMap { [$0.canonicalName, $0.swiftType] + $0.aliases })
        var requiredImportedOperationSourceIDs = Set<String>()
        let catalogSurface = analysis.catalogSurface
        performance.setCounter("native_api_catalog.hit_module_count", value: UInt64(catalogSurface.hitModules.count))
        performance.setCounter("native_api_catalog.miss_module_count", value: UInt64(catalogSurface.missingModules.count))
        performance.setCounter("native_api_catalog.entry_count", value: UInt64(catalogSurface.documents.reduce(0) { $0 + $1.entries.count }))
        var importedTypes = analysis.importedTypes
        try performance.measure("frontend.bind_native_api_catalogs") {
            if request.callingSurfacePolicy.expandsImportedModules {
                // Consumer ASTs may spell one imported nominal through a
                // Clang alias while the declaring-module Catalog uses its
                // Swift overlay name (for example NSURLResourceKey versus
                // URLResourceKey). Normalize the source observation before
                // matching declaration projections; Catalog operations
                // themselves remain untouched.
                let catalogComparisonAliases = try makeImportedSwiftTypeAliases(
                    importedTypes
                )
                importedOperationSurface.operations = importedOperationSurface
                    .operations.map {
                        applyingSwiftTypeAliases(
                            $0,
                            aliases: catalogComparisonAliases
                        )
                    }
                importedOperationSurface.operations = try
                    applyingObjectiveCInitializerTypeModules(
                        to: importedOperationSurface.operations,
                        importedTypes: importedTypes
                    )
                importedOperationSurface.operations =
                    applyingObjectiveCDeclarationModules(
                        to: importedOperationSurface.operations,
                        modulesByUSR: catalogSurface.modulesByDeclarationUSR
                    )
                importedOperationSurface.operations =
                    applyingCDeclarationModules(
                        to: importedOperationSurface.operations,
                        modulesByUSR: catalogSurface.modulesByDeclarationUSR
                    )
                let relevantCatalogOperations = FrontendReceipt.CatalogSurface
                    .operationsRelevantToSource(
                        catalogSurface.operations,
                        source: importedOperationSurface.operations
                    )
                performance.setCounter(
                    "native_api_catalog.relevant_operation_count",
                    value: UInt64(relevantCatalogOperations.count)
                )
                let catalogOperations = relevantCatalogOperations.map {
                    operation -> FrontendReceipt.Adapter.ImportedOperation in
                    var operation = operation
                    operation.isEmittedToDevice = request.callingSurfacePolicy
                        == .managedProductionModule
                    return operation
                }
                requiredImportedOperationSourceIDs.formUnion(
                    catalogOperations.map(\.sourceFileLogicalID)
                )
                importedOperationSurface.operations = try
                    applyingMeasuredObjectiveCEvidence(
                        to: importedOperationSurface.operations,
                        measured: catalogOperations
                    )
                importedOperationSurface.operations = try
                    mergingAuthoritativeImportedOperations(
                        source: importedOperationSurface.operations,
                        authoritative: catalogOperations,
                        comparisonAliases: catalogComparisonAliases
                    )
            } else {
                let unresolvedObjectiveCEvidence = importedOperationSurface
                    .operations.compactMap(\.objectiveC)
                    .filter { $0.moduleName == nil }
                let unresolvedRuntimeNames = Set(
                    unresolvedObjectiveCEvidence.map(\.runtimeClassName)
                )
                let unresolvedCOperations = importedOperationSurface.operations
                    .filter { $0.c != nil && $0.c?.moduleName == nil }
                let unresolvedDeclarationUSRs = Set(
                    unresolvedObjectiveCEvidence.map(\.declarationUSR)
                        + unresolvedCOperations.compactMap {
                            $0.c?.declarationUSR
                        }
                )
                let candidateModules = Set(
                    unresolvedCOperations.flatMap(\.importedModules)
                )
                if !unresolvedRuntimeNames.isEmpty
                    || !unresolvedDeclarationUSRs.isEmpty {
                    let resolution = try performance.measure(
                        "frontend.resolve_native_declaration_modules"
                    ) {
                        try FrontendReceipt.ManagedNativeSurface
                            .resolveDeclarationModules(
                                importedTypes: importedTypes,
                                runtimeNames: unresolvedRuntimeNames,
                                declarationUSRs: unresolvedDeclarationUSRs,
                                candidateModules: candidateModules,
                                minimumOS: request.metadata.minimumOS,
                                frontend: frontend,
                                invocation:
                                    request.metadata.frontendInvocation,
                                cache: cache,
                                compilerFingerprint: toolchain.fingerprint,
                                compilerInputHash: compilerInputHash
                            )
                    }
                    performance.setCounter(
                        "native_declaration_module.module_count",
                        value: resolution.metrics.moduleCount
                    )
                    performance.setCounter(
                        "native_declaration_module.symbol_graph_cache_hit_count",
                        value: resolution.metrics.symbolGraphCacheHitCount
                    )
                    performance.setCounter(
                        "native_declaration_module.symbol_graph_cache_miss_count",
                        value: resolution.metrics.symbolGraphCacheMissCount
                    )
                    importedTypes = resolution.importedTypes
                    importedOperationSurface.operations = try
                        applyingObjectiveCInitializerTypeModules(
                            to: importedOperationSurface.operations,
                            importedTypes: importedTypes
                        )
                    importedOperationSurface.operations =
                        applyingObjectiveCDeclarationModules(
                            to: importedOperationSurface.operations,
                            modulesByUSR:
                                resolution.modulesByDeclarationUSR
                        )
                    importedOperationSurface.operations =
                        applyingCDeclarationModules(
                            to: importedOperationSurface.operations,
                            modulesByUSR: resolution.modulesByDeclarationUSR
                        )
                }
            }
        }
        // Catalog property evidence is compiler-authored and already exact.
        // Only declarations missing that evidence need a narrow fallback
        // probe, keeping repeated project builds off the Swift frontend.
        performance.setCounter(
            "objective_c_selector.fallback_count",
            value: UInt64(
                FrontendReceipt.ObjectiveCSelectorResolver
                    .unresolvedCandidateCount(
                        in: importedOperationSurface.operations
                    )
            )
        )
        importedOperationSurface.operations = try performance.measure(
            "frontend.resolve_objective_c_selectors"
        ) {
            try FrontendReceipt.ObjectiveCSelectorResolver.resolve(
                operations: importedOperationSurface.operations,
                frontend: frontend,
                invocation: request.metadata.frontendInvocation
            )
        }
        let objectiveCStructures = try performance.measure(
            "frontend.resolve_native_structures"
        ) {
            try objectiveCStructureTypes(
                in: catalogSurface.operations
                    + importedOperationSurface.operations,
                targetTriple: request.metadata.frontendInvocation.targetTriple
            )
        }
        let provisionalNativeTypes = try performance.measure(
            "frontend.make_provisional_native_types"
        ) {
            try makeNativeTypes(
                request.nativeImportCatalog,
                sourceNominals: sourceNominals,
                importedTypes: importedTypes,
                mainActorReferenceTypes: [],
                metadata: request.metadata,
                objectiveCStructures: objectiveCStructures
            )
        }
        let nativeTypeIDs = try performance.measure(
            "frontend.make_native_type_lookup"
        ) {
            try makeNativeTypeLookup(
                records: provisionalNativeTypes,
                importedTypes: importedTypes,
                sourceNominals: sourceNominals
            )
        }
        let resolvedNativeTypeIDs = Set(nativeTypeIDs.values)
        let declarationTypeEnvironment = try performance.measure(
            "frontend.make_type_environment"
        ) {
            try silFile.typeEnvironment.includingNativeTypes(
                nativeTypeIDs,
                kinds: Dictionary(uniqueKeysWithValues:
                    provisionalNativeTypes.compactMap {
                        resolvedNativeTypeIDs.contains($0.id)
                            ? ($0.id, $0.kind) : nil
                    }
                ),
                requiresMainActor: Set(provisionalNativeTypes.compactMap {
                    $0.requiresMainActor
                            && resolvedNativeTypeIDs.contains($0.id)
                        ? $0.id : nil
                })
            )
        }
        let localValueTypes = makeLocalValueTypeLookup(sourceNominals)
        var importedSwiftTypeAliases = try performance.measure(
            "frontend.make_imported_type_aliases"
        ) {
            try makeImportedSwiftTypeAliases(importedTypes)
        }
        let modulePrefix = moduleName + "."
        for (qualified, relative) in sourceNominalAliasIndex.exact
        where qualified.hasPrefix(modulePrefix) {
            importedSwiftTypeAliases[qualified] = relative
        }
        importedOperationSurface.operations = try performance.measure(
            "frontend.normalize_imported_operations"
        ) {
            try mergeImportedOperations(
                importedOperationSurface.operations.map {
                    applyingSwiftTypeAliases(
                        $0,
                        aliases: importedSwiftTypeAliases
                    )
                }
            )
        }
        let catalogCapabilities = try performance.measure(
            "frontend.materialize_native_api_catalogs"
        ) {
            try FrontendReceipt.CatalogSurface.materializeCapabilities(
                catalogSurface,
                nativeTypes: nativeTypeIDs,
                emittedSymbols: Set(
                    importedOperationSurface.operations
                        .filter(\.isEmittedToDevice)
                        .flatMap(\.silReferences)
                ),
                emitCompleteSurface: request.callingSurfacePolicy
                    == .managedProductionModule
            )
        }
        let retainedRequiredOperationSourceIDs = Set(
            importedOperationSurface.operations.map(\.sourceFileLogicalID)
        ).intersection(requiredImportedOperationSourceIDs)
        guard retainedRequiredOperationSourceIDs
                == requiredImportedOperationSourceIDs
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "Native API Catalog operations lost their authoritative source identity before publication; missing: "
                    + requiredImportedOperationSourceIDs.subtracting(
                        retainedRequiredOperationSourceIDs
                    ).sorted().joined(separator: ", ")
            )
        }
        let importedOperationDeclarations = try performance.measure(
            "frontend.make_imported_operation_declarations"
        ) {
            try makeImportedOperationDeclarations(
                importedOperationSurface.operations,
                moduleName: moduleName,
                nativeTypes: nativeTypeIDs,
                sourceTypeNames: Set(sourceNominals.map(\.canonicalName)),
                requiredSourceFileLogicalIDs:
                    requiredImportedOperationSourceIDs
            )
        }
        // Build location and symbol indexes once for this immutable SIL module.
        // Recreating them for every declaration makes large modules quadratic.
        let silResolver = performance.measure("frontend.index_sil_functions") {
            FrontendReceipt.SILFunctionResolver(file: silFile)
        }
        var drafts: [Draft] = []
        try performance.measure("frontend.index_source_declarations") {
        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourceByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "source document does not map to the requested source set"
                )
            }
            let items = try FrontendReceipt.TypedAST.items(in: document)
            let imports = imports(in: items)
            let locationMap = SourceTransform.LocationMap(source.contents)
            try walk(
                items: items,
                context: nil,
                source: source,
                locationMap: locationMap,
                imports: imports,
                moduleName: moduleName,
                configuration: effectiveConfiguration,
                demangled: demangled,
                silResolver: silResolver,
                typeEnvironment: declarationTypeEnvironment,
                nativeTypes: nativeTypeIDs,
                localValueTypes: localValueTypes,
                importedSwiftTypeAliases: importedSwiftTypeAliases,
                sourceNominals: sourceNominalsByName,
                sourceNominalAliasIndex: sourceNominalAliasIndex,
                drafts: &drafts
            )
        }
        }
        guard Set(drafts.map { $0.candidate.mangledName }).count == drafts.count else {
            throw FrontendReceipt.Error.malformedAST(
                "typed AST contains duplicate function symbols"
            )
        }
        try performance.measure("frontend.fingerprint_declarations") {
            let archivedSymbols = Set(drafts.map {
                $0.candidate.mangledName
            })
            for index in drafts.indices {
                let symbol = drafts[index].candidate.mangledName
                guard let function = silFile.function(mangledName: symbol)
                else {
                    throw FrontendReceipt.Error.missingSILFunction(symbol)
                }
                drafts[index].candidate.implementationFingerprint =
                    ReleaseCompiler.ImplementationFingerprint.compute(
                        root: function,
                        in: silFile,
                        archivedSymbols: archivedSymbols
                    )
            }
        }
        try performance.measure("frontend.validate_native_anchors") {
            try validateNativeAnchors(drafts, sources: sourceStates)
        }
        let mainActorReferenceTypes = Set(drafts.compactMap { draft in
            draft.candidate.effects.requiresMainActor ? draft.referenceReceiverType : nil
        })
        var nativeTypeRecords = try performance.measure(
            "frontend.make_native_types"
        ) {
            try makeNativeTypes(
                request.nativeImportCatalog,
                sourceNominals: sourceNominals,
                importedTypes: importedTypes,
                mainActorReferenceTypes: mainActorReferenceTypes,
                metadata: request.metadata,
                objectiveCStructures: objectiveCStructures
            )
        }
        guard nativeTypeRecords.map(\.id) == provisionalNativeTypes.map(\.id) else {
            throw FrontendReceipt.Error.invalidRequest(
                "native type identity changed while resolving actor isolation"
            )
        }

        let builtinNativeImports = try NativeImportCatalog.Builtins.records()
        applyNativeImportEffectEnvelope(
            builtinNativeImports,
            to: &drafts,
            configuration: effectiveConfiguration,
            moduleName: moduleName
        )
        let frozenValueTypes = try performance.measure(
            "frontend.make_frozen_value_types"
        ) {
            try makeFrozenValueTypes(
                referencedBy: drafts.map(\.candidate),
                sourceNominals: sourceNominals,
                typeEnvironment: declarationTypeEnvironment
            )
        }
        var explicitNativeImports = try NativeImportCatalog.Builtins.merging(
            makeNativeImportCandidates(
                request.nativeImportCatalog,
                metadata: request.metadata,
                configuration: effectiveConfiguration,
                nativeTypes: nativeTypeIDs
            )
        )
        let sourceRecords = sourceStates.map {
            InterfaceArchive.SourceRecord(
                logicalPath: $0.logicalPath,
                contentHash: $0.contentHash
            )
        }
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: toolchain.fingerprint
        )
        let preliminary = try performance.measure("frontend.preliminary_index") {
            try ReleaseCompiler.Indexer().index(
                .init(
                    metadata: request.metadata,
                    compatibility: compatibility,
                    configuration: effectiveConfiguration,
                    sources: sourceRecords,
                    declarations: drafts.map(\.candidate),
                    nativeImportCandidates: explicitNativeImports,
                    nativeTypes: nativeTypeRecords,
                    frozenValueTypes: frozenValueTypes
                )
            )
        }
        let entrySymbols = Set(preliminary.archive.functions.compactMap { function in
            function.patchability.isEligible ? function.mangledName : nil
        })
        explicitNativeImports = exactFallbackImports(
            explicitNativeImports,
            excludingEntrySymbols: entrySymbols
        )
        var discovery = try performance.measure("frontend.discover_native_imports") {
            try NativeImportDiscovery.Engine().discover(
                declarations: drafts.compactMap { draft in
                    entrySymbols.contains(draft.candidate.mangledName)
                        ? nil : draft.nativeImportDeclaration
                } + importedOperationDeclarations,
                metadata: request.metadata,
                configuration: effectiveConfiguration,
                nativeTypeKinds: Dictionary(uniqueKeysWithValues:
                    nativeTypeRecords.map { ($0.id, $0.kind) }
                )
            )
        }
        // Selection is anchored to SIL symbols so an explicit Catalog entry may
        // safely rename a source-discovered operation while overriding its factory.
        let scopedNativeImportSymbols = Set(
            discovery.candidates.flatMap(\.record.silMangledNames)
        )
        let discoveredNativeImportCandidates = try mergeNativeImportCandidates(
            explicit: explicitNativeImports,
            discovered: &discovery,
            moduleName: request.metadata.frontendInvocation.moduleName
        )
        let nativeImportCandidates = try mergeNativeAPICatalogCandidates(
            discoveredNativeImportCandidates,
            catalog: catalogCapabilities.map(\.record),
            moduleName: request.metadata.frontendInvocation.moduleName
        )
        let scopedNativeImportRecords = nativeImportCandidates.filter {
            !scopedNativeImportSymbols.isDisjoint(with: $0.silMangledNames)
        }
        let scopedNativeImportCallees = scopedNativeImportRecords.map(\.canonicalCallee)
        applyNativeImportEffectEnvelope(
            scopedNativeImportRecords,
            to: &drafts,
            configuration: effectiveConfiguration,
            moduleName: request.metadata.frontendInvocation.moduleName
        )
        let resolvedConfiguration = configuration(
            effectiveConfiguration,
            allowing: nativeImportPublicationCallees(
                candidates: nativeImportCandidates,
                sourceScopedCallees: scopedNativeImportCallees,
                policy: request.callingSurfacePolicy
            ),
            moduleName: request.metadata.frontendInvocation.moduleName
        )
        if request.callingSurfacePolicy == .managedDevelopmentModule {
            let publishedTypeIDs = developmentNativeTypePublicationIDs(
                nativeTypeLookup: nativeTypeIDs,
                sourceObservedTypeNames: sourceObservedImportedTypeNames,
                sourceReferenceTypeNames: Set(
                    sourceNominals.compactMap {
                        $0.kind == .reference ? $0.canonicalName : nil
                    }
                ),
                functions: preliminary.archive.functions,
                nativeImports: nativeImportCandidates
            )
            for index in nativeTypeRecords.indices {
                nativeTypeRecords[index].isEmittedToDevice =
                    publishedTypeIDs.contains(nativeTypeRecords[index].id)
            }
        }

        let indexed = try performance.measure("frontend.final_index") {
            try ReleaseCompiler.Indexer().index(
                .init(
                    metadata: request.metadata,
                    compatibility: compatibility,
                    configuration: resolvedConfiguration,
                    sources: sourceRecords,
                    declarations: drafts.map(\.candidate),
                    nativeImportCandidates: nativeImportCandidates,
                    nativeTypes: nativeTypeRecords,
                    frozenValueTypes: frozenValueTypes
                )
            )
        }
        let finalEntrySymbols = Set(indexed.archive.functions.compactMap { function in
            function.patchability.isEligible ? function.mangledName : nil
        })
        guard finalEntrySymbols == entrySymbols else {
            throw FrontendReceipt.Error.invalidRequest(
                "Entry eligibility changed while resolving the managed NativeImport surface"
            )
        }
        let nativeImportBindings = try performance.measure(
            "frontend.make_native_import_bindings"
        ) {
            try mergeNativeImportBindings(
                makeNativeImportBindings(
                    catalog: request.nativeImportCatalog,
                    archive: indexed.archive
                ) + makeDiscoveredNativeImportBindings(
                    discovery.candidates,
                    archive: indexed.archive
                ) + NativeImportCatalog.Builtins.bindings(
                    archive: indexed.archive
                ),
                catalog: catalogCapabilities.map(\.binding),
                moduleName: request.metadata.frontendInvocation.moduleName
            )
        }
        let resolvedObjectiveCStructureABIs = try performance.measure(
            "frontend.resolve_native_structure_abis"
        ) {
            try objectiveCStructureABIs(in: indexed.archive)
        }
        let nativeTypeBindings = try performance.measure(
            "frontend.make_native_type_bindings"
        ) {
            try makeNativeTypeBindings(
                catalog: request.nativeImportCatalog,
                archive: indexed.archive,
                sourceNominals: sourceNominals,
                importedTypes: importedTypes,
                objectiveCStructures: resolvedObjectiveCStructureABIs
            )
        }
        let eligibleNames = finalEntrySymbols
        var roots: [ShellBuildReceipt.Root] = []
        for draft in drafts {
            guard var root = draft.root else { continue }
            if root.sourceBodyTransform != nil,
               !eligibleNames.contains(draft.candidate.mangledName) {
                // Source-body installations have no independently safe Native
                // replacement descriptor. Keep their rejection diagnostic,
                // but do not persist a transform that can never dispatch.
                continue
            }
            if eligibleNames.contains(draft.candidate.mangledName) {
                guard let bridge = draft.bridge else {
                    throw FrontendReceipt.Error.unsupportedDeclaration(
                        "\(draft.candidate.canonicalDeclaration) passed HLBC eligibility "
                            + "without a representable generated Bridge"
                    )
                }
                root.bridge = bridge
            }
            roots.append(root)
        }
        guard eligibleNames == Set(roots.compactMap {
            $0.bridge == nil ? nil : $0.declarationMangledName
        }) else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "typed frontend and Bridge capability sets disagree"
            )
        }
        let receipt = ShellBuildReceipt.Document(
            metadata: indexed.archive.metadata,
            compatibility: compatibility,
            configuration: resolvedConfiguration,
            capabilities: Set(indexed.archive.capabilities),
            sources: sourceStates.map {
                .init(logicalPath: $0.logicalPath, contentHash: $0.contentHash)
            },
            declarations: drafts.map(\.candidate),
            roots: roots,
            nativeImportCandidates: indexed.archive.nativeImports,
            nativeImportBindings: nativeImportBindings,
            nativeTypes: indexed.archive.nativeTypes,
            frozenValueTypes: indexed.archive.frozenValueTypes,
            nativeTypeBindings: nativeTypeBindings
        )
        try performance.measure("frontend.validate_receipt") {
            try receipt.validate()
        }
        try performance.measure("frontend.validate_catalog_publication") {
            try FrontendReceipt.CatalogSurface.validatePublishedEntries(
                catalogSurface.documents,
                receipt: receipt,
                policy: request.callingSurfacePolicy,
                diagnostics: discovery.diagnostics,
                discoveredCandidates: discovery.candidates
            )
        }
        performance.setCounter(
            "frontend.declaration_count",
            value: UInt64(receipt.declarations.count)
        )
        performance.setCounter(
            "frontend.root_count",
            value: UInt64(receipt.roots.count)
        )
        performance.setCounter(
            "frontend.native_import_count",
            value: UInt64(receipt.nativeImportCandidates.count)
        )
        performance.setCounter(
            "frontend.native_type_count",
            value: UInt64(receipt.nativeTypes.count)
        )
        return .init(
            receipt: receipt,
            diagnostics: (indexed.diagnostics + discovery.diagnostics).sorted {
                ($0.location?.file ?? "", $0.location?.line ?? 0, $0.code, $0.message)
                    < ($1.location?.file ?? "", $1.location?.line ?? 0, $1.code, $1.message)
            },
            toolchain: toolchain,
            importedModules: importedModules,
            performance: performance.trace()
        )
    }

    func validate(_ request: FrontendReceipt.Request) throws {
        var failures: [String] = []
        func check(_ label: String, _ operation: () throws -> Void) {
            do { try operation() } catch { failures.append("\(label): \(error)") }
        }
        check("configuration") { try request.configuration.validate() }
        if request.sources.isEmpty { failures.append("source set is empty") }
        let logical = Dictionary(grouping: request.sources, by: \.logicalPath)
        for path in logical.keys.sorted() where logical[path]!.count > 1 {
            failures.append("duplicate logical source \(String(reflecting: path)): \(logical[path]!.map { $0.url.path }.sorted())")
        }
        let physical = Dictionary(grouping: request.sources) {
            $0.url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        for path in physical.keys.sorted() where physical[path]!.count > 1 {
            failures.append("duplicate physical source \(String(reflecting: path)): \(physical[path]!.map(\.logicalPath).sorted())")
        }
        if !request.metadata.machOUUIDs.isEmpty {
            failures.append("pre-link metadata must have no Mach-O UUIDs; observed \(request.metadata.machOUUIDs)")
        }
        if request.metadata.transformPipelineHash != ShellBuild.transformPipelineHash {
            failures.append("transform identity mismatch: expected \(ShellBuild.transformPipelineHash.hex), observed \(request.metadata.transformPipelineHash.hex)")
        }
        let module = request.metadata.frontendInvocation.moduleName
        if request.configuration.modules[module] == nil {
            failures.append("module \(String(reflecting: module)) is absent from configuration modules \(request.configuration.modules.keys.sorted())")
        }
        check("frontend invocation") { try request.metadata.frontendInvocation.validate() }
        check("native import catalog") { try request.nativeImportCatalog.validate() }
        let catalogOrder = request.nativeAPICatalogs.map {
            $0.document.identity.moduleName + "\u{0}" + $0.document.identity.cacheKey.hex
        }
        if request.nativeAPICatalogs.count > 256 || catalogOrder != catalogOrder.sorted()
            || Set(request.nativeAPICatalogs.map { $0.document.identity.moduleName }).count != catalogOrder.count {
            failures.append("Native API Catalog snapshots are duplicated, noncanonical, or exceed 256: \(catalogOrder)")
        }
        if !request.callingSurfacePolicy.expandsImportedModules && !request.nativeAPICatalogs.isEmpty {
            failures.append("Native API Catalog snapshots are incompatible with calling-surface policy \(request.callingSurfacePolicy.rawValue)")
        }
        for snapshot in request.nativeAPICatalogs {
            check("Native API Catalog \(snapshot.document.identity.moduleName)") { try snapshot.validateIfNeeded() }
        }
        for source in request.sources {
            let components = source.logicalPath.split(separator: "/", omittingEmptySubsequences: false)
            if source.logicalPath.isEmpty || source.logicalPath.hasPrefix("/") || components.contains("")
                || components.contains("..") || source.url.pathExtension != "swift"
                || source.url.path.contains("\n") || source.url.path.contains("\r") {
                failures.append("unsafe logical Swift source path \(String(reflecting: source.logicalPath)), physical=\(String(reflecting: source.url.path))")
            }
        }
        guard failures.isEmpty else { throw FrontendReceipt.Error.invalidRequest(failures.joined(separator: "\n")) }
    }

    func validateCompilerVersion(
        _ documents: [FrontendReceipt.TypedAST.Object],
        toolchain: ReleaseCompiler.ToolchainIdentity
    ) throws {
        let versions = Set(documents.compactMap {
            ($0["compiler_version"] as? [String: Any])?["full"] as? String
        })
        guard versions.count == 1, let version = versions.first,
              !version.isEmpty, toolchain.versionOutput.hasPrefix(version)
        else {
            throw FrontendReceipt.Error.malformedAST(
                "typed AST compiler version differs from the fingerprinted compiler"
            )
        }
    }
}
}

extension FrontendReceipt.Adapter {
    struct SourceState {
        var logicalPath: String
        var url: URL
        var contents: Data
        var contentHash: Core.Digest
        private var lineStartUTF8Offsets: [Int]

        init(
            logicalPath: String,
            url: URL,
            contents: Data,
            contentHash: Core.Digest
        ) {
            self.logicalPath = logicalPath
            self.url = url
            self.contents = contents
            self.contentHash = contentHash
            var starts = [0]
            starts.reserveCapacity(contents.count / 32 + 1)
            for (offset, byte) in contents.enumerated()
            where byte == UInt8(ascii: "\n") && offset + 1 <= contents.count {
                starts.append(offset + 1)
            }
            lineStartUTF8Offsets = starts
        }

        func sourceLocation(atUTF8Offset offset: Int) -> Core.SourceLocation? {
            guard offset >= 0, offset <= contents.count else { return nil }
            var lower = lineStartUTF8Offsets.startIndex
            var upper = lineStartUTF8Offsets.endIndex
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if lineStartUTF8Offsets[middle] <= offset {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            let lineIndex = max(0, lower - 1)
            return .init(
                file: url.path,
                line: lineIndex + 1,
                column: offset - lineStartUTF8Offsets[lineIndex] + 1
            )
        }
    }

    enum SourceNominalKind: Equatable, Sendable {
        case reference
        case structure
        case enumeration
        case actor
        case alias

        var isValue: Bool {
            self == .structure || self == .enumeration
        }
    }

    struct SourceNominal: Sendable, Equatable {
        var declarationIdentity: String
        var declarationOffset: Int?
        var canonicalName: String
        var sourceFileLogicalID: String
        var kind: SourceNominalKind
        var isFileScoped: Bool
        var hasAmbiguousName: Bool = false
        /// A private nominal member cannot be named by generated file-scope
        /// declarations, even in its defining file. Codecs need this exact
        /// frontend access fact before promising a source reconstruction path.
        var isFileScopeNameable: Bool
        /// Generated codecs are unconditional. Availability-attributed source
        /// values remain closed until the codec contract models those guards.
        var isAvailabilityConstrained: Bool

        var localTypeKey: Bytecode.LocalTypeKey {
            let separator = canonicalName.firstIndex(of: ".")
            return .init(
                rawValue: separator.map {
                    String(canonicalName[canonicalName.index(after: $0)...])
                } ?? canonicalName
            )
        }
    }

    struct NominalContext {
        var canonicalName: String
        var moduleQualifiedName: String
        var kind: SourceNominalKind?
        var referenceTypeID: Core.TypeID?
        var localValueTypeKey: Bytecode.LocalTypeKey?
        var isFileScopeNameable: Bool
        var isAvailabilityConstrained: Bool
        var isGenericContext: Bool
        var sourceFileLogicalID: String? = nil
    }

    struct SourceNominalAliasIndex: Sendable {
        struct Candidate: Sendable {
            var relativeName: String
            var components: [String]
        }

        var exact: [String: String]
        var byBaseName: [String: [Candidate]]

        init(sourceNominals: [SourceNominal], moduleName: String) {
            let modulePrefix = moduleName + "."
            var exact: [String: String] = [:]
            var candidates: [String: [Candidate]] = [:]
            for nominal in sourceNominals
            where nominal.isFileScopeNameable
                    && !nominal.hasAmbiguousName
                    && !nominal.isAvailabilityConstrained {
                let relative = nominal.canonicalName.hasPrefix(modulePrefix)
                    ? String(nominal.canonicalName.dropFirst(modulePrefix.count))
                    : nominal.canonicalName
                let components = relative.split(separator: ".").map(String.init)
                guard let baseName = components.last else { continue }
                exact[nominal.canonicalName] = relative
                exact[relative] = relative
                candidates[baseName, default: []].append(
                    .init(relativeName: relative, components: components)
                )
            }
            self.exact = exact
            byBaseName = candidates.mapValues {
                $0.sorted { $0.relativeName < $1.relativeName }
            }
        }

        func aliases(
            visibleFrom context: NominalContext?,
            in declaration: String
        ) -> [String: String] {
            let tokens = Self.nominalTokens(in: declaration)
            var result: [String: String] = [:]
            var requestedBaseNames = Set<String>()
            for token in tokens {
                var prefix = token
                while true {
                    if let replacement = exact[prefix] {
                        result[prefix] = replacement
                    }
                    guard let separator = prefix.lastIndex(of: ".") else {
                        requestedBaseNames.insert(prefix)
                        break
                    }
                    prefix = String(prefix[..<separator])
                }
            }

            let contextComponents = context?.canonicalName
                .split(separator: ".").map(String.init) ?? []
            for baseName in requestedBaseNames.sorted() {
                guard let candidates = byBaseName[baseName] else { continue }
                let ranked = candidates.compactMap {
                    candidate -> (Int, String)? in
                    if candidate.components == contextComponents {
                        return (0, candidate.relativeName)
                    }
                    let parent = Array(candidate.components.dropLast())
                    if parent == contextComponents {
                        return (1, candidate.relativeName)
                    }
                    for ancestorLength in stride(
                        from: contextComponents.count,
                        through: 0,
                        by: -1
                    ) where parent == Array(
                        contextComponents.prefix(ancestorLength)
                    ) {
                        return (
                            2 + contextComponents.count - ancestorLength,
                            candidate.relativeName
                        )
                    }
                    return nil
                }.sorted {
                    $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
                }
                guard let first = ranked.first,
                      ranked.dropFirst().first?.0 != first.0
                else { continue }
                result[baseName] = first.1
            }
            return result
        }

        private static func nominalTokens(in value: String) -> Set<String> {
            var result = Set<String>()
            var token = ""
            func finish() {
                guard !token.isEmpty else { return }
                result.insert(token)
                token.removeAll(keepingCapacity: true)
            }
            for character in value {
                if character == "." || character == "_"
                    || character.isLetter || character.isNumber {
                    token.append(character)
                } else {
                    finish()
                }
            }
            finish()
            return result
        }
    }

    struct Draft {
        var candidate: ReleaseCompiler.DeclarationCandidate
        var root: ShellBuildReceipt.Root?
        var bridge: ShellBuildReceipt.Bridge?
        /// A declaration may be a Shell root without also being a legal native
        /// import. Frozen value receivers are the important case: their ABI is
        /// represented by the Shell codec, not by a process-native Swift type.
        var nativeImportDeclaration: NativeImportDiscovery.Declaration?
        var referenceReceiverType: String?
    }

    func discoverSourceNominals(
        documents: [FrontendReceipt.TypedAST.Object],
        sourcesByPhysicalPath: [String: SourceState],
        moduleName: String,
        demangled: [String: String]
    ) throws -> [SourceNominal] {
        var byUSR: [String: SourceNominal] = [:]
        for document in documents {
            guard let filename = document["filename"] as? String else {
                throw FrontendReceipt.Error.malformedAST(
                    "nominal discovery document has no source filename"
                )
            }
            let resolvedFilename = URL(fileURLWithPath: filename)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard let source = sourcesByPhysicalPath[resolvedFilename] else {
                throw FrontendReceipt.Error.malformedAST(
                    "nominal discovery source does not map to the requested source set: "
                        + filename
                )
            }
            let items = try FrontendReceipt.TypedAST.items(in: document)
            try collectSourceNominals(
                items: items,
                parentCanonicalName: nil,
                isInsideGenericContext: false,
                isInsidePrivateMemberScope: false,
                isInsideFileScope: false,
                isInsideAvailabilityConstrainedScope: false,
                source: source,
                moduleName: moduleName,
                demangled: demangled,
                byUSR: &byUSR
            )
        }
        return try Self.resolveSourceNominalNames(Array(byUSR.values))
    }

    func collectSourceNominals(
        items: [Any],
        parentCanonicalName: String?,
        isInsideGenericContext: Bool,
        isInsidePrivateMemberScope: Bool,
        isInsideFileScope: Bool,
        isInsideAvailabilityConstrainedScope: Bool,
        source: SourceState,
        moduleName: String,
        demangled: [String: String],
        byUSR: inout [String: SourceNominal]
    ) throws {
        for value in items {
            guard let item = value as? [String: Any],
                  let kind = item["_kind"] as? String
            else { continue }
            switch kind {
            case "class_decl", "struct_decl", "enum_decl", "actor_decl":
                guard let name = baseName(in: item),
                      let members = item["members"] as? [Any]
                else { continue }
                let relativeName = [parentCanonicalName, name]
                    .compactMap { $0 }.joined(separator: ".")
                let canonicalName = "\(moduleName).\(relativeName)"
                let isActor = kind == "actor_decl"
                    || (item["actor"] as? NSNumber)?.boolValue == true
                let nominalKind: SourceNominalKind = if isActor {
                    .actor
                } else if kind == "class_decl" {
                    .reference
                } else if kind == "struct_decl" {
                    .structure
                } else {
                    .enumeration
                }
                // A declaration inside a generic context has no single concrete
                // Swift runtime type that can back a frozen TypeID.
                let entersGenericContext = isInsideGenericContext
                    || Self.hasGenericSignature(item)
                let entersPrivateMemberScope = isInsidePrivateMemberScope
                    || (parentCanonicalName != nil
                        && (item["access"] as? String) == "private")
                let entersFileScope = isInsideFileScope
                    || ["private", "fileprivate"].contains(item["access"] as? String ?? "")
                let entersAvailabilityConstrainedScope =
                    isInsideAvailabilityConstrainedScope
                    || Self.hasAvailabilityAttribute(item)
                if !entersGenericContext {
                    let nominal = SourceNominal(
                        declarationIdentity: item["usr"] as? String ?? "",
                        declarationOffset: sourceRange(in: item)?.start,
                        canonicalName: canonicalName,
                        sourceFileLogicalID: source.logicalPath,
                        kind: nominalKind,
                        isFileScoped: entersFileScope,
                        isFileScopeNameable: !entersPrivateMemberScope,
                        isAvailabilityConstrained:
                            entersAvailabilityConstrainedScope
                    )
                    try Self.insertSourceNominal(nominal, into: &byUSR)
                }
                try collectSourceNominals(
                    items: members,
                    parentCanonicalName: relativeName,
                    isInsideGenericContext: entersGenericContext,
                    isInsidePrivateMemberScope: entersPrivateMemberScope,
                    isInsideFileScope: entersFileScope,
                    isInsideAvailabilityConstrainedScope:
                        entersAvailabilityConstrainedScope,
                    source: source,
                    moduleName: moduleName,
                    demangled: demangled,
                    byUSR: &byUSR
                )
            case "typealias", "typealias_decl":
                guard !isInsideGenericContext,
                      let name = baseName(in: item)
                else { continue }
                let relativeName = [parentCanonicalName, name]
                    .compactMap { $0 }.joined(separator: ".")
                let canonicalName = "\(moduleName).\(relativeName)"
                let isNameable = !isInsidePrivateMemberScope
                    && (parentCanonicalName == nil
                        || (item["access"] as? String) != "private")
                let alias = SourceNominal(
                    declarationIdentity: item["usr"] as? String ?? "",
                    declarationOffset: sourceRange(in: item)?.start,
                    canonicalName: canonicalName,
                    sourceFileLogicalID: source.logicalPath,
                    kind: .alias,
                    isFileScoped: isInsideFileScope
                        || ["private", "fileprivate"].contains(item["access"] as? String ?? ""),
                    isFileScopeNameable: isNameable,
                    isAvailabilityConstrained:
                        isInsideAvailabilityConstrainedScope
                            || Self.hasAvailabilityAttribute(item)
                )
                try Self.insertSourceNominal(alias, into: &byUSR)
            case "extension_decl":
                guard let mangled = item["extended_type"] as? String,
                      let fullName = demangled[mangled],
                      let members = item["members"] as? [Any]
                else { continue }
                let prefix = moduleName + "."
                let sourceName = Self.sourceNominalSpelling(fullName)
                let relativeName = sourceName.hasPrefix(prefix)
                    ? String(sourceName.dropFirst(prefix.count))
                    : sourceName
                try collectSourceNominals(
                    items: members,
                    parentCanonicalName: relativeName,
                    isInsideGenericContext: isInsideGenericContext
                        || Self.hasGenericSignature(item)
                        || fullName.contains("<"),
                    isInsidePrivateMemberScope: isInsidePrivateMemberScope,
                    isInsideFileScope: isInsideFileScope
                        || fullName.contains(" in _"),
                    isInsideAvailabilityConstrainedScope:
                        isInsideAvailabilityConstrainedScope
                            || Self.hasAvailabilityAttribute(item),
                    source: source,
                    moduleName: moduleName,
                    demangled: demangled,
                    byUSR: &byUSR
                )
            default:
                continue
            }
        }
    }

    func callingSurfaceConfiguration(
        _ configuration: PatchConfiguration.Document,
        policy: FrontendReceipt.CallingSurfacePolicy,
        moduleName: String,
        sources: [FrontendReceipt.Source]
    ) throws -> PatchConfiguration.Document {
        guard policy.expandsImportedModules else { return configuration }
        guard var module = configuration.modules[moduleName] else {
            throw FrontendReceipt.Error.invalidRequest(
                "managed native calling surface has no module configuration for \(moduleName)"
            )
        }
        var result = configuration
        module.nativeImports = .init(
            candidateIndex: .sourceAndCatalog,
            emit: .scoped,
            allow: module.nativeImports.allow,
            sourceScope: .init(
                include: sources.map(\.logicalPath).sorted(),
                // The source path already scopes authority to this module.
                // Calls discovered inside it may legitimately target any
                // imported SDK/dependency module and must retain their stable,
                // project-independent native identity.
                declarations: ["*"],
                visibility: .all,
                profile: .readWrite,
                maximumBoundedDurationMicroseconds:
                    Core.NativeImportExecutionPolicy
                        .maximumMainThreadDurationMicroseconds,
                maximumSuspendingDurationMicroseconds: 30_000_000,
                allowsMainThread: true
            )
        )
        result.modules[moduleName] = module
        try result.validate()
        return result
    }

    func exactFallbackImports(
        _ records: [InterfaceArchive.NativeImportRecord],
        excludingEntrySymbols entrySymbols: Set<String>
    ) -> [InterfaceArchive.NativeImportRecord] {
        records.compactMap { record in
            var exact = record
            exact.silMangledNames.removeAll(where: entrySymbols.contains)
            return exact.silMangledNames.isEmpty ? nil : exact
        }
    }

    func makeNativeImportCandidates(
        _ catalog: NativeImportCatalog.Document,
        metadata: InterfaceArchive.ReleaseMetadata,
        configuration: PatchConfiguration.Document,
        nativeTypes: [String: Core.TypeID]
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        let moduleName = metadata.frontendInvocation.moduleName
        guard let module = configuration.modules[moduleName] else {
            throw FrontendReceipt.Error.invalidRequest(
                "NativeImport configuration is absent for module \(moduleName)"
            )
        }
        if !catalog.candidates.isEmpty || !catalog.nativeTypes.isEmpty {
            guard module.nativeImports.candidateIndex == .explicitCatalog
                    || module.nativeImports.candidateIndex == .sourceAndCatalog
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "NativeImport Catalog requires explicit-catalog or source-and-catalog mode"
                )
            }
        }
        let allowed = Set(module.nativeImports.allow)
            .subtracting(NativeImportCatalog.Builtins.automaticCallees)
        let catalogNames = Set(catalog.candidates.map(\.canonicalCallee))
        guard allowed.isSubset(of: catalogNames) else {
            let missing = allowed.subtracting(catalogNames).sorted().joined(separator: ", ")
            throw FrontendReceipt.Error.invalidRequest(
                "selected NativeImport has no catalog factory: \(missing)"
            )
        }

        var records: [InterfaceArchive.NativeImportRecord] = []
        var keys = Set<Core.NativeCall.Key>()
        for candidate in catalog.candidates {
            let parameterTypes = try candidate.signature.parameters.map { spelling in
                guard let type = FrontendReceipt.ValueTypeParser.parse(
                    spelling,
                    allowVoid: false,
                    nativeTypes: nativeTypes
                ) else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "NativeImport \(candidate.canonicalCallee) has an unresolved parameter type \(spelling)"
                    )
                }
                return type
            }
            guard let resultType = FrontendReceipt.ValueTypeParser.parse(
                candidate.signature.result,
                allowVoid: true,
                nativeTypes: nativeTypes
            ) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "NativeImport \(candidate.canonicalCallee) has an unresolved result type "
                        + candidate.signature.result
                )
            }
            let key = try Core.NativeCall.Key.derive(
                descriptor: candidate.descriptor
            )
            guard keys.insert(key).inserted else {
                throw FrontendReceipt.Error.invalidRequest(
                    "NativeImport Catalog derives duplicate key for \(candidate.canonicalCallee)"
                )
            }
            records.append(
                .init(
                    id: nil,
                    key: key,
                    descriptor: candidate.descriptor,
                    silMangledNames: candidate.silMangledNames,
                    parameterTypes: parameterTypes,
                    resultType: resultType,
                    contract: candidate.contract,
                    capability: candidate.capability,
                    isEmittedToDevice: true
                )
            )
        }
        return records.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func mergeNativeImportCandidates(
        explicit: [InterfaceArchive.NativeImportRecord],
        discovered: inout NativeImportDiscovery.Result,
        moduleName: String
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        let explicitSymbols = Set(explicit.flatMap(\.silMangledNames))
        var retained: [NativeImportDiscovery.Candidate] = []
        for candidate in discovered.candidates {
            if !explicitSymbols.isDisjoint(with: candidate.record.silMangledNames) {
                discovered.diagnostics.append(
                    .init(
                        code: "HLXNID008",
                        severity: .note,
                        message: "\(candidate.record.canonicalCallee): explicit NativeImport Catalog entry overrides source discovery",
                        location: .init(
                            file: candidate.generatedBinding.sourceFileLogicalID,
                            line: 1,
                            column: 1
                        )
                    )
                )
            } else {
                retained.append(candidate)
            }
        }
        discovered.candidates = retained
        let records = explicit + retained.map(\.record)
        guard Set(records.map(\.key)).count == records.count else {
            throw FrontendReceipt.Error.invalidRequest(
                "module \(moduleName) NativeImport discovery conflicts with explicit identities"
            )
        }
        return records.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func mergeNativeAPICatalogCandidates(
        _ records: [InterfaceArchive.NativeImportRecord],
        catalog: [InterfaceArchive.NativeImportRecord],
        moduleName: String
    ) throws -> [InterfaceArchive.NativeImportRecord] {
        var merged = Dictionary(
            uniqueKeysWithValues: records.map { ($0.key, $0) }
        )
        for candidate in catalog {
            guard var existing = merged[candidate.key] else {
                merged[candidate.key] = candidate
                continue
            }
            guard existing.id == nil,
                  candidate.id == nil,
                  existing.descriptor == candidate.descriptor,
                  existing.parameterTypes == candidate.parameterTypes,
                  existing.parameterProjection == candidate.parameterProjection,
                  existing.resultType == candidate.resultType,
                  existing.contract == candidate.contract,
                  existing.capability == candidate.capability,
                  existing.abiAdapter == candidate.abiAdapter
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "module \(moduleName) source and Native API Catalog disagree for "
                        + "\(candidate.canonicalCallee) [\(candidate.key)]"
                )
            }
            existing.silMangledNames = Array(Set(
                existing.silMangledNames + candidate.silMangledNames
            )).sorted()
            existing.isEmittedToDevice = existing.isEmittedToDevice
                || candidate.isEmittedToDevice
            merged[candidate.key] = existing
        }
        return merged.values.sorted { $0.key < $1.key }
    }

    func mergeNativeImportBindings(
        _ bindings: [ShellBuildReceipt.NativeImportBinding],
        catalog: [ShellBuildReceipt.NativeImportBinding],
        moduleName: String
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        var merged: [
            Core.NativeCall.Key: ShellBuildReceipt.NativeImportBinding
        ] = [:]
        for binding in bindings {
            if let existing = merged[binding.key], existing != binding {
                throw FrontendReceipt.Error.invalidRequest(
                    "module \(moduleName) discovered duplicate bindings for "
                        + "NativeCallKey \(binding.key)"
                )
            }
            merged[binding.key] = binding
        }
        for binding in catalog {
            if let existing = merged[binding.key],
               existing.strategy != binding.strategy {
                throw FrontendReceipt.Error.invalidRequest(
                    "module \(moduleName) source and Native API Catalog select "
                        + "different execution strategies for NativeCallKey "
                        + "\(binding.key)"
                )
            }
            // The module-level projection is authoritative for compiler
            // spellings and reusable Pack placement. A consumer observation
            // can use aliases while still deriving the same stable key.
            merged[binding.key] = binding
        }
        return merged.values.sorted { $0.key < $1.key }
    }

    func nativeImportPublicationCallees(
        candidates: [InterfaceArchive.NativeImportRecord],
        sourceScopedCallees: [String],
        policy: FrontendReceipt.CallingSurfacePolicy
    ) -> [String] {
        guard policy == .managedProductionModule else {
            return Array(Set(sourceScopedCallees)).sorted()
        }
        // Source scope controls which imports can affect the current module's
        // inferred effects. Production publication is intentionally broader:
        // every compiler-qualified Catalog capability must receive a compact
        // release ID even when the baseline source never references it.
        return Array(Set(candidates.compactMap {
            $0.isEmittedToDevice ? $0.canonicalCallee : nil
        })).sorted()
    }

    func developmentNativeTypePublicationIDs(
        nativeTypeLookup: [String: Core.TypeID],
        sourceObservedTypeNames: Set<String>,
        sourceReferenceTypeNames: Set<String>,
        functions: [InterfaceArchive.FunctionRecord],
        nativeImports: [InterfaceArchive.NativeImportRecord]
    ) -> Set<Core.TypeID> {
        var result = Set(
            sourceObservedTypeNames.union(sourceReferenceTypeNames)
                .compactMap { nativeTypeLookup[$0] }
        )
        for function in functions where function.patchability.isEligible {
            for type in function.parameterTypes + [function.resultType] {
                result.formUnion(type.referencedNativeTypeIDs)
            }
        }
        for nativeImport in nativeImports where nativeImport.isEmittedToDevice {
            for type in nativeImport.parameterTypes + [nativeImport.resultType] {
                result.formUnion(type.referencedNativeTypeIDs)
            }
        }
        return result
    }

    func applyNativeImportEffectEnvelope(
        _ records: [InterfaceArchive.NativeImportRecord],
        to drafts: inout [Draft],
        configuration: PatchConfiguration.Document,
        moduleName: String
    ) {
        guard !records.isEmpty, let module = configuration.modules[moduleName] else { return }
        let mayAllocate = records.contains { $0.effects.mayAllocate }
        let hasExternalSideEffects = records.contains { $0.effects.hasExternalSideEffects }
        guard mayAllocate || hasExternalSideEffects else { return }
        for index in drafts.indices {
            let candidate = drafts[index].candidate
            guard module.includes(logicalPath: candidate.sourceFileLogicalID),
                  module.entrypoints.allows(
                    accessLevel: candidate.interface.accessLevel
                  )
            else { continue }
            drafts[index].candidate.effects.mayAllocate =
                candidate.effects.mayAllocate || mayAllocate
            drafts[index].candidate.effects.hasExternalSideEffects =
                candidate.effects.hasExternalSideEffects || hasExternalSideEffects
            drafts[index].candidate.interface.effects = drafts[index].candidate.effects
        }
    }

    func configuration(
        _ configuration: PatchConfiguration.Document,
        allowing discoveredCallees: [String],
        moduleName: String
    ) -> PatchConfiguration.Document {
        guard !discoveredCallees.isEmpty,
              var module = configuration.modules[moduleName]
        else { return configuration }
        var result = configuration
        if module.nativeImports.candidateIndex == nil,
           module.nativeImports.emit == nil,
           module.nativeImports.allow.isEmpty,
           module.nativeImports.sourceScope == nil {
            module.nativeImports.candidateIndex = .explicitCatalog
            module.nativeImports.emit = .allowlisted
        }
        module.nativeImports.allow = Array(
            Set(module.nativeImports.allow + discoveredCallees)
        ).sorted()
        result.modules[moduleName] = module
        return result
    }

    func makeDiscoveredNativeImportBindings(
        _ candidates: [NativeImportDiscovery.Candidate],
        archive: InterfaceArchive.Archive
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        let cataloged = Dictionary(
            uniqueKeysWithValues: archive.nativeImports.map { ($0.key, $0) }
        )
        return try candidates.compactMap { candidate in
            guard cataloged[candidate.record.key] != nil else { return nil }
            return try candidate.shellBuildBinding()
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func makeNativeTypes(
        _ catalog: NativeImportCatalog.Document,
        sourceNominals: [SourceNominal],
        importedTypes: [ImportedNativeType],
        mainActorReferenceTypes: Set<String>,
        metadata: InterfaceArchive.ReleaseMetadata,
        objectiveCStructures: [String: Core.NativeCall.ABIType] = [:]
    ) throws -> [InterfaceArchive.TypeRecord] {
        let catalogByName = Dictionary(uniqueKeysWithValues: catalog.nativeTypes.map {
            ($0.canonicalName, $0)
        })
        let sourceTypeNames = Set(sourceNominals.map(\.canonicalName))
        let sourceReferences = sourceNominals.filter { $0.kind == .reference && !$0.hasAmbiguousName }
        let sourceValues = sourceNominals.filter { $0.kind.isValue }
        if let collision = sourceValues.first(where: {
            catalogByName[$0.canonicalName] != nil
        }) {
            throw FrontendReceipt.Error.invalidRequest(
                "source value type \(collision.canonicalName) must use its indexed structural codec, not NativeImport TypeOps"
            )
        }
        for source in sourceReferences {
            guard let explicit = catalogByName[source.canonicalName] else { continue }
            guard explicit.kind == .reference,
                  !mainActorReferenceTypes.contains(source.canonicalName)
                    || explicit.requiresMainActor
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "cataloged source class \(source.canonicalName) disagrees with its reference or MainActor semantics"
                )
            }
        }
        var records = catalog.nativeTypes.map { type in
            InterfaceArchive.TypeRecord(
                id: .derive(
                    namespace: metadata.shellNamespaceID,
                    canonicalType: type.canonicalName
                ),
                canonicalName: type.canonicalName,
                kind: type.kind,
                layoutFingerprint: type.layoutFingerprint,
                isCopyable: type.isCopyable,
                requiresMainActor: type.requiresMainActor,
                isEmittedToDevice: true,
                estimatedSize: type.estimatedSize
            )
        }
        for source in sourceReferences where catalogByName[source.canonicalName] == nil {
            records.append(
                .init(
                    id: .derive(
                        namespace: metadata.shellNamespaceID,
                        canonicalType: source.canonicalName
                    ),
                    canonicalName: source.canonicalName,
                    kind: .reference,
                    layoutFingerprint: .sha256(
                        "HLX.SourceReferenceType.v1:\(source.canonicalName)"
                    ),
                    isCopyable: true,
                    requiresMainActor: mainActorReferenceTypes.contains(source.canonicalName),
                    isEmittedToDevice: true,
                    estimatedSize: 8
                )
            )
        }
        for imported in importedTypes {
            let exactCatalogMatches = catalog.nativeTypes.filter {
                $0.canonicalName == imported.canonicalName
            }
            let qualifiedCatalogMatches = catalog.nativeTypes.filter {
                !sourceTypeNames.contains($0.canonicalName)
                    && $0.canonicalName.split(separator: ".").last
                        == Substring(imported.canonicalName)
            }
            let catalogMatches = exactCatalogMatches.isEmpty
                ? qualifiedCatalogMatches : exactCatalogMatches
            guard catalogMatches.count <= 1 else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported type \(imported.canonicalName) has ambiguous catalog TypeOps"
                )
            }
            if let catalogType = catalogMatches.first {
                guard catalogType.kind == imported.kind,
                      !imported.requiresMainActor || catalogType.requiresMainActor
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "cataloged imported type \(imported.canonicalName) disagrees with its kind or MainActor semantics"
                    )
                }
                guard let recordIndex = records.firstIndex(where: {
                    $0.canonicalName == catalogType.canonicalName
                }) else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "cataloged imported type \(imported.canonicalName) has no captured TypeRecord"
                    )
                }
                records[recordIndex].swiftTypeAliases = Array(Set(
                    records[recordIndex].swiftTypeAliases
                        + nativeTypeAliases(
                            for: imported,
                            excluding: catalogType.canonicalName
                        )
                )).sorted()
                continue
            }
            let objectiveCStructure = try objectiveCStructure(
                for: imported,
                catalog: objectiveCStructures
            )
            guard objectiveCStructure == nil || imported.kind == .value else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Objective-C structure \(imported.canonicalName) is not an imported value"
                )
            }
            let layoutFingerprint: Core.Digest
            if let structure = objectiveCStructure {
                let physicalName = structure.canonicalName
                    ?? imported.canonicalName
                let encoding = structure.encoding ?? ""
                let size = structure.size ?? 0
                let alignment = structure.alignment ?? 0
                layoutFingerprint = .sha256(
                    "HLX.ObjectiveCStructure.v1:\(physicalName):"
                        + "\(encoding):\(size):\(alignment)"
                )
            } else {
                layoutFingerprint = .sha256(
                    "HLX.ImportedNativeType.v1:"
                        + "\(metadata.frontendInvocation.targetTriple):"
                        + "\(imported.kind.rawValue):\(imported.canonicalName)"
                )
            }
            records.append(
                .init(
                    id: .derive(
                        namespace: metadata.shellNamespaceID,
                        canonicalType: imported.canonicalName
                    ),
                    canonicalName: imported.canonicalName,
                    swiftTypeAliases: nativeTypeAliases(
                        for: imported,
                        excluding: imported.canonicalName
                    ),
                    kind: imported.kind,
                    layoutFingerprint: layoutFingerprint,
                    objectiveCRuntimeName: imported.objectiveCRuntimeName,
                    isCopyable: true,
                    requiresMainActor: imported.requiresMainActor,
                    isEmittedToDevice: true,
                    estimatedSize: UInt64(objectiveCStructure?.size ?? 8)
                )
            )
        }
        guard Set(records.map(\.canonicalName)).count == records.count else {
            throw FrontendReceipt.Error.invalidRequest(
                "native type catalog collides with a source class"
            )
        }
        return records.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func objectiveCStructureTypes(
        in operations: [ImportedOperation],
        targetTriple: String
    ) throws -> [String: Core.NativeCall.ABIType] {
        var result: [String: Core.NativeCall.ABIType] = [:]
        for evidence in operations.compactMap(\.objectiveC) {
            for raw in evidence.parameters.map(\.swiftABIType)
                + [evidence.resultSwiftABIType] {
                guard let type = FrontendReceipt.ObjectiveCABI.structureType(
                    swiftABIType: raw,
                    targetTriple: targetTriple
                ), let name = type.canonicalName
                else { continue }
                let aliases = Set([name, name.split(separator: ".").last.map(
                    String.init
                ) ?? name])
                for alias in aliases {
                    if let existing = result[alias], existing != type {
                        throw FrontendReceipt.Error.invalidRequest(
                            "Objective-C structure \(alias) has conflicting target ABI evidence"
                        )
                    }
                    result[alias] = type
                }
            }
        }
        return result
    }

    private func objectiveCStructure(
        for imported: ImportedNativeType,
        catalog: [String: Core.NativeCall.ABIType]
    ) throws -> Core.NativeCall.ABIType? {
        let names = Set(
            [imported.canonicalName, imported.swiftType] + imported.aliases
        ).flatMap { name in
            [name, name.split(separator: ".").last.map(String.init) ?? name]
        }
        let matches = Set(names.compactMap { catalog[$0] })
        guard matches.count <= 1 else {
            throw FrontendReceipt.Error.invalidRequest(
                "imported native type \(imported.canonicalName) has ambiguous Objective-C structure ABI evidence"
            )
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// The typed AST and mangled ABI jointly prove these spellings denote the
    /// same imported nominal. Persist that proof for patch-time SIL parsing;
    /// guessing overlay names from Foundation's `NS` convention is unsound.
    private func nativeTypeAliases(
        for imported: ImportedNativeType,
        excluding canonicalName: String
    ) -> [String] {
        Array(Set(imported.aliases + [
            imported.canonicalName,
            imported.swiftType,
        ])).filter {
            $0 != canonicalName
                && !FrontendReceipt.ValueTypeParser
                    .isBuiltinValueSpelling($0)
        }.sorted()
    }

    func makeLocalValueTypeLookup(
        _ sourceNominals: [SourceNominal]
    ) -> [String: Bytecode.LocalTypeKey] {
        var result: [String: Bytecode.LocalTypeKey] = [:]
        for nominal in sourceNominals where nominal.kind.isValue && !nominal.hasAmbiguousName {
            result[nominal.canonicalName] = nominal.localTypeKey
            result[nominal.localTypeKey.rawValue] = nominal.localTypeKey
        }
        return result
    }

    /// Materializes only the transitive source values that can reach a Shell
    /// declaration boundary. Large applications commonly contain thousands of
    /// unrelated value declarations, and eagerly resolving all of them would
    /// turn one boundary feature into whole-module quadratic work.
    func makeFrozenValueTypes(
        referencedBy declarations: [ReleaseCompiler.DeclarationCandidate],
        sourceNominals: [SourceNominal],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> [InterfaceArchive.FrozenValueTypeRecord] {
        let sourceValues = Dictionary(uniqueKeysWithValues: sourceNominals
            .filter { $0.kind.isValue && !$0.hasAmbiguousName }
            .map { ($0.localTypeKey, $0) })
        var pending: [Bytecode.LocalTypeKey] = []
        func collect(_ type: Bytecode.ValueType) {
            switch type {
            case let .local(key): pending.append(key)
            case let .array(element), let .optional(element), let .set(element):
                collect(element)
            case let .dictionary(key, value):
                collect(key)
                collect(value)
            case let .tuple(elements):
                elements.forEach(collect)
            default:
                break
            }
        }
        for declaration in declarations {
            (declaration.parameterTypes + [declaration.resultType]).forEach(
                collect
            )
        }

        var visited = Set<Bytecode.LocalTypeKey>()
        var records: [InterfaceArchive.FrozenValueTypeRecord] = []
        while let key = pending.popLast() {
            guard visited.insert(key).inserted,
                  let nominal = sourceValues[key], nominal.isFileScopeNameable,
                  !nominal.isAvailabilityConstrained
            else { continue }
            let record: InterfaceArchive.FrozenValueTypeRecord
            do {
                record = try typeEnvironment.frozenValueTypeRecord(
                    key: key,
                    canonicalName: nominal.canonicalName,
                    sourceFileLogicalID: nominal.sourceFileLogicalID
                )
            } catch CanonicalSIL.LoweringError.unsupportedType {
                continue
            }
            records.append(record)
            switch record.kind {
            case let .structure(fields):
                fields.forEach { collect($0.type) }
            case let .enumeration(cases):
                cases.compactMap(\.payloadType).forEach(collect)
            }
        }
        return records.sorted { $0.key < $1.key }
    }

    func makeNativeImportBindings(
        catalog: NativeImportCatalog.Document,
        archive: InterfaceArchive.Archive
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        var catalogByKey: [Core.NativeCall.Key: NativeImportCatalog.Candidate] = [:]
        for candidate in catalog.candidates {
            let key = try Core.NativeCall.Key.derive(
                descriptor: candidate.descriptor
            )
            catalogByKey[key] = candidate
        }
        return archive.nativeImports.compactMap { item in
            guard let candidate = catalogByKey[item.key] else { return nil }
            return .init(
                key: item.key,
                strategy: .factory,
                factoryReference: "\(candidate.factoryType).make",
                importedModules: candidate.importedModules
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func makeNativeTypeBindings(
        catalog: NativeImportCatalog.Document,
        archive: InterfaceArchive.Archive,
        sourceNominals: [SourceNominal],
        importedTypes: [ImportedNativeType],
        objectiveCStructures: [Core.TypeID: Core.NativeCall.ABIType]
    ) throws -> [ShellBuildReceipt.NativeTypeBinding] {
        let byName = Dictionary(uniqueKeysWithValues: catalog.nativeTypes.map {
            ($0.canonicalName, $0)
        })
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceNominals
            .filter { $0.kind == .reference && !$0.hasAmbiguousName }
            .map { ($0.canonicalName, $0) })
        let importedByName = Dictionary(uniqueKeysWithValues: importedTypes.map {
            ($0.canonicalName, $0)
        })
        let generatedSourceIDs = Set(
            sourceNominals.map(\.sourceFileLogicalID)
                + importedTypes.map(\.sourceFileLogicalID)
        )
        let groupNames = Dictionary(uniqueKeysWithValues:
            generatedSourceIDs.map {
                ($0, BridgeGeneration.GeneratedNativeType.groupName(
                    sourceFileLogicalID: $0
                ))
            }
        )
        let candidateTypeIDs = archive.nativeImports.reduce(
            into: Set<Core.TypeID>()
        ) { result, nativeImport in
            nativeImport.parameterTypes.forEach {
                result.formUnion($0.referencedNativeTypeIDs)
            }
            result.formUnion(nativeImport.resultType.referencedNativeTypeIDs)
        }
        return try archive.nativeTypes.compactMap { item in
            guard item.isEmittedToDevice || candidateTypeIDs.contains(item.id)
            else { return nil }
            if let candidate = byName[item.canonicalName] {
                guard candidate.layoutFingerprint == item.layoutFingerprint else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "emitted native type \(item.canonicalName) changed its cataloged layout"
                    )
                }
                let expression = "\(candidate.factoryType).make("
                    + "id: Core.TypeID(rawValue: try! Core.Digest(hex: "
                    + "\(String(reflecting: item.id.rawValue.hex))))), "
                    + "canonicalName: \(String(reflecting: item.canonicalName)), "
                    + "layoutFingerprint: try! Core.Digest(hex: "
                    + "\(String(reflecting: item.layoutFingerprint.hex))), "
                    + "requiresMainActor: \(item.requiresMainActor))"
                return .init(
                    canonicalName: item.canonicalName,
                    layoutFingerprint: item.layoutFingerprint,
                    requiresMainActor: item.requiresMainActor,
                    operationsExpression: expression,
                    importedModules: candidate.importedModules
                )
            }
            if let imported = importedByName[item.canonicalName] {
                let structure = objectiveCStructures[item.id]
                if let runtimeName = item.objectiveCRuntimeName {
                    guard item.kind == .reference,
                          item.isCopyable,
                          structure == nil,
                          imported.objectiveCRuntimeName == runtimeName,
                          Core.NativeCall.isCanonicalObjectiveCRuntimeClassName(
                              runtimeName
                          )
                    else {
                        throw FrontendReceipt.Error.invalidRequest(
                            "Objective-C reference \(item.canonicalName) disagrees with its runtime identity"
                        )
                    }
                    return .init(
                        canonicalName: item.canonicalName,
                        layoutFingerprint: item.layoutFingerprint,
                        requiresMainActor: item.requiresMainActor,
                        strategy: .objectiveCReference,
                        importedModules: imported.importedModules
                    )
                }
                let representation: ShellBuildReceipt.GeneratedNativeType.Representation =
                    if structure != nil {
                        .objectiveCStructure
                    } else {
                        switch imported.representation {
                        case .reference: .reference
                        case .rawRepresentable: .rawRepresentable
                        case .opaqueValue: .opaqueValue
                        }
                    }
                if let structure {
                    guard imported.kind == .value,
                          structure.kind == .structure,
                          let size = structure.size,
                          UInt64(size) == item.estimatedSize,
                          structure.alignment != nil,
                          structure.encoding != nil
                    else {
                        throw FrontendReceipt.Error.invalidRequest(
                            "Objective-C structure \(item.canonicalName) disagrees with its TypeRecord"
                        )
                    }
                }
                let generated = ShellBuildReceipt.GeneratedNativeType(
                    sourceFileLogicalID: imported.sourceFileLogicalID,
                    swiftType: imported.swiftType,
                    representation: representation,
                    nativeABIEncoding: structure?.encoding,
                    nativeModuleName: imported.nativeModuleName
                )
                let expression = BridgeGeneration.GeneratedNativeType.bindingExpression(
                    sourceFileLogicalID: generated.sourceFileLogicalID,
                    id: item.id,
                    canonicalName: item.canonicalName,
                    layoutFingerprint: item.layoutFingerprint,
                    requiresMainActor: item.requiresMainActor,
                    estimatedSize: item.estimatedSize,
                    precomputedGroupName: groupNames[
                        generated.sourceFileLogicalID
                    ]
                )
                return .init(
                    canonicalName: item.canonicalName,
                    layoutFingerprint: item.layoutFingerprint,
                    requiresMainActor: item.requiresMainActor,
                    operationsExpression: expression,
                    importedModules: imported.importedModules,
                    generated: generated
                )
            }
            guard let source = sourceByName[item.canonicalName],
                  item.kind == .reference
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "emitted native type \(item.canonicalName) has no deterministic factory binding"
                )
            }
            let modulePrefix = archive.metadata.frontendInvocation.moduleName + "."
            let swiftType = item.canonicalName.hasPrefix(modulePrefix)
                ? String(item.canonicalName.dropFirst(modulePrefix.count))
                : item.canonicalName
            let generated = ShellBuildReceipt.GeneratedNativeType(
                sourceFileLogicalID: source.sourceFileLogicalID,
                swiftType: swiftType
            )
            let expression = BridgeGeneration.GeneratedNativeType.bindingExpression(
                sourceFileLogicalID: generated.sourceFileLogicalID,
                id: item.id,
                canonicalName: item.canonicalName,
                layoutFingerprint: item.layoutFingerprint,
                requiresMainActor: item.requiresMainActor,
                estimatedSize: item.estimatedSize,
                precomputedGroupName: groupNames[
                    generated.sourceFileLogicalID
                ]
            )
            return .init(
                canonicalName: item.canonicalName,
                layoutFingerprint: item.layoutFingerprint,
                requiresMainActor: item.requiresMainActor,
                operationsExpression: expression,
                generated: generated
            )
        }.sorted {
            ($0.canonicalName, $0.layoutFingerprint)
                < ($1.canonicalName, $1.layoutFingerprint)
        }
    }

    private func objectiveCStructureABIs(
        in archive: InterfaceArchive.Archive
    ) throws -> [Core.TypeID: Core.NativeCall.ABIType] {
        var result: [Core.TypeID: Core.NativeCall.ABIType] = [:]
        func record(
            _ type: Core.NativeCall.ABIType,
            logical: Bytecode.ValueType
        ) throws {
            guard type.kind == .structure,
                  case let .native(id) = logical
            else { return }
            if let existing = result[id], existing != type {
                throw FrontendReceipt.Error.invalidRequest(
                    "native type \(id) has conflicting Objective-C structure ABIs"
                )
            }
            result[id] = type
        }
        for call in archive.nativeImports
        where call.descriptor.target.backend == .objectiveCMessage {
            for parameter in call.descriptor.physicalSignature.parameters {
                guard parameter.source.kind == .argument,
                      let index = parameter.source.logicalArgumentIndex,
                      call.parameterTypes.indices.contains(Int(index))
                else { continue }
                try record(
                    parameter.type,
                    logical: call.parameterTypes[Int(index)]
                )
            }
            try record(
                call.descriptor.physicalSignature.result,
                logical: call.resultType
            )
        }
        return result
    }

    func loadSources(_ sources: [FrontendReceipt.Source], collectFailures: Bool = false) throws -> [SourceState] {
        if collectFailures {
            var loaded: [SourceState] = []
            var failures: [String] = []
            for source in sources {
                do { loaded.append(contentsOf: try loadSources([source])) }
                catch { failures.append("\(source.logicalPath) (\(source.url.path)): \(error)") }
            }
            guard failures.isEmpty else { throw FrontendReceipt.Error.invalidRequest(failures.joined(separator: "\n")) }
            return loaded
        }
        return try sources.map { source in
            let url = source.url.resolvingSymlinksInPath().standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source is not a regular file: \(url.path)"
                )
            }
            guard size <= 64 * 1_024 * 1_024 else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source \(source.logicalPath) is \(size) bytes; maximum is 67108864 bytes (64 MiB): \(url.path)"
                )
            }
            let contents = try Data(contentsOf: url, options: .mappedIfSafe)
            guard contents.count == size, String(data: contents, encoding: .utf8) != nil else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source changed while reading or is not UTF-8: \(url.path)"
                )
            }
            return .init(
                logicalPath: source.logicalPath,
                url: url,
                contents: contents,
                contentHash: .sha256(contents)
            )
        }
    }

    func imports(in items: [Any]) -> [String] {
        Array(Set(items.compactMap { value -> String? in
            guard let item = value as? [String: Any],
                  item["_kind"] as? String == "import_decl",
                  let path = item["module_path"] as? [String],
                  !path.isEmpty
            else { return nil }
            return path.joined(separator: ".")
        })).sorted()
    }

    func validateNativeAnchors(_ drafts: [Draft], sources: [SourceState]) throws {
        let sourceByPath = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.logicalPath, $0.contents)
        })
        for draft in drafts {
            guard let root = draft.root,
                  let replacement = root.nativeReplacement,
                  let source = sourceByPath[draft.candidate.sourceFileLogicalID]
            else { continue }
            let anchor = Data(replacement.declarationAnchor.utf8)
            let offset = replacement.declarationAnchorUTF8Offset
            guard offset <= source.count,
                  anchor.count <= source.count - offset,
                  source[offset..<(offset + anchor.count)]
                    == anchor,
                  Self.occurrence(
                      of: anchor,
                      at: offset,
                      in: source
                  ) == replacement.declarationOccurrence
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "native declaration anchor is inconsistent with typed AST offset for "
                        + draft.candidate.mangledName
                )
            }
        }
    }

    func walk(
        items: [Any],
        context: NominalContext?,
        source: SourceState,
        locationMap: SourceTransform.LocationMap,
        imports: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silResolver: FrontendReceipt.SILFunctionResolver,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        nativeTypes: [String: Core.TypeID],
        localValueTypes: [String: Bytecode.LocalTypeKey],
        importedSwiftTypeAliases: [String: String],
        sourceNominals: SourceNominalIndex,
        sourceNominalAliasIndex: SourceNominalAliasIndex,
        drafts: inout [Draft]
    ) throws {
        for value in items {
            guard let item = value as? [String: Any],
                  let kind = item["_kind"] as? String
            else { continue }
            switch kind {
            case "func_decl":
                if let draft = try makeDraft(
                    item,
                    context: context,
                    source: source,
                    locationMap: locationMap,
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silResolver: silResolver,
                    typeEnvironment: typeEnvironment,
                    nativeTypes: nativeTypes,
                    localValueTypes: localValueTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases,
                    sourceNominalAliasIndex: sourceNominalAliasIndex
                ) {
                    drafts.append(draft)
                }
            case "var_decl":
                if let accessorDrafts = try makeReloadableAccessorDrafts(
                    item,
                    context: context,
                    source: source,
                    importedModules: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silResolver: silResolver,
                    typeEnvironment: typeEnvironment,
                    nativeTypes: nativeTypes,
                    localValueTypes: localValueTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases
                ) {
                    drafts.append(contentsOf: accessorDrafts)
                } else {
                    if let observerDrafts = try makeReloadableObserverDrafts(
                        item,
                        context: context,
                        source: source,
                        importedModules: imports,
                        moduleName: moduleName,
                        configuration: configuration,
                        demangled: demangled,
                        silResolver: silResolver,
                        typeEnvironment: typeEnvironment,
                        nativeTypes: nativeTypes,
                        localValueTypes: localValueTypes,
                        importedSwiftTypeAliases: importedSwiftTypeAliases
                    ) {
                        drafts.append(contentsOf: observerDrafts)
                    }
                    drafts.append(contentsOf: try makeSourcePropertyDrafts(
                        item,
                        context: context,
                        source: source,
                        importedModules: imports,
                        moduleName: moduleName,
                        configuration: configuration,
                        demangled: demangled,
                        silResolver: silResolver,
                        nativeTypes: nativeTypes,
                        importedSwiftTypeAliases: importedSwiftTypeAliases
                    ))
                }
            case "subscript_decl":
                if let accessorDrafts = try makeReloadableAccessorDrafts(
                    item,
                    context: context,
                    source: source,
                    importedModules: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silResolver: silResolver,
                    typeEnvironment: typeEnvironment,
                    nativeTypes: nativeTypes,
                    localValueTypes: localValueTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases
                ) {
                    drafts.append(contentsOf: accessorDrafts)
                }
            case "class_decl", "struct_decl", "enum_decl", "actor_decl":
                guard let name = baseName(in: item),
                      let members = item["members"] as? [Any]
                else { continue }
                let canonicalName = [context?.canonicalName, name]
                    .compactMap { $0 }.joined(separator: ".")
                let moduleQualifiedName = "\(moduleName).\(canonicalName)"
                let nominal = sourceNominals.resolve(moduleQualifiedName, in: source.logicalPath)
                try walk(
                    items: members,
                    context: .init(
                        canonicalName: canonicalName,
                        moduleQualifiedName: moduleQualifiedName,
                        kind: nominal?.kind,
                        referenceTypeID: nominal?.kind == .reference
                            ? nativeTypes[moduleQualifiedName] : nil,
                        localValueTypeKey: nominal?.kind.isValue == true && nominal?.hasAmbiguousName != true
                            ? nominal?.localTypeKey : nil,
                        isFileScopeNameable:
                            nominal?.isFileScopeNameable != false && nominal?.hasAmbiguousName != true,
                        isAvailabilityConstrained:
                            nominal?.isAvailabilityConstrained == true,
                        isGenericContext: context?.isGenericContext == true
                            || Self.hasGenericSignature(item),
                        sourceFileLogicalID: nominal?.isFileScoped == true ? source.logicalPath : nil
                    ),
                    source: source,
                    locationMap: locationMap,
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silResolver: silResolver,
                    typeEnvironment: typeEnvironment,
                    nativeTypes: nativeTypes,
                    localValueTypes: localValueTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases,
                    sourceNominals: sourceNominals,
                    sourceNominalAliasIndex: sourceNominalAliasIndex,
                    drafts: &drafts
                )
            case "extension_decl":
                guard let mangled = item["extended_type"] as? String,
                      let fullName = demangled[mangled],
                      let members = item["members"] as? [Any]
                else { continue }
                let prefix = moduleName + "."
                let sourceName = Self.sourceNominalSpelling(fullName)
                let canonicalName = sourceName.hasPrefix(prefix)
                    ? String(sourceName.dropFirst(prefix.count))
                    : sourceName
                let moduleQualifiedName = sourceName.hasPrefix(prefix)
                    ? sourceName : "\(moduleName).\(sourceName)"
                let nominal = sourceNominals.resolve(moduleQualifiedName, in: source.logicalPath)
                try walk(
                    items: members,
                    context: .init(
                        canonicalName: canonicalName,
                        moduleQualifiedName: moduleQualifiedName,
                        kind: nominal?.kind,
                        referenceTypeID: nominal?.kind == .reference
                            ? nativeTypes[moduleQualifiedName] : nil,
                        localValueTypeKey: nominal?.kind.isValue == true && nominal?.hasAmbiguousName != true
                            ? nominal?.localTypeKey : nil,
                        isFileScopeNameable:
                            nominal?.isFileScopeNameable != false && nominal?.hasAmbiguousName != true,
                        isAvailabilityConstrained:
                            nominal?.isAvailabilityConstrained == true
                                || Self.hasAvailabilityAttribute(item),
                        isGenericContext: Self.hasGenericSignature(item)
                            || fullName.contains("<"),
                        sourceFileLogicalID: nominal?.isFileScoped == true ? source.logicalPath : nil
                    ),
                    source: source,
                    locationMap: locationMap,
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silResolver: silResolver,
                    typeEnvironment: typeEnvironment,
                    nativeTypes: nativeTypes,
                    localValueTypes: localValueTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases,
                    sourceNominals: sourceNominals,
                    sourceNominalAliasIndex: sourceNominalAliasIndex,
                    drafts: &drafts
                )
            default:
                continue
            }
        }
    }

    func makeDraft(
        _ item: [String: Any],
        context: NominalContext?,
        source: SourceState,
        locationMap: SourceTransform.LocationMap,
        imports: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silResolver: FrontendReceipt.SILFunctionResolver,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        nativeTypes: [String: Core.TypeID],
        localValueTypes: [String: Bytecode.LocalTypeKey],
        importedSwiftTypeAliases: [String: String],
        sourceNominalAliasIndex: SourceNominalAliasIndex
    ) throws -> Draft? {
        guard item["implicit"] as? Bool != true,
              let usr = item["usr"] as? String,
              usr.hasPrefix("s:"),
              let baseName = baseName(in: item),
              Self.isSwiftIdentifier(baseName),
              let body = item["body"] as? [String: Any],
              let functionRange = sourceRange(in: item),
              let bodyRange = sourceRange(in: body),
              functionRange.start >= 0,
              bodyRange.start >= functionRange.start,
              bodyRange.start < source.contents.count,
              bodyRange.end >= bodyRange.start,
              bodyRange.end < source.contents.count,
              source.contents[bodyRange.end] == UInt8(ascii: "}")
        else {
            return nil
        }
        let astMangledName = "$s" + usr.dropFirst(2)
        guard let sil = try silResolver
            .function(for: item, source: source, baseName: baseName)
        else {
            throw FrontendReceipt.Error.missingSILFunction(astMangledName)
        }
        let mangledName = sil.mangledName
        let rawHeaderData = source.contents.subdata(
            in: functionRange.start..<bodyRange.start
        )
        guard let rawHeader = String(data: rawHeaderData, encoding: .utf8),
              let token = Self.functionToken(in: rawHeader, baseName: baseName),
              source.contents[bodyRange.start] == UInt8(ascii: "{")
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): typed range for \(baseName) has no unique func token"
            )
        }
        let sourceHeader = String(rawHeader[token.functionStart...])
        let relativeNameStart = rawHeader.distance(
            from: token.functionStart,
            to: token.nameStart
        )
        let sourceNameStart = sourceHeader.index(
            sourceHeader.startIndex,
            offsetBy: relativeNameStart
        )
        let sourceNameEnd = sourceHeader.index(
            sourceNameStart,
            offsetBy: baseName.count
        )
        let expectedPrefix = String(sourceHeader[..<sourceNameEnd])
        let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
            usr: usr,
            baseName: baseName
        )
        let declarationOffset = functionRange.start
            + rawHeader[..<token.functionStart].utf8.count

        func replacingFunctionName(in value: String) -> String {
            var result = value
            let start = result.index(
                result.startIndex,
                offsetBy: relativeNameStart
            )
            let end = result.index(start, offsetBy: baseName.count)
            result.replaceSubrange(start..<end, with: replacementName)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parametersObject = item["params"] as? [String: Any]
        let parameterItems = parametersObject?["params"] as? [[String: Any]] ?? []
        let canonicalFunctionHeader = replacingFunctionName(in: sourceHeader)
        let sourceTypeAliases = sourceNominalAliasIndex.aliases(
            visibleFrom: context,
            in: sourceHeader
        )
        guard let parameterRange = parametersObject.flatMap(sourceRange(in:)),
              parameterRange.start >= declarationOffset,
              parameterRange.end >= parameterRange.start,
              parameterRange.end < bodyRange.start
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(mangledName) has no bounded source parameter list"
            )
        }
        let relativeParameterRange: Range<Int> = (
            parameterRange.start - declarationOffset
        )..<(parameterRange.end - declarationOffset + 1)
        guard let qualifiedSourceHeader = FrontendReceipt.SourceFunctionSpelling
            .replacingNominalAliases(
                in: sourceHeader,
                parameterUTF8Range: relativeParameterRange,
                aliases: sourceTypeAliases
            )
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): cannot preserve the qualified signature for \(baseName)"
            )
        }
        let generatedFunctionHeader = replacingFunctionName(
            in: qualifiedSourceHeader
        )

        let parameterNames = try parameterItems.map { parameter -> String in
            guard let name = self.baseName(in: parameter), Self.isSwiftIdentifier(name) else {
                throw FrontendReceipt.Error.unsupportedDeclaration(
                    "\(source.logicalPath): unnamed or operator parameter"
                )
            }
            return name
        }
        let parameterTypes = try parameterItems.map {
            try demangledType($0["interface_type"], using: demangled)
        }
        let resultType = try demangledType(item["result"], using: demangled)
        let generatedParameterTypes = parameterTypes.map {
            FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                in: $0,
                aliases: importedSwiftTypeAliases
            )
        }
        let generatedResultType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(
                in: resultType,
                aliases: importedSwiftTypeAliases
            )
        let labels = argumentLabels(in: item)
        guard labels.count == parameterNames.count else {
            throw FrontendReceipt.Error.malformedAST(
                "\(mangledName) argument labels and parameters disagree"
            )
        }
        let originalReference = Self.originalReference(
            baseName: baseName,
            labels: labels
        )
        let attributes = item["attrs"] as? [[String: Any]] ?? []
        let attributeKinds = Set(attributes.compactMap { $0["_kind"] as? String })
        let customAttributeItems = attributes.filter {
            $0["_kind"] as? String == "custom_attr"
        }
        let decodedCustomAttributes = customAttributeItems.compactMap { attribute -> String? in
            guard let type = attribute["type"] as? String,
                  let demangledType = demangled[type]
            else { return nil }
            return Self.customAttributeName(demangledType)
        }
        let silIsolationName: String? = switch sil.isolation {
        case .unspecified, .nonisolated:
            nil
        case let .globalActor(name):
            name
        case let .actorInstance(name):
            name ?? "actor-instance"
        case let .unknown(description):
            description
        }
        let hasSupportedSILIsolation = supportedIsolation(sil.isolation)
        let hasMainActorAttribute = decodedCustomAttributes.contains(
            where: Self.isMainActor
        )
        let mainActor = switch sil.isolation {
        case let .globalActor(name):
            Self.isMainActor(name)
        case .unspecified:
            hasMainActorAttribute
        case .nonisolated, .actorInstance, .unknown:
            false
        }
        let customAttributes = Array(Set(
            decodedCustomAttributes.filter { !Self.isMainActor($0) }
        )).sorted()
        let hasUnrepresentableCustomAttribute =
            decodedCustomAttributes.count != customAttributeItems.count
        // The source header may legally contain a backticked `async`
        // identifier. The lowered convention is the authoritative ABI signal
        // and avoids treating such synchronous declarations as async roots.
        let isAsync = sil.loweredType.range(
            of: #"(?:^|\s)@async(?:\s|$)"#,
            options: .regularExpression
        ) != nil
        let mayThrow = Self.containsWord("throws", in: canonicalFunctionHeader)
            || Self.containsWord("rethrows", in: canonicalFunctionHeader)
            || sil.loweredType.contains("@error")
        let sourceBodyTransform: ShellBuildReceipt.SourceBodyTransform?
        if isAsync {
            let span = bodyRange.end.subtractingReportingOverflow(bodyRange.start)
            if !span.overflow, span.partialValue < 64 * 1_024 {
                sourceBodyTransform = .init(
                    kind: .asynchronousFunction,
                    openingBraceUTF8Offset: bodyRange.start,
                    closingBraceUTF8Offset: bodyRange.end,
                    expectedBodyHash: .sha256(
                        source.contents.subdata(
                            in: bodyRange.start..<(bodyRange.end + 1)
                        )
                    )
                )
            } else {
                sourceBodyTransform = nil
            }
        } else {
            sourceBodyTransform = nil
        }
        let hasTypedThrows = canonicalFunctionHeader.range(
            of: #"\bthrows\s*\("#,
            options: .regularExpression
        ) != nil
        let isGeneric = canonicalFunctionHeader[
            canonicalFunctionHeader.index(
                canonicalFunctionHeader.startIndex,
                offsetBy: 5
            )...
        ]
            .hasPrefix("\(replacementName)<")
            || Self.hasGenericSignature(item)
            || context?.isGenericContext == true
        let hasInOut = parameterItems.contains { $0["inout"] as? Bool == true }
            || (item["implicit_self_decl"] as? [String: Any])?["inout"] as? Bool == true
        let forbiddenAttributes: Set<String> = [
            "transparent_attr", "inlinable_attr", "always_emit_into_client_attr",
            "cdecl_attr", "silgen_name_attr", "available_attr",
        ]
        let hasSupportedInstallationContext = attributeKinds.isDisjoint(
            with: forbiddenAttributes
        )
            && !hasUnrepresentableCustomAttribute
            && hasSupportedSILIsolation
            && context?.kind != .actor
            && context?.isAvailabilityConstrained != true
            && (!isAsync || context?.isFileScopeNameable != false)
            && (!isAsync || sourceBodyTransform != nil)
        let access = item["access"] as? String ?? "internal"
        let moduleRule = configuration.modules[moduleName]
        let selectedByConfiguration = moduleRule?.includes(
            logicalPath: source.logicalPath
        ) == true && (
            moduleRule?.entrypoints.allows(accessLevel: access) == true
        )
        let valueParameterTypes = parameterTypes.map {
            FrontendReceipt.ValueTypeParser.parse(
                $0,
                allowVoid: false,
                nativeTypes: nativeTypes,
                localTypes: localValueTypes
            ) ?? .never
        }
        let valueResultType = FrontendReceipt.ValueTypeParser.parse(
            resultType,
            allowVoid: true,
            nativeTypes: nativeTypes,
            localTypes: localValueTypes
        ) ?? .never
        let isTypeMethod = item["static"] as? Bool == true
        let referenceReceiverType = context.flatMap { nominal -> String? in
            guard !isTypeMethod, nominal.kind == .reference,
                  nominal.referenceTypeID != nil
            else { return nil }
            return nominal.moduleQualifiedName
        }
        let referenceReceiverID = referenceReceiverType.flatMap { _ in
            context?.referenceTypeID
        }
        let valueReceiverKey = context.flatMap { nominal -> Bytecode.LocalTypeKey? in
            guard !isTypeMethod, nominal.kind?.isValue == true else {
                return nil
            }
            return nominal.localValueTypeKey
        }
        let bridgedReceiverType: Bytecode.ValueType? = referenceReceiverID.map {
            .native($0)
        } ?? valueReceiverKey.map { .local($0) }
        let bridgedParameterTypes = valueParameterTypes
            + (bridgedReceiverType.map { [$0] } ?? [])
        // Canonical SIL is the single ownership authority. In particular, `Any`
        // and `Error` can carry reference identity despite not being linear VM
        // handles, so source-level `inout` versus owned inference is incomplete.
        let bridgedParameterConventions = try CanonicalSIL.Lowerer(
            typeEnvironment: typeEnvironment
        ).parseParameterConventions(
            sil.loweredType,
            parameterTypes: bridgedParameterTypes
        )
        guard bridgedParameterConventions.count == bridgedParameterTypes.count else {
            throw FrontendReceipt.Error.malformedAST(
                "\(mangledName) has an inconsistent canonical ownership signature"
            )
        }
        let explicitParameterConventions = bridgedParameterConventions.prefix(
            parameterNames.count
        )
        let originalArguments = Self.arguments(
            labels: labels,
            values: zip(parameterNames, explicitParameterConventions).map {
                $0.1 == .inout ? "&\($0.0)" : $0.0
            }
        )
        let bridgeArguments = Self.arguments(
            labels: labels,
            values: zip(
                parameterNames.indices.map { "argument\($0)" },
                explicitParameterConventions
            ).map { $0.1 == .inout ? "&\($0.0)" : $0.0 }
        )
        let effects = Core.Effects(
            mayThrow: mayThrow,
            requiresMainActor: mainActor,
            isAsync: isAsync
        )
        let contextPrefix = context.map { "\($0.canonicalName)." } ?? ""
        let modifierPrefix = String(rawHeader[..<token.functionStart])
        var declarationPrefix = ""
        for attribute in customAttributes {
            declarationPrefix += "@\(attribute) "
        }
        if mainActor { declarationPrefix += "@MainActor " }
        if item["nonisolated(unsafe)"] as? Bool == true || modifierPrefix.range(
            of: #"\bnonisolated\s*\(\s*unsafe\s*\)"#,
            options: .regularExpression
        ) != nil {
            declarationPrefix += "nonisolated(unsafe) "
        } else if item["nonisolated"] as? Bool == true
                    || Self.containsWord("nonisolated", in: modifierPrefix) {
            declarationPrefix += "nonisolated "
        }
        if attributeKinds.contains("borrowing_attr") {
            declarationPrefix += "borrowing "
        } else if attributeKinds.contains("consuming_attr") {
            declarationPrefix += "consuming "
        }
        if isTypeMethod {
            declarationPrefix += Self.containsWord("class", in: modifierPrefix)
                ? "class " : "static "
        }
        if attributeKinds.contains("mutating_attr") { declarationPrefix += "mutating " }
        let replacementDeclaration = declarationPrefix + generatedFunctionHeader
        let enclosure = context.map { ("extension \($0.canonicalName) {", "}") }
        let asyncOriginalThunk: String? = if isAsync,
            hasSupportedInstallationContext {
            try FrontendReceipt.AsyncOriginalThunk.render(
                body: body,
                bodyRange: bodyRange,
                source: source.contents,
                locationMap: locationMap,
                logicalPath: source.logicalPath,
                originalFunctionName: originalReference,
                thunkHeader: replacementDeclaration,
                enclosingPrefix: enclosure?.0 ?? "",
                enclosingSuffix: enclosure?.1 ?? ""
            )
        } else {
            nil
        }
        let canInstallBridge = hasSupportedInstallationContext
            && (!isAsync || asyncOriginalThunk != nil)
        let canonicalHeader = (declarationPrefix + canonicalFunctionHeader)
            .replacingOccurrences(of: replacementName, with: baseName)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let interfaceType = try demangledType(item["interface_type"], using: demangled)
        let isolation = mainActor
            ? "MainActor" : customAttributes.first ?? silIsolationName
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: baseName,
            argumentLabels: labels.map { $0.isEmpty ? "_" : $0 },
            accessLevel: access,
            canonicalFormalType: interfaceType,
            loweredSILType: sil.loweredType,
            genericSignature: isGeneric ? canonicalHeader : nil,
            effects: effects,
            isolation: isolation,
            dispatchIdentity: usr
        )
        let candidate = ReleaseCompiler.DeclarationCandidate(
            moduleName: moduleName,
            sourceFileLogicalID: source.logicalPath,
            canonicalDeclaration: contextPrefix + canonicalHeader,
            mangledName: mangledName,
            role: context == nil ? .function : .method,
            loweredSignature: .init(
                parameters: parameterTypes,
                result: resultType,
                isThrowing: mayThrow,
                isAsync: isAsync,
                isolation: isolation
            ),
            parameterTypes: bridgedParameterTypes,
            parameterConventions: bridgedParameterConventions,
            resultType: valueResultType,
            interface: interface,
            canonicalSILBody: sil.body,
            effects: effects,
            isAsync: isAsync,
            hasInOut: hasInOut,
            isGeneric: isGeneric,
            isNoncopyable: false,
            hasTypedThrows: hasTypedThrows,
            hasCompleteDynamicCoverage: canInstallBridge,
            forcedPatchability: {
                if !customAttributes.isEmpty || hasUnrepresentableCustomAttribute {
                    return .rejected(
                        "HLXIDX012",
                        explanation: "custom function attributes are Native-only in HLBC v1"
                    )
                }
                if !hasSupportedSILIsolation, context?.kind != .actor {
                    return .rejected(
                        "HLXIDX012",
                        explanation: "custom function isolation requires a supported executor Bridge"
                    )
                }
                if attributeKinds.contains("available_attr")
                    || context?.isAvailabilityConstrained == true {
                    return .rejected(
                        "HLXIDX010",
                        explanation: "availability-constrained declarations cannot install a permanent Bridge across the Shell deployment range"
                    )
                }
                if isAsync, context?.isFileScopeNameable == false {
                    return .rejected(
                        "HLXIDX020",
                        explanation: "the source-local async original thunk cannot name this private nested receiver"
                    )
                }
                if context != nil, bridgedReceiverType == nil {
                    return .rejected(
                        "HLXIDX020",
                        explanation: "this member receiver has no ABI-safe HLBC self Bridge"
                    )
                }
                if isAsync,
                   sourceBodyTransform == nil || asyncOriginalThunk == nil {
                    return .rejected(
                        "HLXIDX010",
                        explanation: "async source body exceeds permanent Bridge metadata limits"
                    )
                }
                return nil
            }()
        )
        let normalizedLabels = labels.map { $0.isEmpty ? "_" : $0 }
        let canonicalReference = Self.originalReference(
            baseName: baseName,
            labels: normalizedLabels
        )
        let nativeImportCanonicalParameterTypes = FrontendReceipt
            .FunctionTypeSpelling.overlayCallbackParameters(
                parameterTypes,
                formalFunctionType: interfaceType
            )
        let nativeImportCallbackLifetimes = bridgedParameterTypes.contains(
            where: \.containsClosureValue
        ) ? try CanonicalSIL.Lowerer(
            typeEnvironment: typeEnvironment
        ).parseNativeCallbackLifetimes(
            sil.loweredType,
            parameterTypes: bridgedParameterTypes
        ) : [:]
        let nativeImportDeclaredParameterTypes = FrontendReceipt
            .FunctionTypeSpelling.applyingAuthoritativeLifetimes(
                nativeImportCallbackLifetimes,
                to: nativeImportCanonicalParameterTypes
            ) ?? nativeImportCanonicalParameterTypes
        let nativeImportGeneratedExplicitParameterTypes =
            nativeImportDeclaredParameterTypes.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: importedSwiftTypeAliases
                )
            }
        let nativeImportSignatureSwiftTypes = nativeImportDeclaredParameterTypes
            + (bridgedReceiverType.flatMap { _ in context?.canonicalName }.map { [$0] } ?? [])
        let nativeImportParameterSwiftTypes = nativeImportGeneratedExplicitParameterTypes
            + (bridgedReceiverType.flatMap { _ in context?.canonicalName }.map { [$0] } ?? [])
        let nativeImportCallbacks = FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: nativeImportSignatureSwiftTypes,
            parameterTypes: bridgedParameterTypes,
            authoritativeLifetimes: nativeImportCallbackLifetimes
        ) ?? []
        let generatedNativeImportParameterSwiftTypes = FrontendReceipt
            .NativeBridgeProfile.generatedParameterSpellings(
                nativeImportParameterSwiftTypes,
                parameterTypes: bridgedParameterTypes
            ) ?? nativeImportParameterSwiftTypes
        let nativeImportModules = nativeImportSignatureSwiftTypes
            == generatedNativeImportParameterSwiftTypes
            && resultType == generatedResultType
            ? [] : imports
        let nativeImportSignature = Core.LoweredSignature(
            parameters: nativeImportSignatureSwiftTypes,
            result: resultType,
            isThrowing: mayThrow,
            isAsync: isAsync,
            isolation: isolation
        )
        let nativeImportDeclaration = NativeImportDiscovery.Declaration(
            moduleName: moduleName,
            sourceFileLogicalID: source.logicalPath,
            mangledName: mangledName,
            canonicalCallee: [moduleName, context?.canonicalName, canonicalReference]
                .compactMap { $0 }.joined(separator: "."),
            accessLevel: access,
            dispatch: context == nil
                ? .globalFunction
                : (isTypeMethod ? .staticMethod : .instanceMethod),
            ownerType: context?.canonicalName,
            baseName: baseName,
            argumentLabels: normalizedLabels,
            parameterSwiftTypes: generatedNativeImportParameterSwiftTypes,
            parameterProjection: .identity(
                parameterCount: bridgedParameterTypes.count
            ),
            resultSwiftType: generatedResultType,
            importedModules: nativeImportModules,
            parameterTypes: bridgedParameterTypes,
            resultType: valueResultType,
            signature: nativeImportSignature,
            callbacks: nativeImportCallbacks,
            inferredEffects: effects,
            isGeneric: isGeneric,
            hasInOut: hasInOut,
            hasTypedThrows: hasTypedThrows,
            hasUnsupportedAttributes: !customAttributes.isEmpty
                || hasUnrepresentableCustomAttribute
                || attributeKinds.contains("available_attr")
                || !hasSupportedSILIsolation
                || context?.kind == .actor
                || context?.isAvailabilityConstrained == true
        )
        guard selectedByConfiguration, canInstallBridge else {
            return .init(
                candidate: candidate,
                root: nil,
                bridge: nil,
                nativeImportDeclaration: nativeImportDeclaration,
                referenceReceiverType: referenceReceiverType
            )
        }
        let sourceDeclaration = Core.DynamicReplacement.Declaration(
            identity: usr,
            kind: .function,
            originalReference: originalReference,
            replacementHeader: replacementDeclaration,
            members: [
                .init(
                    role: .functionBody,
                    fallbackBody: "return "
                        + (mayThrow ? "try " : "")
                        + (isAsync ? "await " : "")
                        + "\(baseName)(\(originalArguments))"
                ),
            ],
            enclosingPrefix: enclosure?.0 ?? "",
            enclosingSuffix: enclosure?.1 ?? ""
        )
        let anchorData = source.contents.subdata(
            in: declarationOffset..<(bodyRange.start + 1)
        )
        guard let declarationAnchor = String(data: anchorData, encoding: .utf8) else {
            throw FrontendReceipt.Error.malformedAST(
                "\(mangledName) declaration anchor is not UTF-8"
            )
        }
        let anchorBytes = Data(declarationAnchor.utf8)
        guard let declarationOccurrence = Self.occurrence(
            of: anchorBytes,
            at: declarationOffset,
            in: source.contents
        ) else {
            throw FrontendReceipt.Error.malformedAST(
                "\(mangledName) declaration occurrence is inconsistent"
            )
        }
        let nativeReplacement = ShellBuildReceipt.NativeReplacement(
            declarationAnchorUTF8Offset: declarationOffset,
            declarationAnchor: declarationAnchor,
            declarationOccurrence: declarationOccurrence,
            loweredType: sil.loweredType,
            importedModules: imports
        )
        let root = ShellBuildReceipt.Root(
            declarationMangledName: mangledName,
            declarationUTF8Offset: declarationOffset,
            expectedDeclarationPrefix: expectedPrefix,
            declarationInsertion: isAsync
                || attributeKinds.contains("dynamic_attr")
                || Self.containsWord("dynamic", in: modifierPrefix)
                ? nil : "dynamic ",
            sourceDeclaration: sourceDeclaration,
            memberRole: .functionBody,
            reloadRole: Self.reloadRole(baseName: baseName),
            nominalType: context.map {
                .init(moduleName: moduleName, canonicalName: $0.canonicalName,
                      sourceFileLogicalID: $0.sourceFileLogicalID)
            },
            sourceBodyTransform: sourceBodyTransform,
            nativeReplacement: isAsync ? nil : nativeReplacement
        )
        let bridge: ShellBuildReceipt.Bridge?
        let writebackCount = bridgedParameterConventions.filter {
            $0 == .inout
        }.count
        if (context == nil || bridgedReceiverType != nil),
           writebackCount <= 1,
           (!hasInOut || writebackCount == 1),
           !(isAsync && writebackCount > 0),
           !isGeneric, !hasTypedThrows,
           customAttributes.isEmpty, !hasUnrepresentableCustomAttribute,
           valueParameterTypes.allSatisfy({ $0 != .never }),
           valueResultType != .never {
            let receiverOffset = parameterNames.count
            let bridgeParameterExpressions = parameterNames
                + (bridgedReceiverType.map { _ in ["self"] } ?? [])
            let bridgeParameterSwiftTypes = generatedParameterTypes
                + (bridgedReceiverType.flatMap { _ in context?.canonicalName }
                    .map { [$0] } ?? [])
            let bridgedInvocation: String
            if bridgedReceiverType != nil {
                bridgedInvocation = "argument\(receiverOffset).\(replacementName)(\(bridgeArguments))"
            } else {
                bridgedInvocation = "\(replacementName)(\(bridgeArguments))"
            }
            bridge = .init(
                privateImportSourceFile: source.logicalPath,
                parameterExpressions: bridgeParameterExpressions,
                parameterSwiftTypes: bridgeParameterSwiftTypes,
                resultSwiftType: generatedResultType,
                originalInvocation: "\(baseName)(\(originalArguments))",
                bridgeInvocation: bridgedInvocation,
                sourceSupplementalDeclaration: asyncOriginalThunk
            )
        } else {
            bridge = nil
        }
        return .init(
            candidate: candidate,
            root: root,
            bridge: bridge,
            nativeImportDeclaration: nativeImportDeclaration,
            referenceReceiverType: referenceReceiverType
        )
    }

    func demangledType(_ value: Any?, using types: [String: String]) throws -> String {
        guard let mangled = value as? String, let type = types[mangled] else {
            throw FrontendReceipt.Error.malformedAST(
                "declaration contains an absent or undecodable Swift type"
            )
        }
        return type
    }

    func baseName(in item: [String: Any]) -> String? {
        guard let name = item["name"] as? [String: Any],
              let base = name["base_name"] as? [String: Any]
        else { return nil }
        return base["name"] as? String
    }

    func argumentLabels(in item: [String: Any]) -> [String] {
        guard let name = item["name"] as? [String: Any] else { return [] }
        return name["args"] as? [String] ?? []
    }

    func sourceRange(in item: [String: Any]) -> (start: Int, end: Int)? {
        guard let range = item["range"] as? [String: Any],
              let start = (range["start"] as? NSNumber)?.intValue,
              let end = (range["end"] as? NSNumber)?.intValue
        else { return nil }
        return (start, end)
    }
}

extension FrontendReceipt.Adapter {
    static func isSwiftIdentifier(_ value: String) -> Bool {
        Core.SwiftName.isIdentifier(value)
    }

    struct FunctionToken {
        var functionStart: String.Index
        var nameStart: String.Index
    }

    static func functionToken(in header: String, baseName: String) -> FunctionToken? {
        let pattern = #"\bfunc\s+"#
            + NSRegularExpression.escapedPattern(for: baseName)
            + #"\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.numberOfMatches(
                  in: header,
                  range: NSRange(header.startIndex..., in: header)
              ) == 1,
              let match = expression.firstMatch(
                  in: header,
                  range: NSRange(header.startIndex..., in: header)
              ),
              let matchRange = Range(match.range, in: header),
              let nameRange = header.range(
                  of: baseName,
                  options: .backwards,
                  range: matchRange
              )
        else { return nil }
        return .init(functionStart: matchRange.lowerBound, nameStart: nameRange.lowerBound)
    }

    static func containsWord(_ word: String, in value: String) -> Bool {
        value.range(
            of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
            options: .regularExpression
        ) != nil
    }

    static func hasAvailabilityAttribute(_ item: [String: Any]) -> Bool {
        (item["attrs"] as? [[String: Any]])?.contains {
            $0["_kind"] as? String == "available_attr"
        } == true
    }

    static func hasGenericSignature(_ item: [String: Any]) -> Bool {
        item["generic_signature"] != nil
    }

    static func customAttributeName(_ demangledType: String) -> String? {
        var value = demangledType.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".Type") { value.removeLast(5) }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ isSwiftIdentifier(String($0)) })
        else { return nil }
        return components.joined(separator: ".")
    }

    static func isMainActor(_ attribute: String) -> Bool {
        attribute == "MainActor" || attribute == "Swift.MainActor"
    }

    static func generatedSwiftTypeSpelling(_ value: String) -> String {
        value.replacingOccurrences(of: "__C.", with: "")
    }

    static func originalReference(baseName: String, labels: [String]) -> String {
        let arguments = labels.map { ($0.isEmpty ? "_" : $0) + ":" }.joined()
        return "\(baseName)(\(arguments))"
    }

    static func arguments(labels: [String], values: [String]) -> String {
        zip(labels, values).map { label, value in
            label.isEmpty || label == "_" ? value : "\(label): \(value)"
        }.joined(separator: ", ")
    }

    static func reloadRole(baseName: String) -> ReloadIndex.FunctionRole {
        switch baseName {
        case "loadView", "viewDidLoad", "viewWillAppear", "viewDidAppear":
            return .viewLoadOrInitialization
        case "viewWillLayoutSubviews", "viewDidLayoutSubviews",
             "updateViewConstraints", "layoutSubviews":
            return .layoutCallback
        case "draw", "updateConfiguration", "configure":
            return .drawingOrConfiguration
        default:
            if baseName.hasPrefix("tableView") || baseName.hasPrefix("collectionView")
                || baseName == "numberOfSections" {
                return .tableOrCollectionDataSource
            }
            if baseName.hasPrefix("did") || baseName.hasPrefix("handle") {
                return .eventHandler
            }
            return .modelOrService
        }
    }

    static func occurrence(of needle: Data, at offset: Int, in haystack: Data) -> UInt32? {
        guard !needle.isEmpty else { return nil }
        var occurrence: UInt32 = 0
        var lowerBound = haystack.startIndex
        while lowerBound <= haystack.endIndex - min(needle.count, haystack.count) {
            guard let match = haystack.range(
                  of: needle,
                  options: [],
                  in: lowerBound..<haystack.endIndex
            ) else { return nil }
            if match.lowerBound == offset { return occurrence }
            if match.lowerBound > offset { return nil }
            let next = occurrence.addingReportingOverflow(1)
            guard !next.overflow else { return nil }
            occurrence = next.partialValue
            lowerBound = match.upperBound
        }
        return nil
    }
}
