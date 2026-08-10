import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevTools
import HelixInterface

extension CLI.Application {
func executeShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellHelp)
    }
    let command = arguments[0]
    let tail = Array(arguments.dropFirst())
    switch command {
    case "metadata": return try metadataShell(tail)
    case "index": return try indexShell(tail)
    case "index-project": return try indexProjectShell(tail)
    case "build": return try buildShell(tail)
    case "finalize": return try finalizeShell(tail)
    case "audit-release": return try auditReleaseShell(tail)
    default: throw CLI.Error.usage("unknown shell command \(command)")
    }
}

private func indexProjectShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellIndexProjectHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["plan", "output"],
        flagOptions: ["force"]
    )
    try requireNoShellPositionals(options, command: "shell index-project")
    let planURL = files.resolve(try options.require("plan"))
    let outputURL = files.resolve(try options.require("output"))
    let plan = try ProjectIndex.Codec.decode(readProjectFile(planURL))
    let base = planURL.deletingLastPathComponent()
    func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    let configurationURL = resolve(plan.configurationPath)
    var inputURLs = [planURL, configurationURL]
    let configurationData = try readProjectFile(configurationURL)
    guard let configurationText = String(data: configurationData, encoding: .utf8) else {
        throw CLI.Error.input("project patchability configuration is not UTF-8")
    }
    let configuration = try PatchConfiguration.Document.parse(yaml: configurationText)
    let compilerURL = plan.compilerPath.map(resolve)
        ?? URL(fileURLWithPath: "/usr/bin/swiftc")
    inputURLs.append(compilerURL)
    var requests: [FrontendReceipt.Request] = []
    for module in plan.modules {
        let metadataURL = resolve(module.metadataPath)
        inputURLs.append(metadataURL)
        let metadataBytes = try readProjectFile(metadataURL)
        let metadata: InterfaceArchive.ReleaseMetadata
        do {
            metadata = try JSONDecoder().decode(
                InterfaceArchive.ReleaseMetadata.self,
                from: metadataBytes
            )
            guard try Core.CanonicalJSON.encode(metadata) == metadataBytes else {
                throw CLI.Error.input(
                    "Release metadata for \(module.moduleName) is not canonical"
                )
            }
        } catch let error as CLI.Error {
            throw error
        } catch {
            throw CLI.Error.input(
                "cannot decode Release metadata for \(module.moduleName): \(error)"
            )
        }
        guard metadata.frontendInvocation.moduleName == module.moduleName else {
            throw CLI.Error.input(
                "project plan module \(module.moduleName) disagrees with Release metadata"
            )
        }
        let catalog: NativeImportCatalog.Document
        if let path = module.nativeImportCatalogPath {
            let catalogURL = resolve(path)
            inputURLs.append(catalogURL)
            catalog = try NativeImportCatalog.Codec.decode(readProjectFile(catalogURL))
        } else {
            catalog = .empty
        }
        let sources = module.sources.map {
            FrontendReceipt.Source(logicalPath: $0.logicalPath, url: resolve($0.physicalPath))
        }
        inputURLs.append(contentsOf: sources.map(\.url))
        requests.append(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: sources,
                compilerURL: compilerURL,
                nativeImportCatalog: catalog
            )
        )
    }
    try requireProjectOutputOutsideInputs(outputURL, inputs: inputURLs)
    let indexed = try FrontendReceipt.ProjectAdapter().generate(
        .init(modules: requests)
    )
    var artifacts: [String: Data] = [
        "ProjectIndexReport.json": try Core.CanonicalJSON.encode(indexed.report),
    ]
    for module in indexed.report.modules {
        guard let output = indexed.modules[module.moduleName] else {
            throw CLI.Error.input("project adapter omitted module \(module.moduleName)")
        }
        let receipt = try ShellBuildReceipt.Codec.encode(output.receipt)
        guard Core.Digest.sha256(receipt) == module.receiptHash else {
            throw CLI.Error.input("project receipt hash changed for \(module.moduleName)")
        }
        artifacts[module.receiptPath] = receipt
        artifacts[module.diagnosticsPath] = try Core.CanonicalJSON.encode(output.diagnostics)
    }
    try files.writeDirectory(
        artifacts,
        to: outputURL,
        force: options.hasFlag("force")
    )
    let importCount = indexed.report.modules.reduce(0) {
        $0 + Int($1.generatedNativeImportCount)
    }
    return .init(
        exitCode: 0,
        standardOutput: "Indexed \(indexed.report.modules.count) Swift modules at "
            + "\(outputURL.path)\nGenerated NativeImports: \(importCount)\n"
            + "Compiler: \(indexed.report.toolchainFingerprint)\n"
    )
}

