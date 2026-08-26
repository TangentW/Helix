import Darwin
import Foundation
import HelixCore
import HelixDevProtocol
@testable import HelixDevTools
import Testing

extension DevToolsTests {
@Suite("Build Context registry")
struct ContextRegistry {
    @Test("Stable Shell identity is exact-build scoped and reproducible")
    func stableShellIdentity() throws {
        let first = try makeContext(index: 1, registeredAt: 100)
        let factory = DevSession.ShellIdentityFactory()
        let identity = try factory.make(
            workspacePathHash: first.workspacePathHash,
            build: first.shellIdentity.build
        )
        let duplicate = try factory.make(
            workspacePathHash: first.workspacePathHash,
            build: first.shellIdentity.build
        )
        #expect(identity == duplicate)
        #expect(identity.shellID.rawValue.uuidString.split(separator: "-")[2]
            .first == "5")

        let otherWorkspace = try factory.make(
            workspacePathHash: .sha256("another-workspace"),
            build: first.shellIdentity.build
        )
        #expect(otherWorkspace.shellID != identity.shellID)

        var otherBuild = first.shellIdentity.build
        otherBuild.liveReloadIndexHash = .sha256("another-index")
        let changed = try factory.make(
            workspacePathHash: first.workspacePathHash,
            build: otherBuild
        )
        #expect(changed.shellID != identity.shellID)
    }

    @Test("Exact build lookup is idempotent and rejects stale refreshes")
    func exactLookup() async throws {
        let registry = try DevSession.ContextRegistry()
        let original = try makeContext(index: 1, registeredAt: 100)
        #expect(try await registry.register(original))
        #expect(await registry.resolve(original.shellIdentity.build) == original)
        let duplicateChanged = try await registry.register(original)
        #expect(!duplicateChanged)

        var stale = original
        stale.registeredAt = Date(timeIntervalSince1970: 99)
        stale.configurationPath = "/tmp/helix/older/HelixDev.json"
        let staleChanged = try await registry.register(stale)
        #expect(!staleChanged)
        #expect(await registry.resolve(original.shellIdentity.build) == original)

        var refreshed = original
        refreshed.registeredAt = Date(timeIntervalSince1970: 101)
        refreshed.configurationPath = "/tmp/helix/newer/HelixDev.json"
        #expect(try await registry.register(refreshed))
        #expect(await registry.resolve(original.shellIdentity.build) == refreshed)
    }

    @Test("Equivalent Shell rotation succeeds while ambiguous collisions fail closed")
    func collisions() async throws {
        let registry = try DevSession.ContextRegistry()
        let first = try makeContext(index: 1, registeredAt: 100)
        _ = try await registry.register(first)

        var shellCollision = try makeContext(index: 2, registeredAt: 101)
        shellCollision.shellIdentity = .init(
            shellID: first.shellIdentity.shellID,
            build: shellCollision.shellIdentity.build
        )
        await expectContextError(.shellIdentityCollision) {
            _ = try await registry.register(shellCollision)
        }

        var buildCollision = try makeContext(index: 3, registeredAt: 102)
        buildCollision.shellIdentity = .init(
            shellID: buildCollision.shellIdentity.shellID,
            build: first.shellIdentity.build
        )
        #expect(try await registry.register(buildCollision))
        #expect(await registry.context(shellID: first.shellIdentity.shellID) == nil)
        #expect(
            await registry.resolve(first.shellIdentity.build)?.shellIdentity.shellID
                == buildCollision.shellIdentity.shellID
        )

