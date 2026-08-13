import Foundation
@testable import HelixHubCore
import HelixDevTools
import Testing

@Suite("Helix Hub project discovery")
struct ProjectParserTests {
    @Test("Checked-in Demo project exposes targets, sources, products, and schemes")
    func parsesDemo() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try Hub.ProjectFileParser().parse(
            projectURL: repository.appendingPathComponent("Demo/HelixDemo.xcodeproj")
        )
        #expect(project.name == "HelixDemo")
        #expect(project.configurations == ["Debug", "Release"])
        #expect(project.sharedSchemes.map(\.name).contains("Helix Live Reload Demo"))

        let liveFeature = try #require(project.target(named: "LiveReloadFeature"))
        #expect(liveFeature.kind == .framework)
        #expect(liveFeature.sourceFiles == [
            "LiveReloadFeature/Sources/LiveReloadFeature.Screen.swift",
        ])
        #expect(
            liveFeature.baseConfigurationPaths["Debug"]
                == ".helix/xcode/Profiles/live/Feature.xcconfig"
        )

        let liveApp = try #require(project.target(named: "LiveReloadDemo"))
        #expect(liveApp.kind == .application)
        #expect(liveApp.buildableName == "LiveReloadDemo.app")
        #expect(liveApp.packageProducts == ["HelixDevAppRuntime"])
    }

    @Test("Capability selection is canonical and nonempty")
    func capabilitySelection() throws {
        let selection = try Hub.CapabilitySelection([
            .liveReload, .hotPatch, .liveReload,
        ])
        #expect(selection.values == [.hotPatch, .liveReload])
        #expect(selection.contains(.hotPatch))
        #expect(throws: Hub.Error.noCapabilitiesSelected) {
            _ = try Hub.CapabilitySelection([])
        }
    }

    @Test("Malformed OpenStep projects fail with a focused error")
    func malformedProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("Broken.xcodeproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{ objects = { duplicate = one; duplicate = two; }; }".utf8).write(
            to: project.appendingPathComponent("project.pbxproj")
        )
        #expect(throws: Hub.Error.self) {
            _ = try Hub.ProjectFileParser().parse(projectURL: project)
        }
    }

    @Test("Workspace selection resolves only concrete project references")
    func locatesWorkspaceProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-workspace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Fixture.xcworkspace", isDirectory: true)
        let project = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let workspaceXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0">
          <FileRef location="group:App.xcodeproj"></FileRef>
          <FileRef location="group:Dependencies/Package.xcodeproj"></FileRef>
        </Workspace>
        """
        try Data(workspaceXML.utf8).write(
            to: workspace.appendingPathComponent("contents.xcworkspacedata")
        )
        let candidates = try Hub.ProjectLocator().locate(from: workspace)
        #expect(candidates.count == 1)
        #expect(candidates[0].projectURL == project.standardizedFileURL)
        #expect(candidates[0].workspaceURL == workspace.standardizedFileURL)
    }

    @Test("Resolved Xcode settings preserve xcconfig-derived identity")
    func resolvesTargetSettings() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try Hub.ProjectFileParser().parse(
            projectURL: repository.appendingPathComponent("Demo/HelixDemo.xcodeproj")
        )
        let payload = """
        [{"target":"LiveReloadDemo","buildSettings":{
          "PRODUCT_MODULE_NAME":"LiveReloadDemo",
          "PRODUCT_BUNDLE_IDENTIFIER":"dev.example.live",
          "PRODUCT_NAME":"Example Live",
          "SRCROOT":"\(project.sourceRootURL.path)",
          "SWIFT_VERSION":"6.0"
        }}]
        """
        let inspector = Hub.ProjectInspector(
            runner: FixedRunner(result: .init(
                status: 0,
                standardOutput: payload,
                standardError: ""
            ))
        )
        let settings = try inspector.settings(
            project: project,
            targetName: "LiveReloadDemo",
            configurationName: "Debug"
        )
        #expect(settings.moduleName == "LiveReloadDemo")
        #expect(settings.bundleIdentifier == "dev.example.live")
        #expect(settings.productName == "Example Live")
        #expect(settings.swiftVersion == "6.0")
    }
}

private struct FixedRunner: ProcessExecution.Running {
    var result: ProcessExecution.Result

    func run(
        executable _: URL,
        arguments _: [String],
        environment _: [String: String],
        workingDirectory _: URL?
    ) throws -> ProcessExecution.Result {
        result
    }
}
