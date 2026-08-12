import Foundation
import HelixCore
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
        #expect(first.manifest.artifacts.first {
            $0.path == "Scripts/helix-phase.sh"
        }?.permissions == 0o755)
        #expect(first.manifest.artifacts.first {
            $0.path == "Shared/Helix.xcconfig"
        }?.permissions == 0o644)

        let live = try #require(first.manifest.profiles.first {
            $0.profileID == "live"
        })
        let patch = try #require(first.manifest.profiles.first {
            $0.profileID == "patch"
        })
        #expect(live.runtimePackageProduct == "HelixDevAppRuntime")
        #expect(patch.runtimePackageProduct == "HelixAppRuntime")

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
            "SWIFT_EXEC = $(HELIX_PROFILE_OUTPUT_DIR)/Compiler/Feature/swiftc"
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
            "\"$(HELIX_BRIDGE_OBJECT)\" -Xlinker -u -Xlinker _hlx_bridge_provider_v1"
        ))
        let patchProfile = text(
            try #require(first.artifacts[patch.commonConfiguration])
        )
        #expect(patchProfile.contains("HELIX_PATCH_PRIVATE_KEY"))
        #expect(first.artifacts["Profiles/patch/patch.sh"] != nil)
        let guide = text(try #require(first.artifacts["Integration.md"]))
        #expect(guide.contains(
            "Run `Profiles/live/live-start.sh` as a Scheme Run"
        ))
        #expect(guide.contains("Do not start the session from a Build post-action"))
        #expect(guide.contains("Aggregate Target `Build Patch`"))
        #expect(guide.contains("`SUPPORTED_PLATFORMS` to `iphoneos iphonesimulator`"))
        #expect(guide.contains("destination must match the SDK"))
        #expect(guide.contains("Scheme `Helix Patch Action`"))
        let liveProfile = text(
            try #require(first.artifacts[live.commonConfiguration])
        )
        #expect(liveProfile.contains("EMIT_FRONTEND_COMMAND_LINES = YES"))
        #expect(!patchProfile.contains("EMIT_FRONTEND_COMMAND_LINES = YES"))

        #expect(first.artifacts[live.bridgePhaseScript] != nil)
        #expect(!first.artifacts.keys.contains { $0.hasSuffix("Sources.xcfilelist") })
        #expect(!first.artifacts.keys.contains { $0.hasSuffix("Bridge.xcconfig") })
        #expect(guide.contains("never add Helix"))
        #expect(guide.contains("DerivedData output to the project"))
        let dispatcher = text(
            try #require(first.artifacts["Scripts/helix-phase.sh"])
        )
        #expect(dispatcher.contains("exec \"$helix_executable\" xcode phase"))
        #expect(dispatcher.contains("${HELIX_EXECUTABLE:-helix}"))
        #expect(dispatcher.contains("clean|analyze|installhdrs|installsrc"))
        #expect(dispatcher.contains(
            "unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION"
        ))
        #expect(!dispatcher.contains("SESSION_SECRET"))

        let proxy = try XcodeIntegration.CompilerCapture.proxyScript(
            realCompilerURL: URL(fileURLWithPath: "/Toolchain/usr/bin/swiftc")
        )
        let proxyText = text(proxy)
        #expect(proxyText.contains("HLX.SwiftInvocation.v1"))
        #expect(proxyText.contains("FrontendInvocation.hlxswiftc"))
        #expect(proxyText.contains("has_module=false"))
        #expect(proxyText.contains("[ \"$has_sdk\" = true ]"))
        let invocation = try #require(proxyText.range(of: "\"$real_compiler\" \"$@\""))
        let capture = try #require(proxyText.range(of: "mv -f \"$temporary\" \"$capture_file\""))
        #expect(invocation.lowerBound < capture.lowerBound)
        #expect(proxyText.contains("compiler_status=$?"))
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
            clangModuleMapURLs: [URL(fileURLWithPath: "/Modules/Runtime.modulemap")],
            generatedSourceURLs: sources,
            outputURL: output,
            moduleName: "HelixBridge_fixture"
        )
        #expect(plan.compilerURL.path == "/Toolchain/usr/bin/swiftc")
        #expect(plan.arguments.contains("-whole-module-optimization"))
        #expect(plan.arguments.contains("-enable-private-imports"))
        #expect(plan.arguments.contains("-enable-dynamic-replacement-chaining"))
        #expect(plan.arguments.contains("DEBUG"))
        #expect(plan.arguments.contains("-fmodule-map-file=/Modules/Runtime.modulemap"))
        #expect(plan.arguments.contains("/Build/Products/Debug-iphonesimulator"))
        #expect(!plan.arguments.contains("/Sources/App.swift"))
        #expect(!plan.arguments.contains("/tmp/AppOutputs.json"))
        #expect(!plan.arguments.contains("/tmp/DemoApp.swiftmodule"))
        #expect(plan.arguments.suffix(2) == ["-o", output.path])

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

    @Test("Host Plan fails closed on unknown fields, duplicate sources, and path expansion")
    func rejectsAmbiguousPlans() throws {
        let canonical = try XcodeIntegration.HostPlanCodec.encode(makePlan())
        var text = String(decoding: canonical, as: UTF8.self)
        text.insert(contentsOf: "\"unknown\":true,", at: text.index(after: text.startIndex))
        #expect(throws: XcodeIntegration.Error.hostPlanNonCanonical) {
            try XcodeIntegration.HostPlanCodec.decode(Data(text.utf8))
        }

        var duplicate = makePlan()
        duplicate.features[0].sourceFiles = ["Sources/Feature.swift", "Sources/Feature.swift"]
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicate.validate()
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

        var duplicateActionScheme = makePlan()
        let existingSchemeName = duplicateActionScheme.profiles[0].schemeName
        duplicateActionScheme.profiles[1].patch?.actionSchemeName =
            existingSchemeName
        #expect(throws: XcodeIntegration.Error.self) {
            try duplicateActionScheme.validate()
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
        let planURL = root.appendingPathComponent("HelixXcode.json")
        var variables = [
            "SRCROOT": root.path,
            "BUILD_DIR": root.appendingPathComponent("DerivedData/Build/Products").path,
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
            "HELIX_PROFILE_ID": "live",
            "HELIX_WORKFLOW": "liveReload",
            "HELIX_RUNTIME_PRODUCT": "HelixDevAppRuntime",
            "TARGET_NAME": "LiveDemo",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.helix.live-demo",
            "MARKETING_VERSION": "1.0",
            "TARGET_BUILD_DIR": root.appendingPathComponent(
                "DerivedData/Build/Products/Debug-iphonesimulator"
            ).path,
            "WRAPPER_NAME": "LiveDemo.app",
            "EXECUTABLE_PATH": "LiveDemo.app/LiveDemo",
            "HELIX_ACTIVITY_LOG_DIR": root.appendingPathComponent(
                "DerivedData/Logs/Build"
            ).path,
        ]
        let context = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: "live",
            variables: variables
        )
        #expect(context.environment.targetTriple == "arm64-apple-ios15.0-simulator")
        #expect(context.environment.compilerURL == compiler)
        #expect(context.environment.semanticArguments.contains("-swift-version"))
        #expect(context.environment.semanticArguments.contains("6"))
        #expect(context.environment.semanticArguments.contains("HELIX_DEMO"))
        #expect(context.environment.deviceHost == nil)
        #expect(
            context.environment.profileOutputURL.path
                == root.appendingPathComponent(
                    "DerivedData/Build/Products/HelixGenerated/live"
                ).path
        )
        let product = try XcodeIntegration.EnvironmentResolver().resolveProduct(
            context: context,
            variables: variables
        )
        #expect(product.applicationBundleURL.lastPathComponent == "LiveDemo.app")
        #expect(product.executableURL.lastPathComponent == "LiveDemo")
        #expect(product.activityLogDirectoryURL.lastPathComponent == "Build")

        var deviceVariables = variables
        deviceVariables["PLATFORM_NAME"] = "iphoneos"
        deviceVariables["SDKROOT"] = root.appendingPathComponent(
            "iPhoneOS.sdk"
        ).path
        deviceVariables["HELIX_DEVICE_HOST"] = "192.0.2.42"
        let deviceContext = try XcodeIntegration.EnvironmentResolver().resolve(
            plan: plan,
            planURL: planURL,
            profileID: "live",
            variables: deviceVariables
        )
        #expect(deviceContext.environment.targetTriple == "arm64-apple-ios15.0")
        #expect(deviceContext.environment.deviceHost == "192.0.2.42")

        var invalidDeviceHostVariables = deviceVariables
        invalidDeviceHostVariables["HELIX_DEVICE_HOST"] = "https://192.0.2.42"
        #expect(throws: XcodeIntegration.EnvironmentError.invalid(
            name: "HELIX_DEVICE_HOST",
            value: "https://192.0.2.42"
        )) {
            try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: "live",
                variables: invalidDeviceHostVariables
            )
        }

        var simulatorHostVariables = variables
        simulatorHostVariables["HELIX_DEVICE_HOST"] = "192.0.2.42"
        #expect(throws: XcodeIntegration.EnvironmentError.invalid(
            name: "HELIX_DEVICE_HOST",
            value: "192.0.2.42"
        )) {
            try XcodeIntegration.EnvironmentResolver().resolve(
                plan: plan,
                planURL: planURL,
                profileID: "live",
                variables: simulatorHostVariables
            )
        }

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
        #expect(
            generatedContext.sourceRootURL.standardizedFileURL.path
                == root.appendingPathComponent("LiveFeature").standardizedFileURL.path
        )

        variables["HELIX_RUNTIME_PRODUCT"] = "HelixAppRuntime"
        #expect(throws: XcodeIntegration.EnvironmentError.mismatch(
            name: "HELIX_RUNTIME_PRODUCT",
            expected: "HelixDevAppRuntime",
            actual: "HelixAppRuntime"
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
            planURL: root.appendingPathComponent("HelixXcode.json"),
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
                    moduleName: "PatchFeature",
                    sourceRoot: "PatchFeature",
                    patchConfigurationPath: "Configurations/Patch.yml",
                    sourceFiles: ["Sources/Feature.swift"]
                ),
                .init(
                    id: "live-feature",
                    moduleName: "LiveFeature",
                    sourceRoot: "LiveFeature",
                    patchConfigurationPath: "Configurations/Live.yml",
                    sourceFiles: ["Sources/Live Feature.swift"]
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
