import Foundation
import HelixCore
import HelixInterface

public enum SwiftFrontend {}

extension SwiftFrontend {
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
    case sdkResolutionFailed(String)
    case sdkBuildMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .executableNotFound(path): "Swift compiler not found at \(path)"
        case let .launchFailed(reason): "failed to launch Swift compiler: \(reason)"
        case let .compilationFailed(status, diagnostics): "Swift compilation failed (\(status)): \(diagnostics)"
        case .invalidUTF8Output: "Swift frontend emitted non-UTF-8 output"
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

    public init(
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.compilerURL = compilerURL
        self.environment = environment
    }

    public func emitCanonicalSIL(
        sourceFiles: [URL],
        moduleName: String,
        optimization: String = "-O",
        additionalArguments: [String] = []
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: compilerURL.path) else {
            throw SwiftFrontend.Error.executableNotFound(compilerURL.path)
        }
        let arguments = ["-emit-sil", optimization, "-module-name", moduleName]
            + wholeModuleArguments(sourceCount: sourceFiles.count, existing: additionalArguments)
            + additionalArguments
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
        additionalArguments: [String] = []
    ) throws -> String {
        try invocation.validate()
        let sdk = try sdkIdentity(name: invocation.sdkName)
        guard sdk.buildVersion == invocation.sdkBuild else {
            throw SwiftFrontend.Error.sdkBuildMismatch(
                expected: invocation.sdkBuild,
                actual: sdk.buildVersion
            )
        }
        let arguments = [
            "-emit-sil", invocation.optimization,
            "-module-name", invocation.moduleName,
            "-target", invocation.targetTriple,
            "-sdk", sdk.path,
        ] + wholeModuleArguments(
            sourceCount: sourceFiles.count,
            existing: invocation.semanticArguments + additionalArguments
        ) + invocation.semanticArguments + additionalArguments
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
    private func directFrontendArguments(_ arguments: [String]) throws -> [String] {
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
            environment: environment
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
        guard let output = String(data: outputData, encoding: .utf8),
              let diagnostics = String(data: errorData, encoding: .utf8)
        else {
            throw SwiftFrontend.Error.invalidUTF8Output
        }
        return .init(
            standardOutput: output,
            standardError: diagnostics,
            terminationStatus: process.terminationStatus
        )
    }
}
}
