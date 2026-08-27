import Foundation
import HelixCore
import Testing

extension CoreTests {
@Suite("Native capability manifest")
struct NativeCapability {
    @Test("Manifest canonicalizes one dense immutable authority table")
    func canonicalAuthority() throws {
        let fixture = try Fixture()
        let manifest = Core.NativeCapability.Manifest(
            identity: fixture.identity,
            capabilities: [.nativeImportsV1, .baselineV1],
            entries: [fixture.entries[1], fixture.entries[0]]
        )

        try manifest.validate()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.capabilities == [.baselineV1, .nativeImportsV1])
        #expect(manifest.entries.map(\.id.rawValue) == [0, 1])
        #expect(manifest.nativeCallKeys == Set(fixture.entries.map(\.key)))
        #expect(manifest.entry(for: fixture.entries[0].key) == fixture.entries[0])

        let bytes = try Core.CanonicalJSON.encode(manifest)
        let decoded = try JSONDecoder().decode(
            Core.NativeCapability.Manifest.self,
            from: bytes
        )
        #expect(decoded == manifest)
        #expect(try manifest.contentHash() == .sha256(bytes))
    }

    @Test("Manifest rejects key, compact-ID, capability, and identity tampering")
    func rejectsTampering() throws {
        let fixture = try Fixture()
        let original = fixture.manifest

        var changed = original
        changed.entries[0].key = .init(rawValue: .sha256("forged-call"))
        #expect(throws: Core.NativeCapability.Error.invalidEntry(
            changed.entries[0].key
        )) {
            try changed.validate()
        }

        changed = original
        changed.entries[1].id = .init(rawValue: 7)
        #expect(throws: Core.NativeCapability.Error.invalidManifest) {
            try changed.validate()
        }

        changed = original
        changed.capabilities.append(.nativeImportsV1)
        #expect(throws: Core.NativeCapability.Error.invalidManifest) {
            try changed.validate()
        }

        changed = original
        changed.capabilities.removeAll { $0 == .nativeImportsV1 }
        #expect(throws: Core.NativeCapability.Error.invalidManifest) {
            try changed.validate()
        }

        changed = original
        changed.identity.bundleID = ""
        #expect(throws: Core.NativeCapability.Error.invalidManifest) {
            try changed.validate()
        }
    }

    @Test("Manifest digest binds release identity and native policy")
    func digestBindsAuthority() throws {
        let fixture = try Fixture()
        let originalHash = try fixture.manifest.contentHash()

        var changedIdentity = fixture.manifest
        changedIdentity.identity.buildNumber = "8"
        #expect(try changedIdentity.contentHash() != originalHash)

        var changedPolicy = fixture.manifest
        changedPolicy.entries[0].contract.execution.maximumDurationMicroseconds += 1
        #expect(try changedPolicy.contentHash() != originalHash)
    }

    @Test("Manifest may advertise native-import support before publishing calls")
    func emptyAuthority() throws {
        let fixture = try Fixture()
        let manifest = Core.NativeCapability.Manifest(
            identity: fixture.identity,
            capabilities: [.baselineV1, .nativeImportsV1],
            entries: []
        )

        try manifest.validate()
        #expect(manifest.nativeCallKeys.isEmpty)
    }
}
}

extension CoreTests.NativeCapability {
private struct Fixture {
    let identity: Core.NativeCapability.Identity
    let entries: [Core.NativeCapability.Entry]

    init() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.native-capability",
            buildNumber: "7",
            seed: "native-capability-test"
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "fixture-swift"
        )
        identity = .init(
            bundleID: "dev.helix.native-capability",
            buildNumber: "7",
            shellNamespaceID: namespace,
            shellInterfaceHash: .sha256("fixture-shell"),
            targetTriple: "arm64-apple-ios15.0",
            minimumOSVersion: .init(15),
            xcodeBuild: "18A1",
            sdkBuild: "22A1",
            compatibility: compatibility
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        entries = try ["first", "second"].enumerated().map { index, name in
            let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.\(name)()",
                signature: .init(parameters: [], result: "Swift.Int"),
                effects: .init(),
                contract: contract
            )
            return .init(
                id: .init(rawValue: UInt32(index)),
                key: try Core.NativeCall.Key.derive(descriptor: descriptor),
                descriptor: descriptor,
                contract: contract
            )
        }
    }

    var manifest: Core.NativeCapability.Manifest {
        .init(
            identity: identity,
            capabilities: [.baselineV1, .nativeImportsV1],
            entries: entries
        )
    }
}
}
