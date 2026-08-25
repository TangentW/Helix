import Foundation
import HelixCore
import HelixInterface

public enum SwiftFrontend {}

extension SwiftFrontend {
public enum InvocationKind: String, Codable, Hashable, Sendable {
    case typedAST = "typed_ast"
    case canonicalSIL = "canonical_sil"
    case symbolGraph = "symbol_graph"
    case sdkPath = "sdk_path"
    case sdkBuild = "sdk_build"
    case targetInfo = "target_info"
    case compilerVersion = "compiler_version"
    case demangle
    case other
}

public struct InvocationMetric: Hashable, Sendable {
    public var kind: SwiftFrontend.InvocationKind
    public var executableName: String
    public var durationMicroseconds: UInt64
    public var terminationStatus: Int32?
    public var standardOutputBytes: UInt64
    public var standardErrorBytes: UInt64

    public init(
        kind: SwiftFrontend.InvocationKind,
        executableName: String,
        durationMicroseconds: UInt64,
        terminationStatus: Int32?,
        standardOutputBytes: UInt64,
        standardErrorBytes: UInt64
    ) {
        self.kind = kind
        self.executableName = executableName
        self.durationMicroseconds = durationMicroseconds
        self.terminationStatus = terminationStatus
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
    }
}

public typealias InvocationObserver = @Sendable (SwiftFrontend.InvocationMetric) -> Void

public struct Output: Sendable {
    public var standardOutput: String
    public var standardError: String
    public var terminationStatus: Int32

    public init(standardOutput: String, standardError: String, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)
    case compilationFailed(status: Int32, diagnostics: String)
    case invalidUTF8Output
    case symbolGraphFailed(module: String, diagnostics: String)
    case invalidSymbolGraph(String)
    case sdkResolutionFailed(String)
    case sdkBuildMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .executableNotFound(path): "Swift compiler not found at \(path)"
        case let .launchFailed(reason): "failed to launch Swift compiler: \(reason)"
        case let .compilationFailed(status, diagnostics): "Swift compilation failed (\(status)): \(diagnostics)"
        case .invalidUTF8Output: "Swift frontend emitted non-UTF-8 output"
        case let .symbolGraphFailed(module, diagnostics):
            "Swift frontend could not extract the \(module) symbol graph: \(diagnostics)"
        case let .invalidSymbolGraph(reason): "Swift frontend emitted an invalid symbol graph: \(reason)"
        case let .sdkResolutionFailed(reason): "failed to resolve Apple SDK: \(reason)"
        case let .sdkBuildMismatch(expected, actual):
            "Apple SDK build mismatch; HLXI requires \(expected), installed SDK is \(actual)"
        }
    }
}

public struct Driver: Sendable {
    public struct SDKIdentity: Hashable, Sendable {
        public var name: String
        public var path: String
        public var buildVersion: String
    }

    public var compilerURL: URL
    public var environment: [String: String]
    public var invocationObserver: SwiftFrontend.InvocationObserver?

    public init(
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.compilerURL = compilerURL
        self.environment = environment
        self.invocationObserver = invocationObserver
    }

