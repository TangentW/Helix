#if os(macOS)
import Foundation
@testable import HelixHubCore
import Testing

@Suite("Helix Hub project registry", .serialized)
struct ProjectStoreTests {
    @Test("Registry is canonical, owner-only, ordered, and replaceable")
    func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-store-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/HubProjects.json")
        let store = try Hub.ProjectStore(url: url)
        #expect(await store.records().isEmpty)

        let older = try await store.register(
            installation: installation(root: root, name: "Older", capability: .liveReload),
            configuredAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = try await store.register(
            installation: installation(root: root, name: "Newer", capability: .hotPatch),
            configuredAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(await store.records().map(\.id) == [newer.id, older.id])
        #expect(permissions(url) == 0o600)
        #expect(permissions(url.deletingLastPathComponent()) == 0o700)

        let reopened = try Hub.ProjectStore(url: url)
        #expect(await reopened.records().map(\.id) == [newer.id, older.id])
        _ = try await reopened.register(
            installation: installation(root: root, name: "Older", capability: .hotPatch),
            configuredAt: Date(timeIntervalSince1970: 3_000)
        )
        let replaced = await reopened.records()
        #expect(replaced.count == 2)
        #expect(replaced[0].name == "Older")
        #expect(replaced[0].capabilities == [.hotPatch])

        try await reopened.remove(id: newer.id)
        #expect(await reopened.records().count == 1)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
        #expect(throws: Hub.Error.self) {
            _ = try Hub.ProjectStore(url: url)
        }
    }

    private func installation(
        root: URL,
        name: String,
        capability: Hub.Capability
    ) -> Hub.InstallationResult {
        let project = root.appendingPathComponent("\(name).xcodeproj")
        return .init(
            projectURL: project,
            hostPlanURL: root.appendingPathComponent(".helix/\(name)/HostPlan.json"),
            capabilities: [capability],
            requirements: [.init(
                code: "REQ-\(name)",
                severity: .information,
                summary: "Example requirement",
                detail: "Example detail"
            )],
            featureTargetNames: ["feature": "Feature"],
            developmentIdentityProfiles: capability == .hotPatch ? ["hot-patch"] : [],
            writtenRelativePaths: []
        )
    }

    private func permissions(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
#endif
