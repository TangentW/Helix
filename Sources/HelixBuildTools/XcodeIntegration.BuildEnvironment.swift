import Foundation
import HelixCore
import HelixInterface

extension XcodeIntegration {
public struct BuildEnvironment: Hashable, Sendable {
    public var sourceRootURL: URL
    public var buildDirectoryURL: URL
    public var profileOutputURL: URL
    public var configurationName: String
    public var architecture: String
    public var platformName: String
    public var sdkName: String
    public var sdkRootURL: URL
    public var generatedModuleMapDirectoryURL: URL
    public var sdkBuild: String
    public var xcodeBuild: String
    public var minimumOS: String
    public var buildNumber: String
    public var compilerURL: URL
    public var optimization: String
    public var semanticArguments: [String]
    /// Capture written beside this target's Xcode intermediate objects. Only
    /// the Feature prepare phase consumes it directly.
    public var targetFrontendInvocationURL: URL?
    /// App-target module search paths needed to compile the hidden Bridge.
    public var bridgeModuleSearchArguments: [String]

    public init(
        sourceRootURL: URL,
        buildDirectoryURL: URL,
        profileOutputURL: URL,
        configurationName: String,
        architecture: String,
        platformName: String,
        sdkName: String,
        sdkRootURL: URL,
        generatedModuleMapDirectoryURL: URL,
        sdkBuild: String,
        xcodeBuild: String,
        minimumOS: String,
        buildNumber: String,
        compilerURL: URL,
        optimization: String,
        semanticArguments: [String],
        targetFrontendInvocationURL: URL?,
        bridgeModuleSearchArguments: [String]
    ) {
        self.sourceRootURL = sourceRootURL
        self.buildDirectoryURL = buildDirectoryURL
        self.profileOutputURL = profileOutputURL
        self.configurationName = configurationName
        self.architecture = architecture
        self.platformName = platformName
        self.sdkName = sdkName
        self.sdkRootURL = sdkRootURL
        self.generatedModuleMapDirectoryURL = generatedModuleMapDirectoryURL
        self.sdkBuild = sdkBuild
        self.xcodeBuild = xcodeBuild
        self.minimumOS = minimumOS
        self.buildNumber = buildNumber
        self.compilerURL = compilerURL
        self.optimization = optimization
        self.semanticArguments = semanticArguments
        self.targetFrontendInvocationURL = targetFrontendInvocationURL
        self.bridgeModuleSearchArguments = bridgeModuleSearchArguments
    }
    public var shellOutputURL: URL {
        profileOutputURL.appendingPathComponent("Shell", isDirectory: true)
    }

    public var finalArchiveURL: URL {
        profileOutputURL.appendingPathComponent("Shell.final.hlxi")
    }

    public var devConfigurationURL: URL {
        profileOutputURL.appendingPathComponent("HelixDev.json")
    }

    /// Validated capture published atomically with the prepared Shell for App
    /// phases and Scheme actions that run outside the Feature target.
    public var frontendInvocationURL: URL {
        shellOutputURL.appendingPathComponent(
            XcodeIntegration.CompilerCapture.shellRelativeInvocationPath
        )
    }

    public var bridgeOutputURL: URL {
        profileOutputURL.appendingPathComponent("Bridge", isDirectory: true)
    }

    public var bridgeObjectURL: URL {
        bridgeOutputURL.appendingPathComponent("HelixBridge.o")
    }

    public var bootstrapObjectURL: URL {
        bridgeOutputURL.appendingPathComponent("HelixBootstrap.o")
    }

    public var targetTriple: String {
        let suffix = sdkName == "iphonesimulator" ? "-simulator" : ""
        return "\(architecture)-apple-ios\(minimumOS)\(suffix)"
    }
}

public struct BuildContext: Sendable {
    public var planURL: URL
    public var plan: XcodeIntegration.HostPlan
    public var profile: XcodeIntegration.Profile
    public var feature: XcodeIntegration.Feature
    public var environment: XcodeIntegration.BuildEnvironment

    public var indexingOptions: FrontendReceipt.IndexingOptions {
        feature.indexing ?? .init(failurePolicy: profile.workflow == .liveReload ? .excludeUnresolved : .strict)
    }

    public init(
        planURL: URL,
        plan: XcodeIntegration.HostPlan,
        profile: XcodeIntegration.Profile,
        feature: XcodeIntegration.Feature,
        environment: XcodeIntegration.BuildEnvironment
    ) {
        self.planURL = planURL
        self.plan = plan
        self.profile = profile
        self.feature = feature
        self.environment = environment
    }
}

public enum EnvironmentError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case missing(String)
    case invalid(name: String, value: String)
    case mismatch(name: String, expected: String, actual: String)
    case unsafePath(String)
    case malformedArguments(String)