        var ambiguousCollision = try makeContext(
            index: 4,
            registeredAt: 103,
            workspace: "/tmp/Other.xcworkspace"
        )
        ambiguousCollision.shellIdentity = .init(
            shellID: ambiguousCollision.shellIdentity.shellID,
            build: first.shellIdentity.build
        )
        await expectContextError(.buildIdentityCollision) {
            _ = try await registry.register(ambiguousCollision)
        }
    }

    @Test("Retention is newest-first per workspace and globally")
    func retention() async throws {
        let limits = try DevSession.ContextRegistry.Limits(
            maximumContexts: 3,
            maximumContextsPerWorkspace: 2
        )
        let registry = try DevSession.ContextRegistry(limits: limits)
        let first = try makeContext(
            index: 1,
            registeredAt: 1,
            workspace: "/tmp/a.xcworkspace"
        )
        let second = try makeContext(
            index: 2,
            registeredAt: 2,
            workspace: "/tmp/a.xcworkspace"
        )
        let third = try makeContext(
            index: 3,
            registeredAt: 3,
            workspace: "/tmp/a.xcworkspace"
        )
        let fourth = try makeContext(
            index: 4,
            registeredAt: 4,
            workspace: "/tmp/b.xcworkspace"
        )
        let fifth = try makeContext(
            index: 5,
            registeredAt: 5,
            workspace: "/tmp/c.xcworkspace"
        )
        for item in [first, second, third, fourth, fifth] {
            _ = try await registry.register(item)
        }
        let remaining = await registry.contexts()
        #expect(remaining.map(\.shellIdentity.shellID) == [
            fifth.shellIdentity.shellID,
            fourth.shellIdentity.shellID,
            third.shellIdentity.shellID,
        ])
        #expect(await registry.resolve(first.shellIdentity.build) == nil)
        #expect(await registry.resolve(second.shellIdentity.build) == nil)
    }

    @Test("Registry persistence is canonical, private, and round-trips")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelixContextStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildContexts.json")
        let store = DevSession.ContextStore(url: url)
        let contexts = [
            try makeContext(index: 1, registeredAt: 100),
            try makeContext(index: 2, registeredAt: 200),
        ]
        try store.save(contexts)
        #expect(try store.load() == Array(contexts.reversed()))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)

        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let reencoded = try JSONSerialization.data(
            withJSONObject: decoded,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(data == reencoded)
    }

    @Test("Context persistence treats noncurrent protocols uniformly without mutation")
    func noncurrentProtocolsFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelixContextVersion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildContexts.json")
        let store = DevSession.ContextStore(url: url)
        let current = try makeContext(index: 1, registeredAt: 100)
        try store.save([current])

        let currentProtocolVersion = DevProtocol.Metadata.currentProtocolVersion
        for protocolVersion: UInt16 in [
            .min,
            currentProtocolVersion + 1,
            currentProtocolVersion + 100,
            .max,
        ] {
            var noncurrent = current
            noncurrent.shellIdentity.build.protocolVersion = protocolVersion
            try writeContextDocument([noncurrent], to: url)
            let original = try Data(contentsOf: url)

            #expect(throws: DevProtocol.Error.malformedMessage(
                "peer build identity is invalid"
            )) {
                _ = try store.load()
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("Persistent startup quarantines invalid reconstructible context state")
    func persistentRecoveryQuarantinesInvalidState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelixContextRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildContexts.json")
        let store = DevSession.ContextStore(url: url)
        try store.save([try makeContext(index: 1, registeredAt: 100)])

        try Data("{\"schemaVersion\":1,\"contexts\":[{}]}".utf8).write(to: url)
        #expect(throws: DevSession.ContextError.self) {
            _ = try store.load()
        }
        #expect(try store.loadOrQuarantineInvalidDocument().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix(".BuildContexts.json.invalid-") }
        #expect(quarantined.count == 1)
    }

    @Test("Context persistence rejects broad permissions and symbolic links")
    func persistenceSecurity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelixContextSecurity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("BuildContexts.json")
        let store = DevSession.ContextStore(url: url)
        try store.save([try makeContext(index: 1, registeredAt: 100)])

        #expect(chmod(url.path, 0o644) == 0)
        #expect(throws: DevSession.ContextError.self) {
            _ = try store.load()
        }
        #expect(throws: DevSession.ContextError.self) {
            _ = try store.loadOrQuarantineInvalidDocument()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(chmod(url.path, 0o600) == 0)

        let link = directory.appendingPathComponent("BuildContexts.link.json")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: url
        )
        #expect(throws: DevSession.ContextError.self) {
            _ = try DevSession.ContextStore(url: link).load()
        }
        #expect(throws: DevSession.ContextError.self) {
            _ = try DevSession.ContextStore(url: link)
                .loadOrQuarantineInvalidDocument()
        }
        #expect(
            FileManager.default.fileExists(atPath: url.path)
                && FileManager.default.fileExists(atPath: link.path)
        )
    }

    @Test("A failed persistent registration restores the complete in-memory index")
    func transactionalPersistenceRollback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelixContextRollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let store = DevSession.ContextStore(
            url: blocker.appendingPathComponent("BuildContexts.json")
        )
        let original = try makeContext(index: 1, registeredAt: 100)
        let candidate = try makeContext(index: 2, registeredAt: 200)
        let registry = try DevSession.ContextRegistry(contexts: [original])

        do {
            _ = try await registry.register(candidate, persistingTo: store)
            Issue.record("Expected the persistent registration to fail")
        } catch {
            // The filesystem error is expected; registry rollback is asserted below.
        }
        #expect(await registry.contexts() == [original])
        #expect(await registry.resolve(candidate.shellIdentity.build) == nil)
    }

    @Test("Build Context rejects noncanonical or mismatched workspace paths")
    func validatesPaths() throws {
        var item = try makeContext(index: 1, registeredAt: 100)
        item.workspacePath = "/tmp/helix/../other.xcworkspace"
        item.workspacePathHash = .sha256("/tmp/other.xcworkspace")
        #expect(throws: DevSession.ContextError.invalidValue) {
            try item.validate()
        }

        item = try makeContext(index: 2, registeredAt: 100)
        item.workspacePathHash = .sha256("another-workspace")
        #expect(throws: DevSession.ContextError.invalidValue) {
            try item.validate()
        }
    }
}
}

