#if canImport(CryptoKit) && canImport(Security)
import Foundation
import HelixDevProtocol
import Testing

extension DevProtocolTests {
@Suite("Persistent Host Identity")
struct HostIdentity {
    @Test("The host pin survives certificate renewal")
    func stablePin() throws {
        try withStore { store, keyURL in
            let first = try store.loadOrCreate(
                now: Date(timeIntervalSince1970: 1_000),
                certificateLifetime: 600
            )
            let second = try store.loadOrCreate(
                now: Date(timeIntervalSince1970: 2_000),
                certificateLifetime: 600
            )
            #expect(first.spkiHash == second.spkiHash)
            #expect(first.validUntil != second.validUntil)
            let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
            #expect(attributes[.size] as? Int == NetworkTransport.HostIdentityStore.privateKeyByteCount)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o077 == 0)
        }
    }

    @Test("Concurrent creators converge on one Host Identity")
    func concurrentCreation() async throws {
        try await withStore { store, _ in
            let pins = try await withThrowingTaskGroup(
                of: String.self,
                returning: Set<String>.self
            ) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try store.loadOrCreate().spkiHash.hex
                    }
                }
                var values = Set<String>()
                for try await value in group { values.insert(value) }
                return values
            }
            #expect(pins.count == 1)
        }
    }

    @Test("Loose key permissions fail closed")
    func rejectsLoosePermissions() throws {
        try withStore { store, keyURL in
            _ = try store.loadOrCreate()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: keyURL.path
            )
            #expect(throws: NetworkTransport.Error.self) {
                _ = try store.loadOrCreate()
            }
        }
    }

    @Test("Corrupt key material is never silently replaced")
    func rejectsCorruptKey() throws {
        try withStore { store, keyURL in
            _ = try store.loadOrCreate()
            try Data(repeating: 0, count: 8).write(to: keyURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            #expect(throws: NetworkTransport.Error.self) {
                _ = try store.loadOrCreate()
            }
            #expect((try Data(contentsOf: keyURL)).count == 8)
        }
    }

    @Test("Symbolic-link private keys fail closed")
    func rejectsSymbolicLink() throws {
        try withStore { store, keyURL in
            let targetURL = keyURL.deletingLastPathComponent()
                .appendingPathComponent("external-key")
            try Data(repeating: 7, count: NetworkTransport.HostIdentityStore.privateKeyByteCount)
                .write(to: targetURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: targetURL.path
            )
            try FileManager.default.createSymbolicLink(
                at: keyURL,
                withDestinationURL: targetURL
            )
            do {
                _ = try store.loadOrCreate()
                Issue.record("Expected symbolic-link storage to be rejected")
            } catch NetworkTransport.Error.insecureIdentityStorage {
                // Expected: never follow a replaceable private-key path.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}
}

private func withStore<Result>(
    _ operation: (
        NetworkTransport.HostIdentityStore,
        URL
    ) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HelixHostIdentityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let keyURL = directory.appendingPathComponent("HostIdentity.p256")
    return try operation(.init(privateKeyURL: keyURL), keyURL)
}

private func withStore<Result>(
    _ operation: (
        NetworkTransport.HostIdentityStore,
        URL
    ) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HelixHostIdentityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let keyURL = directory.appendingPathComponent("HostIdentity.p256")
    return try await operation(.init(privateKeyURL: keyURL), keyURL)
}
#endif
