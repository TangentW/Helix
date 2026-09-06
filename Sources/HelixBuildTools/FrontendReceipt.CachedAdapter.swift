import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
/// Reuses one fully validated module receipt while delegating partial misses to
/// the finer-grained SDK graph and declaration-probe caches.
public struct CachedAdapter: Sendable {
    private struct SourceIdentity: Codable, Sendable {
        var logicalPath: String
        var physicalPath: String
        var contentHash: Core.Digest
    }

    private struct Key: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var compilerCaptureSHA256: Core.Digest
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var compilerInputs: BuildCache.CompilerInputs.Snapshot
        var metadata: InterfaceArchive.ReleaseMetadata
        var configuration: PatchConfiguration.Document
        var nativeImportCatalog: NativeImportCatalog.Document
        var nativeAPICatalogs: [CatalogIdentity]
        var callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy
        var sources: [SourceIdentity]
    }

    private struct CatalogIdentity: Codable, Sendable {
        var moduleName: String
        var artifactIdentity: Core.Digest
    }

    private struct Payload: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var receipt: ShellBuildReceipt.Document
        var diagnostics: [Core.Diagnostic]
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var importedModules: [String]
    }

    public var cache: BuildCache.Store

    public init(cache: BuildCache.Store) {
        self.cache = cache
    }

    public func generate(
        _ request: FrontendReceipt.Request,
        compilerCapture: Data,
        compilerArguments: [String] = [],
        workingDirectory: URL? = nil,
        precomputedToolchain: ReleaseCompiler.ToolchainIdentity? = nil,
        precomputedCompilerInputs: BuildCache.CompilerInputs.Snapshot? = nil
    ) throws -> FrontendReceipt.Output {
        try generate(
            request, compilerCapture: compilerCapture, compilerArguments: compilerArguments,
            workingDirectory: workingDirectory, precomputedToolchain: precomputedToolchain,
            precomputedCompilerInputs: precomputedCompilerInputs, diagnostics: nil)
    }

    public func diagnose(
        _ request: FrontendReceipt.Request,
        compilerCapture: Data,
        compilerArguments: [String] = [],
        workingDirectory: URL? = nil,
        precomputedToolchain: ReleaseCompiler.ToolchainIdentity? = nil,
        precomputedCompilerInputs: BuildCache.CompilerInputs.Snapshot? = nil,
        catalogFailure: String? = nil
    ) throws -> FrontendReceipt.DiagnosticReport {
        let session = FrontendReceipt.DiagnosticSession(collectFailures: true, catalogFailure: catalogFailure)
        do {
            let output = try generate(
            request, compilerCapture: compilerCapture, compilerArguments: compilerArguments,
            workingDirectory: workingDirectory, precomputedToolchain: precomputedToolchain,
            precomputedCompilerInputs: precomputedCompilerInputs, diagnostics: session)
            return session.report(output: output)
        } catch {
            if error is CancellationError { throw error }
            if session.checks.isEmpty {
                return .failure(stage: "frontend.setup", reason: String(describing: error))
            }
            return session.report(output: nil, error: error)
        }
    }

    private func generate(
        _ request: FrontendReceipt.Request,
        compilerCapture: Data,
        compilerArguments: [String] = [],
        workingDirectory: URL? = nil,
        precomputedToolchain: ReleaseCompiler.ToolchainIdentity? = nil,
        precomputedCompilerInputs: BuildCache.CompilerInputs.Snapshot? = nil,
        diagnostics: FrontendReceipt.DiagnosticSession?
    ) throws -> FrontendReceipt.Output {
        let performance = diagnostics?.performance ?? BuildPerformance.Recorder()
        let adapter = FrontendReceipt.Adapter()
        try performance.measure("frontend_cache.validate_request") {
            try adapter.validate(request)
        }
        let states = try performance.measure("frontend_cache.load_sources") {
            try adapter.loadSources(
                request.sources.sorted { $0.logicalPath < $1.logicalPath },
                collectFailures: diagnostics != nil
            )
        }
        let sourceImports = performance.measure("frontend_cache.scan_imports") {
            FrontendReceipt.SourceImports.scan(contents: states.map(\.contents))
        }
        let toolchain = try precomputedToolchain
            ?? performance.measure("frontend_cache.toolchain_identity") {
                try ReleaseCompiler.Driver().toolchainIdentity(
                    compilerURL: request.compilerURL,
                    invocationObserver: performance.subprocessObserver
                )
            }
        let inputArguments = compilerArguments.isEmpty
            ? request.metadata.frontendInvocation.semanticArguments
            : compilerArguments
        var compilerInputs: BuildCache.CompilerInputs.Snapshot
        if let precomputedCompilerInputs,
           precomputedCompilerInputs.importedModules == sourceImports.modules {
            compilerInputs = precomputedCompilerInputs
        } else {
            compilerInputs = performance.measure("frontend_cache.compiler_inputs") {
                BuildCache.CompilerInputs.capture(
                    arguments: inputArguments,
                    currentModuleName: request.metadata.frontendInvocation.moduleName,
                    workingDirectory: workingDirectory
                        ?? request.sources.first?.url.deletingLastPathComponent()
                        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    importedModules: Set(sourceImports.modules)
                )
            }
        }
        compilerInputs.isComplete = compilerInputs.isComplete
            && sourceImports.isComplete
        let compilerInputHash = try BuildCache.key(
            domain: "HLX.BuildCache.CompilerInputs.v1",
            value: compilerInputs
        )
        guard compilerInputs.isComplete else {
            performance.incrementCounter(
                "frontend_cache.compiler_inputs_incomplete_count"
            )
            performance.incrementCounter("frontend_cache.module_bypass_count")
            var output = try adapter.generate(
                request,
                cache: nil,
                toolchain: toolchain,
                compilerInputHash: nil, diagnostics: diagnostics
            )
            if diagnostics == nil { performance.merge(output.performance) }
            output.performance = performance.trace()
            return output
        }
        let expectedSources = states.map {
            ShellBuildReceipt.Source(
                logicalPath: $0.logicalPath,
                contentHash: $0.contentHash
            )
        }
        let checkpointIdentity = try BuildCache.key(
            domain: "HLX.BuildCache.CompilerCheckpointInputs.v1",
            value: FrontendReceipt.CompilerCheckpoints.Identity(
                compilerCaptureHash: .sha256(compilerCapture), toolchain: toolchain,
                compilerPath: request.compilerURL.path, compilerInputHash: compilerInputHash,
                invocation: request.metadata.frontendInvocation,
                transformPipelineHash: request.metadata.transformPipelineHash,
                sources: expectedSources, physicalPaths: states.map { $0.url.path }
            )
        )
        let checkpoints = FrontendReceipt.CompilerCheckpoints.Context(
            cache: cache, identity: checkpointIdentity,
            confirmInputs: {
                var confirmedInputs = BuildCache.CompilerInputs.capture(
                    arguments: inputArguments,
                    currentModuleName: request.metadata.frontendInvocation.moduleName,
                    workingDirectory: workingDirectory
                        ?? request.sources.first?.url.deletingLastPathComponent()
                        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    importedModules: Set(sourceImports.modules)
                )
                confirmedInputs.isComplete = confirmedInputs.isComplete && sourceImports.isComplete
                let confirmedSources = try adapter.loadSources(
                    request.sources.sorted { $0.logicalPath < $1.logicalPath }
                ).map {
                    ShellBuildReceipt.Source(logicalPath: $0.logicalPath, contentHash: $0.contentHash)
                }
                guard confirmedInputs == compilerInputs, confirmedSources == expectedSources else {
                    throw FrontendReceipt.SourceImports.ValidationError.sourceChanged
                }
            }
        )
        if let diagnostics {
            // Diagnosis rechecks compiler facts, bypasses the complete receipt
            // cache, and retains validated checkpoints for the next correction.
            let output = try adapter.generate(request, cache: cache, toolchain: toolchain,
                compilerInputHash: compilerInputHash, expectedImports: sourceImports,
                expectedSources: expectedSources, checkpoints: checkpoints, diagnostics: diagnostics)
            try checkpoints.confirmInputs()
            guard output.receipt.sources == expectedSources else {
                throw FrontendReceipt.SourceImports.ValidationError.sourceChanged
            }
            return output
        }
        let key = try performance.measure("frontend_cache.make_key") {
            let catalogIdentities = try request.nativeAPICatalogs.map {
                CatalogIdentity(
                    moduleName: $0.document.identity.moduleName,
                    artifactIdentity: try $0.cacheIdentity()
                )
            }
            return try BuildCache.key(
                domain: "HLX.BuildCache.ModuleFrontend.v1",
                value: Key(
                    compilerCaptureSHA256: .sha256(compilerCapture),
                    toolchain: toolchain,
                    compilerInputs: compilerInputs,
                    metadata: request.metadata,
                    configuration: request.configuration,
                    nativeImportCatalog: request.nativeImportCatalog,
                    nativeAPICatalogs: catalogIdentities,
                    callingSurfacePolicy: request.callingSurfacePolicy,
                    sources: states.map {
                        SourceIdentity(
                            logicalPath: $0.logicalPath,
                            physicalPath: $0.url.path,
                            contentHash: $0.contentHash
                        )
                    }
                )
            )
        }
        var generatedOutput: FrontendReceipt.Output?
        var validatedPayload: Payload?
        let value: BuildCache.Value
        do {
            value = try performance.measure("frontend_cache.lookup_or_generate") {
                try cache.value(
                    namespace: .moduleFrontend,
                    key: key,
                    maximumBytes: 64 * 1_024 * 1_024,
                    validate: {
                        validatedPayload = try Self.decode(
                            $0,
                            request: request,
                            expectedSources: expectedSources,
                            toolchain: toolchain,
                            sourceImports: sourceImports
                        )
                    }
                ) {
                    let output = try adapter.generate(
                        request,
                        cache: cache,
                        toolchain: toolchain,
                        compilerInputHash: compilerInputHash,
                        expectedImports: sourceImports,
                        expectedSources: expectedSources,
                        checkpoints: checkpoints
                    )
                    generatedOutput = output
                    var confirmedInputs = BuildCache.CompilerInputs.capture(
                        arguments: inputArguments,
                        currentModuleName: request.metadata.frontendInvocation.moduleName,
                        workingDirectory: workingDirectory
                            ?? request.sources.first?.url.deletingLastPathComponent()
                            ?? URL(
                                fileURLWithPath: FileManager.default.currentDirectoryPath
                            ),
                        importedModules: Set(sourceImports.modules)
                    )
                    confirmedInputs.isComplete = confirmedInputs.isComplete
                        && sourceImports.isComplete
                    guard confirmedInputs == compilerInputs,
                          output.receipt.sources == expectedSources
                    else {
                        throw FrontendReceipt.SourceImports.ValidationError
                            .sourceChanged
                    }
                    return try Core.CanonicalJSON.encode(Payload(
                        receipt: output.receipt,
                        diagnostics: output.diagnostics,
                        toolchain: output.toolchain,
                        importedModules: output.importedModules
                    ))
                }
            }
        } catch FrontendReceipt.SourceImports.ValidationError
            .compilerImportMismatch {
            performance.incrementCounter(
                "frontend_cache.import_scan_mismatch_count"
            )
            performance.incrementCounter("frontend_cache.module_bypass_count")
            var output = try adapter.generate(
                request,
                cache: nil,
                toolchain: toolchain,
                compilerInputHash: nil
            )
            performance.merge(output.performance)
            output.performance = performance.trace()
            return output
        } catch FrontendReceipt.SourceImports.ValidationError.sourceChanged {
            performance.incrementCounter("frontend_cache.input_drift_count")
            performance.incrementCounter("frontend_cache.module_bypass_count")
            var output = try adapter.generate(
                request,
                cache: nil,
                toolchain: toolchain,
                compilerInputHash: nil
            )
            performance.merge(output.performance)
            output.performance = performance.trace()
            return output
        }

        switch value.source {
        case .hit:
            guard let payload = validatedPayload else {
                throw FrontendReceipt.Error.frontendFailed(
                    "module frontend cache was not validated"
                )
            }
            let confirmedStates = try adapter.loadSources(
                request.sources.sorted { $0.logicalPath < $1.logicalPath }
            )
            let confirmedSources = confirmedStates.map {
                ShellBuildReceipt.Source(
                    logicalPath: $0.logicalPath,
                    contentHash: $0.contentHash
                )
            }
            guard confirmedSources == expectedSources else {
                performance.incrementCounter("frontend_cache.input_drift_count")
                performance.incrementCounter("frontend_cache.module_bypass_count")
                var output = try adapter.generate(
                    request,
                    cache: nil,
                    toolchain: toolchain,
                    compilerInputHash: nil
                )
                performance.merge(output.performance)
                output.performance = performance.trace()
                return output
            }
            performance.incrementCounter("frontend_cache.module_hit_count")
            return .init(
                receipt: payload.receipt,
                diagnostics: payload.diagnostics,
                toolchain: payload.toolchain,
                importedModules: payload.importedModules,
                performance: performance.trace()
            )
        case .generated, .repaired, .bypassed:
            performance.incrementCounter("frontend_cache.module_miss_count")
            if value.source == .repaired {
                performance.incrementCounter("frontend_cache.module_repair_count")
            } else if value.source == .bypassed {
                performance.incrementCounter("frontend_cache.module_bypass_count")
            }
            guard var output = generatedOutput else {
                throw FrontendReceipt.Error.frontendFailed(
                    "module cache reported a miss without producing a receipt"
                )
            }
            if value.source == .generated || value.source == .repaired {
                performance.setCounter("frontend_checkpoint.retired_count", value: checkpoints.retire())
            }
            performance.merge(output.performance)
            output.performance = performance.trace()
            return output
        }
    }

    private static func decode(
        _ data: Data,
        request: FrontendReceipt.Request,
        expectedSources: [ShellBuildReceipt.Source],
        toolchain: ReleaseCompiler.ToolchainIdentity,
        sourceImports: FrontendReceipt.SourceImports.Result
    ) throws -> Payload {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var expectedMetadata = request.metadata
        var sourceBaseline = Core.StableHasher(
            domain: "HLXI.SourceBaseline.v1"
        )
        for source in expectedSources.sorted(by: {
            $0.logicalPath < $1.logicalPath
        }) {
            sourceBaseline.append(source.logicalPath)
            sourceBaseline.append(source.contentHash)
        }
        expectedMetadata.sourceBaselineHash = sourceBaseline.finalize()
        guard payload.schemaVersion == 1,
              payload.toolchain == toolchain,
              payload.receipt.metadata == expectedMetadata,
              payload.receipt.compatibility.compilerFingerprint
                  == toolchain.fingerprint,
              payload.receipt.sources == expectedSources,
              payload.importedModules == payload.importedModules.sorted(),
              Set(payload.importedModules).count == payload.importedModules.count,
              payload.importedModules.allSatisfy({ !$0.isEmpty }),
              sourceImports.covers(compilerModules: payload.importedModules),
              payload.diagnostics.count <= 1_000_000,
              payload.diagnostics == payload.diagnostics.sorted(by: diagnosticOrder),
              try Core.CanonicalJSON.encode(payload) == data
        else {
            throw FrontendReceipt.Error.frontendFailed(
                "module frontend cache payload is invalid"
            )
        }
        try payload.receipt.validate()
        return payload
    }

    private static func diagnosticOrder(
        _ lhs: Core.Diagnostic,
        _ rhs: Core.Diagnostic
    ) -> Bool {
        (lhs.location?.file ?? "", lhs.location?.line ?? 0, lhs.code, lhs.message)
            < (rhs.location?.file ?? "", rhs.location?.line ?? 0, rhs.code, rhs.message)
    }
}
}
