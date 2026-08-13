#if os(macOS)
import Foundation
@testable import HelixHubApp
import HelixHubCore
import Testing

@Suite("Helix Hub application editor")
struct HubApplicationEditorTests {
    @Test("A new project selects both workflows using matching targets")
    func recommendsBothCapabilities() throws {
        let editor = HubApplication.Editor(project: project())

        #expect(editor.selectedForms.map(\.capability) == [.hotPatch, .liveReload])
        #expect(editor.forms[0].applicationTargetName == "PatchApp")
        #expect(editor.forms[0].featureTargetName == "PatchFeature")
        #expect(editor.forms[0].schemeName == "Patch Scheme")
        #expect(editor.forms[1].applicationTargetName == "ReloadApp")
        #expect(editor.forms[1].featureTargetName == "ReloadFeature")
        #expect(editor.forms[1].schemeName == "Reload Scheme")
        #expect(editor.canInstall)
        #expect(try editor.selections().count == 2)
        #expect(!editor.hasInstalledCapabilities)
    }

    @Test("One App target keeps both defaults visible but explains isolation")
    func reportsSharedApplicationTarget() {
        var value = project()
        value.targets.removeAll { $0.name == "ReloadApp" }
        let editor = HubApplication.Editor(project: value)

        #expect(editor.selectedForms.count == 2)
        #expect(!editor.canInstall)
        #expect(editor.validationMessages.contains {
            $0.contains("distinct App targets")
        })
    }

    @Test("Installed workflows stay enabled and a skipped workflow can be added")
    func preservesInstalledCapability() throws {
        let value = project()
        let live = Hub.ProfileDraft(
            id: "live-reload",
            capability: .liveReload,
            applicationTargetName: "ReloadApp",
            featureTargetName: "ReloadFeature",
            featureModuleName: "ReloadFeature",
            schemeName: "Reload Scheme",
            configurationName: "Debug",
            bundleIdentifier: "dev.example.reload",
            namespaceSeed: "example-live"
        )
        let draft = Hub.OnboardingDraft(
            project: value,
            capabilities: try .init([.liveReload]),
            profiles: [live]
        )
        var editor = HubApplication.Editor(
            project: value,
            draft: draft,
            requirements: []
        )

        #expect(editor.forms.first { $0.capability == .liveReload }?.isInstalled == true)
        #expect(editor.hasInstalledCapabilities)
        #expect(editor.forms.first { $0.capability == .hotPatch }?.isEnabled == false)
        editor.setEnabled(false, capability: .liveReload)
        #expect(editor.forms.first { $0.capability == .liveReload }?.isEnabled == true)
        editor.setEnabled(true, capability: .hotPatch)
        #expect(editor.canInstall)
    }

    private func project() -> Hub.XcodeProject {
        let root = URL(fileURLWithPath: "/tmp/helix-hub-app-tests")
        return .init(
            projectURL: root.appendingPathComponent("Example.xcodeproj"),
            sourceRootURL: root,
            name: "Example",
            objectVersion: "77",
            configurations: ["Debug", "Release"],
            targets: [
                target("PatchApp", kind: .application, products: ["HelixAppRuntime"]),
                target("ReloadApp", kind: .application, products: ["HelixDevAppRuntime"]),
                target("PatchFeature", kind: .framework, sources: ["Patch/Feature.swift"]),
                target("ReloadFeature", kind: .framework, sources: ["Reload/Feature.swift"]),
            ],
            sharedSchemes: [
                .init(name: "Patch Scheme", url: root.appendingPathComponent("Patch.xcscheme")),
                .init(name: "Reload Scheme", url: root.appendingPathComponent("Reload.xcscheme")),
            ]
        )
    }

    private func target(
        _ name: String,
        kind: Hub.XcodeTarget.Kind,
        products: [String] = [],
        sources: [String] = []
    ) -> Hub.XcodeTarget {
        .init(
            id: name,
            name: name,
            productName: name,
            buildableName: kind == .application ? "\(name).app" : "\(name).framework",
            productType: nil,
            kind: kind,
            configurationNames: ["Debug", "Release"],
            sourceFiles: sources,
            packageProducts: products,
            baseConfigurationPaths: [:]
        )
    }
}
#endif
