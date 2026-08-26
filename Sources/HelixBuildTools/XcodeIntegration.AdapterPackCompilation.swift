import Foundation
import HelixCore

extension XcodeIntegration {
public struct AdapterPackCompilationPlan: Hashable, Sendable {
    public var compilation: XcodeIntegration.BridgeCompilationPlan
    public var compilerModuleName: String
    /// Compiler arguments used for object-cache identity. Only the transient
    /// source and output locations are removed; all semantic and search-path
    /// inputs remain exact and are independently content-fingerprinted.
    public var identityArguments: [String]

    public init(
        compilation: XcodeIntegration.BridgeCompilationPlan,
        compilerModuleName: String,
        identityArguments: [String]
    ) {
        self.compilation = compilation
        self.compilerModuleName = compilerModuleName
        self.identityArguments = identityArguments
    }
}

public struct AdapterPackCompilationPlanner: Sendable {
    public init() {}

    public static func compilerModuleName(
        for identity: NativeAdapterPack.Identity
    ) -> String {
        "HelixAdapterPack_\(identity.cacheKey.hex.prefix(24))"
    }

    public func plan(
        compilerPath: String,
        capturedArguments: [String],
        expectedCompilerPath: String,
        expectedCapturedModuleName: String,
        expectedTargetTriple: String,
        expectedSDKPath: String,
        expectedOptimization: String,
        additionalModuleSearchArguments: [String] = [],
        clangModuleMapURLs: [URL],
        generatedSourceURL: URL,
        outputURL: URL,
        identity: NativeAdapterPack.Identity
    ) throws -> XcodeIntegration.AdapterPackCompilationPlan {
        let moduleName = Self.compilerModuleName(for: identity)
        let compilation = try XcodeIntegration.BridgeCompilationPlanner().plan(
            compilerPath: compilerPath,
            capturedArguments: capturedArguments,
            expectedCompilerPath: expectedCompilerPath,
            expectedCapturedModuleName: expectedCapturedModuleName,
            expectedTargetTriple: expectedTargetTriple,
            expectedSDKPath: expectedSDKPath,
            expectedOptimization: expectedOptimization,
            additionalModuleSearchArguments: additionalModuleSearchArguments,
            clangModuleMapURLs: clangModuleMapURLs,
            generatedSourceURLs: [generatedSourceURL],
            outputURL: outputURL,
            moduleName: moduleName
        )
        guard compilation.arguments.count >= 2,
              compilation.arguments.suffix(2) == ["-o", outputURL.path],
              compilation.arguments.filter({
                  $0 == generatedSourceURL.path
              }).count == 1
        else {
            throw XcodeIntegration.BridgeCompilationError.invalidInput
        }
        let identityArguments = compilation.arguments.dropLast(2).map {
            $0 == generatedSourceURL.path
                ? "<helix-adapter-pack-source>" : $0
        }
        return .init(
            compilation: compilation,
            compilerModuleName: moduleName,
            identityArguments: identityArguments
        )
    }
}
}
