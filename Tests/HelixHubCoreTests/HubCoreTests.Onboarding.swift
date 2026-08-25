import Foundation
@testable import HelixHubCore
import HelixCore
import HelixDevTools
import HelixReleaseTools
import Testing

@Suite("Helix Hub onboarding planning")
struct OnboardingPlannerTests {
    @Test("Both workflows produce one canonical host plan and public artifacts")
    func plansDemoWorkflows() throws {
        let project = try demoProject()
        let draft = Hub.OnboardingDraft(
            project: project,
            capabilities: try .init([.hotPatch, .liveReload]),
            profiles: [
                .init(
                    id: "hot",
                    capability: .hotPatch,
                    applicationTargetName: "HotPatchDemo",
                    featureTargetName: "HotPatchFeature",
                    featureModuleName: "HotPatchFeature",
                    schemeName: "Helix Hot Patch Demo",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.helix.demo.hotpatch",
                    namespaceSeed: "helix-demo-hot",
                    patch: .init()
                ),
                .init(
                    id: "live",
                    capability: .liveReload,
                    applicationTargetName: "LiveReloadDemo",
                    featureTargetName: "LiveReloadFeature",
                    featureModuleName: "LiveReloadFeature",
                    schemeName: "Helix Live Reload Demo",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.helix.demo.livereload",
                    namespaceSeed: "helix-demo-live"
                ),
            ]
        )

        let result = try Hub.OnboardingPlanner().plan(draft)
        #expect(result.hostPlan.profiles.map(\.id) == ["hot", "live"])
        #expect(result.hostPlan.features.map(\.id) == [
            "hotpatchfeature", "livereloadfeature",
        ])
        #expect(result.requirements.isEmpty)
        #expect(result.developmentIdentityProfiles == ["hot"])
        #expect(result.artifacts.keys.sorted() == [
            "Configurations/Helix/QuickPatchRecipe.json",
        ])

        let recipeData = try #require(
            result.artifacts["Configurations/Helix/QuickPatchRecipe.json"]
        )
        let recipe = try JSONDecoder().decode(
            ReleasePipeline.QuickPatchRecipe.self,
            from: recipeData
        )
        try recipe.validate()
        #expect(recipe.packageID == "HLX-HOT-001")
        #expect(recipe.maximumTestedOSVersion == Core.SemanticVersion(99))
        let canonicalRecipe = try Core.CanonicalJSON.encode(recipe)
        #expect(recipeData == canonicalRecipe)
    }

    @Test("Missing runtime product is an explicit code-level action")
    func reportsRuntimeRequirement() throws {
        var project = try demoProject()
        let index = try #require(project.targets.firstIndex { $0.name == "LiveReloadDemo" })
        project.targets[index].packageProducts = []
        let draft = Hub.OnboardingDraft(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [liveProfile()]
        )

        let result = try Hub.OnboardingPlanner().plan(draft)
        #expect(result.requirements.count == 1)
        #expect(result.requirements[0].severity == .actionRequired)
        #expect(result.requirements[0].summary.contains("HelixDevAppRuntime"))
    }

    @Test("Release and development workflows cannot share one App image")
    func rejectsSharedAppTarget() throws {
        let project = try demoProject()
        var hot = liveProfile(capability: .hotPatch)
        hot.id = "hot"
        hot.schemeName = "Hot Patch"
        hot.patch = .init()
        let draft = Hub.OnboardingDraft(
            project: project,
            capabilities: try .init([.hotPatch, .liveReload]),
            profiles: [hot, liveProfile()]
        )
        #expect(throws: Hub.Error.self) {
            _ = try Hub.OnboardingPlanner().plan(draft)
        }
    }

    @Test("Root-level Swift files remain valid feature inputs")
    func supportsRootLevelSources() throws {
        let app = target(
            id: "APP",
            name: "ExampleApp",
            kind: .application,
            products: ["HelixDevAppRuntime"]
        )
        var feature = target(id: "FEATURE", name: "Feature", kind: .framework)
        feature.sourceFiles = ["First.swift", "Second.swift"]
        let root = URL(fileURLWithPath: "/tmp/helix-hub-root")
        let project = Hub.XcodeProject(
            projectURL: root.appendingPathComponent("Example.xcodeproj"),
            sourceRootURL: root,
            name: "Example",
            objectVersion: "77",
            configurations: ["Debug"],
            targets: [app, feature],
            sharedSchemes: [.init(
                name: "Example Live",
                url: root.appendingPathComponent("Example Live.xcscheme")
            )]
        )
        let draft = Hub.OnboardingDraft(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "ExampleApp",
                featureTargetName: "Feature",
                featureModuleName: "Feature",
                schemeName: "Example Live",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.app",
                namespaceSeed: "example-live"
            )]
        )

        let plan = try Hub.OnboardingPlanner().plan(draft).hostPlan
        #expect(plan.features[0].sourceRoot == ".")
        #expect(plan.features[0].sourceFiles == ["First.swift", "Second.swift"])
        try plan.validate()
    }

    @Test("GUI selections resolve through exact Xcode build settings")
    func resolvesGUISelections() throws {
        let project = try demoProject()
        let resolver = Hub.DraftResolver(
            inspector: .init(runner: SettingsRunner())
        )
        let draft = try resolver.resolve(
            project: project,
            selections: [
                .init(
                    capability: .hotPatch,
                    applicationTargetName: "HotPatchDemo",
                    featureTargetName: "HotPatchFeature",
                    schemeName: "Helix Hot Patch Demo",
                    configurationName: "Debug"
                ),
                .init(
                    capability: .liveReload,
                    applicationTargetName: "LiveReloadDemo",
                    featureTargetName: "LiveReloadFeature",
                    schemeName: "Helix Live Reload Demo",
                    configurationName: "Debug"
                ),
            ]
        )

        #expect(draft.capabilities.values == [.hotPatch, .liveReload])
        #expect(draft.profiles.map(\.id) == ["hot-patch", "live-reload"])
        #expect(draft.profiles[0].bundleIdentifier == "dev.example.HotPatchDemo")
        #expect(draft.profiles[1].featureModuleName == "LiveReloadFeatureResolved")
        let plan = try Hub.OnboardingPlanner().plan(draft)
        #expect(plan.featureTargetNames["hotpatchfeature"] == "HotPatchFeature")
        #expect(plan.developmentIdentityProfiles == ["hot-patch"])
    }

    private func demoProject() throws -> Hub.XcodeProject {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Hub.ProjectFileParser().parse(
            projectURL: repository.appendingPathComponent("Demo/HelixDemo.xcodeproj")
        )
    }

    private func liveProfile(
        capability: Hub.Capability = .liveReload
    ) -> Hub.ProfileDraft {
        .init(
            id: "live",
            capability: capability,
            applicationTargetName: "LiveReloadDemo",
            featureTargetName: "LiveReloadFeature",
            featureModuleName: "LiveReloadFeature",
            schemeName: "Helix Live Reload Demo",
            configurationName: "Debug",
            bundleIdentifier: "dev.helix.demo.livereload",
            namespaceSeed: "helix-demo-live"
        )
    }

    private func target(
        id: String,
        name: String,
        kind: Hub.XcodeTarget.Kind,
        products: [String] = []
    ) -> Hub.XcodeTarget {
        .init(
            id: id,
            name: name,
            productName: name,
            buildableName: kind == .application ? "\(name).app" : "\(name).framework",
            productType: nil,
            kind: kind,
            configurationNames: ["Debug"],
            sourceFiles: [],
            packageProducts: products,
            baseConfigurationPaths: [:]
        )
    }
}

private struct SettingsRunner: ProcessExecution.Running {
    func run(
        executable _: URL,
        arguments: [String],
        environment _: [String: String],
        workingDirectory _: URL?
    ) throws -> ProcessExecution.Result {
        guard let option = arguments.firstIndex(of: "-target"),
              arguments.indices.contains(option + 1)
        else {
            throw Hub.Error.projectInspectionFailed("missing target argument")
        }
        let target = arguments[option + 1]
        let settings: [String: String] = [
            "PRODUCT_MODULE_NAME": "\(target)Resolved",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.example.\(target)",
            "PRODUCT_NAME": target,
            "SRCROOT": "/tmp/helix-hub-resolver",
            "SWIFT_VERSION": "6.0",
        ]
        let data = try JSONSerialization.data(withJSONObject: [[
            "target": target,
            "buildSettings": settings,
        ]])
        return .init(
            status: 0,
            standardOutput: String(decoding: data, as: UTF8.self),
            standardError: ""
        )
    }
}
