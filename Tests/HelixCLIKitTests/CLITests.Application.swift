import Darwin
import Foundation
import HelixBytecode
import HelixBuildTools
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixReleaseTools
import Testing
@testable import HelixCLIKit

enum CLITests {}

extension CLITests {
@Suite("CLI application")
struct Application {
    @Test("Help and usage failures have stable exit semantics")
    func helpAndUsage() {
        let application = CLI.Application()
        let help = application.run([])
        #expect(help.exitCode == 0)
        #expect(help.standardOutput.contains("Helix Swift hot-patch"))

        let failure = application.run(["unknown"])
        #expect(failure.exitCode == 2)
        #expect(failure.standardError == "error: unknown command unknown\n")
    }

    @Test("Dev commands expose preparation, validation, and the asynchronous daemon")
    func devHelp() async {
        let application = CLI.Application()
        let group = application.run(["dev", "--help"])
        #expect(group.exitCode == 0)
        #expect(group.standardOutput.contains("prepare"))
        #expect(group.standardOutput.contains("validate"))
        #expect(group.standardOutput.contains("run"))

        let preparation = application.run(["dev", "prepare", "--help"])
        #expect(preparation.exitCode == 0)
        #expect(preparation.standardOutput.contains("EMIT_FRONTEND_COMMAND_LINES=YES"))
        #expect(preparation.standardOutput.contains("--activity-log"))
        #expect(preparation.standardOutput.contains("xcodebuild -showBuildSettings"))

        let validation = application.run(["dev", "validate", "--help"])
        #expect(validation.exitCode == 0)
        #expect(validation.standardOutput.contains("--config"))

        let daemon = await application.runAsync(["dev", "run", "--help"])
        #expect(daemon.exitCode == 0)
        #expect(daemon.standardOutput.contains("Control-C"))
    }

    @Test("Rejected live activation prints the App diagnostic")
    func rejectedLiveActivationDiagnostic() {
        let activation = DevProtocol.ActivationResult(
            sourceRevision: .init(rawValue: 2),
            generationID: .init(rawValue: 3),
            codeStatus: .rejected,
            reloadStatus: .notRequested,
            diagnostic: .init(
                code: "HLXLR404",
                message: "dyld rejected native image: invalid signature",
                sourceRevision: .init(rawValue: 2),
                generationID: .init(rawValue: 3),
                backend: .nativeDynamicReplacement,
                nextAction: "use HLBC or fix signing/dependencies"
            )
        )

        switch CLI.Application.describe(.activation(activation)) {
        case let .standardError(diagnostic):
            #expect(diagnostic.contains("r2/g3: rejected, UI notRequested."))
            #expect(diagnostic.contains("HLXLR404"))
            #expect(diagnostic.contains("invalid signature"))
        case .standardOutput:
            Issue.record("Rejected activation must be written to standard error")
        }
    }

    @Test("HLBC inspection and disassembly decode the artifact")
    func inspectAndDisassemble() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent("sample.hlbc")
        let bytes = try Bytecode.Encoder.encode(try module())
        try bytes.write(to: artifactURL)
        let application = CLI.Application(currentDirectoryURL: directory)

        let inspectionResult = application.run(["patch", "inspect", "--json", "sample.hlbc"])
        #expect(inspectionResult.exitCode == 0)
        let inspection = try JSONDecoder().decode(
            CLI.Inspection.self,
            from: Data(inspectionResult.standardOutput.utf8)
        )
        #expect(inspection.kind == .bytecode)
        #expect(inspection.bytecode?.moduleName == "CLIFixture")
        #expect(inspection.bytecode?.functionCount == 1)

        let disassembly = application.run(["patch", "disassemble", "sample.hlbc"])
        #expect(disassembly.exitCode == 0)
        #expect(disassembly.standardOutput.contains("hlbc_module \"CLIFixture\""))
        #expect(disassembly.standardOutput.contains("return %0"))
    }

    @Test("Existing output is not replaced without explicit force")
    func outputCollision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Bytecode.Encoder.encode(try module()).write(
            to: directory.appendingPathComponent("sample.hlbc")
        )
        try Data("keep".utf8).write(to: directory.appendingPathComponent("output.txt"))

