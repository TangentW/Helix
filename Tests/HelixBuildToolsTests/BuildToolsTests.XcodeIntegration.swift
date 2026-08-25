import Foundation
import HelixCore
import HelixDevTools
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Xcode host integration contract")
struct XcodeIntegrationContract {
    @Test("Audited Release baseline receipts are canonical and identity-bound")
    func releaseBaselineReceipt() throws {
        let receipt = XcodeIntegration.ReleaseBaseline(
            profileID: "patch",
            bundleID: "dev.helix.patch-demo",
            marketingVersion: "1.0",
            buildNumber: "7",
            configurationName: "Release",
            moduleName: "PatchFeature",
            targetTriple: "arm64-apple-ios15.0-simulator",
            minimumOS: .init(15, 0, 0),
            xcodeBuild: "18A1",
            sdkBuild: "24A1",
            swiftCompilerFingerprint: "swift-fixture",
            machOUUIDs: [
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            ],
            shellInterfaceHash: .sha256("shell"),
            interfaceArchiveSHA256: .sha256("archive"),
            executableSHA256: .sha256("executable"),
            releaseAuditSHA256: .sha256("audit"),
            createdAtUnixSeconds: 2_000_000_000
        )
        let bytes = try XcodeIntegration.ReleaseBaselineCodec.encode(receipt)
        #expect(try XcodeIntegration.ReleaseBaselineCodec.decode(bytes) == receipt)
        var trailing = bytes
        trailing.append(UInt8(ascii: "\n"))
        #expect(throws: XcodeIntegration.Error.self) {
            try XcodeIntegration.ReleaseBaselineCodec.decode(trailing)
        }
    }

    @Test("Host Plan and generated kit are canonical, deterministic, and workflow-separated")
    func generatesDeterministicKit() throws {
        let plan = makePlan()
        let bytes = try XcodeIntegration.HostPlanCodec.encode(plan)
        let decoded = try XcodeIntegration.HostPlanCodec.decode(bytes)
        #expect(decoded == plan)

        let first = try XcodeIntegration.KitGenerator().generate(plan: decoded)
        let second = try XcodeIntegration.KitGenerator().generate(plan: decoded)
        #expect(first.artifacts == second.artifacts)
        #expect(first.manifest == second.manifest)
        #expect(first.artifacts["HostPlan.json"] == bytes)
        #expect(first.artifacts.count == first.manifest.artifacts.count + 1)
        #expect(!first.manifest.artifacts.contains { $0.path == "IntegrationManifest.json" })
        #expect(first.executablePaths.contains("Scripts/helix-phase.sh"))
        #expect(first.executablePaths.contains(
            XcodeIntegration.CompilerCapture.integrationProxyPath
        ))
        #expect(first.manifest.artifacts.first {
            $0.path == "Scripts/helix-phase.sh"
        }?.permissions == 0o755)
        #expect(first.manifest.artifacts.first {
            $0.path == "Shared/Helix.xcconfig"
        }?.permissions == 0o644)
        #expect(first.manifest.artifacts.first {
            $0.path == XcodeIntegration.CompilerCapture.integrationProxyPath
        }?.permissions == 0o755)
        let shared = text(try #require(first.artifacts["Shared/Helix.xcconfig"]))
        #expect(shared.contains("ENABLE_USER_SCRIPT_SANDBOXING = NO"))

        let live = try #require(first.manifest.profiles.first {
            $0.profileID == "live"
        })
        let patch = try #require(first.manifest.profiles.first {
            $0.profileID == "patch"
        })
        #expect(live.runtimePackageProduct == "HelixAppIntegration")
        #expect(patch.runtimePackageProduct == "HelixAppIntegration")

        let liveFeature = text(
            try #require(first.artifacts[live.featureConfiguration])
        )
        let patchFeature = text(
            try #require(first.artifacts[patch.featureConfiguration])
        )
        #expect(liveFeature.contains("-enable-implicit-dynamic"))
        #expect(liveFeature.contains("-enable-dynamic-replacement-chaining"))
        #expect(liveFeature.contains("HELIX_REAL_SWIFT_EXEC"))
        #expect(liveFeature.contains(
            "SWIFT_EXEC = $(HELIX_INTEGRATION_ROOT)/Scripts/Compiler/swiftc"
        ))
        #expect(liveFeature.contains("SWIFT_USE_INTEGRATED_DRIVER = NO"))
        #expect(liveFeature.contains("LD_DYLIB_INSTALL_NAME = @rpath/$(EXECUTABLE_PATH)"))
        #expect(patchFeature.contains("LD_DYLIB_INSTALL_NAME = @rpath/$(EXECUTABLE_PATH)"))
        #expect(patchFeature.contains("-enable-implicit-dynamic"))
        #expect(patchFeature.contains("-enable-dynamic-replacement-chaining"))
        #expect(patchFeature.contains("HELIX_REAL_SWIFT_EXEC"))
        #expect(patchFeature.contains("SWIFT_USE_INTEGRATED_DRIVER = NO"))
        let liveApplication = text(
            try #require(first.artifacts[live.applicationConfiguration])
        )
        #expect(!liveApplication.contains("SWIFT_EXEC"))
        #expect(liveApplication.contains(
            "\"$(HELIX_BRIDGE_OBJECT)\" \"$(HELIX_BOOTSTRAP_OBJECT)\""
        ))
        #expect(liveApplication.contains("-framework HelixDevSupport"))
        #expect(liveApplication.contains("PackageFrameworks"))
        #expect(liveApplication.contains("_hlx_bridge_provider_v1"))
        #expect(liveApplication.contains("_hlx_dev_hub_contract_v1"))
        let patchApplication = text(
            try #require(first.artifacts[patch.applicationConfiguration])
        )
        #expect(!patchApplication.contains("HelixDevSupport"))
        #expect(!patchApplication.contains("_hlx_dev_hub_contract_v1"))
        let patchProfile = text(
            try #require(first.artifacts[patch.commonConfiguration])
        )
        #expect(patchProfile.contains("HELIX_PATCH_PRIVATE_KEY"))
        #expect(first.artifacts["Profiles/patch/patch.sh"] != nil)
        let guide = text(try #require(first.artifacts["Integration.md"]))
        #expect(guide.contains("Keep Helix open and use Xcode Run"))
        #expect(guide.contains("not a setup checklist"))
        #expect(guide.contains("linked automatically"))
        #expect(guide.contains("file list or policy update"))
        #expect(guide.contains("no second App target"))
        #expect(guide.contains("Scheme `Helix Patch Action`"))
        var distinctTargetPlan = plan
        let patchFeatureIndex = try #require(
            distinctTargetPlan.features.firstIndex { $0.id == "patch-feature" }
        )
        distinctTargetPlan.features[patchFeatureIndex].targetName = "PatchSourceTarget"
        let distinctTargetKit = try XcodeIntegration.KitGenerator().generate(
            plan: distinctTargetPlan
        )
        let distinctTargetGuide = text(try #require(
            distinctTargetKit.artifacts["Integration.md"]
        ))
        #expect(distinctTargetGuide.contains("Source target: `PatchSourceTarget`"))
        #expect(!distinctTargetGuide.contains("Source target: `PatchFeature`"))
        let patchGuide = try #require(
            guide.split(separator: "## `patch`", maxSplits: 1).last.map(String.init)
        )
        #expect(patchGuide.contains("records the compiler, SDK, App identity"))
        let liveProfile = text(try #require(
            first.artifacts[live.commonConfiguration]
        ))
        #expect(!liveProfile.contains("EMIT_FRONTEND_COMMAND_LINES"))
        #expect(!patchProfile.contains("EMIT_FRONTEND_COMMAND_LINES"))

        #expect(first.artifacts[live.bridgePhaseScript] != nil)
        #expect(!first.artifacts.keys.contains { $0.hasSuffix("Sources.xcfilelist") })
        #expect(!first.artifacts.keys.contains { $0.hasSuffix("Bridge.xcconfig") })
        #expect(guide.contains("Generated Bridge code remains in DerivedData"))
        #expect(!guide.contains("Use `Profiles/"))
        let livePrepare = text(try #require(
            first.artifacts["Profiles/live/prepare.sh"]
        ))
        #expect(livePrepare.contains("script_directory=$(CDPATH= cd"))
        #expect(livePrepare.contains("$script_directory/../.."))
        #expect(livePrepare.contains(
            "export HELIX_HOST_PLAN=\"$integration_root/HostPlan.json\""
        ))
        #expect(livePrepare.contains("export HELIX_PROFILE_ID=\"live\""))
        let dispatcher = text(
            try #require(first.artifacts["Scripts/helix-phase.sh"])
        )
        #expect(dispatcher.contains("exec \"$helix_executable\" xcode phase"))
        #expect(dispatcher.contains("${HELIX_EXECUTABLE:-}"))
        #expect(dispatcher.contains(
            "Library/Application Support/Helix/Service.json"
        ))
        #expect(dispatcher.contains(
            "plutil -extract toolExecutablePath raw"
        ))
        #expect(dispatcher.contains("plutil -extract schemaVersion raw"))
        #expect(dispatcher.contains("[ \"$record_schema\" = \"1\" ]"))
        #expect(dispatcher.contains("plutil -extract processIdentifier raw"))
        #expect(dispatcher.contains("/bin/kill -0 \"$record_pid\""))
        #expect(dispatcher.contains("[ \"$record_mode\" = \"600\" ]"))
        #expect(dispatcher.contains("clean|analyze|installhdrs|installsrc"))
        #expect(dispatcher.contains(
            "unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION"
        ))
        #expect(!dispatcher.contains("SESSION_SECRET"))

        let proxy = XcodeIntegration.CompilerCapture.proxyScript()
        let proxyText = text(proxy)
        #expect(proxyText.contains("HLX.SwiftInvocation.v1"))
        #expect(proxyText.contains("FrontendInvocation.hlxswiftc"))
        #expect(proxyText.contains("has_module=false"))
        #expect(proxyText.contains("[ \"$has_sdk\" = true ]"))
        #expect(proxyText.contains("${HELIX_REAL_SWIFT_EXEC:-}"))
        #expect(proxyText.contains("/usr/bin/xcrun --find swiftc"))
        #expect(proxyText.contains("should_capture=false"))
        #expect(proxyText.contains("-output-file-map"))
        #expect(proxyText.contains("Objects-*"))
        let invocation = try #require(proxyText.range(of: "\"$real_compiler\" \"$@\""))
        let capture = try #require(proxyText.range(of: "mv -f \"$temporary\" \"$capture_file\""))
        #expect(invocation.lowerBound < capture.lowerBound)
        #expect(proxyText.contains("compiler_status=$?"))
    }

    @Test("Compiler proxy forwards discovery and captures successful target compiles")
    func compilerProxyForwardsDiscoveryAndCapturesCompile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-swift-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let realCompiler = root.appendingPathComponent("swiftc")
        try Data(
            """
            #!/bin/sh
            if [ "${HELIX_FIXTURE_FAIL:-}" = 1 ]; then
                exit 23
            fi
            printf 'Swift version fixture\n'

            """.utf8
        ).write(
            to: realCompiler
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: realCompiler.path
        )
        let callbackCapture = root.appendingPathComponent("PostCompile.txt")
        let callback = root.appendingPathComponent("post-compile.sh")
        try Data(
            "#!/bin/sh\nprintf '%s' \"$1\" > \"$HELIX_POST_CAPTURE\"\n".utf8
        ).write(to: callback)
        let proxy = root.appendingPathComponent("proxy-swiftc")
        try XcodeIntegration.CompilerCapture.proxyScript(
            postCompileScriptName: callback.lastPathComponent
        ).write(to: proxy)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: proxy.path
        )

        let standardOutput = Pipe()
        let process = Process()
        process.executableURL = proxy
        process.arguments = ["--version"]
        process.environment = [
            "HELIX_REAL_SWIFT_EXEC": realCompiler.path,
            "HELIX_POST_CAPTURE": callbackCapture.path,
        ]
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ) == "Swift version fixture\n")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Compiler").path
        ))
        #expect(!FileManager.default.fileExists(atPath: callbackCapture.path))

        let outputMap = root.appendingPathComponent(
            "Intermediates/Demo.build/Debug/Feature.build/Objects-normal/arm64/Feature-OutputFileMap.json"
        )
        try FileManager.default.createDirectory(
            at: outputMap.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let compilation = Process()
        compilation.executableURL = proxy
        compilation.arguments = [
            "-module-name", "Feature",
            "-target", "arm64-apple-ios15.0-simulator",
            "-sdk", "/SDK/iPhoneSimulator.sdk",
            "-output-file-map", outputMap.path,
        ]
        let failedCompilation = Process()
        failedCompilation.executableURL = proxy
        failedCompilation.arguments = compilation.arguments
        failedCompilation.environment = [
            "HELIX_REAL_SWIFT_EXEC": realCompiler.path,
            "HELIX_FIXTURE_FAIL": "1",
            "HELIX_POST_CAPTURE": callbackCapture.path,
        ]
        failedCompilation.standardOutput = Pipe()
        failedCompilation.standardError = Pipe()
        try failedCompilation.run()
        failedCompilation.waitUntilExit()
        #expect(failedCompilation.terminationStatus == 23)
        #expect(!FileManager.default.fileExists(atPath: callbackCapture.path))

        let recordURL = root.appendingPathComponent(
            "Intermediates/Demo.build/Debug/Feature.build/Helix/FrontendInvocation.hlxswiftc"
        )
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))

        compilation.environment = [
            "HELIX_REAL_SWIFT_EXEC": realCompiler.path,
            "HELIX_POST_CAPTURE": callbackCapture.path,
        ]
        let diagnostics = Pipe()
        compilation.standardOutput = Pipe()
        compilation.standardError = diagnostics
        try compilation.run()
        compilation.waitUntilExit()
        #expect(
            compilation.terminationStatus == 0,
            Comment(rawValue: String(
                decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ))
        )

        let record = try BuildCapture.SwiftInvocationReader().readFrontendJob(
            at: recordURL
        )
        #expect(record.executable == realCompiler.path)
        #expect(record.arguments == (compilation.arguments ?? []))
        #expect(try String(contentsOf: callbackCapture, encoding: .utf8) == recordURL.path)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: recordURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Compiler scheduling uses one stable target-owned source")
    func compilerTriggerIdentity() {
        let path = XcodeIntegration.CompilerCapture.targetTriggerPath(
            targetName: "Demo App"
        )
        #expect(path.hasPrefix("Compiler/Targets/HelixBuildTrigger_"))
        #expect(path.hasSuffix(".swift"))
        #expect(path == XcodeIntegration.CompilerCapture.targetTriggerPath(
            targetName: "Demo App"
        ))
        #expect(path != XcodeIntegration.CompilerCapture.targetTriggerPath(
            targetName: "Other App"
        ))
        #expect(XcodeIntegration.CompilerCapture.isTargetTriggerLogicalPath(
            ".helix/xcode/\(path)",
            integrationRoot: ".helix/xcode"
        ))
        #expect(!XcodeIntegration.CompilerCapture.isTargetTriggerLogicalPath(
            "Sources/HelixBuildTrigger_fixture.swift",
            integrationRoot: ".helix/xcode"
        ))
    }

    @Test("Captured compiler arguments preserve semantics and discard build outputs")
    func selectsCapturedCompilerArguments() throws {
        let captured = [
            "-module-name", "Example",
            "-target", "arm64-apple-ios15.0-simulator",
            "-sdk", "/SDK/iPhoneSimulator.sdk",
            "-I", "/Build/Products",
            "-F/Frameworks",
            "-D", "DEBUG",
            "-Xcc", "-fmodule-map-file=/Modules/Example.modulemap",
            "-swift-version", "6",
            "-Xfrontend", "-enable-private-imports",
            "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-dynamic-replacement-chaining",
            "-Xfrontend", "-serialize-debugging-options",
            "-output-file-map", "/Build/Outputs.json",
            "-emit-module-path", "/Build/Example.swiftmodule",
            "/Sources/Example.swift",
        ]
        let semantic = try XcodeIntegration.CompilerArguments.semanticArguments(
            from: captured
        )
        #expect(semantic == [
            "-parse-as-library",
            "-I", "/Build/Products",
            "-F/Frameworks",
            "-D", "DEBUG",
            "-Xcc", "-fmodule-map-file=/Modules/Example.modulemap",
            "-swift-version", "6",
            "-Xfrontend", "-enable-private-imports",
            "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-dynamic-replacement-chaining",
        ])
        #expect(!semantic.contains("/Sources/Example.swift"))
        #expect(!semantic.contains("/Build/Outputs.json"))
        #expect(try XcodeIntegration.CompilerArguments.moduleSearchArguments(
            from: captured
        ) == ["-I", "/Build/Products"])

        #expect(throws: XcodeIntegration.CompilerArgumentError.missing(
            "-enable-dynamic-replacement-chaining"
        )) {
            _ = try XcodeIntegration.CompilerArguments.semanticArguments(
                from: [
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-implicit-dynamic",
                ]
            )
        }
        #expect(throws: XcodeIntegration.CompilerArgumentError.invalid("-I")) {
            _ = try XcodeIntegration.CompilerArguments.moduleSearchArguments(
                from: ["-I", "relative/path"]
            )
        }
    }

    @Test("Xcode phase discovers the exact tool published by the running Hub")
    func dispatcherDiscoversHubTool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-xcode-tool-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let serviceDirectory = root.appendingPathComponent(
            "Library/Application Support/Helix",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: serviceDirectory,
            withIntermediateDirectories: true
        )
        let tool = root.appendingPathComponent("Helix Tool")
        let capture = root.appendingPathComponent("Arguments.txt")
        try Data(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HELIX_TEST_CAPTURE\"\n".utf8
        ).write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tool.path
        )
        let service = serviceDirectory.appendingPathComponent("Service.json")
        let escapedTool = tool.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        try Data(
            """
            {"schemaVersion":1,"processIdentifier":\(processIdentifier),"toolExecutablePath":"\(escapedTool)"}
            """.utf8
        ).write(to: service)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: service.path
        )

        let kit = try XcodeIntegration.KitGenerator().generate(plan: makePlan())
        let dispatcher = root.appendingPathComponent("helix-phase.sh")
        try #require(kit.artifacts["Scripts/helix-phase.sh"]).write(to: dispatcher)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [dispatcher.path, "prepare"]
        process.environment = [
            "HOME": root.path,
            "HELIX_HOST_PLAN": "/tmp/HostPlan.json",
            "HELIX_PROFILE_ID": "live",
            "HELIX_TEST_CAPTURE": capture.path,
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: capture, encoding: .utf8) == """
        xcode
        phase
        --plan
        /tmp/HostPlan.json
        --profile
        live
        --phase
        prepare
        """ + "\n")
    }

    @Test("Xcode phase ignores a stale Hub service record")
    func dispatcherRejectsStaleHubRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-xcode-stale-tool-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let serviceDirectory = root.appendingPathComponent(
            "Library/Application Support/Helix",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: serviceDirectory,
            withIntermediateDirectories: true
        )
        let tool = root.appendingPathComponent("helix")
        let capture = root.appendingPathComponent("Arguments.txt")
        try Data(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HELIX_TEST_CAPTURE\"\n".utf8
        ).write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tool.path
        )
        let escapedTool = tool.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let service = serviceDirectory.appendingPathComponent("Service.json")
        try Data(
            """
            {"schemaVersion":1,"processIdentifier":2147483647,"toolExecutablePath":"\(escapedTool)"}
            """.utf8
        ).write(to: service)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: service.path
        )

        let kit = try XcodeIntegration.KitGenerator().generate(plan: makePlan())
        let dispatcher = root.appendingPathComponent("helix-phase.sh")
        try #require(kit.artifacts["Scripts/helix-phase.sh"]).write(to: dispatcher)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [dispatcher.path, "prepare"]
        process.environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "HELIX_HOST_PLAN": "/tmp/HostPlan.json",
            "HELIX_PROFILE_ID": "live",
            "HELIX_TEST_CAPTURE": capture.path,
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("Hidden Bridge compilation preserves semantics but rejects Feature build outputs")
    func plansHiddenBridgeCompilation() throws {
        let root = URL(fileURLWithPath: "/tmp/Helix Bridge")
        let output = root.appendingPathComponent("Bridge.o")
        let sources = [
            root.appendingPathComponent("Generated/Entry.swift"),
            root.appendingPathComponent("Generated/Provider.swift"),
        ]
        let plan = try XcodeIntegration.BridgeCompilationPlanner().plan(
            compilerPath: "/Toolchain/usr/bin/swiftc",
            capturedArguments: [
                "-module-name", "DemoApp",
                "-target", "arm64-apple-ios15.0-simulator",
                "-sdk", "/SDK/iPhoneSimulator.sdk",
                "-I", "/Build/Products/Debug-iphonesimulator",
                "-F", "/Build/Products/Debug-iphonesimulator",
                "-D", "DEBUG",
                "-Xcc", "-fmodule-map-file=/tmp/module.modulemap",
                "-Xfrontend", "-enable-private-imports",
                "-Xfrontend", "-enable-implicit-dynamic",
                "-Xfrontend", "-enable-dynamic-replacement-chaining",
                "-output-file-map", "/tmp/AppOutputs.json",
                "-emit-module-path", "/tmp/DemoApp.swiftmodule",
                "/Sources/App.swift",
                "-Onone",
            ],
            expectedCompilerPath: "/Toolchain/usr/bin/swiftc",
            expectedCapturedModuleName: "DemoApp",
            expectedTargetTriple: "arm64-apple-ios15.0-simulator",
            expectedSDKPath: "/SDK/iPhoneSimulator.sdk",
            expectedOptimization: "-Onone",
            additionalModuleSearchArguments: [
                "-F", "/Dependencies/Frameworks",
                "-I", "/Dependencies/Modules",
            ],
            clangModuleMapURLs: [URL(fileURLWithPath: "/Modules/Runtime.modulemap")],
            generatedSourceURLs: sources,
            outputURL: output,
            moduleName: "HelixBridge_fixture"
        )
        #expect(plan.compilerURL.path == "/Toolchain/usr/bin/swiftc")
        #expect(plan.arguments.contains("-whole-module-optimization"))
        #expect(plan.arguments.contains("-enable-private-imports"))
        #expect(plan.arguments.contains("-enable-dynamic-replacement-chaining"))
        #expect(plan.arguments.contains("-enable-implicit-dynamic"))
        #expect(plan.arguments.contains("DEBUG"))
        #expect(plan.arguments.contains("-fmodule-map-file=/Modules/Runtime.modulemap"))
        #expect(plan.arguments.contains("/Build/Products/Debug-iphonesimulator"))
        #expect(plan.arguments.contains("/Dependencies/Frameworks"))
        #expect(plan.arguments.contains("/Dependencies/Modules"))
        #expect(!plan.arguments.contains("/Sources/App.swift"))
        #expect(!plan.arguments.contains("/tmp/AppOutputs.json"))
        #expect(!plan.arguments.contains("/tmp/DemoApp.swiftmodule"))
        #expect(plan.arguments.suffix(2) == ["-o", output.path])

        #expect(throws: XcodeIntegration.BridgeCompilationError.invalidInput) {
            try XcodeIntegration.BridgeCompilationPlanner().plan(
                compilerPath: "/Toolchain/usr/bin/swiftc",
                capturedArguments: [
                    "-module-name", "DemoApp",
                    "-target", "arm64-apple-ios15.0-simulator",
                    "-sdk", "/SDK/iPhoneSimulator.sdk",
                ],
                expectedCompilerPath: "/Toolchain/usr/bin/swiftc",
                expectedCapturedModuleName: "DemoApp",
                expectedTargetTriple: "arm64-apple-ios15.0-simulator",
                expectedSDKPath: "/SDK/iPhoneSimulator.sdk",
                expectedOptimization: "-Onone",
                additionalModuleSearchArguments: ["-o", "/tmp/injected.o"],
                clangModuleMapURLs: [],
                generatedSourceURLs: sources,
                outputURL: output,
                moduleName: "HelixBridge_fixture"
            )
        }

        #expect(throws: XcodeIntegration.BridgeCompilationError.invalidInput) {
            try XcodeIntegration.BridgeCompilationPlanner().plan(
                compilerPath: "/Toolchain/usr/bin/swiftc",
                capturedArguments: [
                    "-module-name", "DemoApp",
                    "-target", "arm64-apple-ios15.0-simulator",
                    "-sdk", "/SDK/iPhoneSimulator.sdk",
                ],
                expectedCompilerPath: "/Toolchain/usr/bin/swiftc",
                expectedCapturedModuleName: "DemoApp",
                expectedTargetTriple: "arm64-apple-ios15.0-simulator",
                expectedSDKPath: "/SDK/iPhoneSimulator.sdk",
                expectedOptimization: "-Onone",
                additionalModuleSearchArguments: ["-I", "/Pods/$(CONFIGURATION)"],
                clangModuleMapURLs: [],
                generatedSourceURLs: sources,
                outputURL: output,
                moduleName: "HelixBridge_fixture"
            )
        }

        #expect(throws: XcodeIntegration.BridgeCompilationError.captureMismatch) {
            try XcodeIntegration.BridgeCompilationPlanner().plan(
                compilerPath: "/Toolchain/usr/bin/swiftc",
                capturedArguments: [
                    "-module-name", "DemoApp",
                    "-target", "x86_64-apple-ios15.0-simulator",
                    "-sdk", "/SDK/iPhoneSimulator.sdk",
                ],
                expectedCompilerPath: "/Toolchain/usr/bin/swiftc",
                expectedCapturedModuleName: "DemoApp",
                expectedTargetTriple: "arm64-apple-ios15.0-simulator",
                expectedSDKPath: "/SDK/iPhoneSimulator.sdk",
                expectedOptimization: "-Onone",
                clangModuleMapURLs: [],
                generatedSourceURLs: sources,
                outputURL: output,
                moduleName: "HelixBridge_fixture"
            )
        }
    }

    @Test("Host Plan fails closed on unknown or obsolete fields and path expansion")
    func rejectsAmbiguousPlans() throws {
        let canonical = try XcodeIntegration.HostPlanCodec.encode(makePlan())
        var text = String(decoding: canonical, as: UTF8.self)
        text.insert(contentsOf: "\"unknown\":true,", at: text.index(after: text.startIndex))
        #expect(throws: XcodeIntegration.Error.hostPlanNonCanonical) {
            try XcodeIntegration.HostPlanCodec.decode(Data(text.utf8))
        }

        let obsolete = String(decoding: canonical, as: UTF8.self).replacingOccurrences(
            of: "\"moduleName\":\"LiveFeature\"",
            with: "\"moduleName\":\"LiveFeature\",\"sourceFiles\":[\"Feature.swift\"],\"sourceRoot\":\"Sources\""
        )
        #expect(throws: XcodeIntegration.Error.hostPlanNonCanonical) {
            try XcodeIntegration.HostPlanCodec.decode(Data(obsolete.utf8))
        }

        var expanding = makePlan()
        expanding.integrationRoot = "$(HOME)/generated"
        #expect(throws: XcodeIntegration.Error.self) {
            try expanding.validate()
        }

        var colliding = makePlan()
        colliding.features[1].moduleName = colliding.features[0].moduleName
        #expect(throws: XcodeIntegration.Error.self) {
            try colliding.validate()
        }

        var duplicateFeatureTarget = makePlan()
        duplicateFeatureTarget.features[1].targetName =
            duplicateFeatureTarget.features[0].targetName
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicateFeatureTarget.validate()
        }

        var collidingPatchTarget = makePlan()
        collidingPatchTarget.profiles[1].patch?.actionTargetName = "PatchFeature"
        #expect(throws: XcodeIntegration.Error.self) {
            try collidingPatchTarget.validate()
        }

        var duplicateActionScheme = makePlan()
        let existingSchemeName = duplicateActionScheme.profiles[0].schemeName
        duplicateActionScheme.profiles[1].patch?.actionSchemeName =
            existingSchemeName
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicateActionScheme.validate()
        }

        var duplicateApplicationSlot = makePlan()
        let applicationPatchIndex = try #require(
            duplicateApplicationSlot.profiles.firstIndex { $0.id == "patch" }
        )
        duplicateApplicationSlot.profiles[applicationPatchIndex].applicationTargetName = "LiveDemo"
        duplicateApplicationSlot.profiles[applicationPatchIndex].configurationName = "Debug"
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicateApplicationSlot.validate()
        }

        var duplicateFeatureSlot = makePlan()
        let featurePatchIndex = try #require(
            duplicateFeatureSlot.profiles.firstIndex { $0.id == "patch" }
        )
        duplicateFeatureSlot.profiles[featurePatchIndex].featureID = "live-feature"
        duplicateFeatureSlot.profiles[featurePatchIndex].configurationName = "Debug"
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicateFeatureSlot.validate()
        }
    }

    @Test("Xcode environment resolves exact build identity and rejects profile drift")
    func resolvesBuildEnvironment() throws {
        let plan = makePlan()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-xcode-environment-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let toolchain = root.appendingPathComponent("Toolchain", isDirectory: true)
        let compiler = toolchain.appendingPathComponent("usr/bin/swiftc")
        try FileManager.default.createDirectory(
            at: compiler.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(
            atPath: compiler.path,
            contents: Data("#!/bin/sh\n".utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: compiler.path
        )
        let planURL = root.appendingPathComponent("HostPlan.json")
        var variables = [
            "SRCROOT": root.path,
            "BUILD_DIR": root.appendingPathComponent("DerivedData/Build/Products").path,
            "BUILT_PRODUCTS_DIR": root.appendingPathComponent(
                "DerivedData/Build/Products/Debug-iphonesimulator"
            ).path,
            "OBJROOT": root.appendingPathComponent(
                "DerivedData/Build/Intermediates.noindex"
            ).path,
            "TARGET_TEMP_DIR": root.appendingPathComponent(
                "DerivedData/Build/Intermediates.noindex/Demo.build/Debug/LiveDemo.build"
            ).path,
            "CONFIGURATION": "Debug",
            "PLATFORM_NAME": "iphonesimulator",
            "SDKROOT": root.appendingPathComponent("iPhoneSimulator.sdk").path,
            "GENERATED_MODULEMAP_DIR": root.appendingPathComponent("ModuleMaps").path,
            "ARCHS": "arm64",
            "CURRENT_ARCH": "arm64e",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "SDK_PRODUCT_BUILD_VERSION": "24A1",
            "XCODE_PRODUCT_BUILD_VERSION": "18A1",
            "CURRENT_PROJECT_VERSION": "42",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "SWIFT_EXEC": root.appendingPathComponent("Transient/swiftc").path,
            "TOOLCHAIN_DIR": toolchain.path,
            "SWIFT_VERSION": "6.0",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG HELIX_DEMO",
            "OTHER_SWIFT_FLAGS": "-Xfrontend -enable-private-imports "
                + "-Xfrontend -enable-implicit-dynamic "
                + "-Xfrontend -enable-dynamic-replacement-chaining",
            "SWIFT_INCLUDE_PATHS": root.appendingPathComponent("Dependencies/Modules").path,
            "FRAMEWORK_SEARCH_PATHS": "\""
                + root.appendingPathComponent("Dependencies/Frameworks").path
                + "\" $(inherited)",
            "HELIX_PROFILE_ID": "live",
            "HELIX_WORKFLOW": "liveReload",
            "HELIX_RUNTIME_PRODUCT": "HelixAppIntegration",
            "TARGET_NAME": "LiveDemo",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.helix.live-demo",
            "MARKETING_VERSION": "1.0",
            "TARGET_BUILD_DIR": root.appendingPathComponent(
                "DerivedData/Build/Products/Debug-iphonesimulator"
            ).path,
            "WRAPPER_NAME": "LiveDemo.app",
            "EXECUTABLE_PATH": "LiveDemo.app/LiveDemo",
        ]
        let context = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: "live",
            variables: variables,
            requireTargetCompilerCapture: true
        )
        #expect(context.environment.targetTriple == "arm64-apple-ios15.0-simulator")
        #expect(context.environment.compilerURL == compiler)
        #expect(context.environment.semanticArguments.contains("-swift-version"))
        #expect(context.environment.semanticArguments.contains("6"))
        #expect(context.environment.semanticArguments.contains("HELIX_DEMO"))
        #expect(context.environment.bridgeModuleSearchArguments == [
            "-I", root.appendingPathComponent("Dependencies/Modules").path,
            "-F", root.appendingPathComponent("Dependencies/Frameworks").path,
        ])
        #expect(
            context.environment.profileOutputURL.path
                == root.appendingPathComponent(
                    "DerivedData/Build/Products/Debug-iphonesimulator/HelixGenerated/live"
                ).path
        )
        #expect(
            context.environment.targetFrontendInvocationURL?.path
                == root.appendingPathComponent(
                    "DerivedData/Build/Intermediates.noindex/Demo.build/Debug/LiveDemo.build/Helix/FrontendInvocation.hlxswiftc"
                ).path
        )
        var schemeVariables = variables
        schemeVariables.removeValue(forKey: "OBJROOT")
        schemeVariables.removeValue(forKey: "TARGET_TEMP_DIR")
        let schemeContext = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: "live",
            variables: schemeVariables,
            requireFeatureCompilerSettings: false
        )
        #expect(schemeContext.environment.targetFrontendInvocationURL == nil)

        var escapedCapture = variables
        escapedCapture["TARGET_TEMP_DIR"] = root.appendingPathComponent(
            "Outside/LiveDemo.build"
        ).path
        #expect(throws: XcodeIntegration.EnvironmentError.self) {
            try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: "live",
                variables: escapedCapture,
                requireTargetCompilerCapture: true
            )
        }
        let product = try XcodeIntegration.EnvironmentResolver().resolveProduct(
            context: context,
            variables: variables
        )
        #expect(product.applicationBundleURL.lastPathComponent == "LiveDemo.app")
        #expect(product.executableURL.lastPathComponent == "LiveDemo")

        var deviceVariables = variables
        deviceVariables["PLATFORM_NAME"] = "iphoneos"
        deviceVariables["SDKROOT"] = root.appendingPathComponent(
            "iPhoneOS.sdk"
        ).path
        let deviceContext = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: "live",
            variables: deviceVariables
        )
        #expect(deviceContext.environment.targetTriple == "arm64-apple-ios15.0")

        var ambiguousArchitectures = variables
        ambiguousArchitectures["ARCHS"] = "arm64 x86_64"
        #expect(throws: XcodeIntegration.EnvironmentError.invalid(
            name: "ARCHS",
            value: "arm64 x86_64"
        )) {
            try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: "live",
                variables: ambiguousArchitectures
            )
        }

        variables["MARKETING_VERSION"] = "not-a-version"
        #expect(throws: XcodeIntegration.EnvironmentError.invalid(
            name: "MARKETING_VERSION",
            value: "not-a-version"
        )) {
            try XcodeIntegration.EnvironmentResolver().resolveProduct(
                context: context,
                variables: variables
            )
        }
        variables["MARKETING_VERSION"] = "1.0"

        let generatedPlanURL = root.appendingPathComponent(
            ".helix/xcode/HostPlan.json"
        )
        let generatedContext = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: generatedPlanURL,
            profileID: "live",
            variables: variables
        )
        #expect(generatedContext.environment.sourceRootURL == root)

        variables["HELIX_RUNTIME_PRODUCT"] = "UnexpectedRuntime"
        #expect(throws: XcodeIntegration.EnvironmentError.mismatch(
            name: "HELIX_RUNTIME_PRODUCT",
            expected: "HelixAppIntegration",
            actual: "UnexpectedRuntime"
        )) {
            try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: "live",
                variables: variables
            )
        }
    }

    @Test("Patch output cannot escape through a symbolic directory")
    func rejectsPatchOutputSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-xcode-patch-path-\(UUID().uuidString)",
            isDirectory: true
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-xcode-patch-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".helix", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".helix/patches"),
            withDestinationURL: outside
        )
        let buildDirectory = root.appendingPathComponent("DerivedData/Build/Products")
        let variables = [
            "SRCROOT": root.path,
            "BUILD_DIR": buildDirectory.path,
            "BUILT_PRODUCTS_DIR": root.appendingPathComponent(
                "DerivedData/Build/Products/Release-iphonesimulator"
            ).path,
            "OBJROOT": root.appendingPathComponent(
                "DerivedData/Build/Intermediates.noindex"
            ).path,
            "TARGET_TEMP_DIR": root.appendingPathComponent(
                "DerivedData/Build/Intermediates.noindex/Demo.build/Release/App.build"
            ).path,
            "CONFIGURATION": "Release",
            "PLATFORM_NAME": "iphonesimulator",
            "SDKROOT": root.appendingPathComponent("iPhoneSimulator.sdk").path,
            "GENERATED_MODULEMAP_DIR": root.appendingPathComponent("ModuleMaps").path,
            "CURRENT_ARCH": "arm64",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "SDK_PRODUCT_BUILD_VERSION": "24A1",
            "XCODE_PRODUCT_BUILD_VERSION": "18A1",
            "CURRENT_PROJECT_VERSION": "42",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_EXEC": "/usr/bin/swiftc",
            "HELIX_PATCH_RECIPE": root.appendingPathComponent(
                "Configurations/PatchRecipe.json"
            ).path,
            "HELIX_PATCH_CERTIFICATE": root.appendingPathComponent(
                ".helix/private/SigningCertificate.json"
            ).path,
            "HELIX_PATCH_TRUSTED_ROOT": root.appendingPathComponent(
                ".helix/private/TrustedRoot.json"
            ).path,
            "HELIX_PATCH_PRIVATE_KEY": root.appendingPathComponent(
                ".helix/private/PatchSigningKey.json"
            ).path,
            "HELIX_PATCH_OUTPUT_ROOT": root.appendingPathComponent(".helix/patches").path,
            "MARKETING_VERSION": "1.0",
        ]
        let plan = makePlan()
        let context = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: root.appendingPathComponent("HostPlan.json"),
            profileID: "patch",
            variables: variables,
            requireFeatureCompilerSettings: false
        )
        #expect(throws: XcodeIntegration.EnvironmentError.self) {
            try XcodeIntegration.EnvironmentResolver().resolvePatch(
                context: context,
                variables: variables
            )
        }
    }

    private func makePlan() -> XcodeIntegration.HostPlan {
        .init(
            projectPath: "Demo.xcodeproj",
            features: [
                .init(
                    id: "patch-feature",
                    targetName: "PatchFeature",
                    moduleName: "PatchFeature"
                ),
                .init(
                    id: "live-feature",
                    targetName: "LiveFeature",
                    moduleName: "LiveFeature"
                ),
            ],
            profiles: [
                .init(
                    id: "patch",
                    workflow: .hotPatch,
                    schemeName: "Helix Patch Demo",
                    applicationTargetName: "PatchDemo",
                    configurationName: "Release",
                    bundleIdentifier: "dev.helix.patch-demo",
                    namespaceSeed: "helix-demo-patch",
                    featureID: "patch-feature",
                    patch: .init(
                        actionTargetName: "Build Patch",
                        actionSchemeName: "Helix Patch Action",
                        recipePath: "Configurations/PatchRecipe.json",
                        signingCertificatePath: ".helix/private/SigningCertificate.json",
                        trustedRootPath: ".helix/private/TrustedRoot.json"
                    )
                ),
                .init(
                    id: "live",
                    workflow: .liveReload,
                    schemeName: "Helix Live Demo",
                    applicationTargetName: "LiveDemo",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.helix.live-demo",
                    namespaceSeed: "helix-demo-live",
                    featureID: "live-feature"
                ),
            ]
        )
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
}
