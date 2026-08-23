import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

extension DevCompilation {
/// Compiles body-only Swift edits into signed Dynamic Replacement images. All
/// declaration spelling and ownership metadata comes from the frozen Reload
/// Index generated with the Dev Shell.
public actor NativeBuilder {
    public let archive: InterfaceArchive.Archive
    public let manifest: DevBuildManifest.Document
    public let reloadIndex: ReloadIndex.Document
    public let compilerURL: URL
    public let outputDirectory: URL

    private let imageBuilder: NativeGeneration.DefaultBuilder
    private let bodyExtractor: NativeGeneration.BodyExtractor
    private let selfReferenceRebinder: NativeGeneration.SelfReferenceRebinder
    private var activeFunctions: Set<Core.FunctionKey>

    public init(
        archive: InterfaceArchive.Archive,
        manifest: DevBuildManifest.Document,
        reloadIndex: ReloadIndex.Document,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        outputDirectory: URL,
        initiallyActiveFunctions: Set<Core.FunctionKey> = [],
        runner: ProcessExecution.Runner = .init(),
        bodyExtractor: NativeGeneration.BodyExtractor = .init(),
        selfReferenceRebinder: NativeGeneration.SelfReferenceRebinder = .init()
    ) throws {
        self.archive = archive
        self.manifest = manifest
        self.reloadIndex = reloadIndex
        self.compilerURL = compilerURL
        self.outputDirectory = outputDirectory
        imageBuilder = .init(runner: runner)
        self.bodyExtractor = bodyExtractor
        self.selfReferenceRebinder = selfReferenceRebinder
        activeFunctions = initiallyActiveFunctions
        try Self.validateFrozenInputs(
            archive: archive,
            manifest: manifest,
            reloadIndex: reloadIndex,
            activeFunctions: initiallyActiveFunctions
        )
    }

    public func build(
        _ request: DevSession.BuildRequest
    ) async throws -> DevSession.BuildOutcome {
        do {
            try Self.validateFrozenInputs(
                archive: archive,
                manifest: manifest,
                reloadIndex: reloadIndex,
                activeFunctions: activeFunctions
            )
        } catch {
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR301",
                    message: String(describing: error),
                    request: request,
                    nextAction: "rebuild the Dev Shell and regenerate its Reload Index"
                )
            )
        }
        try validate(request)

