import Darwin
import Foundation
import HelixBytecode
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
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

    @Test("Dev build commands and the persistent Hub service have separate entry points")
    func devHelp() async {
        let application = CLI.Application()
        let group = application.run(["dev", "--help"])
        #expect(group.exitCode == 0)
        #expect(group.standardOutput.contains("prepare"))
        #expect(group.standardOutput.contains("validate"))
        #expect(!group.standardOutput.contains("run"))

        let preparation = application.run(["dev", "prepare", "--help"])
        #expect(preparation.exitCode == 0)
        #expect(preparation.standardOutput.contains("EMIT_FRONTEND_COMMAND_LINES=YES"))
        #expect(preparation.standardOutput.contains("--activity-log"))
        #expect(preparation.standardOutput.contains("xcodebuild -showBuildSettings"))

        let validation = application.run(["dev", "validate", "--help"])
        #expect(validation.exitCode == 0)
        #expect(validation.standardOutput.contains("--config"))

        let hub = application.run(["hub", "--help"])
        #expect(hub.exitCode == 0)
        #expect(hub.standardOutput.contains("persistent authenticated Helix service"))

        let service = await application.runAsync(["hub", "run", "--help"])
        #expect(service.exitCode == 0)
        #expect(service.standardOutput.contains("single-listener service"))
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
        try Data("name = LiveApp; product = HelixAppIntegration;\n".utf8).write(
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
        let plan = XcodeIntegration.HostPlan(
            projectPath: "Demo.xcodeproj",
            features: [
                .init(
                    id: "feature",
                    targetName: "Feature",
                    moduleName: "Feature"
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
        let planURL = directory.appendingPathComponent("HostPlan.json")
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
        #expect(report.profiles.first?.runtimePackageProduct == "HelixAppIntegration")

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
            atPath: output.appendingPathComponent("Profiles/live/live-register.sh").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Profiles/live/bridge.sh").path
        ))
        let scriptAttributes = try FileManager.default.attributesOfItem(
            atPath: output.appendingPathComponent("Profiles/live/live-register.sh").path
        )
        #expect((scriptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let wrapper = output.appendingPathComponent(
            "ProjectConfigurations/live-Feature-Debug.xcconfig"
        )
        let wrapperBytes = Data("#include \"../Profiles/live/Feature.xcconfig\"\n".utf8)
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wrapperBytes.write(to: wrapper)

        let refused = application.run(generationArguments)
        #expect(refused.exitCode == 1)
        #expect(refused.standardError.contains("output already exists"))
        let replaced = application.run(generationArguments + ["--force"])
        #expect(replaced.exitCode == 0)
        #expect(try Data(contentsOf: wrapper) == wrapperBytes)

        let installedPlanURL = output.appendingPathComponent("HostPlan.json")
        let installedValidation = application.run([
            "xcode", "validate", "--plan", installedPlanURL.path, "--json",
        ])
        #expect(
            installedValidation.exitCode == 0,
            Comment(rawValue: installedValidation.standardError)
        )
        let installedGeneration = application.run([
            "xcode", "generate", "--plan", installedPlanURL.path,
        ])
        #expect(installedGeneration.exitCode == 1)
        #expect(
            installedGeneration.standardError.contains("output already exists")
        )
        let installedRegeneration = application.run([
            "xcode", "generate", "--plan", installedPlanURL.path, "--force",
        ])
        #expect(
            installedRegeneration.exitCode == 0,
            Comment(rawValue: installedRegeneration.standardError)
        )
        #expect(try Data(contentsOf: wrapper) == wrapperBytes)

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
        #expect(doctorReport.checks.contains { $0.code == "HLXXC015" && $0.severity == .warning && $0.detail.contains("compilation cache") })
        #expect(!doctorReport.checks.contains { $0.severity == .error })

        let installedDoctor = application.run([
            "xcode", "doctor", "--plan", installedPlanURL.path,
            "--profile", "live", "--static", "--json",
        ])
        #expect(installedDoctor.exitCode == 0, Comment(rawValue: installedDoctor.standardOutput))
        let installedDoctorReport = try JSONDecoder().decode(
            CLI.XcodeDoctorReport.self,
            from: Data(installedDoctor.standardOutput.dropLast().utf8)
        )
        #expect(installedDoctorReport.passed)
        #expect(!installedDoctorReport.checks.contains { $0.severity == .error })

        // A self-consistent old manifest must not hide an obsolete compiler setting.
        let featurePath = "Profiles/live/Feature.xcconfig"
        let featureURL = output.appendingPathComponent(featurePath)
        let oldFeature = Data(try String(contentsOf: featureURL, encoding: .utf8)
            .replacingOccurrences(of: "SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS = NO", with: "SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS = YES").utf8)
        try oldFeature.write(to: featureURL)
        let manifestURL = output.appendingPathComponent("IntegrationManifest.json")
        var oldManifest = try JSONDecoder().decode(XcodeIntegration.KitManifest.self, from: Data(contentsOf: manifestURL))
        let featureIndex = try #require(oldManifest.artifacts.firstIndex { $0.path == featurePath })
        oldManifest.artifacts[featureIndex] = .init(path: featurePath, data: oldFeature)
        try Core.CanonicalJSON.encode(oldManifest).write(to: manifestURL)
        let stale = application.run(["xcode", "doctor", "--plan", installedPlanURL.path,
            "--profile", "live", "--static", "--json"])
        #expect(stale.exitCode == 1)
        #expect(stale.standardOutput.contains("active Helix tool"))
        #expect(stale.standardOutput.contains(featurePath))
        #expect(application.run(["xcode", "generate", "--plan", installedPlanURL.path, "--force"]).exitCode == 0)
        #expect(application.run(["xcode", "doctor", "--plan", installedPlanURL.path,
            "--profile", "live", "--static"]).exitCode == 0)
    }

    @Test("Preflight defaults to input and AST checks and preserves explicit stage selection")
    func preflightCommand() async throws {
        let app = CLI.Application(currentDirectoryURL: URL(fileURLWithPath: "/tmp"))
        let base = ["xcode", "preflight", "--plan", "MissingPlan.json", "--profile", "live",
            "--capture", "FrontendAttempt.hlxswiftc", "--json"]
        let result = await app.runAsync(base)
        let report = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(result.standardOutput.utf8))
        #expect(!report.passed && report.requestedStages == [.inputs, .typedAST])
        let selected = await app.runAsync(base + ["--stages", "inputs"])
        let selectedReport = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(selected.standardOutput.utf8))
        #expect(selectedReport.requestedStages == [.inputs])
        #expect(app.run(["xcode", "preflight", "--help"]).standardOutput.contains("FrontendAttempt.hlxswiftc"))
    }

    @Test("Post-compile diagnosis returns structured failures for invalid inputs")
    func xcodeDiagnosisInputFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = CLI.Application(currentDirectoryURL: directory)
        let result = await app.runAsync(["xcode", "post-compile", "--plan", "MissingPlan.json",
            "--profile", "live", "--capture", "MissingCapture", "--diagnose", "--json"])
        #expect(result.exitCode == 1)
        let report = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(result.standardOutput.utf8))
        #expect(!report.passed)
        #expect(report.checks.contains { $0.stage == "xcode.context" && $0.status == .failed })
        #expect(report.checks.contains { $0.status == .blocked })
        let human = await app.runAsync(["xcode", "post-compile", "--plan", "MissingPlan.json",
            "--profile", "live", "--capture", "MissingCapture", "--diagnose"])
        #expect(human.exitCode == 1)
        #expect(human.standardOutput.contains("[failed] xcode.context"))
        #expect(human.standardOutput.contains("Scope: frontend receipt analysis"))
        let invalid = await app.runAsync(["xcode", "post-compile", "--json"])
        #expect(invalid.exitCode != 0)
        #expect(invalid.standardError.contains("--diagnose"))
        let selected = await app.runAsync(["xcode", "post-compile", "--plan", "MissingPlan.json",
            "--profile", "live", "--capture", "MissingCapture", "--diagnose", "--json", "--stages", "source-nominals,imported-types"])
        let scoped = try JSONDecoder().decode(FrontendReceipt.DiagnosticReport.self, from: Data(selected.standardOutput.utf8))
        #expect(scoped.schemaVersion == 2)
        #expect(scoped.requestedStages == [.importedTypes, .sourceNominals])
        #expect(scoped.checks.contains { $0.stage == "frontend.receipt" } == false)
        #expect(scoped.checks.contains { $0.stage == "frontend.discover_imported_types" && $0.status == .blocked })
        let scopedHuman = await app.runAsync(["xcode", "post-compile", "--plan", "MissingPlan.json",
            "--profile", "live", "--capture", "MissingCapture", "--diagnose", "--stages", "typed-ast"])
        #expect(scopedHuman.standardOutput.contains("full receipt validation was not requested"))
        for value in ["", "typed-ast,", "unknown"] {
            let unknown = await app.runAsync(["xcode", "post-compile", "--diagnose", "--stages", value])
            #expect(unknown.exitCode != 0)
            #expect(unknown.standardError.contains("stage") || unknown.standardError.contains("value"))
        }
        let requiresDiagnosis = await app.runAsync(["xcode", "post-compile", "--stages", "typed-ast"])
        #expect(requiresDiagnosis.standardError.contains("--stages requires --diagnose"))
    }

    @Test("Xcode prepare discovers all source entries and manages the Debug SDK surface")
    func xcodePreparePhase() async throws {
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
            import ExternalFixture

            private func hidden(_ input: Int) -> Int { input + 1 }
            public func value(_ input: Int) -> Int { hidden(input) }
            public func externalValue(_ input: Int) -> Int {
                ExternalValue(rawValue: input).incremented()
            }
            """.utf8
        ).write(to: sourceRoot.appendingPathComponent("Sources/Feature.swift"))
        let compilerInputRoot = directory.appendingPathComponent(
            "CompilerInputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: compilerInputRoot,
            withIntermediateDirectories: false
        )
        let externalModule = compilerInputRoot.appendingPathComponent(
            "ExternalFixture.swiftmodule"
        )
        let plan = XcodeIntegration.HostPlan(
            projectPath: "Demo.xcodeproj",
            features: [
                .init(
                    id: "feature",
                    targetName: "Feature",
                    moduleName: "Feature"
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
        let planURL = directory.appendingPathComponent("HostPlan.json")
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
        try writeFixtureSwiftModule(
            version: 1,
            compiler: compiler,
            sdkRoot: sdkRoot,
            outputURL: externalModule,
            directory: compilerInputRoot
        )
        let sourceURL = sourceRoot.appendingPathComponent("Sources/Feature.swift")
        try writeSwiftCapture(
            profileID: "patch",
            buildDirectory: buildDirectory,
            compiler: compiler,
            sdkRoot: sdkRoot,
            sourceURLs: [sourceURL],
            additionalArguments: ["-I", compilerInputRoot.path]
        )
        let environment = [
            "SRCROOT": directory.path,
            "BUILD_DIR": buildDirectory.path,
            "BUILT_PRODUCTS_DIR": buildDirectory.path,
            "OBJROOT": buildDirectory.appendingPathComponent("Intermediates").path,
            "TARGET_TEMP_DIR": buildDirectory.appendingPathComponent(
                "Intermediates/patch"
            ).path,
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
            "SWIFT_INCLUDE_PATHS": compilerInputRoot.path,
            "HELIX_PROFILE_ID": "patch",
            "HELIX_WORKFLOW": "hotPatch",
            "HELIX_RUNTIME_PRODUCT": "HelixAppIntegration",
            "HELIX_BUILD_CACHE_DIR": directory.appendingPathComponent(
                "BuildCache",
                isDirectory: true
            ).path,
        ]
        let application = CLI.Application(
            currentDirectoryURL: directory,
            environment: environment,
            hubControlClient: StubHubControlClient()
        )
        let patchCaptureURL = buildDirectory.appendingPathComponent(
            "Intermediates/patch/Helix/FrontendInvocation.hlxswiftc"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: patchCaptureURL.path
        )
        let permissiveCapture = await application.runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(permissiveCapture.exitCode != 0)
        #expect(permissiveCapture.standardError.contains("owner-only"))
        let failedPerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/BuildPerformance.prepare.json"
            )
        )
        #expect(failedPerformance.schemaVersion == 1)
        #expect(failedPerformance.operation == .prepare)
        #expect(failedPerformance.workflow == .hotPatch)
        #expect(failedPerformance.outcome == .failure)
        #expect(failedPerformance.trace.stages.contains {
            $0.name == "prepare.capture_frontend"
        })
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: patchCaptureURL.path
        )
        let result = await application.runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        let patchPerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/BuildPerformance.prepare.json"
            )
        )
        #expect(patchPerformance.outcome == .success)
        #expect(patchPerformance.totalDurationMicroseconds > 0)
        #expect(patchPerformance.trace.stages.contains {
            $0.name == "prepare.frontend_receipt"
        })
        #expect(
            patchPerformance.trace.subprocesses.contains {
                $0.kind == .typedAST && $0.invocationCount > $0.failureCount
            } || patchPerformance.trace.counters.contains {
                $0.name == "frontend_cache.module_hit_count" && $0.value == 1
            },
            Comment(rawValue: String(describing: patchPerformance.trace))
        )
        #expect(patchPerformance.trace.counters.contains {
            $0.name == "frontend.source_count" && $0.value == 1
        })
        #expect(patchPerformance.trace.artifacts.contains {
            $0.relativePath == "Shell/ShellBuildReceipt.json" && $0.byteCount > 0
        })
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
            "Generated/FeatureBridge.Provider.swift",
        ] {
            #expect(FileManager.default.fileExists(
                atPath: shell.appendingPathComponent(path).path
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: shell.appendingPathComponent(
                "Generated/FeatureBridge.HubContract.swift"
            ).path
        ))
        #expect(!FileManager.default.fileExists(atPath: buildDirectory
            .appendingPathComponent("HelixGenerated/patch/Compiler/Feature/swiftc")
            .path))

        let patchReceipt = try ShellBuildReceipt.Codec.decode(
            Data(contentsOf: shell.appendingPathComponent("ShellBuildReceipt.json"))
        )
        #expect(patchReceipt.configuration.schema == 1)
        let builtinCallees: Set<String> = [
            "Swift.String.init(describing:)",
            "Swift.String.init(reflecting:)",
            "Swift.debugPrint(_:separator:terminator:)",
            "Swift.print(_:separator:terminator:)",
        ]
        let patchCallees = Set(
            patchReceipt.nativeImportCandidates.map(\.canonicalCallee)
        )
        #expect(builtinCallees.isSubset(of: patchCallees))
        #expect(patchCallees.contains {
            $0.hasPrefix("ExternalFixture.ExternalValue.")
        })
        #expect(patchReceipt.nativeImportCandidates
            .filter { $0.canonicalCallee.hasPrefix("ExternalFixture.") }
            .allSatisfy { $0.isEmittedToDevice })
        let externalTypeBinding = try #require(
            patchReceipt.nativeTypeBindings.first {
                $0.generated?.nativeModuleName == "ExternalFixture"
            }
        )
        let generatedExternalType = try #require(
            externalTypeBinding.generated
        )
        let externalTypeSource = try String(
            contentsOf: shell.appendingPathComponent(
                BridgeGeneration.Generator.entrySourcePath(
                    for: generatedExternalType.sourceFileLogicalID
                )
            ),
            encoding: .utf8
        )
        #expect(externalTypeSource.contains("import ExternalFixture"))
        #expect(!externalTypeSource.contains("@_private(sourceFile:"))
        let externalAdapterSource = try String(
            contentsOf: shell.appendingPathComponent(
                BridgeGeneration.Generator.adapterPackSourcePath(
                    moduleName: "ExternalFixture"
                )
            ),
            encoding: .utf8
        )
        #expect(externalAdapterSource.contains("import ExternalFixture"))
        let stableShellArtifact = shell.appendingPathComponent(
            "Generated/FeatureBridge.swift"
        )
        let stableIdentity = try #require(
            FileManager.default.attributesOfItem(atPath: stableShellArtifact.path)[
                .systemFileNumber
            ] as? NSNumber
        )
        let repeatedPatch = await application.runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(repeatedPatch.exitCode == 0, Comment(rawValue: repeatedPatch.standardError))
        let repeatedPatchPerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/BuildPerformance.prepare.json"
            )
        )
        #expect(repeatedPatchPerformance.trace.counters.contains {
            $0.name == "prepare.state_hit_count" && $0.value == 1
        })
        #expect(!repeatedPatchPerformance.trace.subprocesses.contains {
            $0.kind == .typedAST || $0.kind == .canonicalSIL
                || $0.kind == .symbolGraph
        })
        #expect(try #require(
            FileManager.default.attributesOfItem(atPath: stableShellArtifact.path)[
                .systemFileNumber
            ] as? NSNumber
        ) == stableIdentity)

        let stableShellBytes = try Data(contentsOf: stableShellArtifact)
        try Data("tampered generated source\n".utf8).write(
            to: stableShellArtifact,
            options: .atomic
        )
        let repairedPatch = await application.runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(repairedPatch.exitCode == 0, Comment(rawValue: repairedPatch.standardError))
        let repairedPatchPerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/BuildPerformance.prepare.json"
            )
        )
        #expect(repairedPatchPerformance.trace.counters.contains {
            $0.name == "prepare.state_miss_count" && $0.value == 1
        })
        #expect(repairedPatchPerformance.trace.counters.contains {
            $0.name == "frontend_cache.module_hit_count" && $0.value == 1
        })
        #expect(!repairedPatchPerformance.trace.subprocesses.contains {
            $0.kind == .typedAST || $0.kind == .canonicalSIL
                || $0.kind == .symbolGraph
        })
        #expect(try Data(contentsOf: stableShellArtifact) == stableShellBytes)

        try writeFixtureSwiftModule(
            version: 2,
            compiler: compiler,
            sdkRoot: sdkRoot,
            outputURL: externalModule,
            directory: compilerInputRoot
        )
        let changedDependencyPatch = await application.runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "patch",
            "--phase", "prepare",
        ])
        #expect(
            changedDependencyPatch.exitCode == 0,
            Comment(rawValue: changedDependencyPatch.standardError)
        )
        let changedDependencyPerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/patch/BuildPerformance.prepare.json"
            )
        )
        #expect(changedDependencyPerformance.trace.counters.contains {
            $0.name == "prepare.state_miss_count" && $0.value == 1
        })
        #expect(changedDependencyPerformance.trace.counters.contains {
            $0.name == "frontend_cache.module_miss_count" && $0.value == 1
        })
        #expect(changedDependencyPerformance.trace.subprocesses.contains {
            $0.kind == .typedAST
        })

        var liveEnvironment = environment
        liveEnvironment["CONFIGURATION"] = "Debug"
        liveEnvironment["HELIX_PROFILE_ID"] = "live"
        liveEnvironment["HELIX_WORKFLOW"] = "liveReload"
        liveEnvironment["HELIX_RUNTIME_PRODUCT"] = "HelixAppIntegration"
        liveEnvironment["TARGET_TEMP_DIR"] = buildDirectory.appendingPathComponent(
            "Intermediates/live"
        ).path
        try writeSwiftCapture(
            profileID: "live",
            buildDirectory: buildDirectory,
            compiler: compiler,
            sdkRoot: sdkRoot,
            sourceURLs: [sourceURL],
            additionalArguments: ["-I", compilerInputRoot.path]
        )
        let liveResult = await CLI.Application(
            currentDirectoryURL: directory,
            environment: liveEnvironment,
            hubControlClient: StubHubControlClient()
        ).runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "live",
            "--phase", "prepare",
        ])
        #expect(liveResult.exitCode == 0, Comment(rawValue: liveResult.standardError))
        let livePerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/live/BuildPerformance.prepare.json"
            )
        )
        #expect(livePerformance.operation == .prepare)
        #expect(livePerformance.workflow == .liveReload)
        #expect(livePerformance.outcome == .success)
        #expect(livePerformance.trace.counters.contains {
            $0.name == "prepare.catalog_hit_module_count" && $0.value > 0
        })
        #expect(livePerformance.trace.subprocesses.contains {
            $0.kind == .canonicalSIL && $0.invocationCount >= 2
        })
        let liveShell = buildDirectory.appendingPathComponent(
            "HelixGenerated/live/Shell",
            isDirectory: true
        )
        let reservationURL = liveShell.appendingPathComponent(
            XcodeIntegration.HubReservationDocument.relativePath
        )
        let reservationAttributes = try FileManager.default.attributesOfItem(
            atPath: reservationURL.path
        )
        #expect(
            (reservationAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )
        let sharedCaptureAttributes = try FileManager.default.attributesOfItem(
            atPath: liveShell.appendingPathComponent(
                XcodeIntegration.CompilerCapture.shellRelativeInvocationPath
            ).path
        )
        #expect(
            (sharedCaptureAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )
        let contract = try String(
            contentsOf: liveShell.appendingPathComponent(
                "Generated/FeatureBridge.HubContract.swift"
            ),
            encoding: .utf8
        )
        #expect(contract.contains("@_cdecl(\"hlx_dev_hub_contract_v1\")"))
        #expect(contract.contains("\"AB23\""))
        let liveReceipt = try ShellBuildReceipt.Codec.decode(
            Data(contentsOf: liveShell.appendingPathComponent("ShellBuildReceipt.json"))
        )
        let featureConfiguration = try #require(
            liveReceipt.configuration.modules["Feature"]
        )
        #expect(liveReceipt.configuration.schema == 1)
        #expect(featureConfiguration.nativeImports.sourceScope?.visibility == .all)
        let liveCallees = Set(
            liveReceipt.nativeImportCandidates.map(\.canonicalCallee)
        )
        #expect(builtinCallees.isSubset(of: liveCallees))
        #expect(liveCallees.contains {
            $0.hasPrefix("ExternalFixture.ExternalValue.")
        })
        let entrySymbols = Set(liveReceipt.roots.compactMap { root in
            root.bridge == nil ? nil : root.declarationMangledName
        })
        #expect(entrySymbols.count == 3)
        let importedSymbols = Set(
            liveReceipt.nativeImportCandidates.flatMap(\.silMangledNames)
        )
        #expect(entrySymbols.isDisjoint(with: importedSymbols))

        let repeatedLive = await CLI.Application(
            currentDirectoryURL: directory,
            environment: liveEnvironment,
            hubControlClient: StubHubControlClient()
        ).runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "live",
            "--phase", "prepare",
        ])
        #expect(repeatedLive.exitCode == 0, Comment(rawValue: repeatedLive.standardError))
        let repeatedLivePerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/live/BuildPerformance.prepare.json"
            )
        )
        #expect(repeatedLivePerformance.trace.counters.contains {
            $0.name == "prepare.state_hit_count" && $0.value == 1
        })
        #expect(repeatedLivePerformance.trace.counters.contains {
            $0.name == "prepare.hub_reservation_reused_count" && $0.value == 1
        })
        #expect(!repeatedLivePerformance.trace.subprocesses.contains {
            $0.kind == .typedAST || $0.kind == .canonicalSIL
                || $0.kind == .symbolGraph
        })
        #expect(!repeatedLivePerformance.trace.stages.contains {
            $0.name == "prepare.frontend_receipt"
                || $0.name == "prepare.catalog_read"
                || $0.name == "prepare.catalog_build"
        })
        #expect(repeatedLivePerformance.trace.stages.contains {
            $0.name == "prepare.reserve_hub"
        })

        let liveStateURL = buildDirectory.appendingPathComponent(
            "HelixGenerated/live/PrepareState.json"
        )
        var pendingState = try XcodeIntegration.PrepareStateCodec.decode(
            Data(contentsOf: liveStateURL)
        )
        pendingState.requiresNativeAPICatalogRefresh = true
        try XcodeIntegration.PrepareStateCodec.encode(pendingState).write(
            to: liveStateURL
        )
        let refreshedLive = await CLI.Application(
            currentDirectoryURL: directory,
            environment: liveEnvironment,
            hubControlClient: StubHubControlClient()
        ).runAsync([
            "xcode", "phase",
            "--plan", generatedPlanURL.path,
            "--profile", "live",
            "--phase", "prepare",
        ])
        #expect(
            refreshedLive.exitCode == 0,
            Comment(rawValue: refreshedLive.standardError)
        )
        let refreshedLivePerformance = try buildPerformanceReport(
            at: buildDirectory.appendingPathComponent(
                "HelixGenerated/live/BuildPerformance.prepare.json"
            )
        )
        #expect(refreshedLivePerformance.trace.counters.contains {
            $0.name == "prepare.catalog_refresh_pending_count"
                && $0.value == 1
        })
        #expect(refreshedLivePerformance.trace.counters.contains {
            $0.name == "prepare.state_miss_count" && $0.value == 1
        })
        #expect(refreshedLivePerformance.trace.stages.contains {
            $0.name == "prepare.catalog_read"
        })
        let refreshedState = try XcodeIntegration.PrepareStateCodec.decode(
            Data(contentsOf: liveStateURL)
        )
        #expect(!refreshedState.requiresNativeAPICatalogRefresh)
    }

    @Test("Live Catalog prewarm publishes one private canonical job")
    func catalogPrewarmScheduling() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try BuildCache.Store(
            rootURL: directory.appendingPathComponent("BuildCache")
        )
        let output = directory.appendingPathComponent("Output")
        let compiler = URL(fileURLWithPath: "/usr/bin/swiftc")
        let target = "arm64-apple-ios15.0-simulator"
        let minimumOS = Core.SemanticVersion(15)
        let toolchain = ReleaseCompiler.ToolchainIdentity(
            fingerprint: "catalog-prewarm-fixture",
            versionOutput: "Swift fixture",
            targetInfo: target,
            compilerBinaryHash: .sha256("swiftc")
        )
        let sdk = SwiftFrontend.Driver.SDKIdentity(
            name: "iphonesimulator",
            path: "/tmp/Fixture.sdk",
            buildVersion: "24A1"
        )
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "Feature",
            targetTriple: target,
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: [
                "-parse-as-library", "-swift-version", "6",
            ]
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.prewarm",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.prewarm",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: minimumOS,
            xcodeBuild: "24A1",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("fixture")
        )
        let identity = NativeAPICatalog.Identity(
            provenance: .thirdPartyModule,
            xcodeProductBuild: metadata.xcodeBuild,
            sdkProductBuild: metadata.sdkBuild,
            compilerFingerprint: toolchain.fingerprint,
            targetTriple: target,
            minimumDeployment: minimumOS,
            swiftLanguageMode: "6",
            moduleName: "ExternalFixture",
            moduleContentHash: .sha256("module"),
            moduleSearchPathHash: .sha256("search"),
            dependencyGraphHash: .sha256("dependencies")
        )
        let request = NativeAPICatalog.BuildRequest(
            identity: identity,
            frontendInvocation: invocation,
            compilerURL: compiler,
            workingDirectoryURL: directory,
            precomputedToolchain: toolchain,
            precomputedSDK: sdk
        )
        let compilerInputs = BuildCache.CompilerInputs.Snapshot(
            importedModules: [identity.moduleName],
            searchRoots: [],
            explicitPaths: [],
            fileCount: 0,
            byteCount: 0,
            contentHash: .sha256("inputs"),
            isComplete: true
        )
        let planRequest = NativeAPICatalog.PlanRequest(
            metadata: metadata,
            importedModules: [identity.moduleName],
            compilerArguments: [],
            compilerURL: compiler,
            workingDirectory: directory,
            toolchain: toolchain,
            sdk: sdk,
            compilerInputs: compilerInputs
        )
        let recorder = CatalogPrewarmLaunchRecorder()
        let executable = directory.appendingPathComponent("helix")
        let application = CLI.Application(
            currentDirectoryURL: directory,
            executableURL: executable,
            catalogPrewarmLauncher: recorder.record
        )

        try application.scheduleNativeAPICatalogPrewarm(
            requests: [request],
            cache: cache,
            workingDirectoryURL: directory,
            planRequest: planRequest,
            outputDirectoryURL: output
        )
        let launch = try #require(recorder.invocations.first)
        #expect(recorder.invocations.count == 1)
        #expect(launch.executableURL == executable.standardizedFileURL)
        #expect(launch.workingDirectoryURL == directory.standardizedFileURL)
        #expect(launch.logURL.deletingLastPathComponent()
            == launch.jobURL.deletingLastPathComponent())
        let jobDirectoryAttributes = try FileManager.default.attributesOfItem(
            atPath: launch.jobURL.deletingLastPathComponent().path
        )
        #expect(
            (jobDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )
        let jobAttributes = try FileManager.default.attributesOfItem(
            atPath: launch.jobURL.path
        )
        #expect(
            (jobAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        let decoded = try NativeAPICatalog.PrewarmJobCodec.decode(
            Data(contentsOf: launch.jobURL)
        )
        #expect(decoded.requests == [request])
        #expect(decoded.planRequest.importedModules == [identity.moduleName])

        try application.scheduleNativeAPICatalogPrewarm(
            requests: [request],
            cache: cache,
            workingDirectoryURL: directory,
            planRequest: planRequest,
            outputDirectoryURL: output
        )
        #expect(recorder.invocations.count == 2)
        #expect(recorder.invocations.last?.jobURL == launch.jobURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: launch.jobURL.path
        )
        #expect(throws: CLI.Error.self) {
            try application.scheduleNativeAPICatalogPrewarm(
                requests: [request],
                cache: cache,
                workingDirectoryURL: directory,
                planRequest: planRequest,
                outputDirectoryURL: output
            )
        }
    }

    @Test("Final Bridge identity covers Hub contract compiler inputs")
    func bridgeIdentityCoversHubContractInputs() throws {
        let applicationInputs = BuildCache.CompilerInputs.Snapshot(
            importedModules: ["HelixRuntime"],
            searchRoots: ["/fixture/runtime"],
            explicitPaths: [],
            fileCount: 1,
            byteCount: 128,
            contentHash: .sha256("application-inputs"),
            isComplete: true
        )
        let hubInputs = BuildCache.CompilerInputs.Snapshot(
            importedModules: ["HelixDevRuntime"],
            searchRoots: ["/fixture/dev-runtime"],
            explicitPaths: [],
            fileCount: 1,
            byteCount: 64,
            contentHash: .sha256("hub-inputs"),
            isComplete: true
        )
        let toolchain = ReleaseCompiler.ToolchainIdentity(
            fingerprint: "swift-fixture",
            versionOutput: "Swift fixture",
            targetInfo: "arm64-apple-ios-simulator",
            compilerBinaryHash: .sha256("swiftc")
        )
        let input = CLI.XcodeBridgeInput(
            profileID: "live",
            transformPipelineHash: .sha256("transform"),
            toolchain: toolchain,
            clangCompilerPath: "/fixture/clang",
            clangCompilerHash: .sha256("clang"),
            xcodeBuild: "24A1",
            sdkBuild: "24A1",
            compilerArguments: ["-module-name", "HelixBridge"],
            compilerInputs: applicationInputs,
            generatedSources: [
                .init(
                    path: "Generated/FeatureBridge.HubContract.swift",
                    data: Data("contract".utf8)
                )
            ],
            adapterObjects: [],
            hubContractObject: .init(
                compilerArguments: ["-module-name", "HelixHubContract"],
                compilerInputs: hubInputs
            ),
            moduleMaps: [],
            bootstrapSource: "bootstrap"
        )
        let baseline = try BuildCache.key(
            domain: "HLX.Xcode.BridgeInput.v1",
            value: input
        )
        var changed = input
        changed.hubContractObject?.compilerInputs.contentHash = .sha256(
            "changed-hub-inputs"
        )
        #expect(try BuildCache.key(
            domain: "HLX.Xcode.BridgeInput.v1",
            value: changed
        ) != baseline)
        changed = input
        changed.hubContractObject = nil
        #expect(try BuildCache.key(
            domain: "HLX.Xcode.BridgeInput.v1",
            value: changed
        ) != baseline)
    }

    private func buildPerformanceReport(
        at url: URL
    ) throws -> BuildPerformance.Report {
        let bytes = try Data(contentsOf: url)
        let report = try JSONDecoder().decode(
            BuildPerformance.Report.self,
            from: bytes
        )
        try report.validate()
        #expect(try Core.CanonicalJSON.encode(report) == bytes)
        return report
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

    private func writeFixtureSwiftModule(
        version: Int,
        compiler: String,
        sdkRoot: String,
        outputURL: URL,
        directory: URL
    ) throws {
        let source = directory.appendingPathComponent("ExternalFixture.swift")
        try Data(
            """
            public struct ExternalValue {
                public let rawValue: Int
                public init(rawValue: Int) { self.rawValue = rawValue }
                public func incremented() -> Int { rawValue + \(version) }
                public static let version = \(version)
            }
            """.utf8
        ).write(to: source)
        _ = try toolOutput(
            executable: compiler,
            arguments: [
                "-emit-module", "-parse-as-library", source.path,
                "-module-name", "ExternalFixture",
                "-target", "arm64-apple-ios15.0-simulator",
                "-sdk", sdkRoot,
                "-emit-module-path", outputURL.path,
            ]
        )
    }

    private func writeSwiftCapture(
        profileID: String,
        buildDirectory: URL,
        compiler: String,
        sdkRoot: String,
        sourceURLs: [URL],
        additionalArguments: [String] = []
    ) throws {
        let url = buildDirectory.appendingPathComponent(
            "Intermediates/\(profileID)/Helix/FrontendInvocation.hlxswiftc"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fields = [
            Core.CompilerCapture.recordMarker,
            compiler,
            "-module-name", "Feature",
            "-target", "arm64-apple-ios15.0-simulator",
            "-sdk", sdkRoot,
            "-Onone",
        ] + additionalArguments + sourceURLs.map(\.path)
        var data = Data()
        for field in fields {
            data.append(Data(field.utf8))
            data.append(0)
        }
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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

private struct StubHubControlClient: HubControl.ClientProtocol {
    func reserveAutomaticInvitation(
        reusing existing: Pairing.Reservation?
    ) async throws -> (
        reservation: Pairing.Reservation,
        spkiSHA256: Core.Digest
    ) {
        if let existing {
            return (existing, .sha256("stub Hub Host Identity"))
        }
        return (
            .init(
                invitationID: .init(
                    rawValue: UUID(
                        uuidString: "11111111-2222-3333-4444-555555555555"
                    )!
                ),
                code: try Pairing.Code("AB23"),
                kind: .automaticXcode,
                reservedAt: Date(timeIntervalSinceReferenceDate: 1_000)
            ),
            .sha256("stub Hub Host Identity")
        )
    }

    func registerAndActivate(
        invitationID _: DevProtocol.InvitationID,
        context _: DevSession.BuildContext
    ) async throws -> Pairing.Invitation {
        throw HubControl.Error.invalidMessage
    }
}

private final class CatalogPrewarmLaunchRecorder: @unchecked Sendable {
    struct Invocation {
        var executableURL: URL
        var jobURL: URL
        var logURL: URL
        var workingDirectoryURL: URL
    }

    private let lock = NSLock()
    private var storage: [Invocation] = []

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(
        executableURL: URL,
        jobURL: URL,
        logURL: URL,
        workingDirectoryURL: URL
    ) {
        lock.lock()
        storage.append(.init(
            executableURL: executableURL,
            jobURL: jobURL,
            logURL: logURL,
            workingDirectoryURL: workingDirectoryURL
        ))
        lock.unlock()
    }
}
