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
        var operationSILFile: CanonicalSIL.File
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
        func sil(_ stage: FrontendReceipt.CompilerCheckpoints.Stage, purpose: SwiftFrontend.CanonicalSILPurpose) throws -> CanonicalSIL.File? {
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
                _ = try session.run(prefix + ".ast_mapping") {
                    try validateSILSourceMappings(documents: ast!.documents, sourcesByPhysicalPath: byPath!,
                        functions: inspection!.functions!, compilerURL: request.compilerURL, performance: performance)
                }
            }
            return file
        }
        let identitySIL = try sil(.identitySIL, purpose: .implementationIdentity)
        // Source-level default-argument provenance needs pre-mandatory SIL.
        let semanticSIL = try sil(.semanticSIL, purpose: .semanticLowering)
        let moduleName = request.metadata.frontendInvocation.moduleName
        let effectiveConfiguration = try session.run("frontend.resolve_calling_surface") {
            let configured = try callingSurfaceConfiguration(request.configuration, policy: request.callingSurfacePolicy,
                                                            moduleName: moduleName, sources: orderedSources)
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
            try discoverImportedOperationSurface(documents: ast!.documents, sourcesByPhysicalPath: byPath!, moduleName: moduleName,
                demangled: demangled!, silFile: semanticSIL!, compilerURL: request.compilerURL, performance: performance)
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
        return .init(sourceStates: states!, toolchain: toolchain!, documents: ast!.documents, importedModules: ast!.modules,
                     demangled: demangled!, silFile: identitySIL!, operationSILFile: semanticSIL!, effectiveConfiguration: effectiveConfiguration!,
                     sourceNominals: sourceNominals!, discoveredImportedTypes: discoveredTypes!, importedOperationSurface: operations!,
                     catalogSurface: catalog!, importedTypes: importedTypes!)
    }
}
