import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevTools
import HelixInterface
import HelixPatch
import HelixReleaseTools

extension CLI {
public struct CompiledFunction: Codable, Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var entryIndex: Core.EntryIndex?
    public var declaration: String
    public var bodyFingerprint: Core.Digest
}

public struct CompilationReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var bytecodeSHA256: Core.Digest
    public var bytecodeByteLength: UInt64
    public var moduleName: String
    public var shellInterfaceHash: Core.Digest
    public var toolchainFingerprint: String
    public var capabilities: [Core.Capability]
    public var changedFunctions: [CLI.CompiledFunction]

    init(_ result: ReleaseCompiler.BuildResult) throws {
        schemaVersion = Self.currentSchemaVersion
        bytecodeSHA256 = .sha256(result.bytecode)
        bytecodeByteLength = UInt64(result.bytecode.count)
        moduleName = result.module.name
        shellInterfaceHash = result.module.shellInterfaceHash
        toolchainFingerprint = result.toolchain.fingerprint
        capabilities = result.module.capabilities.sorted()
        changedFunctions = try result.changedFunctions.map { record in
            guard let fingerprint = result.bodyFingerprints[record.key] else {
                throw CLI.Error.input("compiler omitted a changed-function fingerprint")
            }
            return .init(
                functionKey: record.key,
                entryIndex: record.entryIndex,
                declaration: record.canonicalDeclaration,
                bodyFingerprint: fingerprint
            )
        }.sorted { $0.functionKey.rawValue < $1.functionKey.rawValue }
    }
}
}

extension CLI {
public enum Output: Sendable {
    case standardOutput(String)
    case standardError(String)
}

public struct Application: Sendable {
    let files: CLI.FileSystem
    let environment: [String: String]
    let executableURL: URL
    let hubControlClient: (any HubControl.ClientProtocol)?
    let catalogPrewarmLauncher: @Sendable (URL, URL, URL, URL) throws -> Void