        do {
            let descriptors = Dictionary(
                uniqueKeysWithValues: reloadIndex.nativeReplacements.map {
                    ($0.functionKey, $0)
                }
            )
            let records = Dictionary(
                uniqueKeysWithValues: archive.functions.map { ($0.key, $0) }
            )
            let candidateKeys = request.candidateFunctionKeys
            guard candidateKeys.allSatisfy({ descriptors[$0] != nil && records[$0] != nil }) else {
                return .rebuildRequired(
                    diagnostic(
                        code: "HLXLR502",
                        message: "one or more changed roots lack frozen Native replacement metadata",
                        request: request,
                        nextAction: "use HLBC for these roots or rebuild the Dev Shell with Native indexing enabled"
                    )
                )
            }

            let sourceURLs = try orderedSourceURLs()
            let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
            let silText = try frontend.emitCanonicalSIL(
                sourceFiles: sourceURLs,
                invocation: archive.metadata.frontendInvocation
            )
            let sil = try CanonicalSIL.File(text: silText)
            let archivedSymbols = Set(archive.functions.map(\.mangledName))
            var changedFromBaseline = Set<Core.FunctionKey>()
            for key in candidateKeys {
                guard let record = records[key],
                      let descriptor = descriptors[key],
                      let function = sil.function(mangledName: record.mangledName)
                else {
                    return .rebuildRequired(
                        diagnostic(
                            code: "HLXLR303",
                            message: "a frozen Native root is missing from the current SIL module",
                            request: request,
                            nextAction: "restore the declaration or rebuild the Dev Shell"
                        )
                    )
                }
                guard function.loweredType == descriptor.loweredType else {
                    return .rebuildRequired(
                        diagnostic(
                            code: "HLXLR303",
                            message: "the lowered Swift signature or isolation of \(record.canonicalDeclaration) changed",
                            request: request,
                            nextAction: "perform a full build because Native reload only accepts body changes"
                        )
                    )
                }
                if ReleaseCompiler.ImplementationFingerprint.compute(
                    root: function,
                    in: sil,
                    archivedSymbols: archivedSymbols
                ) != record.bodyFingerprint {
                    changedFromBaseline.insert(key)
                }
            }

            let restored = activeFunctions
                .intersection(candidateKeys)
                .subtracting(changedFromBaseline)
            let emittedKeys = changedFromBaseline.union(restored)
            guard !emittedKeys.isEmpty else {
                try validate(request)
                return .noSemanticChange
            }

            let selectedDescriptors = emittedKeys.compactMap { descriptors[$0] }.sorted {
                $0.functionKey.description < $1.functionKey.description
            }
            let sourceState = try loadSources(for: selectedDescriptors)
            let astOutput = try frontend.emitTypedAST(
                sourceFiles: sourceURLs,
                primarySourceFiles: Set(sourceState.values.map {
                    URL(fileURLWithPath: $0.source.absolutePath)
                }),
                invocation: archive.metadata.frontendInvocation
            )
            try validateSourceState(sourceState)
            let sourceData = Dictionary(uniqueKeysWithValues: sourceState.values.map {
                ($0.source.absolutePath, $0.contents)
            })
            let rebindingPlans = try selfReferenceRebinder.analyze(
                astOutput: astOutput,
                sources: sourceData,
                targets: try selectedDescriptors.map { descriptor in
                    guard let record = records[descriptor.functionKey],
                          let source = sourceState[descriptor.sourceFileID]
                    else {
                        throw ContractError.sourceBaselineMismatch(
                            descriptor.sourceFileID.description
                        )
                    }
                    return .init(
                        mangledName: record.mangledName,
                        sourceFilePath: source.source.absolutePath
                    )
                }
            )
            let units = try makeSourceUnits(
                descriptors: selectedDescriptors,
                sourceState: sourceState,
                records: records,
                rebindingPlans: rebindingPlans
            )
            let generated = try NativeGeneration.SourceGenerator().generateFiles(
                moduleName: manifest.moduleName,
                units: units
            )
            let generationDirectory = outputDirectory.appendingPathComponent(
                "r\(request.snapshot.revision.rawValue)-g\(request.generationID.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            let generatedURLs = try writeGeneratedSources(
                generated,
                to: generationDirectory.appendingPathComponent("Sources", isDirectory: true)
            )
            let image = try imageBuilder.build(
                .init(
                    sessionID: manifest.sessionBuildID,
                    sourceRevision: request.snapshot.revision,
                    generationID: request.generationID,
                    manifest: manifest,
                    compilerURL: compilerURL,
                    sourceURLs: generatedURLs,
                    outputDirectory: generationDirectory,
                    changedSources: request.snapshot.files.map(\.id),
                    changedFunctions: Array(emittedKeys)
                )
            )
            try validate(request)
            try validateSourceState(sourceState)
            return .patch(
                .init(
                    backend: .nativeDynamicReplacement,
                    payload: image.artifact.payload,
                    changedFunctions: emittedKeys,
                    restoredFunctions: restored,
                    debugSymbolsUUID: image.descriptor.uuid,
                    debugSymbols: image.debugSymbols
                )
            )
        } catch let error as NativeGeneration.BodyExtractionError {
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR303",
                    message: error.description,
                    request: request,
                    nextAction: "restore the function declaration header or perform a full build"
                )
            )
        } catch let error as NativeGeneration.SelfReferenceError {
            throw diagnostic(
                code: "HLXLR208",
                message: error.description,
                request: request,
                nextAction: "fix the recursive or LiveReload.previous expression and save again"
            )
        } catch let error as ContractError {
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR301",
                    message: error.description,
                    request: request,
                    nextAction: "rebuild the Dev Shell and regenerate its Native metadata"
                )
            )
        } catch let error as SwiftFrontend.Error {
            return try map(error, request: request)
        } catch let diagnostic as DevProtocol.Diagnostic {
            throw diagnostic
        } catch {
            throw diagnostic(
                code: "HLXLR299",
                message: String(describing: error),
                request: request,
                nextAction: "inspect the Native generation diagnostic and save again"
            )
        }
    }

    /// Advances compiler-side state only after the App confirms that dyld
    /// loaded and registered the complete image.
    @discardableResult
    public func didActivate(_ offer: DevProtocol.PatchOffer) -> Bool {
        guard offer.sessionID == manifest.sessionBuildID,
              offer.backend == .nativeDynamicReplacement
        else { return false }
        let restored = Set(offer.restoredFunctions)
        activeFunctions.subtract(restored)
        activeFunctions.formUnion(Set(offer.changedFunctions).subtracting(restored))
        return true
    }

    public var activeFunctionKeys: Set<Core.FunctionKey> {
        activeFunctions
    }

    private static func validateFrozenInputs(
        archive: InterfaceArchive.Archive,
        manifest: DevBuildManifest.Document,
        reloadIndex: ReloadIndex.Document,
        activeFunctions: Set<Core.FunctionKey>
    ) throws {
        try archive.validate()
        try manifest.validate()
        try reloadIndex.validate()
        let invocation = archive.metadata.frontendInvocation
        let archivedSources = Dictionary(
            uniqueKeysWithValues: archive.sources.map { ($0.logicalPath, $0) }
        )
        let manifestSources = Dictionary(
            uniqueKeysWithValues: manifest.sourceFiles.map { ($0.logicalPath, $0) }
        )
        guard archive.metadata.bundleID == manifest.bundleID,
              archive.metadata.machOUUIDs.contains(manifest.executableUUID),
              archive.metadata.targetTriple == manifest.targetTriple,
              archive.metadata.minimumOS == manifest.minimumOS,
              archive.metadata.xcodeBuild == manifest.xcodeBuild,
              archive.metadata.sdkBuild == manifest.sdkBuild,
              archive.compatibility.compilerFingerprint == manifest.swiftCompilerFingerprint,
              invocation.moduleName == manifest.moduleName,
              invocation.targetTriple == manifest.targetTriple,
              invocation.sdkBuild == manifest.sdkBuild,
              invocation.optimization == "-Onone",
              manifest.toolchainCapabilities.privateImports,
              manifest.toolchainCapabilities.dynamicReplacementChaining,
              manifest.frontendArguments.contains("-enable-private-imports"),
              try reloadIndex.contentHash() == manifest.liveReloadIndexHash,
              Set(archivedSources.keys) == Set(manifestSources.keys)
        else {
            throw ContractError.identityMismatch
        }
        for (logicalPath, archived) in archivedSources {
            guard let source = manifestSources[logicalPath],
                  source.contentHash == archived.contentHash,
                  source.id == LiveReload.SourceFileID.derive(logicalPath: logicalPath)
            else {
                throw ContractError.sourceBaselineMismatch(logicalPath)
            }
        }
        let nativeKeys = Set(reloadIndex.nativeReplacements.map(\.functionKey))
        guard activeFunctions.isSubset(of: nativeKeys) else {
            throw ContractError.invalidActiveFunctionState
        }
    }

    private func validate(_ request: DevSession.BuildRequest) throws {
        guard request.snapshot.revision.rawValue > 0,
              request.generationID.rawValue > 0,
              !request.snapshot.files.isEmpty,
              !request.candidateFunctionKeys.isEmpty
        else {
            throw diagnostic(
                code: "HLXLR205",
                message: "the compile request has no revision, source snapshot, or Native roots",
                request: request,
                nextAction: "capture the source transaction again"
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: manifest.sourceFiles.map { ($0.id, $0) })
        let snapshotIDs = Set(request.snapshot.files.map(\.id))
        guard snapshotIDs.count == request.snapshot.files.count,
              Set(request.classification.changedFiles).isSubset(of: snapshotIDs),
              Set(request.classification.restoredToBaseline)
                .isSubset(of: request.classification.changedFiles)
        else {
            throw diagnostic(
                code: "HLXLR205",
                message: "the snapshot classification is inconsistent with its captured files",
                request: request,
                nextAction: "discard this transaction and snapshot the latest save"
            )
        }
        for file in request.snapshot.files {
            let normalized = URL(fileURLWithPath: file.absolutePath).standardizedFileURL.path
            guard let frozen = byID[file.id],
                  frozen.logicalPath == file.logicalPath,
                  URL(fileURLWithPath: frozen.absolutePath).standardizedFileURL.path == normalized,
                  file.contentHash == .sha256(file.contents)
            else {
                throw diagnostic(
                    code: "HLXLR205",
                    message: "captured source \(file.logicalPath) does not match the Dev Manifest",
                    request: request,
                    nextAction: "discard this transaction and rebuild if target membership changed"
                )
            }
            let current = try Data(contentsOf: URL(fileURLWithPath: frozen.absolutePath))
            guard Core.Digest.sha256(current) == file.contentHash else {
                throw diagnostic(
                    code: "HLXLR206",
                    message: "source \(file.logicalPath) changed after its stable snapshot",
                    request: request,
                    nextAction: "wait for the newest save transaction"
                )
            }
        }
    }

    private func orderedSourceURLs() throws -> [URL] {
        let byLogicalPath = Dictionary(
            uniqueKeysWithValues: manifest.sourceFiles.map { ($0.logicalPath, $0) }
        )
        return try archive.sources.sorted(by: { $0.logicalPath < $1.logicalPath }).map {
            guard let source = byLogicalPath[$0.logicalPath] else {
                throw ContractError.sourceBaselineMismatch($0.logicalPath)
            }
            return URL(fileURLWithPath: source.absolutePath)
        }
    }

    private struct SourceState {
        var source: DevBuildManifest.SourceFile
        var contents: Data
        var hash: Core.Digest
    }

    private func loadSources(
        for descriptors: [ReloadIndex.NativeReplacement]
    ) throws -> [LiveReload.SourceFileID: SourceState] {
        let manifestByID = Dictionary(uniqueKeysWithValues: manifest.sourceFiles.map { ($0.id, $0) })
        var result: [LiveReload.SourceFileID: SourceState] = [:]
        for id in Set(descriptors.map(\.sourceFileID)) {
            guard let source = manifestByID[id] else {
                throw ContractError.sourceBaselineMismatch(id.description)
            }
            let contents = try Data(contentsOf: URL(fileURLWithPath: source.absolutePath))
            result[id] = .init(source: source, contents: contents, hash: .sha256(contents))
        }
        return result
    }

    private func validateSourceState(
        _ states: [LiveReload.SourceFileID: SourceState]
    ) throws {
        for state in states.values {
            let current = try Data(contentsOf: URL(fileURLWithPath: state.source.absolutePath))
            guard Core.Digest.sha256(current) == state.hash else {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR206",
                    message: "source \(state.source.logicalPath) changed during Native compilation",
                    backend: .nativeDynamicReplacement,
                    nextAction: "discard this generation and wait for the newest save"
                )
            }
        }
    }

    private func makeSourceUnits(
        descriptors: [ReloadIndex.NativeReplacement],
        sourceState: [LiveReload.SourceFileID: SourceState],
        records: [Core.FunctionKey: InterfaceArchive.FunctionRecord],
        rebindingPlans: [String: NativeGeneration.SelfReferencePlan]
    ) throws -> [NativeGeneration.SourceUnit] {
        let grouped = Dictionary(grouping: descriptors, by: \.sourceFileID)
        return try grouped.map { sourceID, values in
            guard let state = sourceState[sourceID] else {
                throw ContractError.sourceBaselineMismatch(sourceID.description)
            }
            let roots = try values.map { descriptor in
                guard let record = records[descriptor.functionKey],
                      let plan = rebindingPlans[record.mangledName]
                else {
                    throw ContractError.sourceBaselineMismatch(
                        descriptor.functionKey.description
                    )
                }
                guard plan.currentReferenceCount == 0
                        || descriptor.sourceDeclaration.replacementHeader.range(
                    of: #"\bfunc\s+"#
                        + NSRegularExpression.escapedPattern(for: plan.replacementBaseName)
                        + #"(?=[<(])"#,
                    options: .regularExpression
                ) != nil else {
                    throw ContractError.replacementIdentityMismatch(record.mangledName)
                }
                let extractedBody = try bodyExtractor.extractRegion(
                    from: state.contents,
                    declarationAnchor: descriptor.declarationAnchor,
                    declarationOccurrence: descriptor.declarationOccurrence
                )
                let body = try selfReferenceRebinder.rewrite(
                    extractedBody,
                    using: plan
                )
                return NativeGeneration.ReplacementRoot(
                    sourceDeclaration: descriptor.sourceDeclaration,
                    memberRole: descriptor.memberRole,
                    body: body,
                    sourceLine: try declarationLine(
                        in: state.contents,
                        anchor: descriptor.declarationAnchor,
                        occurrence: descriptor.declarationOccurrence
                    )
                )
            }
            return .init(
                sourceFileLogicalPath: state.source.logicalPath,
                privateImportSourceFile: state.source.privateImportSourceFile,
                imports: Array(Set(values.flatMap(\.importedModules))).sorted(),
                roots: roots
            )
        }.sorted { $0.sourceFileLogicalPath < $1.sourceFileLogicalPath }
    }

    private func declarationLine(
        in contents: Data,
        anchor: String,
        occurrence: UInt32
    ) throws -> Int {
        let bytes = Data(anchor.utf8)
        guard !bytes.isEmpty else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        var lowerBound = contents.startIndex
        var selected: Range<Data.Index>?
        for _ in 0...occurrence {
            guard let match = contents.range(
                of: bytes,
                options: [],
                in: lowerBound..<contents.endIndex
            ) else {
                throw NativeGeneration.BodyExtractionError.anchorNotFound
            }
            selected = match
            lowerBound = match.upperBound
        }
        guard let selected else {
            throw NativeGeneration.BodyExtractionError.anchorNotFound
        }
        return contents[..<selected.lowerBound].reduce(1) { line, byte in
            byte == 0x0a ? line + 1 : line
        }
    }

    private func writeGeneratedSources(
        _ sources: [String: String],
        to directory: URL
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try sources.keys.sorted().map { name in
            guard !name.contains("/"), let source = sources[name] else {
                throw BuildCapture.Error.invalidManifest("generated source name is unsafe")
            }
            let url = directory.appendingPathComponent(name)
            try Data(source.utf8).write(to: url, options: .atomic)
            return url
        }
    }

    private func map(
        _ error: SwiftFrontend.Error,
        request: DevSession.BuildRequest
    ) throws -> DevSession.BuildOutcome {
        switch error {
        case let .compilationFailed(_, diagnostics):
            throw diagnostic(
                code: "HLXLR202",
                message: diagnostics.isEmpty ? error.description : diagnostics,
                request: request,
                nextAction: "fix the Swift diagnostic; the previous generation remains active"
            )
        case .sdkBuildMismatch, .executableNotFound:
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR304",
                    message: error.description,
                    request: request,
                    nextAction: "restore the exact Xcode, SDK, and Swift compiler used by the Dev Shell"
                )
            )
        case .launchFailed, .invalidUTF8Output, .symbolGraphFailed,
             .invalidSymbolGraph, .sdkResolutionFailed:
            throw diagnostic(
                code: "HLXLR203",
                message: error.description,
                request: request,
                nextAction: "repair the local Swift toolchain and save again"
            )
        }
    }

    private func diagnostic(
        code: String,
        message: String,
        request: DevSession.BuildRequest,
        nextAction: String
    ) -> DevProtocol.Diagnostic {
        .init(
            code: code,
            message: bounded(message),
            sourceRevision: request.snapshot.revision,
            generationID: request.generationID,
            backend: .nativeDynamicReplacement,
            previousCodeRemainsActive: true,
            nextAction: nextAction
        )
    }

    private func bounded(_ value: String) -> String {
        let data = Data(value.utf8)
        guard data.count > 60 * 1_024 else {
            return value.isEmpty ? "Swift compiler emitted an empty diagnostic" : value
        }
        return String(decoding: data.prefix(60 * 1_024), as: UTF8.self)
    }
}
}

private enum ContractError: Swift.Error, CustomStringConvertible {
    case identityMismatch
    case sourceBaselineMismatch(String)
    case invalidActiveFunctionState
    case replacementIdentityMismatch(String)

    var description: String {
        switch self {
        case .identityMismatch:
            "Dev Manifest, HLXI, and Reload Index do not share one frozen build identity"
        case let .sourceBaselineMismatch(path):
            "Dev Manifest and HLXI disagree on the baseline identity of \(path)"
        case .invalidActiveFunctionState:
            "the restored Dev Session references a root without Native metadata"
        case let .replacementIdentityMismatch(symbol):
            "Native replacement metadata has no matching generated identity for \(symbol)"
        }
    }
}
