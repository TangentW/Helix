#if os(macOS)
import Foundation
@testable import HelixHubApp
import HelixHubCore
import Testing

@Suite("Helix Hub application editor")
struct HubApplicationEditorTests {
    @Test("A new project prefers each App as its zero-configuration source target")
    func recommendsBothCapabilities() throws {
        let editor = HubApplication.Editor(project: project())

        #expect(editor.selectedForms.map(\.capability) == [.hotPatch, .liveReload])
        #expect(editor.forms[0].applicationTargetName == "PatchApp")
        #expect(editor.forms[0].featureTargetName == "PatchApp")
        #expect(editor.forms[0].schemeName == "Patch Scheme")
        #expect(editor.forms[1].applicationTargetName == "ReloadApp")
        #expect(editor.forms[1].featureTargetName == "ReloadApp")
        #expect(editor.forms[1].schemeName == "Reload Scheme")
        #expect(editor.canInstall)
        #expect(try editor.selections().count == 2)
        #expect(!editor.hasInstalledCapabilities)
    }

    @Test("One App target supports both workflows without an isolation error")
    func supportsSharedApplicationTarget() {
        var value = project()
        value.targets.removeAll { $0.name == "ReloadApp" }
        let editor = HubApplication.Editor(project: value)

        #expect(editor.selectedForms.count == 2)
        #expect(editor.canInstall)
        #expect(editor.validationMessages.isEmpty)
    }

    @Test("An ordinary single-target App needs no target, scheme, or config choices")
    func recommendsOrdinaryApplication() {
        let root = URL(fileURLWithPath: "/tmp/helix-single-app-tests")
        let app = target(
            "ExampleApp",
            kind: .application
        )
        let value = Hub.XcodeProject(
            projectURL: root.appendingPathComponent("ExampleApp.xcodeproj"),
            sourceRootURL: root,
            name: "ExampleApp",
            objectVersion: "77",
            configurations: ["Debug", "Release"],
            targets: [app],
            sharedSchemes: [.init(
                name: "ExampleApp",
                url: root.appendingPathComponent("ExampleApp.xcscheme")
            )]
        )

        let editor = HubApplication.Editor(project: value)
        #expect(editor.forms.map(\.applicationTargetName)
            == ["ExampleApp", "ExampleApp"])
        #expect(editor.forms.map(\.featureTargetName)
            == ["ExampleApp", "ExampleApp"])
        #expect(editor.forms.map(\.schemeName) == ["ExampleApp", "ExampleApp"])
        #expect(editor.forms.first { $0.capability == .hotPatch }?.configurationName
            == "Release")
        #expect(editor.forms.first { $0.capability == .liveReload }?.configurationName
            == "Debug")
        #expect(editor.canInstall)
    }

    @Test("A single App receives an automatic shared scheme recommendation")
    func recommendsAutomaticScheme() {
        let root = URL(fileURLWithPath: "/tmp/helix-automatic-scheme-tests")
        let app = target(
            "ExampleApp",
            kind: .application
        )
        let value = Hub.XcodeProject(
            projectURL: root.appendingPathComponent("ExampleApp.xcodeproj"),
            sourceRootURL: root,
            name: "ExampleApp",
            objectVersion: "77",
            configurations: ["Debug", "Release"],
            targets: [app],
            sharedSchemes: []
        )

        let editor = HubApplication.Editor(project: value)
        #expect(editor.forms.map(\.schemeName) == ["ExampleApp", "ExampleApp"])
        #expect(editor.canInstall)
    }

    @Test("Configured workflows can be changed or removed from the active plan")
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
        #expect(editor.forms.first { $0.capability == .liveReload }?.isEnabled == false)
        #expect(editor.canInstall)
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
                target("PatchApp", kind: .application, products: ["HelixAppIntegration"]),
                target(
                    "ReloadApp",
                    kind: .application,
                    products: ["HelixAppIntegration", "HelixDevSupport"]
                ),
                target("PatchFeature", kind: .framework),
                target("ReloadFeature", kind: .framework),
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
        products: [String] = []
    ) -> Hub.XcodeTarget {
        .init(
            id: name,
            name: name,
            productName: name,
            buildableName: kind == .application ? "\(name).app" : "\(name).framework",
            productType: nil,
            kind: kind,
            configurationNames: ["Debug", "Release"],
            supportsSourceCompilation: true,
            packageProducts: products,
            baseConfigurationPaths: [:]
        )
    }
}
#endif
