import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

/// Version-pinned adapter from Swift's typed JSON AST and canonical SIL to the
/// stable Shell Build Receipt. Raw compiler formats are confined to private,
/// exact-toolchain checkpoints and never become a published artifact contract.
public enum FrontendReceipt {}

extension FrontendReceipt {
public enum CallingSurfacePolicy: String, Codable, Hashable, Sendable {
    /// Uses the exact NativeImport scope resolved for this build. Xcode
    /// integration creates it automatically; headless callers may supply one.
    case configured
    /// Uses cached module Catalogs plus calls observed in the current source.
    /// A missing Catalog never triggers a whole-module scan on the foreground
    /// build; Hub prewarms it while source-observed calls remain available.
    case managedDevelopmentModule
    /// Expands one Release feature module and publishes every qualified
    /// candidate as immutable production capability. No project allowlist is
    /// consulted and no device-side registry growth is permitted.
    case managedProductionModule

    var expandsImportedModules: Bool {
        self == .managedDevelopmentModule || self == .managedProductionModule
    }
}

public struct Source: Hashable, Sendable {
    public var logicalPath: String
    public var url: URL

    public init(logicalPath: String, url: URL) {
        self.logicalPath = logicalPath
        self.url = url
    }
}

public struct Request: Sendable {
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var configuration: PatchConfiguration.Document
    public var sources: [FrontendReceipt.Source]
    public var compilerURL: URL
    public var nativeImportCatalog: NativeImportCatalog.Document
    /// Immutable, compiler-derived module surfaces. Xcode integration fills
    /// these automatically; applications never enumerate native APIs.
    public var nativeAPICatalogs: [NativeAPICatalog.Snapshot]
    public var callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy
    public var indexing: FrontendReceipt.IndexingOptions?

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        configuration: PatchConfiguration.Document,
        sources: [FrontendReceipt.Source],
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        nativeImportCatalog: NativeImportCatalog.Document = .empty,
        nativeAPICatalogs: [NativeAPICatalog.Snapshot] = [],
        callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy = .configured
    ) {
        self.metadata = metadata
        self.configuration = configuration
        self.sources = sources
        self.compilerURL = compilerURL
        self.nativeImportCatalog = nativeImportCatalog
        self.nativeAPICatalogs = nativeAPICatalogs.sorted {
            ($0.document.identity.moduleName, $0.document.identity.cacheKey)
                < ($1.document.identity.moduleName, $1.document.identity.cacheKey)
        }
        self.callingSurfacePolicy = callingSurfacePolicy
        self.indexing = nil
    }

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        configuration: PatchConfiguration.Document,
        sources: [FrontendReceipt.Source],
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        nativeImportCatalog: NativeImportCatalog.Document = .empty,
        nativeAPICatalogs: [NativeAPICatalog.Snapshot] = [],
        callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy = .configured,
        indexing: FrontendReceipt.IndexingOptions
    ) {
        self.init(metadata: metadata, configuration: configuration, sources: sources,
            compilerURL: compilerURL, nativeImportCatalog: nativeImportCatalog,
            nativeAPICatalogs: nativeAPICatalogs, callingSurfacePolicy: callingSurfacePolicy)
        self.indexing = indexing
    }
}

public struct Output: Sendable {
    public var receipt: ShellBuildReceipt.Document
    public var diagnostics: [Core.Diagnostic]
    public var toolchain: ReleaseCompiler.ToolchainIdentity
    public var importedModules: [String]
    public var performance: BuildPerformance.Trace

    public var excludedDeclarationCount: Int { diagnostics.filter { $0.code == "HLXIDX024" }.count }

    public init(
        receipt: ShellBuildReceipt.Document,
        diagnostics: [Core.Diagnostic],
        toolchain: ReleaseCompiler.ToolchainIdentity,
        importedModules: [String],
        performance: BuildPerformance.Trace
    ) {
        self.receipt = receipt
        self.diagnostics = diagnostics
        self.toolchain = toolchain
        self.importedModules = importedModules
        self.performance = performance
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest(String)
    case frontendFailed(String)
    case malformedAST(String)
    case demanglingFailed(String)
    case missingSILFunction(String)
    case ambiguousSILFunction(String, [String])
    case unsupportedDeclaration(String)

    public var description: String {
        switch self {
        case let .invalidRequest(reason): "invalid frontend receipt request: \(reason)"
        case let .frontendFailed(reason): "Swift frontend indexing failed: \(reason)"
        case let .malformedAST(reason): "malformed typed Swift AST: \(reason)"
        case let .demanglingFailed(reason): "Swift type demangling failed: \(reason)"
        case let .missingSILFunction(name): "typed AST function is absent from canonical SIL: \(name)"
        case let .ambiguousSILFunction(name, matches):
            "typed AST function maps ambiguously to canonical SIL: \(name) -> "
                + matches.joined(separator: ", ")
        case let .unsupportedDeclaration(reason): "unsupported indexed declaration: \(reason)"
        }
    }
}
}
