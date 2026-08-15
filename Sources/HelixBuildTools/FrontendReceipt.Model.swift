import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

/// Version-pinned adapter from Swift's typed JSON AST and canonical SIL to the
/// stable Shell Build Receipt. Compiler dump formats are never persisted.
public enum FrontendReceipt {}

extension FrontendReceipt {
public enum CallingSurfacePolicy: Hashable, Sendable {
    /// Uses only the NativeImport scopes and catalog explicitly configured by
    /// the Release/host integration.
    case configured
    /// Expands one Debug feature module into exact generated operations. The
    /// archive still contains no wildcard and eligible Entries take priority.
    case managedDebugModule
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
    public var callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        configuration: PatchConfiguration.Document,
        sources: [FrontendReceipt.Source],
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        nativeImportCatalog: NativeImportCatalog.Document = .empty,
        callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy = .configured
    ) {
        self.metadata = metadata
        self.configuration = configuration
        self.sources = sources
        self.compilerURL = compilerURL
        self.nativeImportCatalog = nativeImportCatalog
        self.callingSurfacePolicy = callingSurfacePolicy
    }
}

public struct Output: Sendable {
    public var receipt: ShellBuildReceipt.Document
    public var diagnostics: [Core.Diagnostic]
    public var toolchain: ReleaseCompiler.ToolchainIdentity
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