    public init(
        currentDirectoryURL: URL = URL(
            fileURLWithPath: Foundation.FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil,
        hubControlClient: (any HubControl.ClientProtocol)? = nil,
        catalogPrewarmLauncher: (@Sendable (
            URL, URL, URL, URL
        ) throws -> Void)? = nil
    ) {
        files = .init(currentDirectoryURL: currentDirectoryURL)
        self.environment = environment
        self.hubControlClient = hubControlClient
        self.catalogPrewarmLauncher = catalogPrewarmLauncher
            ?? CLI.CatalogPrewarmProcess.launch
        if let executableURL {
            self.executableURL = executableURL.standardizedFileURL
        } else if let argument = CommandLine.arguments.first, argument.hasPrefix("/") {
            self.executableURL = URL(fileURLWithPath: argument).standardizedFileURL
        } else {
            self.executableURL = currentDirectoryURL.appendingPathComponent(
                CommandLine.arguments.first ?? "helix"
            ).standardizedFileURL
        }
    }

    public func run(_ arguments: [String]) -> CLI.Result {
        do {
            return try execute(arguments)
        } catch {
            return failure(error)
        }
    }

    public func runAsync(
        _ arguments: [String],
        outputHandler: @escaping @Sendable (CLI.Output) -> Void = { _ in }
    ) async -> CLI.Result {
        #if os(macOS)
        if arguments.first == "xcode",
           ["phase", "post-compile"].contains(arguments.dropFirst().first ?? "") {
            do {
                let tail = Array(arguments.dropFirst(2))
                if arguments.dropFirst().first == "post-compile" {
                    return try await executeXcodePostCompile(tail)
                }
                return try await executeXcodePhase(tail)
            } catch {
                return failure(error)
            }
        }
        guard arguments.first == "hub", arguments.dropFirst().first == "run" else {
            return run(arguments)
        }
        do {
            return try await runHubService(
                Array(arguments.dropFirst(2)),
                outputHandler: outputHandler
            )
        } catch {
            return failure(error)
        }
        #else
        guard arguments.first == "hub", arguments.dropFirst().first == "run" else {
            return run(arguments)
        }
        return .init(
            exitCode: 1,
            standardError: "error: helix hub run requires macOS\n"
        )
        #endif
    }

    private func execute(_ arguments: [String]) throws -> CLI.Result {
        guard let group = arguments.first else {
            return .init(exitCode: 0, standardOutput: Self.help)
        }
        if arguments == ["--help"] || arguments == ["help"] {
            return .init(exitCode: 0, standardOutput: Self.help)
        }
        if arguments == ["--version"] || arguments == ["version"] {
            return .init(exitCode: 0, standardOutput: "helix \(DevTools.Metadata.version)\n")
        }
        switch group {
        case "xcode":
            return try executeXcode(Array(arguments.dropFirst()))
        case "shell":
            return try executeShell(Array(arguments.dropFirst()))
        case "patch":
            return try executePatch(Array(arguments.dropFirst()))
        case "dev":
            return try executeDev(Array(arguments.dropFirst()))
        case "hub":
            return try executeHub(Array(arguments.dropFirst()))
        default:
            throw CLI.Error.usage("unknown command \(group)")
        }
    }

    private func executePatch(_ arguments: [String]) throws -> CLI.Result {
        guard let command = arguments.first else {
            return .init(exitCode: 0, standardOutput: Self.patchHelp)
        }
        let tail = Array(arguments.dropFirst())
        if command == "help" || command == "--help" {
            guard tail.isEmpty else { throw CLI.Error.usage("patch help accepts no arguments") }
            return .init(exitCode: 0, standardOutput: Self.patchHelp)
        }
        switch command {
        case "create-development-identity":
            return try createDevelopmentIdentity(tail)
        case "fingerprint": return try fingerprint(tail)
        case "compile": return try compile(tail)
        case "build": return try build(tail)
        case "inspect": return try inspect(tail)
        case "disassemble": return try disassemble(tail)
        default: throw CLI.Error.usage("unknown patch command \(command)")
        }
    }

    private func createDevelopmentIdentity(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.developmentIdentityHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["bundle-id", "output", "validity-days", "max-payload-bytes"],
            flagOptions: ["force"]
        )
        try requireNoPositionals(options, command: "patch create-development-identity")
        func unsigned(_ name: String, default defaultValue: UInt64) throws -> UInt64 {
            guard let value = try options.value(name) else { return defaultValue }
            guard let parsed = UInt64(value) else {
                throw CLI.Error.usage("--\(name) must be an unsigned integer")
            }
            return parsed
        }
        let days = try unsigned("validity-days", default: 365)
        let seconds = days.multipliedReportingOverflow(by: 24 * 60 * 60)
        guard !seconds.overflow else {
            throw CLI.Error.usage("--validity-days is too large")
        }
        let now = Date().timeIntervalSince1970
        guard now > 300, now <= Double(Int64.max) else {
            throw CLI.Error.input("system clock cannot issue a development identity")
        }
        let identity = try ReleasePipeline.DevelopmentIdentity(
            bundleID: options.require("bundle-id"),
            nowUnixSeconds: Int64(now),
            validityDurationSeconds: seconds.partialValue,
            maximumPayloadBytes: try unsigned(
                "max-payload-bytes",
                default: 8 * 1_024 * 1_024
            )
        )
        let outputURL = files.resolve(try options.require("output"))
        var artifacts = try identity.publicArtifacts
        artifacts["PatchSigningKey.json"] = try identity.privateKeyBytes
        try files.writeDirectory(
            artifacts,
            to: outputURL,
            force: options.hasFlag("force"),
            privatePaths: ["PatchSigningKey.json"]
        )
        return .init(
            exitCode: 0,
            standardOutput: "Created local-only Helix development identity at "
                + "\(outputURL.path)\nPrivate key: PatchSigningKey.json (mode 0600)\n"
        )
    }

