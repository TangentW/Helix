import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

/// Version-pinned adapter from Swift's typed JSON AST and canonical SIL to the
/// stable Shell Build Receipt. Compiler dump formats are never persisted.
public enum FrontendReceipt {}

extension FrontendReceipt {
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

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        configuration: PatchConfiguration.Document,
        sources: [FrontendReceipt.Source],
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        nativeImportCatalog: NativeImportCatalog.Document = .empty
    ) {
        self.metadata = metadata
        self.configuration = configuration
        self.sources = sources
        self.compilerURL = compilerURL
        self.nativeImportCatalog = nativeImportCatalog
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
    case unsupportedDeclaration(String)

    public var description: String {
        switch self {
        case let .invalidRequest(reason): "invalid frontend receipt request: \(reason)"
        case let .frontendFailed(reason): "Swift frontend indexing failed: \(reason)"
        case let .malformedAST(reason): "malformed typed Swift AST: \(reason)"
        case let .demanglingFailed(reason): "Swift type demangling failed: \(reason)"
        case let .missingSILFunction(name): "typed AST function is absent from canonical SIL: \(name)"
        case let .unsupportedDeclaration(reason): "unsupported indexed declaration: \(reason)"
        }
    }
}
}