        let result = CLI.Application(currentDirectoryURL: directory).run([
            "patch", "disassemble", "--output", "output.txt", "sample.hlbc",
        ])
        #expect(result.exitCode == 1)
        #expect(result.standardError.contains("output already exists"))
        #expect(try String(contentsOf: directory.appendingPathComponent("output.txt"), encoding: .utf8) == "keep")
    }

    @Test("Release App audit is a CI-stable shell command")
    func releaseAppAuditCommand() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Fixture"],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        var image = Data([0xcf, 0xfa, 0xed, 0xfe])
        image.append(Data("HelixDevProtocol".utf8))
        try image.write(to: app.appendingPathComponent("Fixture"))

        let application = CLI.Application(currentDirectoryURL: directory)
        let failed = application.run([
            "shell", "audit-release", "--app", "Fixture.app", "--json",
        ])
        #expect(failed.exitCode == 1)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(failed.standardOutput.utf8))
                as? [String: Any]
        )
        #expect(object["passed"] as? Bool == false)

        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x00]).write(
            to: app.appendingPathComponent("Fixture")
        )
        let passed = application.run([
            "shell", "audit-release", "--app", "Fixture.app",
        ])
        #expect(passed.exitCode == 0)
        #expect(passed.standardOutput == "Release leakage audit passed with no findings.\n")
    }

    @Test("Private key documents reject broad permissions and symbolic links")
    func privateKeyPermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("key.json")
        let linkURL = directory.appendingPathComponent("key-link.json")
        try Data("{}".utf8).write(to: keyURL)
        #expect(chmod(keyURL.path, 0o644) == 0)
        let files = CLI.FileSystem(currentDirectoryURL: directory)
        #expect(throws: CLI.Error.insecurePrivateKey(keyURL.path)) {
            try files.readPrivateKeyDocument(keyURL.path)
        }

        #expect(chmod(keyURL.path, 0o600) == 0)
        #expect(try files.readPrivateKeyDocument(keyURL.path) == Data("{}".utf8))
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: keyURL)
        #expect(throws: CLI.Error.insecurePrivateKey(linkURL.path)) {
            try files.readPrivateKeyDocument(linkURL.path)
        }
    }

    @Test("Release JSON rejects unknown fields instead of ignoring typos")
    func strictJSON() {
        let data = Data(#"{"schemaVersion":1,"algorithm":"ed25519","rawRepresentation":"","typo":true}"#.utf8)
        #expect(throws: CLI.Error.input("unknown signing key field: typo")) {
            let _: ReleasePipeline.SigningKeyDocument = try CLI.JSONDocument.decode(
                ReleasePipeline.SigningKeyDocument.self,
                from: data,
                kind: .signingKey
            )
        }
    }

    @Test("Development identity command atomically scopes and protects its private key")
    func developmentIdentityCommand() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Identity")
        let result = CLI.Application(currentDirectoryURL: directory).run([
            "patch", "create-development-identity",
            "--bundle-id", "dev.helix.identity-test",
            "--output", output.path,
        ])
        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        for name in ["TrustedRoot.json", "SigningCertificate.json", "PatchSigningKey.json"] {
            #expect(FileManager.default.fileExists(
                atPath: output.appendingPathComponent(name).path
            ))
        }
        var information = Darwin.stat()
        #expect(lstat(output.appendingPathComponent("PatchSigningKey.json").path, &information) == 0)
        #expect(information.st_mode & 0o777 == 0o600)
        let duplicate = CLI.Application(currentDirectoryURL: directory).run([
            "patch", "create-development-identity",
            "--bundle-id", "dev.helix.identity-test",
            "--output", output.path,
        ])
        #expect(duplicate.exitCode == 1)
    }

    @Test("Xcode commands validate inputs and atomically generate the integration kit")
    func xcodeIntegrationCommands() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Demo.xcodeproj")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        try Data("name = LiveApp; product = HelixDevAppRuntime;\n".utf8).write(
            to: project.appendingPathComponent("project.pbxproj")
        )
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(
            at: schemes,
            withIntermediateDirectories: true
        )
        try Data("<Scheme/>\n".utf8).write(
            to: schemes.appendingPathComponent("Live.xcscheme")
        )
        let sourceRoot = directory.appendingPathComponent("Feature")
        try FileManager.default.createDirectory(
            at: sourceRoot.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try Data("public func value() -> Int { 1 }\n".utf8).write(
            to: sourceRoot.appendingPathComponent("Sources/Feature.swift")
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Configurations"),
            withIntermediateDirectories: true
        )
        try Data("schema: 1\nmodules: {}\n".utf8).write(
            to: directory.appendingPathComponent("Configurations/Helix.yml")
        )
        let plan = XcodeIntegration.HostPlan(
            projectPath: "Demo.xcodeproj",
            features: [
                .init(
                    id: "feature",
                    moduleName: "Feature",
                    sourceRoot: "Feature",
                    patchConfigurationPath: "Configurations/Helix.yml",
                    sourceFiles: ["Sources/Feature.swift"]
                ),
            ],
            profiles: [
                .init(
                    id: "live",
                    workflow: .liveReload,
                    schemeName: "Live",
                    applicationTargetName: "LiveApp",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.helix.live",
                    namespaceSeed: "fixture-live",
                    featureID: "feature"
                ),
            ]
        )
        let planURL = directory.appendingPathComponent("HelixXcode.json")
        try XcodeIntegration.HostPlanCodec.encode(plan).write(to: planURL)
        let application = CLI.Application(currentDirectoryURL: directory)

        let phaseHelp = application.run(["xcode", "phase", "--help"])
        #expect(phaseHelp.exitCode == 0)
        #expect(phaseHelp.standardOutput.contains("prepare, bridge, finalize"))

        let validation = application.run([
            "xcode", "validate", "--plan", planURL.path, "--json",
        ])
        #expect(validation.exitCode == 0)
        let report = try JSONDecoder().decode(
            CLI.XcodeValidationReport.self,
            from: Data(validation.standardOutput.dropLast().utf8)
        )
        #expect(report.featureCount == 1)
        #expect(report.sourceFileCount == 1)
        #expect(report.profiles.first?.runtimePackageProduct == "HelixDevAppRuntime")

        let generationArguments = [
            "xcode", "generate", "--plan", planURL.path,
        ]
        let generated = application.run(generationArguments)
        #expect(generated.exitCode == 0)
        let output = directory.appendingPathComponent(".helix/xcode")
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("IntegrationManifest.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Profiles/live/live-start.sh").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Profiles/live/bridge.sh").path
        ))
        let scriptAttributes = try FileManager.default.attributesOfItem(
            atPath: output.appendingPathComponent("Profiles/live/live-start.sh").path
        )
        #expect((scriptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)

        let refused = application.run(generationArguments)
        #expect(refused.exitCode == 1)
        #expect(refused.standardError.contains("output already exists"))
        let replaced = application.run(generationArguments + ["--force"])
        #expect(replaced.exitCode == 0)

        let doctor = application.run([
            "xcode", "doctor", "--plan", planURL.path,
            "--profile", "live", "--static", "--json",
        ])
        #expect(doctor.exitCode == 0, Comment(rawValue: doctor.standardOutput))
        let doctorReport = try JSONDecoder().decode(
            CLI.XcodeDoctorReport.self,
            from: Data(doctor.standardOutput.dropLast().utf8)
        )
        #expect(doctorReport.passed)
        #expect(!doctorReport.checks.contains { $0.severity == .error })
    }

    @Test("Xcode prepare keeps Production explicit and manages the Debug calling surface")
    func xcodePreparePhase() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Demo.xcodeproj"),
            withIntermediateDirectories: true
        )
        let sourceRoot = directory.appendingPathComponent("Feature")
        try FileManager.default.createDirectory(
            at: sourceRoot.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try Data(
            """
            private func hidden(_ input: Int) -> Int { input + 1 }
            public func value(_ input: Int) -> Int { hidden(input) }
            """.utf8
        ).write(to: sourceRoot.appendingPathComponent("Sources/Feature.swift"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Configurations"),
            withIntermediateDirectories: true
        )
        try Data(
            """
            schema: 1
            modules:
              Feature:
                include:
                  - Sources/**/*.swift

            """.utf8
        ).write(to: directory.appendingPathComponent("Configurations/Helix.yml"))
        let plan = XcodeIntegration.HostPlan(
            projectPath: "Demo.xcodeproj",
            features: [
                .init(
                    id: "feature",
                    moduleName: "Feature",
                    sourceRoot: "Feature",
                    patchConfigurationPath: "Configurations/Helix.yml",
                    sourceFiles: ["Sources/Feature.swift"]
                ),
            ],
            profiles: [
                .init(
                    id: "patch",
                    workflow: .hotPatch,
                    schemeName: "Patch",
                    applicationTargetName: "PatchApp",
                    configurationName: "Release",
                    bundleIdentifier: "dev.helix.patch",
                    namespaceSeed: "fixture-patch",
                    featureID: "feature"
                ),
                .init(
                    id: "live",
                    workflow: .liveReload,
                    schemeName: "Live",
                    applicationTargetName: "LiveApp",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.helix.live",
                    namespaceSeed: "fixture-live",
                    featureID: "feature"
                ),
            ]
        )
        let planURL = directory.appendingPathComponent("HelixXcode.json")
        let planBytes = try XcodeIntegration.HostPlanCodec.encode(plan)
        try planBytes.write(to: planURL)
        let generatedPlanURL = directory.appendingPathComponent(
            ".helix/xcode/HostPlan.json"
        )
        try FileManager.default.createDirectory(
            at: generatedPlanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try planBytes.write(to: generatedPlanURL)
        let buildDirectory = directory.appendingPathComponent(
            "DerivedData/Build/Products",
            isDirectory: true
        )
        let compiler = try toolOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--find", "swiftc"]
        )
        let sdkBuild = try toolOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphonesimulator", "--show-sdk-build-version"]
        )
        let sdkRoot = try toolOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"]
        )
        let environment = [
            "SRCROOT": directory.path,
            "BUILD_DIR": buildDirectory.path,
            "CONFIGURATION": "Release",
            "PLATFORM_NAME": "iphonesimulator",
            "SDKROOT": sdkRoot,
            "GENERATED_MODULEMAP_DIR": directory.appendingPathComponent("ModuleMaps").path,
            "CURRENT_ARCH": "arm64",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "SDK_PRODUCT_BUILD_VERSION": sdkBuild,
            "XCODE_PRODUCT_BUILD_VERSION": "18A1",
            "CURRENT_PROJECT_VERSION": "1",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "SWIFT_EXEC": compiler,
            "SWIFT_VERSION": "6.0",
            "OTHER_SWIFT_FLAGS": "-Xfrontend -enable-private-imports "
                + "-Xfrontend -enable-implicit-dynamic "
                + "-Xfrontend -enable-dynamic-replacement-chaining",
            "HELIX_PROFILE_ID": "patch",
            "HELIX_WORKFLOW": "hotPatch",
            "HELIX_RUNTIME_PRODUCT": "HelixAppRuntime",
        ]
        let application = CLI.Application(
            currentDirectoryURL: directory,
            environment: environment
        )
        let result = application.run([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        let shell = buildDirectory.appendingPathComponent(
            "HelixGenerated/patch/Shell",
            isDirectory: true
        )
        for path in [
            "Shell.provisional.hlxi",
            "ShellBuildReceipt.json",
            "ReleaseMetadata.json",
            "ReloadIndex.json",
            "Generated/FeatureBridge.swift",
            "Generated/FeatureBridge.DevBuildContract.swift",
            "Generated/FeatureBridge.Provider.swift",
        ] {
            #expect(FileManager.default.fileExists(
                atPath: shell.appendingPathComponent(path).path
            ))
        }
        for path in ["Compiler/Feature/swiftc"] {
            let proxy = buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/\(path)"
            )
            #expect(FileManager.default.isExecutableFile(atPath: proxy.path))
        }
        #expect(!FileManager.default.fileExists(atPath: buildDirectory
            .appendingPathComponent("HelixGenerated/patch/Compiler/Application/swiftc")
            .path))

        let patchReceipt = try ShellBuildReceipt.Codec.decode(
            Data(contentsOf: shell.appendingPathComponent("ShellBuildReceipt.json"))
        )
        #expect(patchReceipt.configuration.schema == 1)
        #expect(patchReceipt.nativeImportCandidates.map(\.canonicalCallee) == [
            "Swift.print(_:separator:terminator:)",
        ])

        var liveEnvironment = environment
        liveEnvironment["CONFIGURATION"] = "Debug"
        liveEnvironment["HELIX_PROFILE_ID"] = "live"
        liveEnvironment["HELIX_WORKFLOW"] = "liveReload"
        liveEnvironment["HELIX_RUNTIME_PRODUCT"] = "HelixDevAppRuntime"
        let liveResult = CLI.Application(
            currentDirectoryURL: directory,
            environment: liveEnvironment
        ).run([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "live",
            "--phase", "prepare",
        ])
        #expect(liveResult.exitCode == 0, Comment(rawValue: liveResult.standardError))
        let liveShell = buildDirectory.appendingPathComponent(
            "HelixGenerated/live/Shell",
            isDirectory: true
        )
        let liveReceipt = try ShellBuildReceipt.Codec.decode(
            Data(contentsOf: liveShell.appendingPathComponent("ShellBuildReceipt.json"))
        )
        let featureConfiguration = try #require(
            liveReceipt.configuration.modules["Feature"]
        )
        #expect(liveReceipt.configuration.schema == 2)
        #expect(featureConfiguration.nativeImports.sourceScope?.visibility == .all)
        #expect(liveReceipt.nativeImportCandidates.map(\.canonicalCallee) == [
            "Feature.hidden(_:)",
            "Swift.print(_:separator:terminator:)",
        ])
        let entrySymbols = Set(liveReceipt.roots.compactMap { root in
            root.bridge == nil ? nil : root.declarationMangledName
        })
        #expect(entrySymbols.count == 1)
        let importedSymbols = Set(
            liveReceipt.nativeImportCandidates.flatMap(\.silMangledNames)
        )
        #expect(entrySymbols.isDisjoint(with: importedSymbols))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func toolOutput(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLI.Error.input(String(decoding: error, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func module() throws -> Bytecode.Module {
        let hash = Core.Digest.sha256("cli-fixture-shell")
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        return .init(
            name: "CLIFixture",
            shellInterfaceHash: hash,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "fixture"
            ),
            functions: [function]
        )
    }
}
}
