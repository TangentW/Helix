#if os(macOS)
import Darwin
import Foundation
import HelixBuildTools
import HelixCore
import HelixDevTools

extension CLI {
struct XcodePostCompileResolver {
    private let runner = ProcessExecution.Runner()

    func resolve(
        plan: XcodeIntegration.HostPlan,
        planURL: URL,
        profileID: String,
        captureURL: URL,
        environment: [String: String],
        allowAttempt: Bool = false
    ) throws -> XcodeIntegration.BuildContext {
        try plan.validate()
        let profile = try plan.profile(id: profileID)
        let feature = try plan.feature(id: profile.featureID)
        let sourceRoot = try sourceRootURL(plan: plan, planURL: planURL)
        let capture = try readCapture(captureURL)
        let rawJob = try BuildCapture.SwiftInvocationRecord.decode(capture)
        let job = try BuildCapture.FrontendJobNormalizer().normalize(
            rawJob,
            workingDirectory: sourceRoot
        )
        guard job.moduleName == feature.moduleName else {
            throw XcodePostCompileError.mismatch(
                "captured module \(job.moduleName) does not match \(feature.moduleName)"
            )
        }

        let layout = try derivedDataLayout(
            captureURL: captureURL,
            configurationName: profile.configurationName,
            allowAttempt: allowAttempt
        )
        let target = try targetIdentity(job.targetTriple)
        guard target.platformName == layout.platformName else {
            throw XcodePostCompileError.mismatch(
                "captured target \(job.targetTriple) does not match "
                    + "DerivedData platform \(layout.platformName)"
            )
        }
        let compilerURL = URL(fileURLWithPath: job.executable)
            .standardizedFileURL
        guard compilerURL.path.hasPrefix("/"),
              ["swiftc", "swift-driver"].contains(compilerURL.lastPathComponent),
              FileManager.default.isExecutableFile(atPath: compilerURL.path)
        else {
            throw XcodePostCompileError.invalid("captured Swift compiler")
        }
        let sdkRoot = URL(fileURLWithPath: job.sdkPath).standardizedFileURL
        let toolchainEnvironment = developerEnvironment(
            compilerURL: compilerURL,
            inheriting: environment
        )
        let sdk = try sdkIdentity(
            name: target.sdkName,
            environment: toolchainEnvironment,
            workingDirectory: sourceRoot
        )
        guard sdk.path.resolvingSymlinksInPath() == sdkRoot.resolvingSymlinksInPath()
        else {
            throw XcodePostCompileError.mismatch(
                "captured SDK does not match the selected \(target.sdkName) SDK"
            )
        }
        let optimization = job.arguments.last(where: {
            ["-Onone", "-O", "-Osize"].contains($0)
        }) ?? "-Onone"
        let semanticArguments: [String]
        var moduleSearchArguments: [String]
        do {
            semanticArguments = try XcodeIntegration.CompilerArguments
                .semanticArguments(from: job.arguments)
            moduleSearchArguments = try XcodeIntegration.CompilerArguments
                .moduleSearchArguments(from: job.arguments)
        } catch let error as XcodeIntegration.CompilerArgumentError {
            throw XcodePostCompileError.invalid(error.description)
        }
        moduleSearchArguments.append(contentsOf: [
            "-I",
            layout.targetTemporaryDirectory
                .appendingPathComponent("Objects-normal", isDirectory: true)
                .appendingPathComponent(target.architecture, isDirectory: true)
                .path,
        ])
        let xcodeBuild = try selectedXcodeBuild(
            environment: toolchainEnvironment,
            workingDirectory: sourceRoot
        )
        let profileOutput = layout.productsDirectory
            .appendingPathComponent("HelixGenerated", isDirectory: true)
            .appendingPathComponent(profile.id, isDirectory: true)
        let buildNumber = capturedBuildNumber(job.arguments) ?? "1"
        let buildEnvironment = XcodeIntegration.BuildEnvironment(
            sourceRootURL: sourceRoot,
            buildDirectoryURL: layout.productsDirectory,
            profileOutputURL: profileOutput,
            configurationName: profile.configurationName,
            architecture: target.architecture,
            platformName: target.platformName,
            sdkName: target.sdkName,
            sdkRootURL: sdk.path,
            generatedModuleMapDirectoryURL: layout.intermediatesDirectory
                .appendingPathComponent(
                    "GeneratedModuleMaps-\(target.platformName)",
                    isDirectory: true
                ),
            sdkBuild: sdk.build,
            xcodeBuild: xcodeBuild,
            minimumOS: target.minimumOS,
            buildNumber: buildNumber,
            compilerURL: compilerURL,
            optimization: optimization,
            semanticArguments: semanticArguments,
            targetFrontendInvocationURL: captureURL.standardizedFileURL,
            bridgeModuleSearchArguments: moduleSearchArguments
        )
        return .init(
            planURL: planURL,
            plan: plan,
            profile: profile,
            feature: feature,
            environment: buildEnvironment
        )
    }

    private func sourceRootURL(
        plan: XcodeIntegration.HostPlan,
        planURL: URL
    ) throws -> URL {
        let components = plan.integrationRoot.split(separator: "/")
        var root = planURL.standardizedFileURL.deletingLastPathComponent()
        for expected in components.reversed() {
            guard root.lastPathComponent == expected else {
                throw XcodePostCompileError.mismatch(
                    "Host Plan is not stored under its declared integration root"
                )
            }
            root.deleteLastPathComponent()
        }
        let expectedPlan = root.appendingPathComponent(plan.integrationRoot)
            .appendingPathComponent("HostPlan.json")
            .standardizedFileURL
        guard expectedPlan == planURL.standardizedFileURL else {
            throw XcodePostCompileError.mismatch("Host Plan path is not canonical")
        }
        return root.resolvingSymlinksInPath()
    }