    private func executeDev(_ arguments: [String]) throws -> CLI.Result {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.devHelp)
        }
        let command = arguments[0]
        let tail = Array(arguments.dropFirst())
        switch command {
        case "prepare": return try prepareDevConfiguration(tail)
        case "validate": return try validateDevConfiguration(tail)
        default: throw CLI.Error.usage("unknown dev command \(command)")
        }
    }

    private func executeHub(_ arguments: [String]) throws -> CLI.Result {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.hubHelp)
        }
        let command = arguments[0]
        let tail = Array(arguments.dropFirst())
        guard command == "run" else {
            throw CLI.Error.usage("unknown hub command \(command)")
        }
        if tail == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.hubRunHelp)
        }
        throw CLI.Error.usage("hub run requires the asynchronous CLI entry point")
    }

    private func prepareDevConfiguration(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.devPrepareHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: [
                "activity-log", "working-directory", "workspace", "scheme",
                "configuration", "bundle-id", "module", "executable",
                "reload-index", "archive", "receipt", "output", "manifest-output",
                "compiler", "source-map", "link-argument", "product",
                "code-sign-identity", "team-identifier", "entitlements",
                "native-output-directory", "backend",
                "debounce-milliseconds", "maximum-source-bytes", "native-image-limit",
            ],
            flagOptions: [
                "force", "device-native-qualified",
            ]
        )
        try requireNoPositionals(options, command: "dev prepare")
        let outputURL = files.resolve(try options.require("output"))
        try files.requireExtension("json", for: outputURL)
        let manifestURL = try options.value("manifest-output").map(files.resolve)
            ?? outputURL.deletingLastPathComponent().appendingPathComponent("DevBuildManifest.json")
        try files.requireExtension("json", for: manifestURL)
        try files.preflight(
            [manifestURL, outputURL],
            force: options.hasFlag("force")
        )

        var sourceMappings: [String: URL] = [:]
        for value in options.all("source-map") {
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw CLI.Error.usage("--source-map must be LOGICAL_PATH=ABSOLUTE_PATH")
            }
            let logical = String(value[..<separator])
            let path = String(value[value.index(after: separator)...])
            guard !path.isEmpty, sourceMappings[logical] == nil else {
                throw CLI.Error.usage("--source-map is empty or duplicates \(logical)")
            }
            sourceMappings[logical] = files.resolve(path)
        }
        var products: [DevSession.ProductInput] = []
        for value in options.all("product") {
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw CLI.Error.usage("--product must be KIND=PATH")
            }
            let kind = String(value[..<separator])
            let path = String(value[value.index(after: separator)...])
            guard !path.isEmpty else { throw CLI.Error.usage("--product path is empty") }
            products.append(.init(kind: kind, url: files.resolve(path)))
        }
        let compilerURL = try options.value("compiler").map(files.resolve)
        let request = DevSession.PrepareRequest(
            activityLogURL: files.resolve(try options.require("activity-log")),
            workingDirectory: files.resolve(try options.require("working-directory")),
            workspaceURL: files.resolve(try options.require("workspace")),
            scheme: try options.require("scheme"),
            configuration: try options.value("configuration") ?? "Debug",
            bundleID: try options.require("bundle-id"),
            moduleName: try options.require("module"),
            executableURL: files.resolve(try options.require("executable")),
            reloadIndexURL: files.resolve(try options.require("reload-index")),
            interfaceArchiveURL: files.resolve(try options.require("archive")),
            compilerURL: compilerURL,
            sourceMappings: sourceMappings,
            linkArguments: options.all("link-argument"),
            buildProducts: products,
            expandedCodeSignIdentity: try options.value("code-sign-identity"),
            teamIdentifier: try options.value("team-identifier"),
            entitlementsURL: try options.value("entitlements").map(files.resolve)
        )
        let prepared = try DevSession.Preparer(
            probe: BuildCapture.DefaultFrontendReplayProbe(runner: .init())
        ).prepare(request)
        let backendValue = try options.value("backend") ?? "automatic"
        guard let backend = DevBackendSelection.Preference(rawValue: backendValue) else {
            throw CLI.Error.usage("--backend must be automatic, native, or hlbc")
        }
        func unsigned<Value: FixedWidthInteger>(
            _ name: String,
            default defaultValue: Value
        ) throws -> Value {
            guard let value = try options.value(name) else { return defaultValue }
            guard let parsed = Value(value) else {
                throw CLI.Error.usage("--\(name) must be an unsigned integer")
            }
            return parsed
        }
        let configurationDirectory = outputURL.deletingLastPathComponent()
        let manifestPath = manifestURL.deletingLastPathComponent() == configurationDirectory
            ? manifestURL.lastPathComponent
            : manifestURL.path
        let nativeOutputDirectory = try options.value("native-output-directory").map {
            files.resolve($0).path
        } ?? ".helix/dev-native"
        let configuration = DevSession.Configuration(
            manifestPath: manifestPath,
            reloadIndexPath: request.reloadIndexURL.path,
            interfaceArchivePath: request.interfaceArchiveURL.path,
            shellBuildReceiptPath: files.resolve(
                try options.require("receipt")
            ).path,
            compilerPath: prepared.compilerURL.path,
            nativeOutputDirectory: nativeOutputDirectory,
            backendPreference: backend,
            deviceNativeMatrixQualified: options.hasFlag("device-native-qualified"),
            debounceMilliseconds: try unsigned(
                "debounce-milliseconds",
                default: UInt32(120)
            ),
            maximumSourceBytes: try unsigned(
                "maximum-source-bytes",
                default: 8 * 1_024 * 1_024
            ),
            nativeImageSoftLimit: try unsigned(
                "native-image-limit",
                default: UInt32(50)
            )
        )
        try configuration.validate()
        // The configuration is the completion marker for the two-file output.
        try files.write(try Core.CanonicalJSON.encode(prepared.manifest), to: manifestURL)
        try files.write(try Core.CanonicalJSON.encode(configuration), to: outputURL)
        return .init(
            exitCode: 0,
            standardOutput: "Prepared Helix Dev Session \(prepared.manifest.sessionBuildID.uuidString)\n"
                + "Manifest: \(manifestURL.path)\n"
                + "Configuration: \(outputURL.path)\n"
                + "Frontend replay artifacts: \(prepared.probe.replayArtifactCount)\n"
        )
    }

    private func validateDevConfiguration(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.devValidateHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["config"],
            flagOptions: ["json"]
        )
        try requireNoPositionals(options, command: "dev validate")
        let prepared = try DevSession.PreparedConfiguration.load(
            configurationURL: files.resolve(try options.require("config"))
        )
        if options.hasFlag("json") {
            let report = CLI.DevValidationReport(prepared: prepared)
            return .init(
                exitCode: 0,
                standardOutput: String(
                    decoding: try Core.CanonicalJSON.encode(report),
                    as: UTF8.self
                ) + "\n"
            )
        }
        return .init(
            exitCode: 0,
            standardOutput: "Validated Helix Dev Session \(prepared.manifest.sessionBuildID.uuidString)\n"
                + "Bundle: \(prepared.manifest.bundleID)\n"
                + "Platform: \(prepared.manifest.platform.rawValue) / \(prepared.manifest.architecture)\n"
                + "Sources: \(prepared.manifest.sourceFiles.count)\n"
                + "Reload roots: \(prepared.reloadIndex.roots.count)\n"
        )
    }

    private func failure(_ error: any Swift.Error) -> CLI.Result {
        if let error = error as? CLI.Error {
            let code: Int32
            if case .usage = error { code = 2 } else { code = 1 }
            return .init(exitCode: code, standardError: "error: \(error.description)\n")
        }
        return .init(
            exitCode: 1,
            standardError: "error: \(String(describing: error))\n"
        )
    }

    private func fingerprint(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.fingerprintHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["compiler"],
            flagOptions: ["json"]
        )
        try requireNoPositionals(options, command: "patch fingerprint")
        let compilerURL = files.resolve(try options.value("compiler") ?? "/usr/bin/swiftc")
        let identity = try ReleaseCompiler.Driver().toolchainIdentity(compilerURL: compilerURL)
        let output: String
        if options.hasFlag("json") {
            output = String(decoding: try Core.CanonicalJSON.encode(identity), as: UTF8.self) + "\n"
        } else {
            output = [
                "Fingerprint: \(identity.fingerprint)",
                "Compiler SHA-256: \(identity.compilerBinaryHash.hex)",
                "Version: \(identity.versionOutput)",
            ].joined(separator: "\n") + "\n"
        }
        return .init(exitCode: 0, standardOutput: output)
    }

    private func compile(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.compileHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: [
                "archive", "output", "compiler", "source", "function",
                "emit-disassembly", "emit-report",
            ],
            flagOptions: ["force", "no-toolchain-check"]
        )
        let outputURL = files.resolve(try options.require("output"))
        try files.requireExtension("hlbc", for: outputURL)
        let disassemblyURL = try options.value("emit-disassembly").map(files.resolve)
        let reportURL = try options.value("emit-report").map(files.resolve)
        if let reportURL { try files.requireExtension("json", for: reportURL) }
        let outputs = [outputURL, disassemblyURL, reportURL].compactMap { $0 }
        try files.preflight(outputs, force: options.hasFlag("force"))

        let archiveData = try files.read(try options.require("archive"))
        let archive = try InterfaceArchive.Codec.decode(archiveData).archive
        let sources = try sourceURLs(options)
        let selectedKeys = try functionKeys(options)
        let compilerURL = files.resolve(try options.value("compiler") ?? "/usr/bin/swiftc")
        let result = try ReleaseCompiler.Driver().build(
            .init(
                archive: archive,
                sourceFiles: sources,
                selectedFunctionKeys: selectedKeys,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: !options.hasFlag("no-toolchain-check")
            )
        )
        let report = try CLI.CompilationReport(result)
        try files.write(result.bytecode, to: outputURL)
        if let disassemblyURL { try files.write(result.disassembly + "\n", to: disassemblyURL) }
        if let reportURL { try files.write(try Core.CanonicalJSON.encode(report), to: reportURL) }
        return .init(
            exitCode: 0,
            standardOutput: "Wrote \(outputURL.path) (\(result.bytecode.count) bytes, "
                + "\(result.changedFunctions.count) changed functions)\n"
        )
    }

    private func build(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.buildHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: [
                "archive", "config", "certificate", "private-key", "trusted-root",
                "output", "compiler", "source", "function", "emit-bytecode",
                "emit-disassembly", "emit-report",
            ],
            flagOptions: ["force"]
        )
        let outputURL = files.resolve(try options.require("output"))
        try files.requireExtension("hlxp", for: outputURL)
        let bytecodeURL = try options.value("emit-bytecode").map(files.resolve)
        if let bytecodeURL { try files.requireExtension("hlbc", for: bytecodeURL) }
        let disassemblyURL = try options.value("emit-disassembly").map(files.resolve)
        let reportURL = try options.value("emit-report").map(files.resolve)
        if let reportURL { try files.requireExtension("json", for: reportURL) }
        let outputs = [outputURL, bytecodeURL, disassemblyURL, reportURL].compactMap { $0 }
        try files.preflight(outputs, force: options.hasFlag("force"))

        let archive = try InterfaceArchive.Codec.decode(
            files.read(try options.require("archive"))
        ).archive
        let configuration: ReleasePipeline.Configuration = try CLI.JSONDocument.decode(
            ReleasePipeline.Configuration.self,
            from: files.read(try options.require("config")),
            kind: .releaseConfiguration
        )
        let certificate: PatchPackage.SigningCertificate = try CLI.JSONDocument.decode(
            PatchPackage.SigningCertificate.self,
            from: files.read(try options.require("certificate")),
            kind: .signingCertificate
        )
        let signingKey: ReleasePipeline.SigningKeyDocument = try CLI.JSONDocument.decode(
            ReleasePipeline.SigningKeyDocument.self,
            from: files.readPrivateKeyDocument(try options.require("private-key")),
            kind: .signingKey
        )
        let root: PatchPackage.TrustedRoot = try CLI.JSONDocument.decode(
            PatchPackage.TrustedRoot.self,
            from: files.read(try options.require("trusted-root")),
            kind: .trustedRoot
        )
        let compilerURL = files.resolve(try options.value("compiler") ?? "/usr/bin/swiftc")
        let artifact = try ReleasePipeline.Builder().build(
            .init(
                configuration: configuration,
                archive: archive,
                sourceFiles: try sourceURLs(options),
                selectedFunctionKeys: try functionKeys(options),
                compilerURL: compilerURL,
                certificate: certificate,
                signingKey: signingKey,
                trustedRoot: root
            )
        )
        if let bytecodeURL { try files.write(artifact.compilation.bytecode, to: bytecodeURL) }
        if let disassemblyURL {
            try files.write(artifact.compilation.disassembly + "\n", to: disassemblyURL)
        }
        if let reportURL { try files.write(try Core.CanonicalJSON.encode(artifact.report), to: reportURL) }
        // The primary package is the completion marker for multi-output builds.
        try files.write(artifact.packageBytes, to: outputURL)
        return .init(
            exitCode: 0,
            standardOutput: "Wrote \(outputURL.path) (\(artifact.packageBytes.count) bytes, "
                + "\(artifact.report.changedFunctions.count) changed functions)\n"
        )
    }

    private func inspect(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.inspectHelp)
        }
        let options = try CLI.Arguments(arguments, valueOptions: [], flagOptions: ["json"])
        guard options.positionals.count == 1 else {
            throw CLI.Error.usage("patch inspect requires exactly one artifact path")
        }
        let inspection = try CLI.ArtifactInspector().inspect(files.read(options.positionals[0]))
        return .init(
            exitCode: 0,
            standardOutput: try options.hasFlag("json")
                ? inspection.canonicalJSON()
                : inspection.humanDescription()
        )
    }

    private func disassemble(_ arguments: [String]) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.disassembleHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["output"],
            flagOptions: ["force"]
        )
        guard options.positionals.count == 1 else {
            throw CLI.Error.usage("patch disassemble requires exactly one artifact path")
        }
        let text = try CLI.ArtifactInspector().disassemble(files.read(options.positionals[0]))
        if let path = try options.value("output") {
            let outputURL = files.resolve(path)
            try files.preflight([outputURL], force: options.hasFlag("force"))
            try files.write(text, to: outputURL)
            return .init(exitCode: 0, standardOutput: "Wrote \(outputURL.path)\n")
        }
        guard !options.hasFlag("force") else {
            throw CLI.Error.usage("--force requires --output")
        }
        return .init(exitCode: 0, standardOutput: text)
    }

    private func sourceURLs(_ options: CLI.Arguments) throws -> [URL] {
        let paths = options.all("source") + options.positionals
        guard !paths.isEmpty else {
            throw CLI.Error.usage("at least one complete-module Swift source file is required")
        }
        let urls = paths.map(files.resolve)
        guard Set(urls.map(\.standardizedFileURL.path)).count == urls.count else {
            throw CLI.Error.usage("a source file was supplied more than once")
        }
        return urls
    }

    private func functionKeys(_ options: CLI.Arguments) throws -> Set<Core.FunctionKey>? {
        let values = options.all("function")
        guard !values.isEmpty else { return nil }
        let keys = try values.map { value -> Core.FunctionKey in
            do {
                return .init(rawValue: try Core.Digest(hex: value))
            } catch {
                throw CLI.Error.input("invalid function key \(value)")
            }
        }
        guard Set(keys).count == keys.count else {
            throw CLI.Error.usage("a function key was supplied more than once")
        }
        return Set(keys)
    }

    private func requireNoPositionals(_ options: CLI.Arguments, command: String) throws {
        guard options.positionals.isEmpty else {
            throw CLI.Error.usage("\(command) accepts no positional arguments")
        }
    }
}
}

