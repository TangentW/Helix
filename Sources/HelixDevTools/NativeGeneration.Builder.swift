import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

public enum ProcessExecution {}

extension ProcessExecution {
public struct Result: Hashable, Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol Running: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?
    ) throws -> ProcessExecution.Result
}

public struct Runner: ProcessExecution.Running {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil
    ) throws -> ProcessExecution.Result {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdoutURL = temporary.appendingPathComponent("stdout")
        let stderrURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        return .init(
            status: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
}

public enum NativeGeneration {}

extension NativeGeneration {
public struct ReplacementRoot: Codable, Hashable, Sendable {
    public var sourceDeclaration: Core.DynamicReplacement.Declaration
    public var memberRole: Core.DynamicReplacement.MemberRole
    public var body: String
    public var sourceLine: Int?

    public init(
        sourceDeclaration: Core.DynamicReplacement.Declaration,
        memberRole: Core.DynamicReplacement.MemberRole,
        body: String,
        sourceLine: Int? = nil
    ) {
        self.sourceDeclaration = sourceDeclaration
        self.memberRole = memberRole
        self.body = body
        self.sourceLine = sourceLine
    }
}

public struct SourceGenerator: Sendable {
    public init() {}

    public func generate(
        moduleName: String,
        sourceFileLogicalPath: String,
        privateImportSourceFile: String? = nil,
        imports: [String],
        roots: [NativeGeneration.ReplacementRoot]
    ) throws -> String {
        guard !moduleName.isEmpty, !sourceFileLogicalPath.isEmpty, !roots.isEmpty else {
            throw BuildCapture.Error.invalidManifest("replacement source input is empty")
        }
        guard roots.allSatisfy({
            $0.sourceDeclaration.isWellFormed
                && $0.sourceDeclaration.member($0.memberRole) != nil
                && !$0.body.unicodeScalars.contains(where: { $0.value == 0 })
                && $0.body.utf8.count <= 16 * 1_024 * 1_024
        }) else {
            throw BuildCapture.Error.invalidManifest("replacement root is incomplete")
        }
        let groups = Dictionary(
            grouping: roots,
            by: { $0.sourceDeclaration.identity }
        ).values.sorted {
            $0[0].sourceDeclaration.identity < $1[0].sourceDeclaration.identity
        }
        guard groups.allSatisfy({ values in
            guard let first = values.first else { return false }
            return values.allSatisfy({
                $0.sourceDeclaration == first.sourceDeclaration
            }) && Set(values.map(\.memberRole)).count == values.count
        }) else {
            throw BuildCapture.Error.invalidManifest(
                "replacement declaration group is inconsistent"
            )
        }
        let privateImportName = privateImportSourceFile
            ?? URL(fileURLWithPath: sourceFileLogicalPath).lastPathComponent
        guard privateImportName.hasSuffix(".swift"),
              URL(fileURLWithPath: privateImportName).lastPathComponent == privateImportName,
              privateImportName.utf8.count <= 1_024,
              !privateImportName.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw BuildCapture.Error.invalidManifest("private-import source identity is invalid")
        }
        var lines = [
            "// Generated by Helix. Do not edit.",
            "@_private(sourceFile: \(String(reflecting: privateImportName))) import \(moduleName)",
        ]
        for module in imports.sorted() where module != moduleName {
            lines.append("import \(module)")
        }
        for group in groups {
            lines.append("")
            lines.append(try renderDeclarationGroup(
                group,
                sourceFileLogicalPath: sourceFileLogicalPath
            ))
        }
        lines.append("")
        lines.append("@_cdecl(\"hlx_generation_registration_v1\")")
        lines.append("public func generationRegistration() -> UInt32 { \(roots.count) }")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderDeclarationGroup(
        _ roots: [NativeGeneration.ReplacementRoot],
        sourceFileLogicalPath: String
    ) throws -> String {
        guard let first = roots.first else {
            throw BuildCapture.Error.invalidManifest("replacement declaration group is empty")
        }
        let declaration = first.sourceDeclaration
        let rootsByRole = Dictionary(uniqueKeysWithValues: roots.map {
            ($0.memberRole, $0)
        })
        let rendered: String
        if declaration.kind == .function {
            guard roots.count == 1, let root = rootsByRole[.functionBody] else {
                throw BuildCapture.Error.invalidManifest(
                    "function replacement declaration has invalid members"
                )
            }
            rendered = """
            @_dynamicReplacement(for: \(declaration.originalReference))
            \(declaration.replacementHeader) {
            \(indent(try renderBody(root, sourceFileLogicalPath: sourceFileLogicalPath), by: 4))
            }
            """
        } else {
            let accessors = try declaration.members.compactMap {
                member -> String? in
                if let root = rootsByRole[member.role] {
                    return "\(member.header) {\n"
                        + indent(
                            try renderBody(
                                root,
                                sourceFileLogicalPath: sourceFileLogicalPath
                            ),
                            by: 4
                        ) + "\n}"
                }
                guard ![Core.DynamicReplacement.MemberRole.willSet, .didSet]
                    .contains(member.role)
                else { return nil }
                return "\(member.header) {\n"
                    + indent(member.fallbackBody, by: 4) + "\n}"
            }
            guard !accessors.isEmpty else {
                throw BuildCapture.Error.invalidManifest(
                    "accessor replacement declaration has no emitted members"
                )
            }
            rendered = """
            @_dynamicReplacement(for: \(declaration.originalReference))
            \(declaration.replacementHeader) {
            \(indent(accessors.joined(separator: "\n"), by: 4))
            }
            """
        }
        guard !declaration.enclosingPrefix.isEmpty else { return rendered }
        return declaration.enclosingPrefix + "\n"
            + indent(rendered, by: 4) + "\n"
            + declaration.enclosingSuffix
    }

    private func renderBody(
        _ root: NativeGeneration.ReplacementRoot,
        sourceFileLogicalPath: String
    ) throws -> String {
        guard let sourceLine = root.sourceLine else { return root.body }
        guard sourceLine > 0 else {
            throw BuildCapture.Error.invalidManifest("replacement source line is invalid")
        }
        return """
        #sourceLocation(file: \(String(reflecting: sourceFileLogicalPath)), line: \(sourceLine))
        \(root.body)
        #sourceLocation()
        """
    }

    private func indent(_ value: String, by spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
    }
}

public struct SourceUnit: Hashable, Sendable {
    public var sourceFileLogicalPath: String
    public var privateImportSourceFile: String?
    public var imports: [String]
    public var roots: [NativeGeneration.ReplacementRoot]

    public init(
        sourceFileLogicalPath: String,
        privateImportSourceFile: String? = nil,
        imports: [String] = [],
        roots: [NativeGeneration.ReplacementRoot]
    ) {
        self.sourceFileLogicalPath = sourceFileLogicalPath
        self.privateImportSourceFile = privateImportSourceFile
        self.imports = imports.sorted()
        self.roots = roots
    }
}
}

extension NativeGeneration.SourceGenerator {
    public func generateFiles(
        moduleName: String,
        units: [NativeGeneration.SourceUnit]
    ) throws -> [String: String] {
        guard !units.isEmpty else {
            throw BuildCapture.Error.invalidManifest("replacement source units are empty")
        }
        var files: [String: String] = [:]
        var rootCount = 0
        for unit in units.sorted(by: { $0.sourceFileLogicalPath < $1.sourceFileLogicalPath }) {
            let rendered = try renderUnit(moduleName: moduleName, unit: unit)
            let stem = Core.Digest.sha256(unit.sourceFileLogicalPath).hex.prefix(16)
            files["NativeGeneration.Roots_\(stem).swift"] = rendered
            rootCount += unit.roots.count
        }
        files["NativeGeneration.Registration.swift"] = """
        // Generated by Helix. Do not edit.
        @_cdecl("hlx_generation_registration_v1")
        public func generationRegistration() -> UInt32 { \(rootCount) }

        """
        return files
    }

    private func renderUnit(
        moduleName: String,
        unit: NativeGeneration.SourceUnit
    ) throws -> String {
        let complete = try generate(
            moduleName: moduleName,
            sourceFileLogicalPath: unit.sourceFileLogicalPath,
            privateImportSourceFile: unit.privateImportSourceFile,
            imports: unit.imports,
            roots: unit.roots
        )
        guard let registration = complete.range(of: "\n@_cdecl(\"hlx_generation_registration_v1\")") else {
            throw BuildCapture.Error.invalidManifest("generated registration marker is missing")
        }
        return String(complete[..<registration.lowerBound]) + "\n"
    }
}

extension NativeGeneration {

public struct Request: Sendable {
    public var sessionID: UUID
    public var sourceRevision: DevProtocol.SourceRevision
    public var generationID: DevProtocol.GenerationID
    public var manifest: DevBuildManifest.Document
    public var compilerURL: URL
    public var sourceURLs: [URL]
    public var outputDirectory: URL
    public var changedSources: [LiveReload.SourceFileID]
    public var changedFunctions: [Core.FunctionKey]
    public var reloadHints: [DevProtocol.ReloadHint]

    public init(
        sessionID: UUID,
        sourceRevision: DevProtocol.SourceRevision,
        generationID: DevProtocol.GenerationID,
        manifest: DevBuildManifest.Document,
        compilerURL: URL,
        sourceURLs: [URL],
        outputDirectory: URL,
        changedSources: [LiveReload.SourceFileID],
        changedFunctions: [Core.FunctionKey],
        reloadHints: [DevProtocol.ReloadHint] = []
    ) {
        self.sessionID = sessionID
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.manifest = manifest
        self.compilerURL = compilerURL
        self.sourceURLs = sourceURLs.sorted { $0.path < $1.path }
        self.outputDirectory = outputDirectory
        self.changedSources = changedSources
        self.changedFunctions = changedFunctions
        self.reloadHints = reloadHints
    }
}

public struct Result: Sendable {
    public var imageURL: URL
    public var debugSymbols: DebugSymbols.Artifact
    public var descriptor: MachO.Descriptor
    public var artifact: DevProtocol.LiveArtifact
    public var compilerDiagnostics: String

    public var debugSymbolsURL: URL { debugSymbols.bundleURL }
}

public struct Builder<Runner: ProcessExecution.Running>: Sendable {
    public var runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    public func build(_ request: NativeGeneration.Request) throws -> NativeGeneration.Result {
        try request.manifest.validate()
        guard request.sessionID == request.manifest.sessionBuildID,
              request.sourceRevision.rawValue > 0,
              request.generationID.rawValue > 0,
              !request.changedSources.isEmpty,
              !request.changedFunctions.isEmpty,
              !request.sourceURLs.isEmpty,
              request.sourceURLs.count <= 1_024,
              Set(request.sourceURLs.map(\.standardizedFileURL)).count == request.sourceURLs.count,
              request.sourceURLs.allSatisfy({
                  $0.pathExtension == "swift" && FileManager.default.fileExists(atPath: $0.path)
              })
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR205",
                message: "Native generation request does not match the Dev Build Manifest",
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "discard this transaction and rebuild the Dev Shell if its sources changed"
            )
        }
        guard request.manifest.toolchainCapabilities.privateImports,
              request.manifest.toolchainCapabilities.dynamicReplacementChaining
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR502",
                message: "the exact Swift toolchain did not pass private-import and replacement-chaining probes",
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "use the HLBC backend or perform a full build"
            )
        }
        let signingIdentity: String
        switch request.manifest.platform {
        case .iOS:
            guard let identity = request.manifest.expandedCodeSignIdentity?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !identity.isEmpty
            else {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR405",
                    message: "the device build did not capture EXPANDED_CODE_SIGN_IDENTITY",
                    sourceRevision: request.sourceRevision,
                    generationID: request.generationID,
                    backend: .nativeDynamicReplacement,
                    nextAction: "run a Development-signed Dev Shell build or use HLBC"
                )
            }
            signingIdentity = identity
        case .iOSSimulator, .macOS:
            signingIdentity = "-"
        }
        let toolchain: ReleaseCompiler.ToolchainIdentity
        do {
            toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
                compilerURL: request.compilerURL
            )
        } catch {
            throw DevProtocol.Diagnostic(
                code: "HLXLR304",
                message: String(describing: error),
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "restore the Swift compiler used by the Dev Shell"
            )
        }
        guard toolchain.fingerprint == request.manifest.swiftCompilerFingerprint else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR304",
                message: "the selected Swift compiler does not match the Dev Shell",
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "select the exact Xcode toolchain used for the running App"
            )
        }
        if request.manifest.platform != .macOS {
            let sdkName = request.manifest.platform == .iOS ? "iphoneos" : "iphonesimulator"
            do {
                let sdk = try SwiftFrontend.Driver(
                    compilerURL: request.compilerURL
                ).sdkIdentity(name: sdkName)
                guard sdk.buildVersion == request.manifest.sdkBuild else {
                    throw SwiftFrontend.Error.sdkBuildMismatch(
                        expected: request.manifest.sdkBuild,
                        actual: sdk.buildVersion
                    )
                }
            } catch {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR304",
                    message: String(describing: error),
                    sourceRevision: request.sourceRevision,
                    generationID: request.generationID,
                    backend: .nativeDynamicReplacement,
                    nextAction: "restore the exact iOS SDK used by the Dev Shell"
                )
            }
        }
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let stem = "HLXLive-\(request.sessionID.uuidString)-g\(request.generationID.rawValue)"
        let imageURL = request.outputDirectory.appendingPathComponent("\(stem).dylib")
        let objectURL = request.outputDirectory.appendingPathComponent("\(stem).o")
        let installName = "@rpath/\(stem).dylib"
        let sessionSuffix = request.sessionID.uuidString.replacingOccurrences(of: "-", with: "")
        let moduleName = "HLXLive_\(sessionSuffix)_g\(request.generationID.rawValue)"
        let swiftModuleURL = request.outputDirectory.appendingPathComponent(
            "\(moduleName).swiftmodule"
        )
        let compileArguments = try compilationArguments(
            manifest: request.manifest,
            sourceURLs: request.sourceURLs,
            moduleName: moduleName,
            objectURL: objectURL,
            swiftModuleURL: swiftModuleURL
        )
        let compilation = try runner.run(
            executable: request.compilerURL,
            arguments: compileArguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: request.outputDirectory
        )
        guard compilation.status == 0 else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR202",
                message: compilation.standardError,
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "fix the Swift diagnostic; the previous generation remains active"
            )
        }
        let linking = try runner.run(
            executable: request.compilerURL,
            arguments: try linkingArguments(
                manifest: request.manifest,
                moduleName: moduleName,
                objectURL: objectURL,
                imageURL: imageURL,
                installName: installName
            ),
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: request.outputDirectory
        )
        guard linking.status == 0 else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR202",
                message: linking.standardError,
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "fix the Swift link diagnostic; the previous generation remains active"
            )
        }
        let signing = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force", "--sign", signingIdentity,
                "--timestamp=none", imageURL.path,
            ],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: request.outputDirectory
        )
        guard signing.status == 0 else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR405",
                message: signing.standardError.isEmpty
                    ? "codesign exited with status \(signing.status)"
                    : signing.standardError,
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "repair the Development signing identity or use HLBC"
            )
        }
        let image = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        let descriptor = try MachO.Inspector().inspect(image)
        guard descriptor.isCodeSigned, let imageUUID = descriptor.uuid else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR405",
                message: "signed dylib is missing LC_CODE_SIGNATURE or LC_UUID",
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "inspect the signing environment or use HLBC"
            )
        }
        let expectedArchitecture = try architecture(request.manifest.architecture)
        try MachO.Inspector().preflight(
            descriptor,
            expectedArchitecture: expectedArchitecture,
            expectedInstallName: installName,
            expectedPlatform: platform(request.manifest.platform),
            allowedDependencyPrefixes: [
                "/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/",
            ]
        )
        let (debugSymbols, debugDiagnostics) = try buildDebugSymbols(
            request: request,
            imageURL: imageURL,
            imageUUID: imageUUID,
            swiftModuleURL: swiftModuleURL,
            stem: stem
        )
        let offer = DevProtocol.PatchOffer(
            sessionID: request.sessionID,
            sourceRevision: request.sourceRevision,
            generationID: request.generationID,
            backend: .nativeDynamicReplacement,
            payloadByteLength: UInt64(image.count),
            payloadSHA256: .sha256(image),
            changedSources: request.changedSources,
            changedFunctions: request.changedFunctions,
            reloadHints: request.reloadHints,
            debugSymbolsUUID: imageUUID
        )
        return .init(
            imageURL: imageURL,
            debugSymbols: debugSymbols,
            descriptor: descriptor,
            artifact: .init(offer: offer, payload: image),
            compilerDiagnostics: [
                compilation.standardError, linking.standardError,
                signing.standardError, debugDiagnostics,
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
    }

    private func buildDebugSymbols(
        request: NativeGeneration.Request,
        imageURL: URL,
        imageUUID: UUID,
        swiftModuleURL: URL,
        stem: String
    ) throws -> (DebugSymbols.Artifact, String) {
        do {
            let bundleURL = request.outputDirectory.appendingPathComponent(
                "\(stem).dSYM",
                isDirectory: true
            )
            let result = try runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["dsymutil", imageURL.path, "-o", bundleURL.path],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: request.outputDirectory
            )
            guard result.status == 0 else {
                throw DebugSymbols.Error.invalidBundle(
                    result.standardError.isEmpty
                        ? "dsymutil exited with status \(result.status)"
                        : result.standardError
                )
            }
            let dwarfDirectory = bundleURL
                .appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(
                at: dwarfDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let dwarfFiles = try entries.filter {
                try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            guard dwarfFiles.count == 1, let dwarfURL = dwarfFiles.first else {
                throw DebugSymbols.Error.invalidBundle(bundleURL.path)
            }
            let manifestSources = Dictionary(
                uniqueKeysWithValues: request.manifest.sourceFiles.map { ($0.id, $0) }
            )
            let mappings = try Set(request.changedSources).map { id in
                guard let source = manifestSources[id] else {
                    throw BuildCapture.Error.invalidManifest(
                        "changed source is absent from the Dev Build Manifest"
                    )
                }
                return try DebugSymbols.SourceMapping(
                    logicalPath: source.logicalPath,
                    absolutePath: source.absolutePath
                )
            }
            return (
                try DebugSymbols.Artifact(
                    imageUUID: imageUUID,
                    bundleURL: bundleURL,
                    dwarfURL: dwarfURL,
                    swiftModuleURL: swiftModuleURL,
                    sourceMappings: mappings
                ),
                result.standardError
            )
        } catch let diagnostic as DevProtocol.Diagnostic {
            throw diagnostic
        } catch {
            throw DevProtocol.Diagnostic(
                code: "HLXLR204",
                message: String(describing: error),
                sourceRevision: request.sourceRevision,
                generationID: request.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "repair dsymutil; the previous generation remains active"
            )
        }
    }

    private func compilationArguments(
        manifest: DevBuildManifest.Document,
        sourceURLs: [URL],
        moduleName: String,
        objectURL: URL,
        swiftModuleURL: URL
    ) throws -> [String] {
        let environment = try capturedEnvironment(manifest)
        return [
            "-emit-object", "-whole-module-optimization",
            "-emit-module", "-emit-module-path", swiftModuleURL.path,
            "-debug-module-path", swiftModuleURL.path,
            "-Onone", "-g", "-parse-as-library",
            "-target", environment.target,
            "-sdk", environment.sdk,
            "-module-name", moduleName,
            "-runtime-compatibility-version", "none",
            "-disable-autolinking-runtime-compatibility",
            "-disable-autolinking-runtime-compatibility-concurrency",
            "-disable-autolinking-runtime-compatibility-dynamic-replacements",
            "-Xfrontend", "-enable-private-imports",
            "-Xfrontend", "-enable-dynamic-replacement-chaining",
        ] + preservedCompilationArguments(manifest.frontendArguments)
            + sourceURLs.map(\.path) + ["-o", objectURL.path]
    }

    private func linkingArguments(
        manifest: DevBuildManifest.Document,
        moduleName: String,
        objectURL: URL,
        imageURL: URL,
        installName: String
    ) throws -> [String] {
        let environment = try capturedEnvironment(manifest)
        return [
            objectURL.path, "-emit-library",
            "-target", environment.target,
            "-sdk", environment.sdk,
            "-module-name", moduleName,
            "-runtime-compatibility-version", "none",
            "-disable-autolinking-runtime-compatibility",
            "-disable-autolinking-runtime-compatibility-concurrency",
            "-disable-autolinking-runtime-compatibility-dynamic-replacements",
            "-Xlinker", "-install_name", "-Xlinker", installName,
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
        ] + preservedLinkArguments(manifest.linkArguments) + ["-o", imageURL.path]
    }

    private func capturedEnvironment(
        _ manifest: DevBuildManifest.Document
    ) throws -> (target: String, sdk: String) {
        guard let targetIndex = manifest.frontendArguments.firstIndex(of: "-target"),
              targetIndex + 1 < manifest.frontendArguments.count,
              let sdkIndex = manifest.frontendArguments.firstIndex(of: "-sdk"),
              sdkIndex + 1 < manifest.frontendArguments.count
        else {
            throw BuildCapture.Error.invalidManifest("captured job lacks target or SDK")
        }
        return (
            manifest.frontendArguments[targetIndex + 1],
            manifest.frontendArguments[sdkIndex + 1]
        )
    }

    private func preservedCompilationArguments(_ arguments: [String]) -> [String] {
        var preserved: [String] = []
        var index = 0
        let takesValue: Set<String> = [
            "-I", "-F", "-Fsystem", "-D", "-Xcc", "-Xfrontend",
            "-module-cache-path", "-plugin-path", "-external-plugin-path",
            "-swift-version", "-strict-concurrency",
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if takesValue.contains(argument), index + 1 < arguments.count {
                preserved.append(argument)
                preserved.append(arguments[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return preserved
    }

    private func preservedLinkArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        let paired = Set(["-L", "-F", "-Fsystem", "-framework", "-weak_framework"])
        while index < arguments.count {
            let argument = arguments[index]
            if paired.contains(argument), index + 1 < arguments.count {
                result.append(argument)
                result.append(arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("-l"), argument.count > 2 {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    private func architecture(_ value: String) throws -> MachO.Architecture {
        switch value {
        case "arm64", "arm64e": .arm64
        case "x86_64": .x86_64
        default:
            throw BuildCapture.Error.invalidManifest(
                "unsupported Native generation architecture \(value)"
            )
        }
    }

    private func platform(_ value: DevProtocol.ApplePlatform) -> MachO.Platform {
        switch value {
        case .iOS: .iOS
        case .iOSSimulator: .iOSSimulator
        case .macOS: .macOS
        }
    }
}

public typealias DefaultBuilder = NativeGeneration.Builder<ProcessExecution.Runner>
}
