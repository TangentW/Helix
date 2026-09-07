import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    struct Analysis {
        var sourceStates: [SourceState]
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var documents: [FrontendReceipt.TypedAST.Object]
        var importedModules: [String]
        var demangled: [String: String]
        var silFile: CanonicalSIL.File
        var identityResolver: FrontendReceipt.SILFunctionResolver
        var selection: FrontendReceipt.DeclarationSelection
        var effectiveConfiguration: PatchConfiguration.Document
        var sourceNominals: [SourceNominal]
        var discoveredImportedTypes: [ImportedNativeType]
        var importedOperationSurface: ImportedOperationSurface
        var catalogSurface: FrontendReceipt.CatalogSurface.Resolution
        var importedTypes: [ImportedNativeType]
    }

    func analyze(
        _ request: FrontendReceipt.Request,
        toolchain suppliedToolchain: ReleaseCompiler.ToolchainIdentity?,
        expectedImports: FrontendReceipt.SourceImports.Result?,
        expectedSources: [ShellBuildReceipt.Source]?,
        checkpoints: FrontendReceipt.CompilerCheckpoints.Context?,
        session: FrontendReceipt.DiagnosticSession
    ) throws -> Analysis {
        let performance = session.performance
        _ = try session.run("frontend.validate_request") { try validate(request) }
        let orderedSources = request.sources.sorted { $0.logicalPath < $1.logicalPath }
        performance.setCounter("frontend.source_count", value: UInt64(orderedSources.count))
        let states = try session.run("frontend.load_sources") {
            let values = try loadSources(orderedSources, collectFailures: session.collectFailures)
            if let expectedSources {
                guard values.map({ ShellBuildReceipt.Source(logicalPath: $0.logicalPath, contentHash: $0.contentHash) }) == expectedSources else {
                    throw FrontendReceipt.SourceImports.ValidationError.sourceChanged
                }
            }
            performance.setCounter("frontend.source_bytes", value: values.reduce(0) { $0 + UInt64($1.contents.count) })
            return values
        }
        let toolchain = try session.run("frontend.toolchain_identity") {
            try suppliedToolchain ?? ReleaseCompiler.Driver().toolchainIdentity(
                compilerURL: request.compilerURL, invocationObserver: performance.subprocessObserver)
        }
        let frontend = SwiftFrontend.Driver(compilerURL: request.compilerURL, invocationObserver: performance.subprocessObserver)
        // Dependency success guarantees that the corresponding optional result
        // below exists. A failed branch never invokes its dependent closure.
        let ast = try session.run("frontend.typed_ast") {
            try FrontendReceipt.CompilerCheckpoints.read(.typedAST, context: checkpoints, performance: performance,
                produce: {
                    try performance.measure("frontend.emit_typed_ast") {
                        try frontend.emitTypedAST(sourceFiles: orderedSources.map(\.url), invocation: request.metadata.frontendInvocation)
                    }
                }, parse: { text in
                    performance.setCounter("frontend.typed_ast_bytes", value: UInt64(text.utf8.count))
                    let documents = try performance.measure("frontend.parse_typed_ast") { try FrontendReceipt.TypedAST.parseDocuments(text) }
                    let expectedPaths = Set(states!.map { $0.url.path })
                    let actualPaths = documents.compactMap { $0["filename"] as? String }.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                    }
                    guard actualPaths.count == expectedPaths.count, Set(actualPaths) == expectedPaths else {
                        let missing = expectedPaths.subtracting(actualPaths).sorted()
                        let unexpected = Set(actualPaths).subtracting(expectedPaths).sorted()
                        throw FrontendReceipt.Error.malformedAST("typed AST source documents do not match the requested source set: missing=\(missing), unexpected=\(unexpected), expectedCount=\(expectedPaths.count), actualCount=\(actualPaths.count)")
                    }
                    let modules = try performance.measure("frontend.collect_imports") {
                        Array(Set(try documents.flatMap { imports(in: try FrontendReceipt.TypedAST.items(in: $0)) }))
                            .filter { $0 != request.metadata.frontendInvocation.moduleName }.sorted()
                    }
                    if let expectedImports, !expectedImports.covers(compilerModules: modules) {
                        throw FrontendReceipt.SourceImports.ValidationError.compilerImportMismatch
                    }
                    try validateCompilerVersion(documents, toolchain: toolchain!)
                    return (documents: documents, modules: modules)
                })
        }
        let demangled = try session.run("frontend.demangle_types") {
            try FrontendReceipt.Demangler(compilerURL: request.compilerURL, invocationObserver: performance.subprocessObserver)
                .demangle(FrontendReceipt.TypedAST.mangledTypes(in: ast!.documents))
        }
        let byPath = states.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.url.path, $0) }) }
        var selection = try session.run("frontend.select_declarations") {
            try FrontendReceipt.DeclarationSelection(documents: ast!.documents, sourcesByPhysicalPath: byPath!, options: request.indexing)
        }
        func sil(_ stage: FrontendReceipt.CompilerCheckpoints.Stage, purpose: SwiftFrontend.CanonicalSILPurpose) throws ->
            (file: CanonicalSIL.File?, resolver: FrontendReceipt.SILFunctionResolver?) {
            let prefix = "frontend." + stage.rawValue
            var inspection: CanonicalSIL.Inspection?
            let file = try session.run(prefix) {
                try FrontendReceipt.CompilerCheckpoints.read(stage, context: checkpoints, performance: performance,
                    produce: {
                        // A rejected cache entry is not evidence for a failed
                        // fresh compiler invocation. Retain only its last output.
                        inspection = nil
                        return try performance.measure("frontend.emit_\(stage.rawValue)") {
                            try frontend.emitCanonicalSIL(sourceFiles: orderedSources.map(\.url), invocation: request.metadata.frontendInvocation, purpose: purpose)
                        }
                    }, parse: { text in
                        performance.setCounter("frontend.\(stage.rawValue)_bytes", value: UInt64(text.utf8.count))
                        return try performance.measure("frontend.parse_\(stage.rawValue)") {
                            guard session.collectFailures else { return try CanonicalSIL.File(text: text) }
                            let checked = try CanonicalSIL.Inspection(text: text)
                            inspection = checked
                            guard let complete = checked.file else {
                                let failures = checked.checks.filter { $0.status == .failed }.map { $0.component.rawValue }
                                throw FrontendReceipt.Error.frontendFailed("SIL component checks failed: " + failures.joined(separator: ", "))
                            }
                            return complete
                        }
                    })
            }
            if session.collectFailures, session.includes(prefix) {
                if let inspection {
                    for check in inspection.checks {
                        let status: FrontendReceipt.DiagnosticCheck.Status
                        switch check.status {
                        case .passed: status = .passed
                        case .failed: status = .failed
                        case .blocked: status = .blocked
                        }
                        session.record(prefix + "." + check.component.rawValue, status: status, detail: check.detail)
                        if check.status != .blocked {
                            performance.merge(.init(stages: [.init(name: prefix + "." + check.component.rawValue,
                                invocationCount: 1, durationMicroseconds: check.durationMicroseconds)]))
                        }
                    }
                } else {
                    for component in CanonicalSIL.Inspection.Component.allCases {
                        session.record(prefix + "." + component.rawValue, status: .blocked,
                            detail: "Requires compiler output from " + prefix)
                    }
                }
            } else if session.includes(prefix + ".ast_mapping") {
                session.record(prefix + ".function_locations", status: file == nil ? .blocked : .passed,
                    detail: file == nil ? "Requires valid " + prefix : "")
            }
            defer { session.indexingDiagnostics = selection?.diagnostics ?? [] }
            let resolver = try session.run(prefix + ".ast_mapping") {
                try analyzeSILSourceMappings(selection: &selection!, sourcesByPhysicalPath: byPath!,
                    functions: (inspection?.functions ?? file?.functions)!, compilerURL: request.compilerURL,
                    performance: performance, stage: prefix)
            }
            return (file, resolver)
        }
        let identitySIL = try sil(.identitySIL, purpose: .implementationIdentity)
        // Source-level default-argument provenance needs pre-mandatory SIL.
        let semanticSIL = try sil(.semanticSIL, purpose: .semanticLowering)
        let moduleName = request.metadata.frontendInvocation.moduleName
        let effectiveConfiguration = try session.run("frontend.resolve_calling_surface") {
            var scoped = request.configuration
            let indexedSources = orderedSources.filter { request.indexing?.includes(logicalPath: $0.logicalPath) != false }
            if request.indexing != nil, var module = scoped.modules[moduleName] {
                let selectedPaths = indexedSources.map(\.logicalPath).filter { module.includes(logicalPath: $0) }
                guard !selectedPaths.isEmpty else {
                    throw FrontendReceipt.Error.invalidRequest("indexing scope and configured module \(moduleName) share no captured source")
                }
                module.include = selectedPaths
                module.exclude = []
                scoped.modules[moduleName] = module
            }
            let configured = try callingSurfaceConfiguration(scoped, policy: request.callingSurfacePolicy,
                                                            moduleName: moduleName, sources: indexedSources)
            let effective = configuration(configured, allowing: Array(NativeImportCatalog.Builtins.automaticCallees), moduleName: moduleName)
            try effective.validate()
            return effective
        }
        let sourceNominals = try session.run("frontend.discover_source_nominals") {
            try discoverSourceNominals(documents: ast!.documents, sourcesByPhysicalPath: byPath!, moduleName: moduleName, demangled: demangled!)
        }
        let discoveredTypes = try session.run("frontend.discover_imported_types") {
            try discoverImportedNativeTypes(documents: ast!.documents, sourcesByPhysicalPath: byPath!, moduleName: moduleName, demangled: demangled!)
        }
        let operations = try session.run("frontend.discover_imported_operations") {
            let surface = try discoverImportedOperationSurface(documents: selection!.availableDocuments(sourcesByPhysicalPath: byPath!),
                sourcesByPhysicalPath: byPath!, moduleName: moduleName, demangled: demangled!, silFile: semanticSIL.file!,
                compilerURL: request.compilerURL, performance: performance, silResolver: semanticSIL.resolver,
                failurePolicy: selection!.failurePolicy, onExclusions: { exclusions in
                    selection!.merge(exclusions)
                    session.indexingDiagnostics = selection!.diagnostics
                })
            return surface
        }
        let catalog: FrontendReceipt.CatalogSurface.Resolution?
        if let failure = session.catalogFailure {
            // Catalog loading is independent of compiler emission. Record a
            // known loader failure even when AST/SIL also fail, and never feed
            // an empty substitute Catalog into receipt generation.
            catalog = try session.run("frontend.resolve_native_api_catalogs", dependencies: []) {
                throw FrontendReceipt.Error.invalidRequest("Catalog inputs are unavailable: \(failure)")
            }
        } else {
            catalog = try session.run("frontend.resolve_native_api_catalogs") {
                try FrontendReceipt.CatalogSurface.resolve(snapshots: request.nativeAPICatalogs, request: request,
                    importedModules: ast!.modules, toolchain: toolchain!)
            }
        }
        let importedTypes = try session.run("frontend.merge_imported_types") {
            try mergeImportedNativeTypes(discoveredTypes: discoveredTypes!, operationTypes: operations!.types
                + (request.callingSurfacePolicy.expandsImportedModules ? catalog!.importedTypes : []))
        }
        try session.requireSuccess()
        guard session.includes("frontend.receipt") else { throw FrontendReceipt.DiagnosticSelectionComplete() }
        performance.setCounter("frontend.excluded_declaration_count", value: UInt64(selection!.exclusions.count))
        return .init(sourceStates: states!, toolchain: toolchain!, documents: try selection!.availableDocuments(sourcesByPhysicalPath: byPath!), importedModules: ast!.modules,
                     demangled: demangled!, silFile: identitySIL.file!,
                     identityResolver: identitySIL.resolver!, selection: selection!, effectiveConfiguration: effectiveConfiguration!,
                     sourceNominals: sourceNominals!, discoveredImportedTypes: discoveredTypes!, importedOperationSurface: operations!,
                     catalogSurface: catalog!, importedTypes: importedTypes!)
    }
}