    private func readCapture(_ url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        var information = stat()
        guard path.hasPrefix("/"), lstat(path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o077 == 0,
              information.st_nlink == 1,
              information.st_size > 0,
              information.st_size
                <= BuildCapture.SwiftInvocationRecord.maximumByteCount
        else {
            throw XcodePostCompileError.invalid("private Swift compiler capture")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private struct DerivedDataLayout {
        var intermediatesDirectory: URL
        var productsDirectory: URL
        var platformName: String
        var targetTemporaryDirectory: URL
    }

    private func derivedDataLayout(
        captureURL: URL,
        configurationName: String,
        allowAttempt: Bool
    ) throws -> DerivedDataLayout {
        let capture = captureURL.standardizedFileURL
        let validNames = [XcodeIntegration.CompilerCapture.invocationFileName]
            + (allowAttempt ? [XcodeIntegration.CompilerCapture.attemptFileName] : [])
        guard validNames.contains(capture.lastPathComponent),
              capture.deletingLastPathComponent().lastPathComponent == "Helix"
        else {
            throw XcodePostCompileError.invalid("Swift compiler capture path")
        }
        let targetTemporaryDirectory = capture.deletingLastPathComponent()
            .deletingLastPathComponent()
        let configurationDirectory = targetTemporaryDirectory
            .deletingLastPathComponent()
        let configurationPlatform = configurationDirectory.lastPathComponent
        let prefix = configurationName + "-"
        guard configurationPlatform.hasPrefix(prefix) else {
            throw XcodePostCompileError.mismatch(
                "capture configuration does not match \(configurationName)"
            )
        }
        let platform = String(configurationPlatform.dropFirst(prefix.count))
        guard ["iphoneos", "iphonesimulator"].contains(platform) else {
            throw XcodePostCompileError.invalid("DerivedData platform \(platform)")
        }
        let intermediates = configurationDirectory.deletingLastPathComponent()
            .deletingLastPathComponent()
        guard intermediates.lastPathComponent == "Intermediates.noindex" else {
            throw XcodePostCompileError.invalid("DerivedData intermediates path")
        }
        let buildDirectory = intermediates.deletingLastPathComponent()
        let products = buildDirectory.appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent(configurationPlatform, isDirectory: true)
        guard contains(targetTemporaryDirectory, in: intermediates) else {
            throw XcodePostCompileError.invalid("target temporary directory")
        }
        return .init(
            intermediatesDirectory: intermediates,
            productsDirectory: products,
            platformName: platform,
            targetTemporaryDirectory: targetTemporaryDirectory
        )
    }

    private struct TargetIdentity {
        var architecture: String
        var minimumOS: String
        var platformName: String
        var sdkName: String
    }

    private func targetIdentity(_ triple: String) throws -> TargetIdentity {
        let marker = "-apple-ios"
        guard let range = triple.range(of: marker) else {
            throw XcodePostCompileError.invalid("target triple \(triple)")
        }
        let architecture = String(triple[..<range.lowerBound])
        var version = String(triple[range.upperBound...])
        let simulator = version.hasSuffix("-simulator")
        if simulator { version.removeLast("-simulator".count) }
        guard ["arm64", "x86_64"].contains(architecture),
              (try? Core.SemanticVersion(parsing: version)) != nil
        else {
            throw XcodePostCompileError.invalid("target triple \(triple)")
        }
        return .init(
            architecture: architecture,
            minimumOS: version,
            platformName: simulator ? "iphonesimulator" : "iphoneos",
            sdkName: simulator ? "iphonesimulator" : "iphoneos"
        )
    }

    private struct SDKIdentity {
        var path: URL
        var build: String
    }

    private func sdkIdentity(
        name: String,
        environment: [String: String],
        workingDirectory: URL
    ) throws -> SDKIdentity {
        let path = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", name, "--show-sdk-path"],
            environment: environment,
            workingDirectory: workingDirectory
        )
        let build = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", name, "--show-sdk-build-version"],
            environment: environment,
            workingDirectory: workingDirectory
        )
        let pathValue = path.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let buildValue = build.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard path.status == 0, build.status == 0, pathValue.hasPrefix("/"),
              !buildValue.isEmpty
        else {
            throw XcodePostCompileError.process("cannot resolve selected SDK identity")
        }
        return .init(
            path: URL(fileURLWithPath: pathValue).standardizedFileURL,
            build: buildValue
        )
    }

    private func selectedXcodeBuild(
        environment: [String: String],
        workingDirectory: URL
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
            throw XcodePostCompileError.process("cannot resolve selected Xcode build")
        }
        let value = String(line.dropFirst("Build version ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw XcodePostCompileError.process("selected Xcode build is empty")
        }
        return value
    }

    private func capturedBuildNumber(_ arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(of: "-user-module-version"),
              index + 1 < arguments.count
        else { return nil }
        let value = arguments[index + 1].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return value
    }

    private func developerEnvironment(
        compilerURL: URL,
        inheriting environment: [String: String]
    ) -> [String: String] {
        var result = environment
        let marker = "/Contents/Developer/"
        if let range = compilerURL.path.range(of: marker) {
            result["DEVELOPER_DIR"] = String(
                compilerURL.path[..<compilerURL.path.index(before: range.upperBound)]
            )
        }
        return result
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

enum XcodePostCompileError: Swift.Error, CustomStringConvertible {
    case invalid(String)
    case mismatch(String)
    case process(String)

    var description: String {
        switch self {
        case let .invalid(reason), let .mismatch(reason), let .process(reason): reason
        }
    }
}
}
#endif