    public func emitCanonicalSIL(
        sourceFiles: [URL],
        moduleName: String,
        optimization: String = "-O",
        additionalArguments: [String] = [],
        purpose: SwiftFrontend.CanonicalSILPurpose = .implementationIdentity
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: compilerURL.path) else {
            throw SwiftFrontend.Error.executableNotFound(compilerURL.path)
        }
        let semanticArguments = purpose.applying(
            to: additionalArguments,
            compilerURL: compilerURL
        )
        let arguments = [
            "-emit-sil", optimization,
            "-module-name", moduleName,
            "-Xllvm", "-sil-print-debuginfo",
        ]
            + wholeModuleArguments(sourceCount: sourceFiles.count, existing: semanticArguments)
            + semanticArguments
            + sourceFiles.map(\.path)
            + ["-o", "-"]
        let output = try run(arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.compilationFailed(
                status: output.terminationStatus,
                diagnostics: output.standardError
            )
        }
        return output.standardOutput
    }

    /// Emits one JSON typed-AST document per primary source while preserving
    /// whole-module name lookup. Source offsets in this output are UTF-8 byte
    /// offsets and are consumed only with the exact captured toolchain.
    public func emitTypedAST(
        sourceFiles: [URL],
        primarySourceFiles: Set<URL>? = nil,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> String {
        try invocation.validate()
        let normalizedSources = sourceFiles.map(\.standardizedFileURL)
        let requestedPrimaries = primarySourceFiles?
            .map(\.standardizedFileURL)
        let primaries = requestedPrimaries.map(Set.init) ?? Set(normalizedSources)
        guard !sourceFiles.isEmpty,
              Set(normalizedSources).count == normalizedSources.count,
              !primaries.isEmpty,
              primaries.isSubset(of: Set(normalizedSources))
        else {
            throw SwiftFrontend.Error.compilationFailed(
                status: -1,
                diagnostics: "typed AST requires unique sources and a nonempty primary subset"
            )
        }
        let sdk = try sdkIdentity(name: invocation.sdkName)
        guard sdk.buildVersion == invocation.sdkBuild else {
            throw SwiftFrontend.Error.sdkBuildMismatch(
                expected: invocation.sdkBuild,
                actual: sdk.buildVersion
            )
        }
        let arguments = [
            "-frontend",
            "-dump-ast",
            "-dump-ast-format", "json",
            "-module-name", invocation.moduleName,
            "-target", invocation.targetTriple,
            "-sdk", sdk.path,
        ] + (try directFrontendArguments(invocation.semanticArguments))
            + normalizedSources.flatMap {
                primaries.contains($0) ? ["-primary-file", $0.path] : [$0.path]
            }
        let output = try run(arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.compilationFailed(
                status: output.terminationStatus,
                diagnostics: output.standardError
            )
        }
        return output.standardOutput
    }

    public func emitCanonicalSIL(
        sourceFiles: [URL],
        invocation: InterfaceArchive.FrontendInvocation,
        additionalArguments: [String] = [],
        purpose: SwiftFrontend.CanonicalSILPurpose = .implementationIdentity
    ) throws -> String {
        try invocation.validate()
        let sdk = try sdkIdentity(name: invocation.sdkName)
        guard sdk.buildVersion == invocation.sdkBuild else {
            throw SwiftFrontend.Error.sdkBuildMismatch(
                expected: invocation.sdkBuild,
                actual: sdk.buildVersion
            )
        }
        let semanticArguments = purpose.applying(
            to: invocation.semanticArguments + additionalArguments,
            compilerURL: compilerURL
        )
        let arguments = [
            "-emit-sil", invocation.optimization,
            "-module-name", invocation.moduleName,
            "-target", invocation.targetTriple,
            "-sdk", sdk.path,
            "-Xllvm", "-sil-print-debuginfo",
        ] + wholeModuleArguments(
            sourceCount: sourceFiles.count,
            existing: semanticArguments
        ) + semanticArguments
            + sourceFiles.map(\.path) + ["-o", "-"]
        let output = try run(arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.compilationFailed(
                status: output.terminationStatus,
                diagnostics: output.standardError
            )
        }
        return output.standardOutput
    }

    private func wholeModuleArguments(
        sourceCount: Int,
        existing: [String]
    ) -> [String] {
        guard sourceCount > 1,
              !existing.contains("-whole-module-optimization"),
              !existing.contains("-wmo")
        else { return [] }
        // The Swift driver otherwise creates one SIL output job per source,
        // which cannot represent the complete module on stdout.
        return ["-whole-module-optimization"]
    }

    /// Frontend invocations consume the value wrapped by each driver-level
    /// `-Xfrontend` directly.
    func directFrontendArguments(_ arguments: [String]) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index].hasPrefix("-Xfrontend=") {
                let value = String(arguments[index].dropFirst("-Xfrontend=".count))
                guard !value.isEmpty else {
                    throw SwiftFrontend.Error.compilationFailed(
                        status: -1,
                        diagnostics: "-Xfrontend= must include a frontend argument"
                    )
                }
                result.append(value)
                index += 1
                continue
            }
            guard arguments[index] == "-Xfrontend" else {
                result.append(arguments[index])
                index += 1
                continue
            }
            guard index + 1 < arguments.count,
                  arguments[index + 1] != "-Xfrontend"
            else {
                throw SwiftFrontend.Error.compilationFailed(
                    status: -1,
                    diagnostics: "-Xfrontend must be followed by one frontend argument"
                )
            }
            result.append(arguments[index + 1])
            index += 2
        }
        return result
    }

    public func sdkIdentity(name: String) throws -> SwiftFrontend.Driver.SDKIdentity {
        guard name == "iphoneos" || name == "iphonesimulator" else {
            throw SwiftFrontend.Error.sdkResolutionFailed("unsupported SDK name \(name)")
        }
        let xcrun = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            environment: environment,
            invocationObserver: invocationObserver
        )
        let path = try xcrun.run(arguments: ["--sdk", name, "--show-sdk-path"])
        let build = try xcrun.run(arguments: ["--sdk", name, "--show-sdk-build-version"])
        guard path.terminationStatus == 0, build.terminationStatus == 0 else {
            throw SwiftFrontend.Error.sdkResolutionFailed(
                (path.standardError + build.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let sdkPath = path.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = build.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sdkPath.isEmpty, !buildVersion.isEmpty,
              FileManager.default.fileExists(atPath: sdkPath)
        else {
            throw SwiftFrontend.Error.sdkResolutionFailed("xcrun returned an invalid SDK identity")
        }
        return .init(name: name, path: sdkPath, buildVersion: buildVersion)
    }

    public func run(arguments: [String], workingDirectory: URL? = nil) throws -> SwiftFrontend.Output {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let kind = invocationKind(arguments: arguments)
        let executableName = compilerURL.lastPathComponent
        var metricStatus: Int32?
        var metricStandardOutputBytes: UInt64 = 0
        var metricStandardErrorBytes: UInt64 = 0
        defer {
            invocationObserver?(
                .init(
                    kind: kind,
                    executableName: executableName,
                    durationMicroseconds:
                        (DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000,
                    terminationStatus: metricStatus,
                    standardOutputBytes: metricStandardOutputBytes,
                    standardErrorBytes: metricStandardErrorBytes
                )
            )
        }
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-frontend-capture-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: false)
        } catch {
            throw SwiftFrontend.Error.launchFailed("cannot create output capture: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let diagnosticsURL = captureDirectory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: diagnosticsURL.path, contents: nil)
        else {
            throw SwiftFrontend.Error.launchFailed("cannot create output capture files")
        }

        let process = Process()
        process.executableURL = compilerURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let stdout: FileHandle
        let stderr: FileHandle
        do {
            stdout = try FileHandle(forWritingTo: outputURL)
            stderr = try FileHandle(forWritingTo: diagnosticsURL)
        } catch {
            throw SwiftFrontend.Error.launchFailed("cannot open output capture: \(error)")
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw SwiftFrontend.Error.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        let outputData = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let errorData = try Data(contentsOf: diagnosticsURL, options: .mappedIfSafe)
        metricStandardOutputBytes = UInt64(outputData.count)
        metricStandardErrorBytes = UInt64(errorData.count)
        guard let output = String(data: outputData, encoding: .utf8),
              let diagnostics = String(data: errorData, encoding: .utf8)
        else {
            throw SwiftFrontend.Error.invalidUTF8Output
        }
        metricStatus = process.terminationStatus
        return .init(
            standardOutput: output,
            standardError: diagnostics,
            terminationStatus: process.terminationStatus
        )
    }

    private func invocationKind(arguments: [String]) -> SwiftFrontend.InvocationKind {
        let executable = compilerURL.lastPathComponent
        if executable == "swift-symbolgraph-extract"
            || arguments.first == "swift-symbolgraph-extract" {
            return .symbolGraph
        }
        if executable == "swift-demangle" || arguments.first == "swift-demangle" {
            return .demangle
        }
        if arguments.contains("-dump-ast") { return .typedAST }
        if arguments.contains("-emit-sil") { return .canonicalSIL }
        if arguments.contains("--show-sdk-path") { return .sdkPath }
        if arguments.contains("--show-sdk-build-version") { return .sdkBuild }
        if arguments.contains("-print-target-info") { return .targetInfo }
        if arguments.contains("-version") || arguments.contains("--version") {
            return .compilerVersion
        }
        return .other
    }
}
}
