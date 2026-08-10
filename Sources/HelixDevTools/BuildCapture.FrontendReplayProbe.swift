import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol

extension BuildCapture {
public struct ProbeRequest: Sendable {
    public var job: BuildCapture.NormalizedFrontendJob
    public var compilerURL: URL
    public var workingDirectory: URL
    public var platform: DevProtocol.ApplePlatform

    public init(
        job: BuildCapture.NormalizedFrontendJob,
        compilerURL: URL,
        workingDirectory: URL,
        platform: DevProtocol.ApplePlatform
    ) {
        self.job = job
        self.compilerURL = compilerURL
        self.workingDirectory = workingDirectory
        self.platform = platform
    }
}

public struct ProbeResult: Hashable, Sendable {
    public var swiftCompilerFingerprint: String
    public var xcodeBuild: String
    public var sdkBuild: String
    public var replayArtifactCount: UInt32
    public var toolchainCapabilities: DevBuildManifest.ToolchainCapabilities

    public init(
        swiftCompilerFingerprint: String,
        xcodeBuild: String,
        sdkBuild: String,
        replayArtifactCount: UInt32,
        toolchainCapabilities: DevBuildManifest.ToolchainCapabilities
    ) {
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.replayArtifactCount = replayArtifactCount
        self.toolchainCapabilities = toolchainCapabilities
    }
}

public protocol Probing: Sendable {
    func probe(_ request: BuildCapture.ProbeRequest) throws -> BuildCapture.ProbeResult
}

/// Replays the captured frontend job with only output locations redirected.
/// Capability checks use fresh sources and therefore cannot be satisfied by a
/// stale build artifact or by merely recognizing an underscored flag name.
public struct FrontendReplayProbe<Runner: ProcessExecution.Running>: BuildCapture.Probing {
    public var runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    public func probe(_ request: BuildCapture.ProbeRequest) throws -> BuildCapture.ProbeResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-dev-prepare-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let environment = environmentForCapturedToolchain(request)
        let replayCount = try replay(
            request.job,
            workingDirectory: request.workingDirectory,
            outputDirectory: directory.appendingPathComponent("Replay", isDirectory: true),
            environment: environment
        )
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: request.compilerURL
        )
        let sdkBuild = try verifySDKIdentity(request, environment: environment)
        let xcodeBuild = try readXcodeBuild(
            workingDirectory: request.workingDirectory,
            environment: environment
        )
        let capabilities = try probeCapabilities(
            request,
            directory: directory.appendingPathComponent("Capabilities", isDirectory: true),
            environment: environment
        )
        return .init(
            swiftCompilerFingerprint: toolchain.fingerprint,
            xcodeBuild: xcodeBuild,
            sdkBuild: sdkBuild,
            replayArtifactCount: UInt32(replayCount),
            toolchainCapabilities: capabilities
        )
    }

    private func replay(
        _ job: BuildCapture.NormalizedFrontendJob,
        workingDirectory: URL,
        outputDirectory: URL,
        environment: [String: String]
    ) throws -> Int {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let rewritten = try ReplayOutputs.rewrite(
            job.arguments,
            into: outputDirectory
        )
        guard !rewritten.expectedFiles.isEmpty else {
            throw BuildCapture.Error.replayFailed(
                "captured command has no replayable output artifact"
            )
        }
        let result = try runner.run(
            executable: URL(fileURLWithPath: job.executable),
            arguments: rewritten.arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        guard result.status == 0 else {
            throw BuildCapture.Error.replayFailed(
                Self.boundedDiagnostics(result.standardError, status: result.status)
            )
        }
        let emitted = rewritten.expectedFiles.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        guard !emitted.isEmpty else {
            throw BuildCapture.Error.replayFailed(
                "isolated replay succeeded but emitted none of its declared outputs"
            )
        }
        return emitted.count
    }

    private func verifySDKIdentity(
        _ request: BuildCapture.ProbeRequest,
        environment: [String: String]
    ) throws -> String {
        let sdkName: String
        switch request.platform {
        case .iOS: sdkName = "iphoneos"
        case .iOSSimulator: sdkName = "iphonesimulator"
        case .macOS: sdkName = "macosx"
        }
        let path = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", sdkName, "--show-sdk-path"],
            environment: environment,
            workingDirectory: request.workingDirectory
        )
        let build = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", sdkName, "--show-sdk-build-version"],
            environment: environment,
            workingDirectory: request.workingDirectory
        )
        guard path.status == 0, build.status == 0 else {
            throw BuildCapture.Error.replayFailed(
                Self.boundedDiagnostics(path.standardError + build.standardError, status: build.status)
            )
        }
        let currentPath = path.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = build.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentPath.isEmpty, !buildVersion.isEmpty,
              URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: request.job.sdkPath)
                    .resolvingSymlinksInPath().standardizedFileURL
        else {
            throw BuildCapture.Error.replayFailed(
                "captured SDK path does not match the selected Xcode SDK"
            )
        }
        return buildVersion
    }

    private func readXcodeBuild(
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-version"],
            environment: environment,
            workingDirectory: workingDirectory
        )
        guard result.status == 0,
              let line = result.standardOutput.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.hasPrefix("Build version ") })
        else {
            throw BuildCapture.Error.replayFailed(
                Self.boundedDiagnostics(result.standardError, status: result.status)
            )
        }
        let value = String(line.dropFirst("Build version ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BuildCapture.Error.replayFailed("xcodebuild returned an empty build identity")
        }
        return value
    }

    private func probeCapabilities(
        _ request: BuildCapture.ProbeRequest,
        directory: URL,
        environment: [String: String]
    ) throws -> DevBuildManifest.ToolchainCapabilities {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseURL = directory.appendingPathComponent("HelixPrepareProbe.Base.swift")
        let patchURL = directory.appendingPathComponent("HelixPrepareProbe.Patch.swift")
        let baseSource = """
        public final class ProbeType {
            private func hiddenValue() -> Int { 40 }
            public init() {}
            public func exposedValue(_ input: Int) -> Int { hiddenValue() + input }
        }
        """
        let patchSource = """
        @_private(sourceFile: \(String(reflecting: baseURL.lastPathComponent))) import HelixPrepareProbe

        extension ProbeType {
            @_dynamicReplacement(for: exposedValue(_:))
            public func replacementExposedValue(_ input: Int) -> Int {
                hiddenValue() + input + 1
            }
        }
        """
        try Data(baseSource.utf8).write(to: baseURL, options: .atomic)
        try Data(patchSource.utf8).write(to: patchURL, options: .atomic)

        let common = [
            "-target", request.job.targetTriple,
            "-sdk", request.job.sdkPath,
            "-Onone",
        ]
        let implicit = try runner.run(
            executable: request.compilerURL,
            arguments: [
                baseURL.path, "-emit-silgen", "-module-name", "HelixPrepareProbe",
            ] + common + [
                "-Xfrontend", "-enable-implicit-dynamic", "-o", "-",
            ],
            environment: environment,
            workingDirectory: directory
        )
        let implicitDynamic = implicit.status == 0
            && implicit.standardOutput.contains("[dynamically_replacable]")
            && implicit.standardOutput.contains("dynamic_function_ref")

        let canonical = try runner.run(
            executable: request.compilerURL,
            arguments: [
                baseURL.path, "-emit-sil", "-O", "-module-name", "HelixPrepareCanonicalProbe",
                "-target", request.job.targetTriple,
                "-sdk", request.job.sdkPath,
                "-o", "-",
            ],
            environment: environment,
            workingDirectory: directory
        )
        let canonicalSIL = canonical.status == 0
            && canonical.standardOutput.contains("sil_stage canonical")

        let moduleURL = directory.appendingPathComponent("HelixPrepareProbe.swiftmodule")
        let objectURL = directory.appendingPathComponent("HelixPrepareProbe.o")
        let module = try runner.run(
            executable: request.compilerURL,
            arguments: [
                baseURL.path, "-emit-object", "-emit-module", "-parse-as-library",
                "-module-name", "HelixPrepareProbe",
            ] + common + [
                "-Xfrontend", "-enable-implicit-dynamic",
                "-Xfrontend", "-enable-private-imports",
                "-emit-module-path", moduleURL.path,
                "-o", objectURL.path,
            ],
            environment: environment,
            workingDirectory: directory
        )
        var privateImports = false
        var dynamicReplacementChaining = false
        if module.status == 0 {
            let privateImport = try runner.run(
                executable: request.compilerURL,
                arguments: [
                    patchURL.path, "-emit-silgen", "-parse-as-library",
                    "-module-name", "HelixPreparePatchProbe",
                ] + common + [
                    "-I", directory.path,
                    "-Xfrontend", "-enable-private-imports",
                    "-o", "-",
                ],
                environment: environment,
                workingDirectory: directory
            )
            privateImports = privateImport.status == 0
                && privateImport.standardOutput.contains("dynamic_replacement_for")
            if privateImports {
                let chaining = try runner.run(
                    executable: request.compilerURL,
                    arguments: [
                        patchURL.path, "-emit-silgen", "-parse-as-library",
                        "-module-name", "HelixPrepareChainingProbe",
                    ] + common + [
                        "-I", directory.path,
                        "-Xfrontend", "-enable-private-imports",
                        "-Xfrontend", "-enable-dynamic-replacement-chaining",
                        "-o", "-",
                    ],
                    environment: environment,
                    workingDirectory: directory
                )
                dynamicReplacementChaining = chaining.status == 0
                    && chaining.standardOutput.contains("dynamic_replacement_for")
            }
        }
        return .init(
            implicitDynamic: implicitDynamic,
            privateImports: privateImports,
            dynamicReplacementChaining: dynamicReplacementChaining,
            nativeInterposing: false,
            canonicalSIL: canonicalSIL
        )
    }

    private func environmentForCapturedToolchain(
        _ request: BuildCapture.ProbeRequest
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for path in [request.compilerURL.path, request.job.sdkPath] {
            let marker = "/Contents/Developer"
            if let range = path.range(of: marker) {
                environment["DEVELOPER_DIR"] = String(path[..<range.upperBound])
                break
            }
        }
        return environment
    }

    private static func boundedDiagnostics(_ value: String, status: Int32) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(text.prefix(16 * 1_024))
        return bounded.isEmpty ? "process exited with status \(status)" : bounded
    }
}