    public var description: String {
        switch self {
        case let .missing(name):
            "missing Xcode build setting \(name)"
        case let .invalid(name, value):
            "invalid Xcode build setting \(name)=\(value)"
        case let .mismatch(name, expected, actual):
            "Xcode build setting \(name) is \(actual); Host Plan requires \(expected)"
        case let .unsafePath(path):
            "Xcode integration path escapes its declared root: \(path)"
        case let .malformedArguments(reason):
            "cannot parse Xcode Swift settings: \(reason)"
        }
    }
}

public struct EnvironmentResolver: Sendable {
    public init() {}

    public func resolve(
        plan: XcodeIntegration.HostPlan,
        planURL: URL,
        profileID: String,
        variables: [String: String] = ProcessInfo.processInfo.environment,
        requireFeatureCompilerSettings: Bool = true,
        requireTargetCompilerCapture: Bool = false
    ) throws -> XcodeIntegration.BuildContext {
        try plan.validate()
        let profile = try plan.profile(id: profileID)
        let feature = try plan.feature(id: profile.featureID)
        let xcodeSourceRoot = try path("SRCROOT", in: variables).resolvingSymlinksInPath()
        let resolvedPlanURL = planURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(resolvedPlanURL, in: xcodeSourceRoot) else {
            throw XcodeIntegration.EnvironmentError.unsafePath(planURL.path)
        }
        try matchIfPresent("HELIX_PROFILE_ID", expected: profile.id, variables: variables)
        try matchIfPresent(
            "HELIX_WORKFLOW",
            expected: profile.workflow.rawValue,
            variables: variables
        )
        try matchIfPresent(
            "HELIX_RUNTIME_PRODUCT",
            expected: profile.runtimePackageProduct,
            variables: variables
        )

        let configuration = try required("CONFIGURATION", in: variables)
        guard configuration == profile.configurationName else {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: "CONFIGURATION",
                expected: profile.configurationName,
                actual: configuration
            )
        }
        // Configuration-qualified products keep Debug and Release profiles
        // isolated while matching the PBX file references linked by the App.
        let buildDirectory = try path("BUILT_PRODUCTS_DIR", in: variables)
        let targetFrontendInvocation: URL?
        if requireTargetCompilerCapture {
            let objectRoot = try path("OBJROOT", in: variables)
            let targetTemporaryDirectory = try path("TARGET_TEMP_DIR", in: variables)
            guard Self.contains(targetTemporaryDirectory, in: objectRoot),
                  Self.contains(
                      targetTemporaryDirectory.resolvingSymlinksInPath(),
                      in: objectRoot.resolvingSymlinksInPath()
                  )
            else {
                throw XcodeIntegration.EnvironmentError.unsafePath(
                    targetTemporaryDirectory.path
                )
            }
            targetFrontendInvocation = targetTemporaryDirectory
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent(
                    XcodeIntegration.CompilerCapture.invocationFileName
                )
        } else {
            targetFrontendInvocation = nil
        }
        let expectedProfileOutput = buildDirectory
            .appendingPathComponent("HelixGenerated", isDirectory: true)
            .appendingPathComponent(profile.id, isDirectory: true)
            .standardizedFileURL
        let profileOutput: URL
        if let configured = nonempty("HELIX_PROFILE_OUTPUT_DIR", in: variables) {
            profileOutput = URL(fileURLWithPath: configured, isDirectory: true)
                .standardizedFileURL
            guard profileOutput.path == expectedProfileOutput.path else {
                throw XcodeIntegration.EnvironmentError.mismatch(
                    name: "HELIX_PROFILE_OUTPUT_DIR",
                    expected: expectedProfileOutput.path,
                    actual: profileOutput.path
                )
            }
        } else {
            profileOutput = expectedProfileOutput
        }
        guard Self.contains(profileOutput, in: buildDirectory),
              Self.contains(
                  profileOutput.resolvingSymlinksInPath(),
                  in: buildDirectory.resolvingSymlinksInPath()
              )
        else {
            throw XcodeIntegration.EnvironmentError.unsafePath(profileOutput.path)
        }

