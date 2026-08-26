import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevTools

extension CLI {
struct XcodeAdapterPackPlan: Sendable {
    var report: ShellBuild.AdapterPackReport
    var source: ShellBuild.Artifact
    var sourceURL: URL
    var compilation: XcodeIntegration.AdapterPackCompilationPlan
    var identity: NativeAdapterPack.ObjectIdentity
    var cacheKey: Core.Digest?
}

struct XcodeAdapterPackObject: Sendable {
    var plan: CLI.XcodeAdapterPackPlan
    var url: URL
    var data: Data
    var cacheSource: BuildCache.Source
}
}

extension CLI.Application {
func planXcodeAdapterPacks(
    reports: [ShellBuild.AdapterPackReport],
    sourceArtifactsByPath: [String: ShellBuild.Artifact],
    sourceURLsByPath: [String: URL],
    captured: BuildCapture.CapturedFrontendJob,
    runtimeModuleMapURLs: [URL],
    moduleMapInputs: [NativeAdapterPack.ObjectIdentity.InputFile],
    toolchain: ReleaseCompiler.ToolchainIdentity,
    minimumDeployment: Core.SemanticVersion,
    context: XcodeIntegration.BuildContext
) throws -> [CLI.XcodeAdapterPackPlan] {
    try reports.map { pack in
        guard pack.identity.compilerFingerprint == toolchain.fingerprint,
              pack.identity.sdkBuild == context.environment.sdkBuild,
              pack.identity.targetTriple == context.environment.targetTriple,
              pack.identity.minimumDeployment == minimumDeployment,
              pack.identity.transformPipelineHash
                == ShellBuild.transformPipelineHash,
              let source = sourceArtifactsByPath[pack.sourcePath],
              let sourceURL = sourceURLsByPath[pack.sourcePath]
        else {
            throw CLI.Error.input(
                "Swift Adapter Pack identity does not match the active build: "
                    + pack.moduleName
            )
        }
        let sourceBytes = try readRegularFile(
            sourceURL,
            maximumBytes: 64 * 1_024 * 1_024,
            label: "Swift Adapter Pack source"
        )
        guard let sourceText = String(data: sourceBytes, encoding: .utf8) else {
            throw CLI.Error.input(
                "Swift Adapter Pack source is not UTF-8: \(pack.moduleName)"
            )
        }
        let document = NativeAdapterPack.Document(
            identity: pack.identity,
            sourcePath: pack.sourcePath,
            source: sourceText
        )
        try document.validate(source: sourceText)
        guard document.sourceHash == pack.sourceHash,
              document.sourceByteCount == pack.sourceByteCount
        else {
            throw CLI.Error.input(
                "Swift Adapter Pack report drifted: \(pack.moduleName)"
            )
        }
        let imports = try FrontendReceipt.SourceImports.scan(
            sources: [.init(logicalPath: pack.sourcePath, url: sourceURL)]
        )
        let objectURL = context.environment.bridgeOutputURL
            .appendingPathComponent(
                ".HelixAdapterPack.\(pack.identity.cacheKey.hex.prefix(16))."
                    + "\(UUID().uuidString).o"
            )
        let compilation = try XcodeIntegration
            .AdapterPackCompilationPlanner().plan(
                compilerPath: captured.executable,
                capturedArguments: captured.arguments,
                expectedCompilerPath: context.environment.compilerURL.path,
                expectedCapturedModuleName: context.feature.moduleName,
                expectedTargetTriple: context.environment.targetTriple,
                expectedSDKPath: context.environment.sdkRootURL.path,
                expectedOptimization: context.environment.optimization,
                additionalModuleSearchArguments:
                    context.environment.bridgeModuleSearchArguments,
                clangModuleMapURLs: runtimeModuleMapURLs,
                generatedSourceURL: sourceURL,
                outputURL: objectURL,
                identity: pack.identity
            )
        var inputs = BuildCache.CompilerInputs.capture(
            arguments: compilation.compilation.arguments,
            currentModuleName: compilation.compilerModuleName,
            workingDirectory: context.environment.bridgeOutputURL,
            importedModules: Set(imports.modules)
        )
        inputs.isComplete = inputs.isComplete && imports.isComplete
        let identity = NativeAdapterPack.ObjectIdentity(
            pack: pack.identity,
            sourceHash: pack.sourceHash,
            compilerModuleName: compilation.compilerModuleName,
            toolchain: toolchain,
            xcodeBuild: context.environment.xcodeBuild,
            compilerArguments: compilation.identityArguments,
            compilerInputs: inputs,
            moduleMaps: moduleMapInputs
        )
        let cacheKey = inputs.isComplete ? try identity.cacheKey() : nil
        return .init(
            report: pack,
            source: source,
            sourceURL: sourceURL,
            compilation: compilation,
            identity: identity,
            cacheKey: cacheKey
        )
    }
}

func materializeXcodeAdapterPack(
    _ plan: CLI.XcodeAdapterPackPlan,
    cache: BuildCache.Store?,
    context: XcodeIntegration.BuildContext
) throws -> CLI.XcodeAdapterPackObject {
    let outputURL = plan.compilation.compilation.outputURL
    let produce: () throws -> Data = {
        let result = try ProcessExecution.Runner().run(
            executable: plan.compilation.compilation.compilerURL,
            arguments: plan.compilation.compilation.arguments,
            environment: environment,
            workingDirectory: context.environment.bridgeOutputURL
        )
        guard result.status == 0 else {
            let diagnostics = String(result.standardError.prefix(512 * 1_024))
            throw CLI.Error.input(
                diagnostics.isEmpty
                    ? "Swift Adapter Pack compiler exited with status \(result.status)"
                    : diagnostics
            )
        }
        try validateXcodeObject(
            outputURL,
            context: context,
            label: "Swift Adapter Pack \(plan.report.moduleName)"
        )
        return try readRegularFile(
            outputURL,
            maximumBytes: 512 * 1_024 * 1_024,
            label: "compiled Swift Adapter Pack"
        )
    }

    let materialized = try materializeXcodeObject(
        outputURL: outputURL,
        namespace: .adapterObject,
        cacheKey: plan.cacheKey,
        cache: cache,
        context: context,
        label: "Swift Adapter Pack \(plan.report.moduleName)",
        produce: produce
    )
    return .init(
        plan: plan,
        url: materialized.url,
        data: materialized.data,
        cacheSource: materialized.cacheSource
    )
}

func linkXcodeBridgeObjects(
    mainObjectURL: URL,
    additionalObjectURLs: [URL],
    outputURL: URL,
    clangURL: URL,
    context: XcodeIntegration.BuildContext
) throws -> ProcessExecution.Result {
    let inputs = [mainObjectURL] + additionalObjectURLs
    let result = try ProcessExecution.Runner().run(
        executable: clangURL,
        arguments: [
            "-target", context.environment.targetTriple,
            "-isysroot", context.environment.sdkRootURL.path,
            "-nostdlib", "-r",
        ] + inputs.map(\.path) + ["-o", outputURL.path],
        environment: environment,
        workingDirectory: context.environment.bridgeOutputURL
    )
    guard result.status == 0 else {
        let diagnostics = String(result.standardError.prefix(512 * 1_024))
        throw CLI.Error.input(
            diagnostics.isEmpty
                ? "hidden Bridge relocatable linker exited with status \(result.status)"
                : diagnostics
        )
    }
    try validateXcodeObject(
        outputURL,
        context: context,
        label: "combined hidden Bridge"
    )
    return result
}
}
