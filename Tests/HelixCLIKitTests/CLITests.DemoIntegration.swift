import Foundation
import HelixBuildTools
import Testing

extension CLITests {
@Suite("Checked-in UIKit Demo integration")
struct DemoIntegration {
    @Test("Host Plan and generated Integration Kit are canonical and in sync")
    func generatedKitMatchesHostPlan() throws {
        let root = repositoryRoot()
        let demo = root.appendingPathComponent("Demo", isDirectory: true)
        let planURL = demo.appendingPathComponent(".helix/xcode/HostPlan.json")
        let planBytes = try Data(contentsOf: planURL)
        let plan = try XcodeIntegration.HostPlanCodec.decode(planBytes)
        try plan.validate()

        #expect(try XcodeIntegration.HostPlanCodec.encode(plan) == planBytes)
        #expect(plan.schemaVersion == 1)
        #expect(plan.features.map(\.moduleName) == [
            "HotPatchFeature", "LiveReloadFeature",
        ])
        #expect(plan.features.map(\.targetName) == [
            "HotPatchFeature", "LiveReloadFeature",
        ])
        #expect(plan.profiles.map(\.workflow) == [.hotPatch, .liveReload])
        #expect(plan.profiles.map(\.runtimePackageProduct) == [
            "HelixAppIntegration", "HelixAppIntegration",
        ])
        let patchProfile = try #require(
            plan.profiles.first(where: { $0.workflow == .hotPatch })
        )
        #expect(
            patchProfile.patch?.recipePath
                == "Configurations/Helix/QuickPatchRecipe.json"
        )

        let recipeURL = demo.appendingPathComponent(
            "Configurations/Helix/QuickPatchRecipe.json"
        )
        #expect(FileManager.default.fileExists(atPath: recipeURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: demo.appendingPathComponent(
                "Configurations/QuickPatchRecipe.json"
            ).path
        ))

        let generated = try XcodeIntegration.KitGenerator().generate(plan: plan)
        let integrationRoot = demo.appendingPathComponent(
            plan.integrationRoot,
            isDirectory: true
        )
        for (path, expected) in generated.artifacts {
            let actual = try Data(
                contentsOf: integrationRoot.appendingPathComponent(path)
            )
            #expect(actual == expected, "Generated integration drifted at \(path)")
        }
        #expect(
            try Data(contentsOf: integrationRoot.appendingPathComponent("HostPlan.json"))
                == planBytes
        )
    }

    @Test("Xcode project keeps Release and Dev runtime graphs isolated")
    func projectGraphIsWorkflowSeparated() throws {
        let root = repositoryRoot()
        let demo = root.appendingPathComponent("Demo", isDirectory: true)
        let project = try text(
            demo.appendingPathComponent("HelixDemo.xcodeproj/project.pbxproj")
        )
        let package = try text(root.appendingPathComponent("Package.swift"))

        #expect(project.occurrences(of: "isa = PBXNativeTarget;") == 4)
        #expect(project.occurrences(of: "isa = PBXAggregateTarget;") == 1)
        #expect(project.contains("name = HelixPatchAction;"))
        #expect(project.contains("alwaysOutOfDate = 1;"))
        #expect(!project.contains("SUPPORTED_PLATFORMS = iphonesimulator;"))
        #expect(project.contains("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;"))
        #expect(project.contains("LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\";"))

        let hotApp = try #require(project.line(containing: "name = HotPatchDemo;"))
        let liveApp = try #require(project.line(containing: "name = LiveReloadDemo;"))
        #expect(hotApp.contains("710000000000000000000001"))
        #expect(!hotApp.contains("F2B7C2DBD1F7AE5303E0E685"))
        #expect(liveApp.contains("710000000000000000000002"))
        #expect(liveApp.contains("F2B7C2DBD1F7AE5303E0E685"))
        #expect(project.occurrences(of: "productName = HelixAppIntegration;") == 2)
        #expect(project.occurrences(of: "productName = HelixDevSupport;") == 1)
        #expect(!project.contains("HelixDevSupport in Frameworks"))

        #expect(package.occurrences(of: "name: \"HelixAppIntegration\"") == 2)
        #expect(package.occurrences(of: "name: \"HelixDevSupport\"") == 2)
        #expect(package.contains("name: \"HelixDevSupport\",\n            type: .dynamic"))
        #expect(!package.contains(
            ".library(name: \"HelixLiveReloadAPI\""
        ))

        #expect(project.contains("HotPatchFeature/Sources/HotPatchFeature.Pricing.swift"))
        #expect(project.contains("LiveReloadFeature/Sources/LiveReloadFeature.Screen.swift"))
        #expect(project.contains(
            ".helix/xcode/ProjectConfigurations/hot-Application-Release.xcconfig"
        ))
        #expect(project.contains(
            ".helix/xcode/ProjectConfigurations/live-Application-Debug.xcconfig"
        ))
        let configurations = demo.appendingPathComponent(
            ".helix/xcode/ProjectConfigurations",
            isDirectory: true
        )
        let expectedIncludes = [
            "hot-Application-Release.xcconfig": "../Profiles/hot/Application.xcconfig",
            "hot-Feature-Release.xcconfig": "../Profiles/hot/Feature.xcconfig",
            "live-Application-Debug.xcconfig": "../Profiles/live/Application.xcconfig",
            "live-Feature-Debug.xcconfig": "../Profiles/live/Feature.xcconfig",
        ]
        for (name, include) in expectedIncludes {
            let wrapper = try text(configurations.appendingPathComponent(name))
            #expect(wrapper.contains(
                "// Generated by Helix Hub. Do not edit."
            ))
            #expect(wrapper.contains("// HELIX_ORIGINAL_BASE_REFERENCE: none"))
            #expect(wrapper.contains("// HELIX_ORIGINAL_BASE_PATH: none"))
            #expect(wrapper.contains("#include \"\(include)\""))
        }
        #expect(project.occurrences(
            of: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";"
        ) == 10)
        #expect(project.occurrences(
            of: "\"CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]\" = NO;"
        ) == 4)
        #expect(project.occurrences(of: "CODE_SIGN_STYLE = Automatic;") == 4)
        #expect(!project.contains("HELIX_DEVICE_NATIVE_QUALIFIED"))
        #expect(project.occurrences(of: "INFOPLIST_FILE = LiveReloadDemo/Info.plist;") == 2)
        #expect(project.occurrences(of: "Helix Bridge (Generated)") == 2)
        #expect(project.occurrences(of: "Helix Prepare (Generated)") == 2)
        #expect(project.contains(
            ".helix/xcode/Profiles/live/prepare.sh"
        ))
        #expect(project.contains("$(BUILT_PRODUCTS_DIR)/HelixGenerated/"))
        #expect(!project.contains("DerivedSources"))
        #expect(!project.contains("HelixBridge.framework"))
        #expect(!project.contains("HelixBridge.swift"))
        #expect(project.contains("HotPatchFeature.framework in Embed Frameworks"))
        #expect(project.contains("LiveReloadFeature.framework in Embed Frameworks"))
        #expect(project.contains("name = \"Embed Helix Runtime Resources (Generated)\";"))
        #expect(project.contains("name = \"Embed Helix Development Support (Generated)\";"))
        #expect(project.contains(
            "name = \"Configure Helix Development Info.plist (Generated)\";"
        ))
        #expect(project.contains("$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"))
        #expect(project.contains("NSBonjourServices"))
        #expect(!project.contains("Build Helix Patch (Generated)"))
    }

    @Test("Shared schemes keep ordinary work inside Xcode")
    func schemesOwnTheCompleteWorkflow() throws {
        let schemes = repositoryRoot()
            .appendingPathComponent("Demo/HelixDemo.xcodeproj/xcshareddata/xcschemes")
        let hot = try text(schemes.appendingPathComponent("Helix Hot Patch Demo.xcscheme"))
        let live = try text(schemes.appendingPathComponent("Helix Live Reload Demo.xcscheme"))
        let patch = try text(schemes.appendingPathComponent("Helix Build Patch.xcscheme"))
        let dispatcher = try text(
            repositoryRoot().appendingPathComponent(
                "Demo/.helix/xcode/Scripts/helix-phase.sh"
            )
        )

        #expect(hot.contains("buildConfiguration=\"Release\""))
        #expect(hot.occurrences(of: "Prepare Helix Demo Prerequisites") == 1)
        #expect(!hot.contains("Helix Hub: Prepare"))
        #expect(hot.occurrences(of: "Helix Hub: Audit hot") == 1)
        #expect(!hot.contains("Profiles/hot/prepare.sh"))
        #expect(hot.occurrences(of: "Profiles/hot/audit.sh") == 1)
        #expect(hot.contains("BlueprintName=\"HotPatchDemo\""))
        #expect(!hot.contains("HelixBridge"))

        #expect(live.contains("buildConfiguration=\"Debug\""))
        #expect(live.occurrences(of: "Prepare Helix Demo Prerequisites") == 1)
        #expect(!live.contains("Helix Hub: Prepare"))
        #expect(live.occurrences(of: "Helix Hub: Register live") == 1)
        #expect(!live.contains("Profiles/live/prepare.sh"))
        #expect(live.occurrences(of: "Profiles/live/live-register.sh") == 1)
        #expect(!live.contains("live-start.sh"))
        #expect(!live.contains("live-stop.sh"))
        #expect(!live.contains("customLLDBInitFile"))
        #expect(live.contains("BlueprintName=\"LiveReloadDemo\""))
        #expect(!live.contains("HelixBridge"))

        #expect(patch.occurrences(of: "BuildActionEntry") == 2)
        #expect(patch.contains("BlueprintName=\"HelixPatchAction\""))
        #expect(patch.occurrences(of: "Helix Hub: Build hot patch") == 1)
        #expect(patch.occurrences(of: "Profiles/hot/patch.sh") == 1)
        #expect(patch.occurrences(of: "BlueprintName=\"HotPatchDemo\"") == 1)
        #expect(patch.contains("HotPatchDemo.app"))
        #expect(!patch.contains("LiveReloadDemo.app"))
        #expect(dispatcher.contains("plutil -extract toolExecutablePath raw"))
        #expect(dispatcher.contains("clean|analyze|installhdrs|installsrc"))
    }

    @Test("Demo fixtures stay at their audited baselines and secrets stay local")
    func fixturesAndSecretBoundary() throws {
        let root = repositoryRoot()
        let hot = try text(
            root.appendingPathComponent(
                "Demo/HotPatchFeature/Sources/HotPatchFeature.Pricing.swift"
            )
        )
        let live = try text(
            root.appendingPathComponent(
                "Demo/LiveReloadFeature/Sources/LiveReloadFeature.Screen.swift"
            )
        )
        let configurationRoot = root.appendingPathComponent(
            "Demo/Configurations/Helix",
            isDirectory: true
        )
        let bootstrap = try text(
            root.appendingPathComponent("Demo/Scripts/DemoBootstrap.sh")
        )
        let liveInfoData = try Data(
            contentsOf: root.appendingPathComponent("Demo/LiveReloadDemo/Info.plist")
        )
        let liveInfo = try #require(
            try PropertyListSerialization.propertyList(from: liveInfoData, format: nil)
                as? [String: Any]
        )
        let generatedInfoURL = root.appendingPathComponent(
            "Demo/.helix/xcode/ProjectConfigurations/live-Application-Info.plist"
        )
        let ignore = try text(root.appendingPathComponent(".gitignore"))

        #expect(hot.occurrences(of: "HELIX_DEMO_BUG") == 1)
        #expect(hot.contains("return 1_999 // HELIX_DEMO_BUG"))
        #expect(live.occurrences(of: "HELIX_LIVE_BASELINE") == 1)
        #expect(live.contains("// HELIX_LIVE_BASELINE"))
        #expect(!FileManager.default.fileExists(
            atPath: configurationRoot.appendingPathComponent(
                "livereloadfeature.yml"
            ).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: configurationRoot.appendingPathComponent(
                "hotpatchfeature.yml"
            ).path
        ))
        #expect(liveInfo["NSBonjourServices"] == nil)
        #expect(liveInfo["NSLocalNetworkUsageDescription"] == nil)
        #expect(!FileManager.default.fileExists(atPath: generatedInfoURL.path))
        #expect(ignore.contains("Demo/.helix/private/"))
        #expect(ignore.contains("Demo/.helix/patches/"))

        let localRootCreation = try #require(
            bootstrap.range(of: "mkdir -p \"$demo_root/.helix\"")
        )
        let identityCreation = try #require(
            bootstrap.range(of: "patch create-development-identity")
        )
        #expect(localRootCreation.lowerBound < identityCreation.lowerBound)
        #expect(!bootstrap.contains("SESSION_SECRET="))
    }
}
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func line(containing needle: String) -> Substring? {
        split(separator: "\n", omittingEmptySubsequences: false).first {
            $0.contains(needle)
        }
    }
}