private func makeContext(
    index: Int,
    registeredAt: TimeInterval,
    workspace: String = "/tmp/Fixture.xcworkspace"
) throws -> DevSession.BuildContext {
    let workspace = URL(fileURLWithPath: workspace).standardizedFileURL.path
    guard let executableUUID = UUID(
        uuidString: String(format: "00000000-0000-0000-0000-%012d", index)
    ), let shellUUID = UUID(
        uuidString: String(format: "10000000-0000-0000-0000-%012d", index)
    ) else {
        throw DevSession.ContextError.invalidValue
    }
    let build = DevProtocol.PeerBuildIdentity(
        bundleID: "dev.helix.fixture.\(index)",
        executableUUID: executableUUID,
        platform: .iOS,
        architecture: "arm64",
        xcodeBuild: "18A1",
        sdkBuild: "22A1",
        swiftCompilerFingerprint: "swift-\(index)",
        liveReloadIndexHash: .sha256("index-\(index)")
    )
    let context = DevSession.BuildContext(
        shellIdentity: .init(
            shellID: .init(rawValue: shellUUID),
            build: build
        ),
        workspacePathHash: .sha256(workspace),
        workspacePath: workspace,
        configurationPath: "/tmp/helix/\(index)/HelixDev.json",
        scheme: "Fixture",
        buildConfiguration: "Debug",
        moduleName: "FixtureFeature",
        registeredAt: Date(timeIntervalSince1970: registeredAt)
    )
    try context.validate()
    return context
}

private func writeContextDocument(
    _ contexts: [DevSession.BuildContext],
    to url: URL
) throws {
    struct StoredDocument: Encodable {
        var schemaVersion: UInt16 = 1
        var contexts: [DevSession.BuildContext]
    }

    let data = try Core.CanonicalJSON.encode(
        StoredDocument(contexts: contexts)
    )
    try data.write(to: url)
}

private func expectContextError(
    _ expected: DevSession.ContextError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected ContextError \(expected)")
    } catch let error as DevSession.ContextError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
