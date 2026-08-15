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
        try validate(request)
        let orderedSources = request.sources.sorted { $0.logicalPath < $1.logicalPath }
        let sourceStates = try loadSources(orderedSources)
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: request.compilerURL
        )
        let frontend = SwiftFrontend.Driver(compilerURL: request.compilerURL)
        let astOutput = try frontend.emitTypedAST(
            sourceFiles: orderedSources.map(\.url),
            invocation: request.metadata.frontendInvocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(astOutput)
        try validateCompilerVersion(documents, toolchain: toolchain)
        let demangled = try FrontendReceipt.Demangler(compilerURL: request.compilerURL)
            .demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let canonicalSIL = try frontend.emitCanonicalSIL(
            sourceFiles: orderedSources.map(\.url),
            invocation: request.metadata.frontendInvocation
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let moduleName = request.metadata.frontendInvocation.moduleName
        let configuredCallingSurface = try callingSurfaceConfiguration(
            request.configuration,
            policy: request.callingSurfacePolicy,
            moduleName: moduleName,
            sources: orderedSources
        )
        let effectiveConfiguration = configuration(
            configuredCallingSurface,
            allowing: Array(NativeImportCatalog.Builtins.automaticCallees),
            moduleName: moduleName
        )
        try effectiveConfiguration.validate()
        let sourceByPhysicalPath = Dictionary(
            uniqueKeysWithValues: sourceStates.map {
                ($0.url.resolvingSymlinksInPath().standardizedFileURL.path, $0)
            }
        )
        let sourceNominals = try discoverSourceNominals(
            documents: documents,
            sourcesByPhysicalPath: sourceByPhysicalPath,
            moduleName: moduleName,
            demangled: demangled
        )
        let sourceNominalsByName = Dictionary(uniqueKeysWithValues: sourceNominals.map {
            ($0.canonicalName, $0)
        })
        let importedReferences = try discoverImportedReferences(
            documents: documents,
            sourcesByPhysicalPath: sourceByPhysicalPath,
            moduleName: moduleName,
            demangled: demangled
        )
        var importedOperationSurface = try discoverImportedOperationSurface(
            documents: documents,
            sourcesByPhysicalPath: sourceByPhysicalPath,
            moduleName: moduleName,
            demangled: demangled,
            silFile: silFile
        )
        var importedTypes = try mergeImportedNativeTypes(
            references: importedReferences,
            operationTypes: importedOperationSurface.types
        )
        if request.callingSurfacePolicy == .managedDebugModule {
            let managedSurface = try FrontendReceipt.ManagedDebugSurface.expand(
                importedTypes: importedTypes,
                minimumOS: request.metadata.minimumOS,
                frontend: frontend,
                invocation: request.metadata.frontendInvocation
            )
            importedTypes = managedSurface.importedTypes
            importedOperationSurface.operations = try mergeImportedOperations(
                importedOperationSurface.operations + managedSurface.operations
            )
        }
        let provisionalNativeTypes = try makeNativeTypes(
            request.nativeImportCatalog,
            sourceNominals: sourceNominals,
            importedTypes: importedTypes,
            mainActorReferenceTypes: [],
            metadata: request.metadata
        )
        let nativeTypeIDs = try makeNativeTypeLookup(
            records: provisionalNativeTypes,
            importedTypes: importedTypes,
            sourceNominals: sourceNominals
        )
        let importedSwiftTypeAliases = try makeImportedSwiftTypeAliases(
            importedTypes
        )
        importedOperationSurface.operations = try mergeImportedOperations(
            importedOperationSurface.operations.map {
                applyingSwiftTypeAliases($0, aliases: importedSwiftTypeAliases)
            }
        )
        let importedOperationDeclarations = try makeImportedOperationDeclarations(
            importedOperationSurface.operations,
            moduleName: moduleName,
            nativeTypes: nativeTypeIDs
        )
        var drafts: [Draft] = []
        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourceByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ],
                  let items = document["items"] as? [Any]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "source document does not map to the requested source set"
                )
            }
            let imports = imports(in: items)
            try walk(
                items: items,
                context: nil,
                source: source,
                imports: imports,
                moduleName: moduleName,
                configuration: effectiveConfiguration,
                demangled: demangled,
                silFile: silFile,
                nativeTypes: nativeTypeIDs,
                importedSwiftTypeAliases: importedSwiftTypeAliases,
                sourceNominals: sourceNominalsByName,
                drafts: &drafts
            )
        }
        guard Set(drafts.map { $0.candidate.mangledName }).count == drafts.count else {
            throw FrontendReceipt.Error.malformedAST(
                "typed AST contains duplicate function symbols"
            )
        }
        let archivedSymbols = Set(drafts.map { $0.candidate.mangledName })
        for index in drafts.indices {
            let symbol = drafts[index].candidate.mangledName
            guard let function = silFile.function(mangledName: symbol) else {
                throw FrontendReceipt.Error.missingSILFunction(symbol)
            }
            drafts[index].candidate.implementationFingerprint =
                ReleaseCompiler.ImplementationFingerprint.compute(
                    root: function,
                    in: silFile,
                    archivedSymbols: archivedSymbols
                )
        }
        try validateNativeAnchors(drafts, sources: sourceStates)
        let mainActorReferenceTypes = Set(drafts.compactMap { draft in
            draft.candidate.effects.requiresMainActor ? draft.referenceReceiverType : nil
        })
        let nativeTypeRecords = try makeNativeTypes(
            request.nativeImportCatalog,
            sourceNominals: sourceNominals,
            importedTypes: importedTypes,
            mainActorReferenceTypes: mainActorReferenceTypes,
            metadata: request.metadata
        )
        guard nativeTypeRecords.map(\.id) == provisionalNativeTypes.map(\.id) else {
            throw FrontendReceipt.Error.invalidRequest(
                "native type identity changed while resolving actor isolation"
            )
        }

        let builtinNativeImports = try NativeImportCatalog.Builtins.records(
            metadata: request.metadata
        )
        applyNativeImportEffectEnvelope(
            builtinNativeImports,
            to: &drafts,
            configuration: effectiveConfiguration,
            moduleName: moduleName
        )
        var explicitNativeImports = try NativeImportCatalog.Builtins.merging(
            makeNativeImportCandidates(
                request.nativeImportCatalog,
                metadata: request.metadata,
                configuration: effectiveConfiguration,
                nativeTypes: nativeTypeIDs
            ),
            metadata: request.metadata
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
        let preliminary = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: request.metadata,
                compatibility: compatibility,
                configuration: effectiveConfiguration,
                sources: sourceRecords,
                declarations: drafts.map(\.candidate),
                nativeImportCandidates: explicitNativeImports,
                nativeTypes: nativeTypeRecords
            )
        )
        let entrySymbols = Set(preliminary.archive.functions.compactMap { function in
            function.patchability.isEligible ? function.mangledName : nil
        })
        explicitNativeImports = exactFallbackImports(
            explicitNativeImports,
            excludingEntrySymbols: entrySymbols
        )
        var discovery = try NativeImportDiscovery.Engine().discover(
            declarations: drafts.compactMap { draft in
                entrySymbols.contains(draft.candidate.mangledName)
                    ? nil : draft.nativeImportDeclaration
            } + importedOperationDeclarations,
            metadata: request.metadata,
            configuration: effectiveConfiguration
        )
        // Selection is anchored to SIL symbols so an explicit Catalog entry may
        // safely rename a source-discovered operation while overriding its factory.
        let scopedNativeImportSymbols = Set(
            discovery.candidates.flatMap(\.record.silMangledNames)
        )
        let nativeImportCandidates = try mergeNativeImportCandidates(
            explicit: explicitNativeImports,
            discovered: &discovery,
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
            allowing: scopedNativeImportCallees,
            moduleName: request.metadata.frontendInvocation.moduleName
        )

        let indexed = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: request.metadata,
                compatibility: compatibility,
                configuration: resolvedConfiguration,
                sources: sourceRecords,
                declarations: drafts.map(\.candidate),
                nativeImportCandidates: nativeImportCandidates,
                nativeTypes: nativeTypeRecords
            )
        )
        let finalEntrySymbols = Set(indexed.archive.functions.compactMap { function in
            function.patchability.isEligible ? function.mangledName : nil
        })
        guard finalEntrySymbols == entrySymbols else {
            throw FrontendReceipt.Error.invalidRequest(
                "Entry eligibility changed while resolving the managed NativeImport surface"
            )
        }
        let nativeImportBindings = try (
            makeNativeImportBindings(
                catalog: request.nativeImportCatalog,
                archive: indexed.archive
            ) + makeDiscoveredNativeImportBindings(
                discovery.candidates,
                archive: indexed.archive
            ) + NativeImportCatalog.Builtins.bindings(archive: indexed.archive)
        ).sorted { $0.key.rawValue < $1.key.rawValue }
        let nativeTypeBindings = try makeNativeTypeBindings(
            catalog: request.nativeImportCatalog,
            archive: indexed.archive,
            sourceNominals: sourceNominals,
            importedTypes: importedTypes
        )
        let eligibleNames = finalEntrySymbols
        var roots: [ShellBuildReceipt.Root] = []
        for draft in drafts {
            guard var root = draft.root else { continue }
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
            metadata: request.metadata,
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
            nativeTypeBindings: nativeTypeBindings
        )
        try receipt.validate()
        return .init(
            receipt: receipt,
            diagnostics: (indexed.diagnostics + discovery.diagnostics).sorted {
                ($0.location?.file ?? "", $0.location?.line ?? 0, $0.code, $0.message)
                    < ($1.location?.file ?? "", $1.location?.line ?? 0, $1.code, $1.message)
            },
            toolchain: toolchain
        )
    }

    private func validate(_ request: FrontendReceipt.Request) throws {
        do {
            try request.configuration.validate()
        } catch {
            throw FrontendReceipt.Error.invalidRequest(String(describing: error))
        }
        guard !request.sources.isEmpty,
              Set(request.sources.map(\.logicalPath)).count == request.sources.count,
              Set(request.sources.map {
                  $0.url.resolvingSymlinksInPath().standardizedFileURL.path
              }).count == request.sources.count,
              request.metadata.machOUUIDs.isEmpty,
              request.metadata.transformPipelineHash == ShellBuild.transformPipelineHash,
              request.configuration.modules[
                  request.metadata.frontendInvocation.moduleName
              ] != nil
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "sources, pre-link identity, transform version, or module configuration is invalid"
            )
        }
        try request.metadata.frontendInvocation.validate()
        try request.nativeImportCatalog.validate()
        for source in request.sources {
            let components = source.logicalPath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !source.logicalPath.isEmpty, !source.logicalPath.hasPrefix("/"),
                  !components.contains(""), !components.contains(".."),
                  source.url.pathExtension == "swift",
                  !source.url.path.contains("\n"), !source.url.path.contains("\r")
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "unsafe logical Swift source path \(source.logicalPath)"
                )
            }
        }
    }

    private func validateCompilerVersion(
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
    }

    enum SourceNominalKind: Equatable, Sendable {
        case reference
        case value
        case actor
    }

    struct SourceNominal: Sendable {
        var canonicalName: String
        var sourceFileLogicalID: String
        var kind: SourceNominalKind
    }

    struct NominalContext {
        var canonicalName: String
        var moduleQualifiedName: String
        var kind: SourceNominalKind?
        var referenceTypeID: Core.TypeID?
    }

    struct Draft {
        var candidate: ReleaseCompiler.DeclarationCandidate
        var root: ShellBuildReceipt.Root?
        var bridge: ShellBuildReceipt.Bridge?
        var nativeImportDeclaration: NativeImportDiscovery.Declaration
        var referenceReceiverType: String?
    }

    func discoverSourceNominals(
        documents: [FrontendReceipt.TypedAST.Object],
        sourcesByPhysicalPath: [String: SourceState],
        moduleName: String,
        demangled: [String: String]
    ) throws -> [SourceNominal] {
        var byName: [String: SourceNominal] = [:]
        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ],
                  let items = document["items"] as? [Any]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "nominal discovery source does not map to the requested source set"
                )
            }
            try collectSourceNominals(
                items: items,
                parentCanonicalName: nil,
                isInsideGenericContext: false,
                source: source,
                moduleName: moduleName,
                demangled: demangled,
                byName: &byName
            )
        }
        return byName.values.sorted { $0.canonicalName < $1.canonicalName }
    }

    func collectSourceNominals(
        items: [Any],
        parentCanonicalName: String?,
        isInsideGenericContext: Bool,
        source: SourceState,
        moduleName: String,
        demangled: [String: String],
        byName: inout [String: SourceNominal]
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
                } else {
                    .value
                }
                // A declaration inside a generic context has no single concrete
                // Swift runtime type that can back a frozen TypeID.
                let entersGenericContext = isInsideGenericContext
                    || item["generic_sig"] != nil
                if !entersGenericContext {
                    let nominal = SourceNominal(
                        canonicalName: canonicalName,
                        sourceFileLogicalID: source.logicalPath,
                        kind: nominalKind
                    )
                    if let existing = byName[canonicalName],
                       existing.sourceFileLogicalID != nominal.sourceFileLogicalID
                        || existing.kind != nominal.kind {
                        throw FrontendReceipt.Error.malformedAST(
                            "source nominal \(canonicalName) has conflicting declarations"
                        )
                    }
                    byName[canonicalName] = nominal
                }
                try collectSourceNominals(
                    items: members,
                    parentCanonicalName: relativeName,
                    isInsideGenericContext: entersGenericContext,
                    source: source,
                    moduleName: moduleName,
                    demangled: demangled,
                    byName: &byName
                )
            case "extension_decl":
                guard let mangled = item["extended_type"] as? String,
                      let fullName = demangled[mangled],
                      let members = item["members"] as? [Any]
                else { continue }
                let prefix = moduleName + "."
                let relativeName = fullName.hasPrefix(prefix)
                    ? String(fullName.dropFirst(prefix.count))
                    : fullName
                try collectSourceNominals(
                    items: members,
                    parentCanonicalName: relativeName,
                    isInsideGenericContext: isInsideGenericContext
                        || item["generic_sig"] != nil
                        || fullName.contains("<"),
                    source: source,
                    moduleName: moduleName,
                    demangled: demangled,
                    byName: &byName
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
        guard policy == .managedDebugModule else { return configuration }
        guard var module = configuration.modules[moduleName] else {
            throw FrontendReceipt.Error.invalidRequest(
                "managed Debug calling surface has no module configuration for \(moduleName)"
            )
        }
        var result = configuration
        module.nativeImports = .init(
            candidateIndex: .sourceAndCatalog,
            emit: .scoped,
            allow: module.nativeImports.allow,
            sourceScope: .init(
                include: sources.map(\.logicalPath).sorted(),
                declarations: ["\(moduleName).*"],
                visibility: .all,
                profile: .boundedReadWrite,
                maximumDurationMicroseconds: 2_000,
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
                "allowlisted NativeImport has no catalog factory: \(missing)"
            )
        }

        var records: [InterfaceArchive.NativeImportRecord] = []
        var keys = Set<Core.NativeImportKey>()
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
            let key = try Core.NativeImportKey.derive(
                namespace: metadata.shellNamespaceID,
                canonicalCallee: candidate.canonicalCallee,
                signature: candidate.signature,
                effects: candidate.effects,
                contract: candidate.contract
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
                    canonicalCallee: candidate.canonicalCallee,
                    silMangledNames: candidate.silMangledNames,
                    parameterTypes: parameterTypes,
                    resultType: resultType,
                    signature: candidate.signature,
                    effects: candidate.effects,
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
        guard Set(records.map(\.key)).count == records.count,
              Set(records.flatMap(\.silMangledNames)).count
                == records.reduce(0, { $0 + $1.silMangledNames.count })
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "module \(moduleName) NativeImport discovery conflicts with explicit identities"
            )
        }
        return records.sorted { $0.key.rawValue < $1.key.rawValue }
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
    ) -> [ShellBuildReceipt.NativeImportBinding] {
        let emitted = Dictionary(uniqueKeysWithValues: archive.nativeImports.compactMap {
            item -> (Core.NativeImportKey, InterfaceArchive.NativeImportRecord)? in
            guard item.isEmittedToDevice, item.id != nil else { return nil }
            return (item.key, item)
        })
        return candidates.compactMap { candidate in
            guard let record = emitted[candidate.record.key], let id = record.id else {
                return nil
            }
            let generated = candidate.generatedBinding
            let expression = BridgeGeneration.GeneratedNativeImport.bindingExpression(
                sourceFileLogicalID: generated.sourceFileLogicalID,
                id: id,
                key: record.key
            )
            let dispatch: ShellBuildReceipt.GeneratedNativeImport.Dispatch = switch generated.dispatch {
            case .globalFunction: .globalFunction
            case .initializer: .initializer
            case .staticMethod: .staticMethod
            case .nativeUpcast: .nativeUpcast
            case .staticGetter: .staticGetter
            case .instanceMethod: .instanceMethod
            case .instanceGetter: .instanceGetter
            case .instanceSetter: .instanceSetter
            case .instanceValueSetter: .instanceValueSetter
            }
            return .init(
                key: record.key,
                invokerExpression: expression,
                importedModules: generated.importedModules,
                generated: .init(
                    declarationMangledName: generated.declarationMangledName,
                    sourceFileLogicalID: generated.sourceFileLogicalID,
                    dispatch: dispatch,
                    ownerType: generated.ownerType,
                    baseName: generated.baseName,
                    argumentLabels: generated.argumentLabels,
                    parameterSwiftTypes: generated.parameterSwiftTypes,
                    resultSwiftType: generated.resultSwiftType
                )
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func makeNativeTypes(
        _ catalog: NativeImportCatalog.Document,
        sourceNominals: [SourceNominal],
        importedTypes: [ImportedNativeType],
        mainActorReferenceTypes: Set<String>,
        metadata: InterfaceArchive.ReleaseMetadata
    ) throws -> [InterfaceArchive.TypeRecord] {
        let catalogByName = Dictionary(uniqueKeysWithValues: catalog.nativeTypes.map {
            ($0.canonicalName, $0)
        })
        let sourceTypeNames = Set(sourceNominals.map(\.canonicalName))
        let sourceReferences = sourceNominals.filter { $0.kind == .reference }
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
                continue
            }
            records.append(
                .init(
                    id: .derive(
                        namespace: metadata.shellNamespaceID,
                        canonicalType: imported.canonicalName
                    ),
                    canonicalName: imported.canonicalName,
                    kind: imported.kind,
                    layoutFingerprint: .sha256(
                        "HLX.ImportedNativeType.v1:\(metadata.frontendInvocation.targetTriple):"
                            + "\(imported.kind.rawValue):\(imported.canonicalName)"
                    ),
                    isCopyable: true,
                    requiresMainActor: imported.requiresMainActor,
                    isEmittedToDevice: true,
                    estimatedSize: 8
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

    func makeNativeImportBindings(
        catalog: NativeImportCatalog.Document,
        archive: InterfaceArchive.Archive
    ) throws -> [ShellBuildReceipt.NativeImportBinding] {
        var catalogByKey: [Core.NativeImportKey: NativeImportCatalog.Candidate] = [:]
        for candidate in catalog.candidates {
            let key = try Core.NativeImportKey.derive(
                namespace: archive.metadata.shellNamespaceID,
                canonicalCallee: candidate.canonicalCallee,
                signature: candidate.signature,
                effects: candidate.effects,
                contract: candidate.contract
            )
            catalogByKey[key] = candidate
        }
        return try archive.nativeImports.compactMap { item in
            guard item.isEmittedToDevice else { return nil }
            guard let candidate = catalogByKey[item.key] else { return nil }
            guard let id = item.id else {
                throw FrontendReceipt.Error.invalidRequest(
                    "emitted NativeImport \(item.canonicalCallee) has no deterministic factory binding"
                )
            }
            let expression = "\(candidate.factoryType).make("
                + "id: Core.NativeImportID(rawValue: \(id.rawValue)), "
                + "key: Core.NativeImportKey(rawValue: try! Core.Digest(hex: "
                + "\(String(reflecting: item.key.rawValue.hex)))))"
            return .init(
                key: item.key,
                invokerExpression: expression,
                importedModules: candidate.importedModules
            )
        }.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    func makeNativeTypeBindings(
        catalog: NativeImportCatalog.Document,
        archive: InterfaceArchive.Archive,
        sourceNominals: [SourceNominal],
        importedTypes: [ImportedNativeType]
    ) throws -> [ShellBuildReceipt.NativeTypeBinding] {
        let byName = Dictionary(uniqueKeysWithValues: catalog.nativeTypes.map {
            ($0.canonicalName, $0)
        })
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceNominals
            .filter { $0.kind == .reference }
            .map { ($0.canonicalName, $0) })
        let importedByName = Dictionary(uniqueKeysWithValues: importedTypes.map {
            ($0.canonicalName, $0)
        })
        return try archive.nativeTypes.compactMap { item in
            guard item.isEmittedToDevice else { return nil }
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
                let representation: ShellBuildReceipt.GeneratedNativeType.Representation =
                    switch imported.representation {
                    case .reference: .reference
                    case .rawRepresentable: .rawRepresentable
                    case .opaqueValue: .opaqueValue
                    }
                let generated = ShellBuildReceipt.GeneratedNativeType(
                    sourceFileLogicalID: imported.sourceFileLogicalID,
                    swiftType: imported.swiftType,
                    representation: representation
                )
                let expression = BridgeGeneration.GeneratedNativeType.bindingExpression(
                    sourceFileLogicalID: generated.sourceFileLogicalID,
                    id: item.id,
                    canonicalName: item.canonicalName,
                    layoutFingerprint: item.layoutFingerprint,
                    requiresMainActor: item.requiresMainActor,
                    estimatedSize: item.estimatedSize
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
                estimatedSize: item.estimatedSize
            )
            return .init(
                canonicalName: item.canonicalName,
                layoutFingerprint: item.layoutFingerprint,
                requiresMainActor: item.requiresMainActor,
                operationsExpression: expression,
                generated: generated
            )
        }.sorted {
            ($0.canonicalName, $0.layoutFingerprint.hex)
                < ($1.canonicalName, $1.layoutFingerprint.hex)
        }
    }

    func loadSources(_ sources: [FrontendReceipt.Source]) throws -> [SourceState] {
        try sources.map { source in
            let url = source.url.resolvingSymlinksInPath().standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size <= 64 * 1_024 * 1_024
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source is missing, non-regular, or too large: \(url.path)"
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
            guard root.declarationUTF8Offset <= source.count,
                  anchor.count <= source.count - root.declarationUTF8Offset,
                  source[root.declarationUTF8Offset..<(root.declarationUTF8Offset + anchor.count)]
                    == anchor,
                  Self.occurrence(
                      of: anchor,
                      at: root.declarationUTF8Offset,
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
        imports: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silFile: CanonicalSIL.File,
        nativeTypes: [String: Core.TypeID],
        importedSwiftTypeAliases: [String: String],
        sourceNominals: [String: SourceNominal],
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
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silFile: silFile,
                    nativeTypes: nativeTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases
                ) {
                    drafts.append(draft)
                }
            case "var_decl":
                drafts.append(contentsOf: try makeStoredPropertyDrafts(
                    item,
                    context: context,
                    source: source,
                    importedModules: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silFile: silFile,
                    nativeTypes: nativeTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases
                ))
            case "class_decl", "struct_decl", "enum_decl", "actor_decl":
                guard let name = baseName(in: item),
                      let members = item["members"] as? [Any]
                else { continue }
                let canonicalName = [context?.canonicalName, name]
                    .compactMap { $0 }.joined(separator: ".")
                let moduleQualifiedName = "\(moduleName).\(canonicalName)"
                let nominal = sourceNominals[moduleQualifiedName]
                try walk(
                    items: members,
                    context: .init(
                        canonicalName: canonicalName,
                        moduleQualifiedName: moduleQualifiedName,
                        kind: nominal?.kind,
                        referenceTypeID: nominal?.kind == .reference
                            ? nativeTypes[moduleQualifiedName] : nil
                    ),
                    source: source,
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silFile: silFile,
                    nativeTypes: nativeTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases,
                    sourceNominals: sourceNominals,
                    drafts: &drafts
                )
            case "extension_decl":
                guard let mangled = item["extended_type"] as? String,
                      let fullName = demangled[mangled],
                      let members = item["members"] as? [Any]
                else { continue }
                let prefix = moduleName + "."
                let canonicalName = fullName.hasPrefix(prefix)
                    ? String(fullName.dropFirst(prefix.count))
                    : fullName
                let moduleQualifiedName = fullName.hasPrefix(prefix)
                    ? fullName : "\(moduleName).\(fullName)"
                let nominal = sourceNominals[moduleQualifiedName]
                try walk(
                    items: members,
                    context: .init(
                        canonicalName: canonicalName,
                        moduleQualifiedName: moduleQualifiedName,
                        kind: nominal?.kind,
                        referenceTypeID: nominal?.kind == .reference
                            ? nativeTypes[moduleQualifiedName] : nil
                    ),
                    source: source,
                    imports: imports,
                    moduleName: moduleName,
                    configuration: configuration,
                    demangled: demangled,
                    silFile: silFile,
                    nativeTypes: nativeTypes,
                    importedSwiftTypeAliases: importedSwiftTypeAliases,
                    sourceNominals: sourceNominals,
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
        imports: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silFile: CanonicalSIL.File,
        nativeTypes: [String: Core.TypeID],
        importedSwiftTypeAliases: [String: String]
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
              bodyRange.start < source.contents.count
        else {
            return nil
        }
        let mangledName = "$s" + usr.dropFirst(2)
        guard let sil = silFile.function(mangledName: mangledName) else {
            throw FrontendReceipt.Error.missingSILFunction(mangledName)
        }
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
        var header = String(rawHeader[token.functionStart...])
        let relativeNameStart = rawHeader.distance(
            from: token.functionStart,
            to: token.nameStart
        )
        let nameStart = header.index(header.startIndex, offsetBy: relativeNameStart)
        let nameEnd = header.index(nameStart, offsetBy: baseName.count)
        let expectedPrefix = String(header[..<nameEnd])
        let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
            usr: usr,
            baseName: baseName
        )
        header.replaceSubrange(nameStart..<nameEnd, with: replacementName)
        header = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let declarationOffset = functionRange.start
            + rawHeader[..<token.functionStart].utf8.count

        let parametersObject = item["params"] as? [String: Any]
        let parameterItems = parametersObject?["params"] as? [[String: Any]] ?? []
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
        let originalArguments = Self.arguments(labels: labels, values: parameterNames)
        let bridgeArguments = Self.arguments(
            labels: labels,
            values: parameterNames.indices.map { "argument\($0)" }
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
        let mainActor = decodedCustomAttributes.contains(where: Self.isMainActor)
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
        let mayThrow = Self.containsWord("throws", in: header)
            || Self.containsWord("rethrows", in: header)
            || sil.loweredType.contains("@error")
        let hasTypedThrows = header.range(
            of: #"\bthrows\s*\("#,
            options: .regularExpression
        ) != nil
        let isGeneric = header[header.index(header.startIndex, offsetBy: 5)...]
            .hasPrefix("\(replacementName)<")
            || item["generic_sig"] != nil
        let hasInOut = parameterItems.contains { $0["inout"] as? Bool == true }
            || (item["implicit_self_decl"] as? [String: Any])?["inout"] as? Bool == true
        let forbiddenAttributes: Set<String> = [
            "transparent_attr", "inlinable_attr", "always_emit_into_client_attr",
            "cdecl_attr", "silgen_name_attr",
        ]
        let canDynamicallyReplace = attributeKinds.isDisjoint(with: forbiddenAttributes)
            && !hasUnrepresentableCustomAttribute
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
                nativeTypes: nativeTypes
            ) ?? .never
        }
        let valueResultType = FrontendReceipt.ValueTypeParser.parse(
            resultType,
            allowVoid: true,
            nativeTypes: nativeTypes
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
        let bridgedParameterTypes = valueParameterTypes
            + (referenceReceiverID.map { [.native($0)] } ?? [])
        let sourceParameterConventions: [Bytecode.ParameterConvention] = parameterItems.map {
            $0["inout"] as? Bool == true ? .inout : .owned
        } + (referenceReceiverID.map { _ in [.borrowed] } ?? [])
        let bridgedParameterConventions = if bridgedParameterTypes.contains(
            where: \.requiresLinearOwnership
        ) {
            try CanonicalSIL.Lowerer().parseParameterConventions(
                sil.loweredType,
                parameterTypes: bridgedParameterTypes
            )
        } else {
            sourceParameterConventions
        }
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
        if Self.containsWord("borrowing", in: modifierPrefix) {
            declarationPrefix += "borrowing "
        } else if Self.containsWord("consuming", in: modifierPrefix) {
            declarationPrefix += "consuming "
        }
        if isTypeMethod {
            declarationPrefix += Self.containsWord("class", in: modifierPrefix)
                ? "class " : "static "
        }
        if attributeKinds.contains("mutating_attr") { declarationPrefix += "mutating " }
        let replacementDeclaration = declarationPrefix + header
        let canonicalHeader = replacementDeclaration
            .replacingOccurrences(of: replacementName, with: baseName)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let interfaceType = try demangledType(item["interface_type"], using: demangled)
        let isolation = mainActor ? "MainActor" : customAttributes.first
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
            hasTypedThrows: hasTypedThrows,
            hasCompleteDynamicCoverage: canDynamicallyReplace,
            forcedPatchability: {
                if !customAttributes.isEmpty || hasUnrepresentableCustomAttribute {
                    return .rejected(
                        "HLXIDX012",
                        explanation: "custom function attributes are Native-only in HLBC v1"
                    )
                }
                if context != nil, referenceReceiverID == nil {
                    return .rejected(
                        "HLXIDX020",
                        explanation: "this member receiver has no ABI-safe HLBC self Bridge"
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
        let nativeImportSignatureSwiftTypes = parameterTypes
            + (referenceReceiverID.flatMap { _ in context?.canonicalName }.map { [$0] } ?? [])
        let nativeImportParameterSwiftTypes = generatedParameterTypes
            + (referenceReceiverID.flatMap { _ in context?.canonicalName }.map { [$0] } ?? [])
        let nativeImportModules = nativeImportSignatureSwiftTypes
            == nativeImportParameterSwiftTypes
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
            parameterSwiftTypes: nativeImportParameterSwiftTypes,
            resultSwiftType: generatedResultType,
            importedModules: nativeImportModules,
            parameterTypes: bridgedParameterTypes,
            resultType: valueResultType,
            signature: nativeImportSignature,
            inferredEffects: effects,
            isGeneric: isGeneric,
            hasInOut: hasInOut,
            hasTypedThrows: hasTypedThrows,
            hasUnsupportedAttributes: !customAttributes.isEmpty
                || hasUnrepresentableCustomAttribute
        )
        guard selectedByConfiguration, canDynamicallyReplace else {
            return .init(
                candidate: candidate,
                root: nil,
                bridge: nil,
                nativeImportDeclaration: nativeImportDeclaration,
                referenceReceiverType: referenceReceiverType
            )
        }
        let enclosure = context.map { ("extension \($0.canonicalName) {", "}") }
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
            declarationAnchor: declarationAnchor,
            declarationOccurrence: declarationOccurrence,
            loweredType: sil.loweredType,
            originalReference: originalReference,
            replacementDeclaration: replacementDeclaration,
            enclosingPrefix: enclosure?.0 ?? "",
            enclosingSuffix: enclosure?.1 ?? "",
            importedModules: imports
        )
        let root = ShellBuildReceipt.Root(
            declarationMangledName: mangledName,
            declarationUTF8Offset: declarationOffset,
            expectedDeclarationPrefix: expectedPrefix,
            reloadRole: Self.reloadRole(baseName: baseName),
            nominalType: context.map {
                .init(moduleName: moduleName, canonicalName: $0.canonicalName)
            },
            nativeReplacement: nativeReplacement
        )
        let bridge: ShellBuildReceipt.Bridge?
        if (context == nil || referenceReceiverID != nil),
           !hasInOut, !isGeneric, !hasTypedThrows,
           customAttributes.isEmpty, !hasUnrepresentableCustomAttribute,
           valueParameterTypes.allSatisfy({ $0 != .never }),
           valueResultType != .never {
            let receiverOffset = parameterNames.count
            let bridgeParameterExpressions = parameterNames
                + (referenceReceiverID.map { _ in ["self"] } ?? [])
            let bridgeParameterSwiftTypes = generatedParameterTypes
                + (referenceReceiverID.flatMap { _ in context?.canonicalName }
                    .map { [$0] } ?? [])
            let bridgedInvocation: String
            if referenceReceiverID != nil {
                bridgedInvocation = "argument\(receiverOffset).\(replacementName)(\(bridgeArguments))"
            } else {
                bridgedInvocation = "\(replacementName)(\(bridgeArguments))"
            }
            bridge = .init(
                privateImportSourceFile: source.logicalPath,
                originalReference: originalReference,
                replacementDeclaration: replacementDeclaration,
                parameterExpressions: bridgeParameterExpressions,
                parameterSwiftTypes: bridgeParameterSwiftTypes,
                resultSwiftType: generatedResultType,
                originalInvocation: "\(baseName)(\(originalArguments))",
                bridgeInvocation: bridgedInvocation,
                enclosingPrefix: enclosure?.0 ?? "",
                enclosingSuffix: enclosure?.1 ?? ""
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
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
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