extension CLI.Application {
private static let help = """
Helix Swift hot-patch and Live Reload tool

Usage:
  helix --version
  helix xcode <command>
  helix shell <command>
  helix patch <command>
  helix dev <command>
  helix hub <command>

Run 'helix xcode --help', 'helix shell --help', 'helix patch --help', or
'helix dev --help' for build commands. Run 'helix hub --help' for service
commands.
""" + "\n"

static let xcodeHelp = """
Usage: helix xcode <command>

Commands:
  inspect       List Xcode targets, configurations, and shared schemes
  install       Install a Host Plan into the Xcode project without the Hub GUI
  generate      Generate deterministic xcconfig, file-list, and Scheme scripts
  validate      Validate the checked-in Host Plan and every referenced input
  doctor        Inspect the active Xcode build environment for one profile
  phase         Run one versioned Xcode prepare/finalize/audit/session phase
  post-compile  Complete an automatically captured same-target Swift build
  catalog-prewarm
                Resume validated module Catalog generation in bounded batches
""" + "\n"

private static let patchHelp = """
Usage: helix patch <command>

Commands:
  create-development-identity
                Create local test trust material; never use it for production
  fingerprint   Fingerprint the exact Swift compiler toolchain
  compile       Compile changed Swift function bodies into HLBC
  build         Build and sign a release HLXP package
  inspect       Decode and summarize an HLXI, HLBC, or HLXP artifact
  disassemble   Disassemble an HLBC or single-HLBC HLXP artifact
""" + "\n"

private static let developmentIdentityHelp = """
Usage: helix patch create-development-identity --bundle-id ID --output DIRECTORY [options]

Creates a one-leaf Ed25519 trust hierarchy for demos and isolated internal
testing. The issuer private key is discarded; PatchSigningKey.json is written
with mode 0600. Do not use this identity for production distribution.

Options:
  --validity-days N        Validity duration (default: 365)
  --max-payload-bytes N    Leaf payload limit (default: 8388608)
  --force                  Atomically replace the output directory
""" + "\n"

private static let devHelp = """
Usage: helix dev <command>

Commands:
  prepare       Capture and replay an exact Xcode frontend job, then write Dev config
  validate      Validate Dev Manifest, Reload Index, HLXI, and compiler identity
""" + "\n"

private static let hubHelp = """
Usage: helix hub <command>

Commands:
  run           Run the persistent authenticated Helix service
""" + "\n"

static let devPrepareHelp = """
Usage: helix dev prepare --activity-log BUILD.xcactivitylog \\
  --working-directory PROJECT_ROOT --workspace Store.xcworkspace \\
  --scheme Store-Debug --bundle-id com.example.store --module StoreFeature \\
  --executable Store.app/Store --reload-index ReloadIndex.json \\
  --archive Store.hlxi --output HelixDev.json [options]

Required inputs come from one successful Debug/Dev Shell build made with
EMIT_FRONTEND_COMMAND_LINES=YES. Helix expands response/file lists, selects the
exact module job, redirects only its outputs for an isolated replay, and checks
the App UUID, HLXI, Reload Index, Xcode, SDK, and Swift compiler as one identity.

Options:
  --configuration NAME          Build configuration (default: Debug)
  --manifest-output PATH.json   Manifest output (default: DevBuildManifest.json)
  --compiler PATH               Override only with swiftc from the captured toolchain
  --source-map LOGICAL=PATH     Resolve an ambiguous HLXI source; repeat for all sources
  --link-argument=VALUE         Preserve a link argument; repeatable
  --product KIND=PATH           Record another build product; repeatable
  --code-sign-identity VALUE    Capture device Development signing identity
  --team-identifier VALUE       Capture the signing team identifier
  --entitlements PATH           Hash the expanded entitlements file
  --native-output-directory P   Native generation directory (default: .helix/dev-native)
  --backend automatic|hlbc|native
                                 Automatic prefers qualified Simulator Native, then HLBC
  --debounce-milliseconds N     Save debounce window (default: 120)
  --maximum-source-bytes N      Per-source safety limit
  --native-image-limit N        Native image soft limit (default: 50)
  --device-native-qualified     Allow automatic/explicit Native on a qualified device matrix
  --force                       Atomically replace existing outputs

Use --link-argument=VALUE when VALUE begins with '--'. No build setting is
reconstructed from xcodebuild -showBuildSettings.
""" + "\n"

static let devValidateHelp = """
Usage: helix dev validate --config HelixDev.json [--json]
""" + "\n"

static let hubRunHelp = """
Usage: helix hub run

Runs the same persistent, single-listener service used by the Helix menu-bar
application. Xcode build phases reach it through an owner-only loopback control
channel; Apps discover it through Bonjour. Stop it with Control-C.

""" + "\n"

private static let fingerprintHelp = """
Usage: helix patch fingerprint [--compiler PATH] [--json]
""" + "\n"

private static let compileHelp = """
Usage: helix patch compile --archive SHELL.hlxi --output PATCH.hlbc [options] SOURCE.swift ...

Options:
  --source PATH              Add a complete-module Swift source file; repeatable
  --function SHA256          Compile only this HLXI FunctionKey; repeatable
  --compiler PATH            Select swiftc (default: /usr/bin/swiftc)
  --emit-disassembly PATH    Write textual HLBC disassembly
  --emit-report PATH.json    Write a canonical JSON compilation report
  --no-toolchain-check       Allow unsigned development compilation with another toolchain
  --force                    Replace existing output files
""" + "\n"

private static let buildHelp = """
Usage: helix patch build --archive SHELL.hlxi --config RELEASE.json \\
  --certificate CERT.json --private-key KEY.json --trusted-root ROOT.json \\
  --output PATCH.hlxp [options] SOURCE.swift ...

Options:
  --source PATH              Add a complete-module Swift source file; repeatable
  --function SHA256          Compile only this HLXI FunctionKey; repeatable
  --compiler PATH            Select swiftc (default: /usr/bin/swiftc)
  --emit-bytecode PATH.hlbc  Also write the verified HLBC payload
  --emit-disassembly PATH    Also write textual disassembly
  --emit-report PATH.json    Also write the canonical release report
  --force                    Replace existing output files

The private-key file must be owned by the current user, must not be a symlink,
and must have mode 0600, 0400, or stricter.
""" + "\n"

private static let inspectHelp = """
Usage: helix patch inspect [--json] ARTIFACT

HLXP inspection validates structure and payload hashes. It does not establish
signature trust because no trust policy is supplied to this command.
""" + "\n"

private static let disassembleHelp = """
Usage: helix patch disassemble [--output PATH] [--force] ARTIFACT
""" + "\n"
}
