#if os(macOS)
import Foundation
@testable import HelixHubCore
import Testing

@Suite("Helix Hub tool discovery")
struct ToolLocatorTests {
    @Test("App helper wins over the sibling source-build product")
    func appHelperWins() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Helix.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/helix")
        let sibling = root.appendingPathComponent("Build/helix")
        try executable(at: helper)
        try executable(at: sibling)

        let result = try Hub.ToolLocator().locate(
            bundleURL: app,
            processExecutableURL: root.appendingPathComponent(
                "Build/helix-hub-app"
            )
        )
        #expect(result == helper.standardizedFileURL)
    }

    @Test("SwiftPM frontend resolves its sibling CLI")
    func sourceBuildSibling() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Build/helix")
        try self.executable(at: executable)

        let result = try Hub.ToolLocator().locate(
            bundleURL: root,
            processExecutableURL: root.appendingPathComponent(
                "Build/helix-hub-app"
            )
        )
        #expect(result == executable.standardizedFileURL)
    }

    @Test("Missing build tool fails before service publication")
    func missing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-missing-tool-\(UUID().uuidString)",
            isDirectory: true
        )
        #expect(throws: Hub.Error.self) {
            _ = try Hub.ToolLocator().locate(
                bundleURL: root,
                processExecutableURL: root.appendingPathComponent("Helix")
            )
        }
    }

    @Test("Symbolic-link tools are not published through the service record")
    func symbolicLinkIsRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real-tool")
        let link = root.appendingPathComponent("Build/helix")
        try executable(at: target)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(throws: Hub.Error.self) {
            _ = try Hub.ToolLocator().locate(
                bundleURL: root,
                processExecutableURL: root.appendingPathComponent(
                    "Build/helix-hub-app"
                )
            )
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-tool-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func executable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
#endif