private func requireProjectOutputOutsideInputs(
    _ outputURL: URL,
    inputs: [URL]
) throws {
    let standardized = outputURL.standardizedFileURL
    let target: String
    if FileManager.default.fileExists(atPath: standardized.path) {
        target = standardized.resolvingSymlinksInPath().path
    } else {
        target = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent)
            .path
    }
    let targetPrefix = target.hasSuffix("/") ? target : target + "/"
    guard inputs.allSatisfy({ input in
        let path = input.resolvingSymlinksInPath().standardizedFileURL.path
        return path != target && !path.hasPrefix(targetPrefix)
    }) else {
        throw CLI.Error.input(
            "project output directory must not contain or replace any plan input"
        )
    }
}

private func readProjectFile(_ url: URL) throws -> Data {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLI.Error.input("file does not exist: \(url.path)")
    }
    do {
        return try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
        throw CLI.Error.input("cannot read \(url.path): \(error.localizedDescription)")
    }
}

private func auditReleaseShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellAuditReleaseHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["app", "output"],
        flagOptions: ["json", "force"]
    )
    try requireNoShellPositionals(options, command: "shell audit-release")
    let outputURL = try options.value("output").map(files.resolve)
    if let outputURL {
        try files.requireExtension("json", for: outputURL)
        try files.preflight([outputURL], force: options.hasFlag("force"))
    } else if options.hasFlag("force") {
        throw CLI.Error.usage("--force requires --output")
    }
    let report = try ReleaseLeakage.AppBundleAuditor().audit(
        appURL: files.resolve(try options.require("app"))
    )
    let encoded = try Core.CanonicalJSON.encode(report)
    if let outputURL { try files.write(encoded, to: outputURL) }
    let output: String
    if options.hasFlag("json") {
        output = String(decoding: encoded, as: UTF8.self) + "\n"
    } else if report.findings.isEmpty {
        output = "Release leakage audit passed with no findings.\n"
    } else {
        output = report.findings.map {
            "[\($0.severity.rawValue)] \($0.code): \($0.detail)"
        }.joined(separator: "\n") + "\n"
    }
    return .init(exitCode: report.passed ? 0 : 1, standardOutput: output)
}

private func metadataShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellMetadataHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: [
            "bundle-id", "build-number", "namespace-seed", "module", "target",
            "minimum-os", "xcode-build", "sdk-name", "sdk-build", "optimization",
            "semantic-argument", "output",
        ],
        flagOptions: ["force"]
    )
    try requireNoShellPositionals(options, command: "shell metadata")
    let outputURL = files.resolve(try options.require("output"))
    try files.preflight([outputURL], force: options.hasFlag("force"))
    let invocation = InterfaceArchive.FrontendInvocation(
        moduleName: try options.require("module"),
        targetTriple: try options.require("target"),
        sdkName: try options.require("sdk-name"),
        sdkBuild: try options.require("sdk-build"),
        optimization: try options.value("optimization") ?? "-O",
        semanticArguments: options.all("semantic-argument")
    )
    let metadata = try ShellBuild.MetadataFactory().make(
        .init(
            bundleID: try options.require("bundle-id"),
            buildNumber: try options.require("build-number"),
            namespaceSeed: try options.require("namespace-seed"),
            minimumOS: try Core.SemanticVersion(
                parsing: options.require("minimum-os")
            ),
            xcodeBuild: try options.require("xcode-build"),
            frontendInvocation: invocation
        )
    )
    try files.write(try Core.CanonicalJSON.encode(metadata), to: outputURL)
    return .init(
        exitCode: 0,
        standardOutput: "Wrote pre-link Release metadata to \(outputURL.path)\n"
            + "Namespace: \(metadata.shellNamespaceID)\n"
            + "Target: \(metadata.targetTriple)\n"
    )
}