        let platform = try required("PLATFORM_NAME", in: variables)
        let sdkName: String
        switch platform {
        case "iphonesimulator": sdkName = "iphonesimulator"
        case "iphoneos": sdkName = "iphoneos"
        default:
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "PLATFORM_NAME",
                value: platform
            )
        }
        // Scheme pre-actions expose SDKROOT as a logical name such as
        // `iphonesimulator26.5`; target phases also provide the resolved SDK_DIR.
        let sdkRoot = try path(
            nonempty("SDK_DIR", in: variables) == nil ? "SDKROOT" : "SDK_DIR",
            in: variables
        )
        let generatedModuleMaps = try path("GENERATED_MODULEMAP_DIR", in: variables)
        let architecture = try architecture(in: variables)
        let minimumOS = try required("IPHONEOS_DEPLOYMENT_TARGET", in: variables)
        _ = try Core.SemanticVersion(parsing: minimumOS)
        let sdkBuild = try required("SDK_PRODUCT_BUILD_VERSION", in: variables)
        let xcodeBuild = try required("XCODE_PRODUCT_BUILD_VERSION", in: variables)
        let buildNumber = try required("CURRENT_PROJECT_VERSION", in: variables)
        let optimization = nonempty("SWIFT_OPTIMIZATION_LEVEL", in: variables) ?? "-Onone"
        guard ["-Onone", "-O", "-Osize"].contains(optimization) else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "SWIFT_OPTIMIZATION_LEVEL",
                value: optimization
            )
        }
        let compiler = try compilerURL(in: variables)
        let bridgeModuleSearchArguments = try moduleSearchArguments(variables: variables)
        let semanticArguments = try requireFeatureCompilerSettings
            ? semanticArguments(variables: variables)
            : []
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: feature.moduleName,
            targetTriple: "\(architecture)-apple-ios\(minimumOS)"
                + (sdkName == "iphonesimulator" ? "-simulator" : ""),
            sdkName: sdkName,
            sdkBuild: sdkBuild,
            optimization: optimization,
            semanticArguments: semanticArguments
        )
        try invocation.validate()

        let environment = XcodeIntegration.BuildEnvironment(
            sourceRootURL: xcodeSourceRoot,
            buildDirectoryURL: buildDirectory,
            profileOutputURL: profileOutput,
            configurationName: configuration,
            architecture: architecture,
            platformName: platform,
            sdkName: sdkName,
            sdkRootURL: sdkRoot,
            generatedModuleMapDirectoryURL: generatedModuleMaps,
            sdkBuild: sdkBuild,
            xcodeBuild: xcodeBuild,
            minimumOS: minimumOS,
            buildNumber: buildNumber,
            compilerURL: compiler,
            optimization: optimization,
            semanticArguments: semanticArguments,
            targetFrontendInvocationURL: targetFrontendInvocation,
            bridgeModuleSearchArguments: bridgeModuleSearchArguments
        )
        return .init(
            planURL: planURL,
            plan: plan,
            profile: profile,
            feature: feature,
            environment: environment
        )
    }

    private func semanticArguments(
        variables: [String: String]
    ) throws -> [String] {
        var result = ["-parse-as-library"]
        if let version = nonempty("SWIFT_VERSION", in: variables) {
            guard let languageVersion = version.split(separator: ".").first,
                  ["5", "6"].contains(String(languageVersion))
            else {
                throw XcodeIntegration.EnvironmentError.invalid(
                    name: "SWIFT_VERSION",
                    value: version
                )
            }
            result.append(contentsOf: ["-swift-version", String(languageVersion)])
        }
        let conditions = try words(
            nonempty("SWIFT_ACTIVE_COMPILATION_CONDITIONS", in: variables) ?? ""
        )
        for condition in conditions where condition != "$(inherited)" {
            guard Self.isSwiftIdentifier(condition) else {
                throw XcodeIntegration.EnvironmentError.invalid(
                    name: "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
                    value: condition
                )
            }
            result.append(contentsOf: ["-D", condition])
        }
        if let flags = nonempty("OTHER_SWIFT_FLAGS", in: variables) {
            result.append(contentsOf: try words(flags).filter { $0 != "$(inherited)" })
        }
        result.append(contentsOf: try moduleSearchArguments(variables: variables))
        guard result.contains("-enable-private-imports") else {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: "OTHER_SWIFT_FLAGS",
                expected: "-Xfrontend -enable-private-imports",
                actual: variables["OTHER_SWIFT_FLAGS"] ?? ""
            )
        }
        for requiredFlag in [
            "-enable-implicit-dynamic",
            "-enable-dynamic-replacement-chaining",
        ] where !result.contains(requiredFlag) {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: "OTHER_SWIFT_FLAGS",
                expected: requiredFlag,
                actual: variables["OTHER_SWIFT_FLAGS"] ?? ""
            )
        }
        guard !result.contains(where: { $0.contains("$" ) }) else {
            throw XcodeIntegration.EnvironmentError.malformedArguments(
                "an inherited build-setting expression was not expanded"
            )
        }
        return result
    }

    private func moduleSearchArguments(
        variables: [String: String]
    ) throws -> [String] {
        var result: [String] = []
        for (setting, flag) in [
            ("SWIFT_INCLUDE_PATHS", "-I"),
            ("FRAMEWORK_SEARCH_PATHS", "-F"),
        ] {
            guard let value = nonempty(setting, in: variables) else { continue }
            for path in try words(value) where path != "$(inherited)" {
                guard !path.contains("$") else {
                    throw XcodeIntegration.EnvironmentError.malformedArguments(
                        "an inherited build-setting expression was not expanded"
                    )
                }
                result.append(contentsOf: [flag, path])
            }
        }
        return result
    }

    private func architecture(in variables: [String: String]) throws -> String {
        // Scheme pre/post-actions can expose the host CPU through CURRENT_ARCH
        // (for example arm64e) before Xcode enters a target compile task. ARCHS
        // is the target contract at that point, so prefer its single resolved
        // value. A Helix Shell is intentionally built for one target triple.
        let value: String
        if let configured = nonempty("ARCHS", in: variables) {
            let architectures = try words(configured).filter {
                $0 != "undefined_arch" && $0 != "$(inherited)"
            }
            guard architectures.count == 1, let first = architectures.first else {
                throw XcodeIntegration.EnvironmentError.invalid(
                    name: "ARCHS",
                    value: configured
                )
            }
            value = first
        } else if let current = nonempty("CURRENT_ARCH", in: variables),
                  current != "undefined_arch" {
            value = current
        } else {
            let architectures = try words(try required("ARCHS", in: variables))
            guard architectures.count == 1, let first = architectures.first else {
                throw XcodeIntegration.EnvironmentError.invalid(
                    name: "ARCHS",
                    value: variables["ARCHS"] ?? ""
                )
            }
            value = first
        }
        guard ["arm64", "x86_64"].contains(value) else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: nonempty("ARCHS", in: variables) == nil ? "CURRENT_ARCH" : "ARCHS",
                value: value
            )
        }
        return value
    }

    private func compilerURL(in variables: [String: String]) throws -> URL {
        var pathValues: [String] = []
        // Helix's SWIFT_EXEC is a transparent capture proxy. Keep the
        // active toolchain compiler explicit so Shell generation and replay do
        // not accidentally identify the proxy as the Swift toolchain.
        if let swift = nonempty("HELIX_REAL_SWIFT_EXEC", in: variables) {
            pathValues.append(swift)
        }
        if let swift = nonempty("SWIFT_EXEC", in: variables) {
            pathValues.append(swift)
        }
        if let toolchain = nonempty("TOOLCHAIN_DIR", in: variables) {
            pathValues.append(
                URL(fileURLWithPath: toolchain)
                    .appendingPathComponent("usr/bin/swiftc").path
            )
        }
        pathValues.append("/usr/bin/swiftc")
        let candidates = pathValues.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        guard candidates.allSatisfy({
            $0.path.hasPrefix("/") && !$0.path.contains("\u{0}")
        }) else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "SWIFT_EXEC",
                value: pathValues.first ?? ""
            )
        }
        // A Scheme action may receive a transient SWIFT_EXEC placeholder that
        // Xcode never materializes. The selected toolchain remains authoritative
        // and points at the same compiler used by the target build.
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) ?? candidates[0]
    }

    private func path(
        _ name: String,
        in variables: [String: String]
    ) throws -> URL {
        let value = try required(name, in: variables)
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw XcodeIntegration.EnvironmentError.invalid(name: name, value: value)
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func required(
        _ name: String,
        in variables: [String: String]
    ) throws -> String {
        guard let value = nonempty(name, in: variables) else {
            throw XcodeIntegration.EnvironmentError.missing(name)
        }
        guard value.utf8.count <= 64 * 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw XcodeIntegration.EnvironmentError.invalid(name: name, value: value)
        }
        return value
    }

    private func nonempty(
        _ name: String,
        in variables: [String: String]
    ) -> String? {
        variables[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func matchIfPresent(
        _ name: String,
        expected: String,
        variables: [String: String]
    ) throws {
        guard let actual = nonempty(name, in: variables) else { return }
        guard actual == expected else {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: name,
                expected: expected,
                actual: actual
            )
        }
    }

    private func words(_ value: String) throws -> [String] {
        do {
            return try XcodeIntegration.ShellWords.parse(value)
        } catch {
            throw XcodeIntegration.EnvironmentError.malformedArguments(
                String(describing: error)
            )
        }
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

private enum ShellWords {
    enum Error: Swift.Error, CustomStringConvertible {
        case unterminatedQuote
        case danglingEscape

        var description: String {
            switch self {
            case .unterminatedQuote: "unterminated quote"
            case .danglingEscape: "dangling escape"
            }
        }
    }

    static func parse(_ text: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                started = true
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                started = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                started = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    result.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        guard quote == nil else { throw Error.unterminatedQuote }
        guard !escaped else { throw Error.danglingEscape }
        if started { result.append(current) }
        return result
    }
}
}
