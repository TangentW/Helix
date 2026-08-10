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
        let planURL = demo.appendingPathComponent("HelixXcode.json")
        let planBytes = try Data(contentsOf: planURL)
        let plan = try XcodeIntegration.HostPlanCodec.decode(planBytes)
        try plan.validate()

        #expect(try XcodeIntegration.HostPlanCodec.encode(plan) == planBytes)
        #expect(plan.schemaVersion == 2)
        #expect(plan.features.map(\.moduleName) == [
            "HotPatchFeature", "LiveReloadFeature",
        ])
        #expect(plan.profiles.map(\.workflow) == [.hotPatch, .liveReload])
        #expect(plan.profiles.map(\.runtimePackageProduct) == [
            "HelixAppRuntime", "HelixDevAppRuntime",
        ])

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
        let demo = repositoryRoot().appendingPathComponent("Demo", isDirectory: true)
        let project = try text(
            demo.appendingPathComponent("HelixDemo.xcodeproj/project.pbxproj")
        )

        #expect(project.occurrences(of: "isa = PBXNativeTarget;") == 6)
        #expect(project.occurrences(of: "isa = PBXAggregateTarget;") == 1)
        #expect(project.contains("name = HelixPatchAction;"))
        #expect(project.contains("alwaysOutOfDate = 1;"))
        #expect(project.contains("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;"))
        #expect(project.contains("LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\";"))

        let hotApp = try #require(project.line(containing: "/* HotPatchDemo */ = {isa = PBXNativeTarget"))
        let liveApp = try #require(project.line(containing: "/* LiveReloadDemo */ = {isa = PBXNativeTarget"))
        let hotBridge = try #require(
            project.line(containing: "/* HotPatchFeatureHelixBridge */ = {isa = PBXNativeTarget")
        )
        let liveBridge = try #require(
            project.line(containing: "/* LiveReloadFeatureHelixBridge */ = {isa = PBXNativeTarget")
        )
        #expect(hotApp.contains("710000000000000000000001 /* HelixAppRuntime */"))
        #expect(hotBridge.contains("710000000000000000000001 /* HelixAppRuntime */"))
        #expect(!hotApp.contains("HelixDevAppRuntime"))
        #expect(!hotBridge.contains("HelixDevAppRuntime"))
        #expect(liveApp.contains("710000000000000000000002 /* HelixDevAppRuntime */"))
        #expect(liveBridge.contains("710000000000000000000002 /* HelixDevAppRuntime */"))
        #expect(!liveApp.contains("HelixAppRuntime */"))
        #expect(!liveBridge.contains("HelixAppRuntime */"))

        #expect(project.contains(
            "../HelixGenerated/hot/Shell/DerivedSources/Sources/"
                + "HelixGenerated.HotPatchFeature.Pricing.swift"
        ))
        #expect(project.contains(
            "../HelixGenerated/live/Shell/DerivedSources/Sources/"
                + "HelixGenerated.LiveReloadFeature.Screen.swift"
        ))
        #expect(project.contains("HotPatchFeature.framework in Embed Frameworks"))
        #expect(project.contains("HotPatchFeatureHelixBridge.framework in Embed Frameworks"))
        #expect(project.contains("LiveReloadFeature.framework in Embed Frameworks"))
        #expect(project.contains("LiveReloadFeatureHelixBridge.framework in Embed Frameworks"))
        #expect(project.contains("name = \"Embed Demo Trust Root\";"))
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

        #expect(hot.contains("buildConfiguration = \"Release\""))
        #expect(hot.occurrences(of: "Profiles/hot/prepare.sh") == 1)
        #expect(hot.occurrences(of: "Profiles/hot/audit.sh") == 1)
        #expect(hot.contains("BlueprintName = \"HotPatchDemo\""))

        #expect(live.contains("buildConfiguration = \"Debug\""))
        #expect(live.occurrences(of: "Profiles/live/prepare.sh") == 1)
        #expect(live.occurrences(of: "Profiles/live/live-start.sh") == 1)
        #expect(live.occurrences(of: "Profiles/live/live-stop.sh") == 1)
        #expect(live.contains("customLLDBInitFile = \"$(HELIX_LLDB_INIT_FILE)\""))
        #expect(live.contains("BlueprintName = \"LiveReloadDemo\""))

        #expect(patch.occurrences(of: "BuildActionEntry") == 2)
        #expect(patch.contains("BlueprintName = \"HelixPatchAction\""))
        #expect(!patch.contains("HotPatchDemo.app"))
        #expect(!patch.contains("LiveReloadDemo.app"))
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
        let bootstrap = try text(
            root.appendingPathComponent("Demo/Scripts/DemoBootstrap.sh")
        )
        let ignore = try text(root.appendingPathComponent(".gitignore"))

        #expect(hot.occurrences(of: "HELIX_DEMO_BUG") == 1)
        #expect(hot.contains("return 1_999 // HELIX_DEMO_BUG"))
        #expect(live.occurrences(of: "HELIX_LIVE_BASELINE") == 1)
        #expect(live.contains("\"SAVE TO RELOAD\" // HELIX_LIVE_BASELINE"))
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
