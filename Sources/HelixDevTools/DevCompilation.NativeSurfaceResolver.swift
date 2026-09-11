import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore

extension DevCompilation {
/// Resolves only the current saved source transaction after ordinary HLBC
/// lowering proves that its linked Shell/Catalog suffix lacks a native call.
/// Complete module Catalogs are consumed from cache without starting a module
/// scan; source-observed compiler facts remain the cold-cache fallback.
public struct NativeSurfaceResolver: Sendable {
    public var manifest: DevBuildManifest.Document
    public var receipt: ShellBuildReceipt.Document
    public var compilerURL: URL
    public var cache: BuildCache.Store

    public init(
        manifest: DevBuildManifest.Document,
        receipt: ShellBuildReceipt.Document,
        compilerURL: URL,
        cache: BuildCache.Store
    ) {
        self.manifest = manifest
        self.receipt = receipt
        self.compilerURL = compilerURL
        self.cache = cache
    }

    public func resolve() throws -> ShellBuildReceipt.Document {
        try manifest.validate()
        try receipt.validate()
        let sources = manifest.sourceFiles.map {
            FrontendReceipt.Source(
                logicalPath: $0.logicalPath,
                url: URL(fileURLWithPath: $0.absolutePath)
            )
        }.sorted { $0.logicalPath < $1.logicalPath }
        let imports = try FrontendReceipt.SourceImports.scan(sources: sources, targetTriple: receipt.metadata.frontendInvocation.targetTriple)
        let workingDirectory = sources[0].url.deletingLastPathComponent()
            .standardizedFileURL
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let frontend = SwiftFrontend.Driver(
            compilerURL: compilerURL,
            defaultWorkingDirectoryURL: workingDirectory
        )
        let sdk = try frontend.sdkIdentity(
            name: receipt.metadata.frontendInvocation.sdkName
        )
        var compilerInputs = BuildCache.CompilerInputs.capture(
            arguments: manifest.frontendArguments,
            currentModuleName: manifest.moduleName,
            workingDirectory: workingDirectory,
            importedModules: Set(imports.modules)
        )
        compilerInputs.isComplete = compilerInputs.isComplete && imports.isComplete
        let snapshots = try cachedCatalogs(
            importedModules: imports.modules,
            compilerInputs: compilerInputs,
            toolchain: toolchain,
            sdk: sdk,
            workingDirectory: workingDirectory
        )
        var configuration = receipt.configuration
        if var module = configuration.modules[manifest.moduleName] {
            // A resolved receipt may list source-observed allow entries. They
            // are outputs, not user configuration, and must not become inputs
            // to a later save transaction.
            module.nativeImports.allow = []
            configuration.modules[manifest.moduleName] = module
        }
        let captureIdentity = try Core.CanonicalJSON.encode(
            manifest.frontendArguments
        )
        return try FrontendReceipt.CachedAdapter(cache: cache).generate(
            .init(
                metadata: receipt.metadata,
                configuration: configuration,
                sources: sources,
                compilerURL: compilerURL,
                nativeImportCatalog: .empty,
                nativeAPICatalogs: snapshots,
                callingSurfacePolicy: .managedDevelopmentModule,
                indexing: manifest.indexingPolicy?.options ?? .init()
            ),
            compilerCapture: captureIdentity,
            compilerArguments: manifest.frontendArguments,
            workingDirectory: workingDirectory,
            precomputedToolchain: toolchain,
            precomputedCompilerInputs: compilerInputs
        ).receipt
    }

    private func cachedCatalogs(
        importedModules: [String],
        compilerInputs: BuildCache.CompilerInputs.Snapshot,
        toolchain: ReleaseCompiler.ToolchainIdentity,
        sdk: SwiftFrontend.Driver.SDKIdentity,
        workingDirectory: URL
    ) throws -> [NativeAPICatalog.Snapshot] {
        var modules = Set(importedModules)
        var snapshotsByModule: [String: NativeAPICatalog.Snapshot] = [:]
        let builder = NativeAPICatalog.Builder(cache: cache)
        for _ in 0..<256 {
            let request = NativeAPICatalog.PlanRequest(
                metadata: receipt.metadata,
                importedModules: modules.sorted(),
                compilerArguments: manifest.frontendArguments,
                compilerURL: compilerURL,
                workingDirectory: workingDirectory,
                toolchain: toolchain,
                sdk: sdk,
                compilerInputs: compilerInputs
            )
            let plan = try NativeAPICatalog.Planner().plan(request)
            var expanded = modules
            for catalogRequest in plan.requests {
                guard snapshotsByModule[
                    catalogRequest.identity.moduleName
                ] == nil,
                      let output = try builder.cached(catalogRequest)
                else { continue }
                snapshotsByModule[catalogRequest.identity.moduleName]
                    = output.snapshot
                expanded.formUnion(output.snapshot.referencedModules)
            }
            guard expanded != modules else { break }
            guard expanded.count <= 256 else {
                throw DevCompilation.NativeCapabilityError
                    .discoveryFailed(
                        "Native API Catalog dependency closure exceeds 256 modules"
                    )
            }
            modules = expanded
        }
        return snapshotsByModule.values.sorted {
            ($0.document.identity.moduleName,
             $0.document.identity.cacheKey)
                < ($1.document.identity.moduleName,
                   $1.document.identity.cacheKey)
        }
    }
}
}