private struct ReplayOutputs {
    var arguments: [String]
    var expectedFiles: [URL]

    static func rewrite(_ arguments: [String], into directory: URL) throws -> Self {
        let fileFlags: Set<String> = [
            "-o", "-emit-module-path", "-emit-module-doc-path",
            "-emit-module-source-info-path", "-emit-dependencies-path",
            "-emit-reference-dependencies-path", "-serialize-diagnostics-path",
            "-emit-objc-header-path", "-emit-tbd-path", "-emit-api-descriptor-path",
            "-emit-const-values-path", "-emit-abi-descriptor-path",
            "-emit-loaded-module-trace-path", "-index-unit-output-path",
            "-save-optimization-record-path", "-emit-pcm-path",
        ]
        let directoryFlags: Set<String> = ["-index-store-path", "-pch-output-dir"]
        let mapFlags: Set<String> = ["-output-file-map", "-supplementary-output-file-map"]
        var result: [String] = []
        var expected: [URL] = []
        var index = 0
        var outputIndex = 0

        func nextOutput(original: String) throws -> URL {
            let suffix: String
            let extensionValue = URL(fileURLWithPath: original).pathExtension
            suffix = extensionValue.isEmpty ? ".out" : ".\(extensionValue)"
            let url = directory.appendingPathComponent("artifact-\(outputIndex)\(suffix)")
            outputIndex += 1
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            expected.append(url)
            return url
        }

        while index < arguments.count {
            let argument = arguments[index]
            if fileFlags.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw BuildCapture.Error.replayFailed("\(argument) has no output path")
                }
                let url = try nextOutput(original: arguments[index + 1])
                result.append(argument)
                result.append(url.path)
                index += 2
                continue
            }
            if directoryFlags.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw BuildCapture.Error.replayFailed("\(argument) has no output directory")
                }
                let url = directory.appendingPathComponent("directory-\(outputIndex)", isDirectory: true)
                outputIndex += 1
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                result.append(argument)
                result.append(url.path)
                index += 2
                continue
            }
            if mapFlags.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw BuildCapture.Error.replayFailed("\(argument) has no map path")
                }
                let mapURL = URL(fileURLWithPath: arguments[index + 1])
                let data = try Data(contentsOf: mapURL, options: .mappedIfSafe)
                guard data.count <= 16 * 1_024 * 1_024 else {
                    throw BuildCapture.Error.replayFailed("output file map exceeds 16 MiB")
                }
                let object = try JSONSerialization.jsonObject(with: data)
                func rewriteObject(_ value: Any) throws -> Any {
                    if let dictionary = value as? [String: Any] {
                        return try dictionary.mapValues(rewriteObject)
                    }
                    if let values = value as? [Any] {
                        return try values.map(rewriteObject)
                    }
                    if let path = value as? String, !path.isEmpty {
                        return try nextOutput(original: path).path
                    }
                    return value
                }
                let rewrittenObject = try rewriteObject(object)
                let rewrittenMapURL = directory.appendingPathComponent("output-map-\(outputIndex).json")
                outputIndex += 1
                try JSONSerialization.data(withJSONObject: rewrittenObject, options: [.sortedKeys])
                    .write(to: rewrittenMapURL, options: .atomic)
                result.append(argument)
                result.append(rewrittenMapURL.path)
                index += 2
                continue
            }
            result.append(argument)
            index += 1
        }
        return .init(arguments: result, expectedFiles: expected)
    }
}

public typealias DefaultFrontendReplayProbe = BuildCapture.FrontendReplayProbe<ProcessExecution.Runner>
}