private func indexShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellIndexHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: [
            "metadata", "configuration", "source-map", "compiler",
            "native-import-catalog", "output",
        ],
        flagOptions: ["force"]
    )
    try requireNoShellPositionals(options, command: "shell index")
    let outputURL = files.resolve(try options.require("output"))
    try files.preflight([outputURL], force: options.hasFlag("force"))
    let metadataBytes = try files.read(try options.require("metadata"))
    let metadata: InterfaceArchive.ReleaseMetadata
    do {
        metadata = try JSONDecoder().decode(
            InterfaceArchive.ReleaseMetadata.self,
            from: metadataBytes
        )
        guard try Core.CanonicalJSON.encode(metadata) == metadataBytes else {
            throw CLI.Error.input("Release metadata JSON is not canonical")
        }
    } catch let error as CLI.Error {
        throw error
    } catch {
        throw CLI.Error.input("cannot decode Release metadata: \(error)")
    }
    let configurationData = try files.read(try options.require("configuration"))
    guard let configurationText = String(data: configurationData, encoding: .utf8) else {
        throw CLI.Error.input("patchability configuration is not UTF-8")
    }
    let configuration = try PatchConfiguration.Document.parse(yaml: configurationText)
    let sources = try parseFrontendSources(options.all("source-map"))
    let compilerURL = files.resolve(try options.value("compiler") ?? "/usr/bin/swiftc")
    let nativeImportCatalog: NativeImportCatalog.Document
    if let path = try options.value("native-import-catalog") {
        nativeImportCatalog = try NativeImportCatalog.Codec.decode(files.read(path))
    } else {
        nativeImportCatalog = .empty
    }
    let indexed = try FrontendReceipt.Adapter().generate(
        .init(
            metadata: metadata,
            configuration: configuration,
            sources: sources,
            compilerURL: compilerURL,
            nativeImportCatalog: nativeImportCatalog
        )
    )
    try files.write(try ShellBuildReceipt.Codec.encode(indexed.receipt), to: outputURL)
    let eligible = indexed.receipt.roots.filter { $0.bridge != nil }.count
    let native = indexed.receipt.roots.filter { $0.nativeReplacement != nil }.count
    return .init(
        exitCode: 0,
        standardOutput: "Indexed Swift Shell sources at \(outputURL.path)\n"
            + "Declarations: \(indexed.receipt.declarations.count), "
            + "HLBC: \(eligible), Native: \(native)\n"
            + "Compiler: \(indexed.toolchain.fingerprint)\n"
    )
}

private func parseFrontendSources(_ mappings: [String]) throws -> [FrontendReceipt.Source] {
    guard !mappings.isEmpty else {
        throw CLI.Error.usage("shell index requires at least one --source-map")
    }
    var sources: [FrontendReceipt.Source] = []
    var logicalPaths = Set<String>()
    var physicalPaths = Set<String>()
    for mapping in mappings {
        guard let separator = mapping.firstIndex(of: "=") else {
            throw CLI.Error.usage("--source-map must be LOGICAL_PATH=PHYSICAL_PATH")
        }
        let logical = String(mapping[..<separator])
        let physical = String(mapping[mapping.index(after: separator)...])
        let url = files.resolve(physical).resolvingSymlinksInPath().standardizedFileURL
        guard !logical.isEmpty, !physical.isEmpty,
              logicalPaths.insert(logical).inserted,
              physicalPaths.insert(url.path).inserted
        else {
            throw CLI.Error.usage(
                "--source-map is empty or duplicates a logical or physical source"
            )
        }
        sources.append(.init(logicalPath: logical, url: url))
    }
    return sources.sorted { $0.logicalPath < $1.logicalPath }
}

private func buildShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellBuildHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["receipt", "source-root", "output"],
        flagOptions: ["force"]
    )
    try requireNoShellPositionals(options, command: "shell build")
    let outputURL = files.resolve(try options.require("output"))
    let receipt = try ShellBuildReceipt.Codec.decode(
        files.read(try options.require("receipt"))
    )
    let output = try ShellBuild.Materializer().materialize(
        receipt: receipt,
        sourceRoot: files.resolve(try options.require("source-root"))
    )
    try files.writeDirectory(
        try output.artifacts(),
        to: outputURL,
        force: options.hasFlag("force")
    )
    return .init(
        exitCode: 0,
        standardOutput: "Materialized Helix Shell build at \(outputURL.path)\n"
            + "Functions: \(output.report.eligibleFunctionCount) eligible, "
            + "\(output.report.rejectedFunctionCount) rejected\n"
            + "Interface: \(output.report.shellInterfaceHash.hex)\n"
    )
}

private func finalizeShell(_ arguments: [String]) throws -> CLI.Result {
    if arguments == ["--help"] {
        return .init(exitCode: 0, standardOutput: Self.shellFinalizeHelp)
    }
    let options = try CLI.Arguments(
        arguments,
        valueOptions: ["archive", "executable", "output"],
        flagOptions: ["force"]
    )
    try requireNoShellPositionals(options, command: "shell finalize")
    let outputURL = files.resolve(try options.require("output"))
    try files.requireExtension("hlxi", for: outputURL)
    try files.preflight([outputURL], force: options.hasFlag("force"))
    let provisional = try InterfaceArchive.Codec.decode(
        files.read(try options.require("archive"))
    ).archive
    let finalized = try ShellBuild.Finalizer().finalize(
        provisionalArchive: provisional,
        linkedExecutable: files.read(try options.require("executable"))
    )
    try files.write(try InterfaceArchive.Codec.encode(finalized), to: outputURL)
    return .init(
        exitCode: 0,
        standardOutput: "Finalized \(outputURL.path)\n"
            + "Mach-O UUID: \(finalized.metadata.machOUUIDs[0].uuidString)\n"
            + "Interface: \(finalized.shellInterfaceHash.hex)\n"
    )
}

