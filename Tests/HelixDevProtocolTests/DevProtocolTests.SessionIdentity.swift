import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
import Testing

extension DevProtocolTests {
@Suite("Development session native inventory")
struct SessionIdentity {
    @Test("Native inventory preserves an exact canonical reconnect identity")
    func acceptsCanonicalInventory() throws {
        let identity = makeIdentity()

        try identity.validate()

        #expect(identity.activeDevelopmentNativeImports.map(\.id) == [
            .init(rawValue: 7),
            .init(rawValue: 9),
        ])
        #expect(identity.activeDevelopmentNativeTypeIDs == [
            typeID("A"),
            typeID("B"),
        ].sorted { $0.rawValue < $1.rawValue })
    }

    @Test("Duplicate or noncanonical NativeImport mappings fail closed")
    func rejectsAmbiguousImportMappings() {
        let first = DevProtocol.ActiveDevelopmentNativeImport(
            id: .init(rawValue: 7),
            key: callKey("A")
        )
        let second = DevProtocol.ActiveDevelopmentNativeImport(
            id: .init(rawValue: 9),
            key: callKey("B")
        )

        var duplicateID = makeIdentity()
        duplicateID.activeDevelopmentNativeImports = [
            first,
            .init(id: first.id, key: second.key),
        ]
        #expect(throws: DevProtocol.Error.self) {
            try duplicateID.validate()
        }

        var duplicateKey = makeIdentity()
        duplicateKey.activeDevelopmentNativeImports = [
            first,
            .init(id: second.id, key: first.key),
        ]
        #expect(throws: DevProtocol.Error.self) {
            try duplicateKey.validate()
        }

        var noncanonical = makeIdentity()
        noncanonical.activeDevelopmentNativeImports.reverse()
        #expect(throws: DevProtocol.Error.self) {
            try noncanonical.validate()
        }
    }

    @Test("Native type inventory is unique, ordered, and generation-bound")
    func rejectsInvalidTypeInventory() {
        var duplicate = makeIdentity()
        duplicate.activeDevelopmentNativeTypeIDs = [typeID("A"), typeID("A")]
        #expect(throws: DevProtocol.Error.self) {
            try duplicate.validate()
        }

        var noncanonical = makeIdentity()
        noncanonical.activeDevelopmentNativeTypeIDs.reverse()
        #expect(throws: DevProtocol.Error.self) {
            try noncanonical.validate()
        }

        var inactive = makeIdentity()
        inactive.activeGenerationID = nil
        #expect(throws: DevProtocol.Error.self) {
            try inactive.validate()
        }

        var withoutHLBC = makeIdentity()
        withoutHLBC.supportedBackends = [.nativeDynamicReplacement]
        #expect(throws: DevProtocol.Error.self) {
            try withoutHLBC.validate()
        }
    }

    private func makeIdentity() -> DevProtocol.SessionIdentity {
        .init(
            sessionID: UUID(uuidString: "A30A0F39-9FA6-4C6E-A20B-947EB796C66A")!,
            bundleID: "dev.helix.fixture",
            executableUUID: UUID(
                uuidString: "C4B71AAE-C662-45F2-9B7F-D7E47C20FC25"
            )!,
            processID: 42,
            platform: .iOSSimulator,
            architecture: "arm64",
            operatingSystemBuild: "23A1",
            xcodeBuild: "23A1",
            sdkBuild: "23A1",
            swiftCompilerFingerprint: "swift-fixture",
            liveReloadIndexHash: .sha256("reload-index"),
            supportedBackends: [.hlbc],
            nativeChainingProbePassed: false,
            highestAppliedSourceRevision: .init(rawValue: 3),
            activeGenerationID: .init(rawValue: 2),
            activeDevelopmentNativeImports: [
                .init(id: .init(rawValue: 9), key: callKey("B")),
                .init(id: .init(rawValue: 7), key: callKey("A")),
            ],
            activeDevelopmentNativeTypeIDs: [typeID("B"), typeID("A")]
        )
    }

    private func callKey(_ suffix: String) -> Core.NativeCall.Key {
        .init(rawValue: .sha256("native-call-\(suffix)"))
    }

    private func typeID(_ suffix: String) -> Core.TypeID {
        .init(rawValue: .sha256("native-type-\(suffix)"))
    }
}
}