private func requireNoShellPositionals(
    _ options: CLI.Arguments,
    command: String
) throws {
    guard options.positionals.isEmpty else {
        throw CLI.Error.usage("\(command) accepts no positional arguments")
    }
}
}

extension CLI.Application {
static let shellHelp = """
Usage: helix shell <command>

Commands:
  metadata    Freeze deterministic pre-link Release and frontend identity
  index       Derive a typed Shell Build Receipt from real Swift frontend output
  index-project  Atomically index every configured Swift module from one canonical plan
  build       Materialize transformed sources, Bridge, provisional HLXI, and Reload Index
  finalize    Bind a provisional HLXI to the linked App executable's real Mach-O UUID
  audit-release  Reject Dev runtime, transport, secret, and Bonjour leakage in a Release App
""" + "\n"

static let shellMetadataHelp = """
Usage: helix shell metadata --bundle-id ID --build-number NUMBER \
  --namespace-seed SEED --module MODULE --target TRIPLE --minimum-os VERSION \
  --xcode-build BUILD --sdk-name iphoneos|iphonesimulator --sdk-build BUILD \
  [--optimization=-O] [--semantic-argument=ARG ...] \
  --output ReleaseMetadata.json [--force]

Creates canonical pre-link identity for shell index. Values should come from the
same Xcode target and configuration that will compile the materialized sources.
Options whose value begins with "-" must use --option=VALUE. Semantic arguments
may be repeated; output actions, source paths, plugins, and target/SDK overrides
are rejected.
""" + "\n"

static let shellIndexHelp = """
Usage: helix shell index --metadata ReleaseMetadata.json \
  --configuration Helix.yml --source-map LOGICAL_PATH=PHYSICAL_PATH \
  [--source-map ...] [--compiler /path/to/swiftc] \
  [--native-import-catalog NativeImports.json] \
  --output ShellBuildReceipt.json [--force]

Runs the exact compiler and SDK recorded in Release metadata, consumes its typed
JSON AST plus canonical SIL, and emits a canonical typed receipt. Source maps may
be repeated and must form a one-to-one logical/physical Swift source mapping.
The optional canonical NativeImport Catalog binds allowlisted SIL symbols to
typed App-provided VM.NativeImportFactory implementations.
""" + "\n"

static let shellIndexProjectHelp = """
Usage: helix shell index-project --plan ProjectIndexPlan.json \
  --output ProjectIndex [--force]

The canonical plan names one shared Helix.yml plus every configured Swift
module's Release metadata, source map, and optional explicit NativeImport
Catalog. Paths are resolved relative to the plan. The command indexes all
modules with one compiler identity and atomically commits per-module receipts,
diagnostics, and ProjectIndexReport.json. Runtime descriptors remain exact and
module-local; the project scope never becomes a device-side wildcard.
""" + "\n"

static let shellBuildHelp = """
Usage: helix shell build --receipt ShellBuildReceipt.json \
  --source-root PROJECT_ROOT --output DERIVED_DIRECTORY [--force]

The receipt must be canonical JSON emitted by the typed compiler adapter.
The output directory is committed atomically and contains DerivedSources,
Generated Bridge sources, Shell.provisional.hlxi, ReloadIndex.json, and a report.
""" + "\n"

static let shellFinalizeHelp = """
Usage: helix shell finalize --archive Shell.provisional.hlxi \
  --executable AppBinary --output Shell.hlxi [--force]

Run after linking and before code signing/resource sealing. The executable must
be a thin iOS Mach-O matching the HLXI target architecture and platform.
""" + "\n"

static let shellAuditReleaseHelp = """
Usage: helix shell audit-release --app Store.app [--json] \
  [--output ReleaseLeakage.json] [--force]

Scans every Mach-O image and Info.plist in the built App bundle. The command
fails when Helix Dev runtime/protocol modules, launch secrets, or the Helix
Bonjour service survive into Release. Unreviewed business Bonjour services are
reported as warnings; they do not fail the audit.
""" + "\n"
}
