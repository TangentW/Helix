import Foundation
import HelixCore
import HelixRuntime
import HelixVM
import Testing
@testable import HelixPatch

extension PatchTests {
@Suite("Production patch safety closure")
struct ProductionSafety {
    @Test("A signing provider response is verified before a container is accepted")
    func rejectsBrokenSigningServiceResponse() throws {
        let fixture = try PatchFixture()
        let original = try fixture.package(revision: 1)
        let provider = CorruptingSignatureProvider(base: fixture.signer)

        #expect(throws: PatchPackage.Error.invalidPackageSignature) {
            _ = try PatchPackage.Container.signed(
                manifest: original.manifest,
                payloads: original.payloads,
                signer: provider
            )
        }
    }

    @Test("A revocation snapshot is canonical, signed, monotonic, and effective")
    func signedRevocationSnapshot() throws {
        let fixture = try PatchFixture()
        let snapshot = try PatchPackage.RevocationSnapshot.issue(
            authorityKeyID: "revocation-1",
            authorityPrivateKey: fixture.revocationKey,
            epoch: 2,
            issuedAtUnixSeconds: fixture.now - 1,
            expiresAtUnixSeconds: fixture.now + 1_000,
            revokedKeyIDs: ["leaf-1"]
        )
        let bytes = try snapshot.encoded()
        #expect(try PatchPackage.RevocationSnapshot.decode(bytes) == snapshot)

        let updated = try fixture.trustStore.applying(
            snapshot,
            nowUnixSeconds: fixture.now
        )
        var forgedSameEpoch = snapshot
        forgedSameEpoch.signature[forgedSameEpoch.signature.startIndex] ^= 0x01
        #expect(throws: PatchPackage.Error.invalidRevocationSnapshot(
            "authority signature failed"
        )) {
            _ = try updated.applying(
                forgedSameEpoch,
                nowUnixSeconds: fixture.now
            )
        }
        let package = try fixture.package(revision: 2).encoded()
        #expect(throws: PatchPackage.Error.signingKeyRevoked("leaf-1")) {
            _ = try PatchPackage.Verifier().verify(
                bytes: package,
                trustStore: updated,
                targetContext: fixture.targetContext,
                acceptancePolicy: fixture.acceptancePolicy,
                antiRollbackState: nil,
                nowUnixSeconds: fixture.now
            )
        }

        let older = try PatchPackage.RevocationSnapshot.issue(
            authorityKeyID: "revocation-1",
            authorityPrivateKey: fixture.revocationKey,
            epoch: 1,
            issuedAtUnixSeconds: fixture.now - 1,
            expiresAtUnixSeconds: fixture.now + 1_000,
            revokedPackageHashes: [.sha256("old")]
        )
        #expect(throws: PatchPackage.Error.revocationEpochRollback(highestSeen: 2, received: 1)) {
            _ = try updated.applying(older, nowUnixSeconds: fixture.now)
        }

        var object = try #require(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        object["unknownCriticalField"] = true
        let noncanonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        #expect(throws: PatchPackage.Error.self) {
            _ = try PatchPackage.RevocationSnapshot.decode(noncanonical)
        }
    }

    @Test("Container payload records have one canonical order")
    func rejectsReorderedPayloadTable() throws {
        let fixture = try PatchFixture()
        let original = try fixture.package(revision: 1)
        var manifest = original.manifest
        var secondDescriptor = try #require(manifest.payloads.first)
        secondDescriptor.path = "variants/second.hlbc"
        manifest.payloads.append(secondDescriptor)
        let package = try PatchPackage.Container.signed(
            manifest: manifest,
            payloads: [
                try #require(manifest.payloads.first).path: fixture.bytecode,
                secondDescriptor.path: fixture.bytecode,
            ],
            signer: fixture.signer
        )
        let reordered = try swappingFirstTwoPayloadRecords(in: package.encoded())

        #expect(throws: PatchPackage.Error.malformedContainer(
            "payload table is not in canonical path order"
        )) {
            _ = try PatchPackage.Container.decode(reordered)
        }
    }

    @Test("Leaf validity cannot extend beyond its trusted root")
    func certificateValidityIsContainedByRoot() throws {
        let fixture = try PatchFixture()
        let rootKey = PatchPackage.PrivateKey()
        let leafKey = PatchPackage.PrivateKey()
        let root = PatchPackage.TrustedRoot(
            keyID: "short-root",
            publicKey: rootKey.publicKeyRepresentation,
            validFromUnixSeconds: fixture.now - 100,
            validUntilUnixSeconds: fixture.now + 100,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc]
        )
        let certificate = try PatchPackage.SigningCertificate.issue(
            keyID: "leaf-1",
            leafPublicKey: leafKey.publicKeyRepresentation,
            issuerKeyID: root.keyID,
            issuerPrivateKey: rootKey,
            validFromUnixSeconds: fixture.now - 50,
            validUntilUnixSeconds: fixture.now + 200,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc],
            allowedBundleIDs: [fixture.targetContext.bundleID],
            maximumPayloadBytes: 1_024 * 1_024
        )
        let signer = try PatchPackage.Signer(certificate: certificate, privateKey: leafKey)
        let original = try fixture.package(revision: 1)
        let package = try PatchPackage.Container.signed(
            manifest: original.manifest,
            payloads: original.payloads,
            signer: signer
        ).encoded()
        let trust = try PatchPackage.TrustStore(roots: [root])

        #expect(throws: PatchPackage.Error.self) {
            _ = try PatchPackage.Verifier().verify(
                bytes: package,
                trustStore: trust,
                targetContext: fixture.targetContext,
                acceptancePolicy: fixture.acceptancePolicy,
                antiRollbackState: nil,
                nowUnixSeconds: fixture.now
            )
        }
    }

    @Test("Concurrent equal revisions cannot replace one another in the ledger")
    func antiRollbackTransitionIsAtomic() async throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-ledger-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try PatchStore.Storage(rootURL: directory)
        let secondStore = try PatchStore.Storage(rootURL: directory)
        let first = try fixture.package(revision: 7)
        var secondManifest = first.manifest
        secondManifest.purpose = "different signed contents at the same revision"
        let second = try PatchPackage.Container.signed(
            manifest: secondManifest,
            payloads: first.payloads,
            signer: fixture.signer
        )
        let candidates = [
            (first.manifest, Core.Digest.sha256(try first.encoded()), firstStore),
            (second.manifest, Core.Digest.sha256(try second.encoded()), secondStore),
        ]

        let accepted = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        try candidate.2.recordSeen(
                            manifest: candidate.0,
                            packageHash: candidate.1,
                            shellInterfaceHash: fixture.shellHash
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(accepted.filter { $0 }.count == 1)
        let loadedState = try firstStore.antiRollbackState(
            campaignID: fixture.campaignID,
            shellInterfaceHash: fixture.shellHash
        )
        let state = try #require(loadedState)
        #expect(state.highestSeenRevision == 7)
        #expect(candidates.map(\.1).contains(try #require(state.highestSeenPackageHash)))
    }

    @Test("WAL rejects overwrite, commits idempotently, and rolls back to LKG")
    func writeAheadActivationLifecycle() throws {
        let directory = try temporaryDirectory(prefix: "helix-wal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let first = pending(
            generation: 1,
            parent: nil,
            packageID: "HLX-first",
            packageHash: .sha256("first")
        )
        let competing = pending(
            generation: 2,
            parent: nil,
            packageID: "HLX-competing",
            packageHash: .sha256("competing")
        )
        try store.beginActivation(first)
        #expect(throws: PatchPackage.Error.self) {
            try store.beginActivation(competing)
        }
        let firstState = activeState(first)
        try store.commitActivation(firstState)
        try store.commitActivation(firstState)
        let second = pending(
            generation: 2,
            parent: 1,
            packageID: "HLX-second",
            packageHash: .sha256("second")
        )
        #expect(throws: PatchPackage.Error.self) {
            try store.beginActivation(second)
        }
        try store.markActiveHealthy(
            expectedActiveID: first.targetGenerationID,
            nowUnixSeconds: 103
        )
        try store.beginActivation(second)
        let secondState = activeState(second)
        try store.commitActivation(secondState)
        #expect(try store.activeState() == secondState)
        #expect(
            try store.rollbackToLastKnownGood(expectedActiveID: second.targetGenerationID)
                == firstState
        )
        #expect(try store.activeState() == firstState)

        let third = pending(
            generation: 3,
            parent: 1,
            packageID: "HLX-third",
            packageHash: .sha256("third")
        )
        try store.beginActivation(third)
        try store.commitActivation(activeState(third))
        // Simulate a crash after the rollback target became active but before
        // the stale LKG pointer was removed.
        try Core.CanonicalJSON.encode(firstState).write(
            to: store.activeURL.appendingPathComponent("active-state.json"),
            options: .atomic
        )
        #expect(
            try store.rollbackToLastKnownGood(expectedActiveID: first.targetGenerationID)
                == firstState
        )
        #expect(try store.activeState() == firstState)
    }

    @Test("Patch Store rejects a symbolic-link root")
    func rejectsSymbolicLinkRoot() throws {
        let container = try temporaryDirectory(prefix: "helix-store-link")
        defer { try? FileManager.default.removeItem(at: container) }
        let target = container.appendingPathComponent("target", isDirectory: true)
        let link = container.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Swift.Error).self) {
            _ = try PatchStore.Storage(rootURL: link)
        }
    }

    @Test("Streaming input is bounded, hashed, installed, and removed from incoming")
    func streamingDownloadInstallsAtomically() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-stream")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let packageBytes = try fixture.package(revision: 1).encoded()
        let receiver = try PatchDownload.Receiver(
            store: store,
            maximumPackageBytes: packageBytes.count,
            expectedByteCount: packageBytes.count,
            expectedSHA256: .sha256(packageBytes)
        )
        let midpoint = packageBytes.count / 2
        try receiver.append(packageBytes[..<midpoint])
        try receiver.append(packageBytes[midpoint...])
        let artifact = try receiver.finish()
        #expect(artifact.packageBytes == packageBytes)

        let runtime = try makeRuntime(fixture)
        let controller = makeController(fixture, store: store, runtime: runtime)
        _ = try controller.installAndActivate(
            artifact: artifact,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        #expect(!FileManager.default.fileExists(atPath: artifact.partialURL.path))

        let oversized = try PatchDownload.Receiver(store: store, maximumPackageBytes: 3)
        #expect(throws: PatchPackage.Error.limitExceeded("incoming package bytes")) {
            try oversized.append(Data(repeating: 0x41, count: 4))
        }
        try oversized.cancel()

        let sourceURL = directory.appendingPathComponent("MockDownload.hlxp")
        try packageBytes.write(to: sourceURL)
        let transportStore = try PatchStore.Storage(
            rootURL: directory.appendingPathComponent("LocalTransport")
        )
        let transported = try PatchDownload.LocalFileTransport(chunkByteCount: 17).receive(
            from: sourceURL,
            into: transportStore,
            expectedSHA256: .sha256(packageBytes),
            maximumPackageBytes: packageBytes.count
        )
        #expect(transported.packageBytes == packageBytes)
        try transportStore.removeIncoming(downloadID: transported.downloadID)

        let symbolicURL = directory.appendingPathComponent("Linked.hlxp")
        try FileManager.default.createSymbolicLink(
            at: symbolicURL,
            withDestinationURL: sourceURL
        )
        #expect(throws: PatchPackage.Error.self) {
            try PatchDownload.LocalFileTransport().receive(
                from: symbolicURL,
                into: transportStore
            )
        }
    }

    @Test("Runtime prebinding failure contains and locally blocks the package")
    func runtimeBindingFailureIsContained() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-runtime-containment")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let runtime = Runtime.Engine(
            originals: try Runtime.OriginalCatalog([]),
            shellInterfaceHash: fixture.shellHash
        )
        let controller = makeController(fixture, store: store, runtime: runtime)
        let bytes = try fixture.package(revision: 1).encoded()
        let hash = Core.Digest.sha256(bytes)

        #expect(throws: Runtime.ActivationError.self) {
            _ = try controller.installAndActivate(
                packageBytes: bytes,
                generationID: .init(rawValue: 1),
                expectedActiveID: nil,
                nowUnixSeconds: fixture.now
            )
        }
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
        #expect(try store.activeState() == nil)
        #expect(try store.localBlock(for: hash)?.reasonCode == "runtimeBindingFailed")
    }

    @Test("Signed key revocation immediately deactivates and persists")
    func revocationDeactivatesCurrentGeneration() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-revocation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let runtime = try makeRuntime(fixture)
        let controller = makeController(fixture, store: store, runtime: runtime)
        let bytes = try fixture.package(revision: 1).encoded()
        let result = try controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        let snapshot = try PatchPackage.RevocationSnapshot.issue(
            authorityKeyID: "revocation-1",
            authorityPrivateKey: fixture.revocationKey,
            epoch: 1,
            issuedAtUnixSeconds: fixture.now - 1,
            expiresAtUnixSeconds: fixture.now + 1_000,
            revokedKeyIDs: ["leaf-1"]
        )

        let applied = try controller.applyRevocationSnapshot(
            snapshot,
            nowUnixSeconds: fixture.now
        )
        #expect(applied.deactivatedGenerationID == .init(rawValue: 1))
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
        #expect(try store.activeState() == nil)
        #expect(try store.revocationState().highestSeenEpoch == 1)
        #expect(try store.localBlock(for: result.packageHash) != nil)
    }

    @Test("Package revocation restores the durable LKG without lowering high-water")
    func packageRevocationRestoresHistoricalLKG() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-revocation-lkg")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let runtime = try makeRuntime(fixture)
        let controller = makeController(fixture, store: store, runtime: runtime)
        let first = try controller.installAndActivate(
            packageBytes: fixture.package(revision: 1).encoded(),
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        try controller.markActiveHealthy(nowUnixSeconds: fixture.now)
        let second = try controller.installAndActivate(
            packageBytes: fixture.package(
                revision: 2,
                rollback: .init(parentGenerationPackageHash: first.packageHash)
            ).encoded(),
            generationID: .init(rawValue: 2),
            expectedActiveID: .init(rawValue: 1),
            nowUnixSeconds: fixture.now + 1
        )
        let snapshot = try PatchPackage.RevocationSnapshot.issue(
            authorityKeyID: "revocation-1",
            authorityPrivateKey: fixture.revocationKey,
            epoch: 1,
            issuedAtUnixSeconds: fixture.now - 1,
            expiresAtUnixSeconds: fixture.now + 1_000,
            revokedPackageHashes: [second.packageHash]
        )

        let applied = try controller.applyRevocationSnapshot(
            snapshot,
            nowUnixSeconds: fixture.now + 2
        )
        #expect(applied.deactivatedGenerationID == .init(rawValue: 2))
        #expect(applied.restoredPersistentState?.generationID == .init(rawValue: 1))
        #expect(applied.restoredRuntimeGenerationID == .init(rawValue: 1))
        #expect(try store.activeState()?.generationID == .init(rawValue: 1))
        let registrySnapshot = runtime.registry.snapshot()
        #expect(registrySnapshot.activeGenerationID == .init(rawValue: 1))
        #expect(registrySnapshot.highestActivatedGenerationID == .init(rawValue: 2))
        #expect(try store.localBlock(for: second.packageHash) != nil)

        withExtendedLifetime((first, second)) {}
    }

    @Test("Crash Guard restores the committed parent and blocks the crashing hash")
    func crashGuardRestoresLastKnownGood() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-launch-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let installRuntime = try makeRuntime(fixture)
        let installer = makeController(fixture, store: store, runtime: installRuntime)
        let first = try installer.installAndActivate(
            packageBytes: fixture.package(revision: 1).encoded(),
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        try installer.markActiveHealthy(nowUnixSeconds: fixture.now)
        let secondBytes = try fixture.package(
            revision: 2,
            rollback: .init(parentGenerationPackageHash: first.packageHash)
        ).encoded()
        let second = try installer.installAndActivate(
            packageBytes: secondBytes,
            generationID: .init(rawValue: 2),
            expectedActiveID: .init(rawValue: 1),
            nowUnixSeconds: fixture.now + 1
        )

        let firstLaunchRuntime = try makeRuntime(fixture)
        let firstLaunch = PatchLaunch.Coordinator(
            activation: makeController(fixture, store: store, runtime: firstLaunchRuntime),
            crashGuard: .init(store: store, uncleanLaunchThreshold: 1)
        )
        let firstLaunchResult = try firstLaunch.prepareLaunch(
            nowUnixSeconds: fixture.now + 2
        )
        #expect(firstLaunchResult.activeGenerationID == .init(rawValue: 2))

        let quarantineObstruction = store.quarantineURL.appendingPathComponent(
            second.packageHash.hex
        )
        #expect(FileManager.default.createFile(
            atPath: quarantineObstruction.path,
            contents: Data("not a directory".utf8)
        ))
        let secondLaunchRuntime = try makeRuntime(fixture)
        let secondLaunch = PatchLaunch.Coordinator(
            activation: makeController(fixture, store: store, runtime: secondLaunchRuntime),
            crashGuard: .init(store: store, uncleanLaunchThreshold: 1)
        )
        let recovered = try secondLaunch.prepareLaunch(nowUnixSeconds: fixture.now + 3)
        #expect(recovered.crashGuardRollbackGenerationID == .init(rawValue: 2))
        #expect(recovered.activeGenerationID == .init(rawValue: 1))
        #expect(try store.activeState()?.generationID == .init(rawValue: 1))
        #expect(try store.localBlock(for: second.packageHash)?.reasonCode == "crashLoop")
        #expect(recovered.recoveryIssues.contains {
            $0.code == .containmentPersistenceFailed
        })
        try secondLaunch.markHealthy(
            sessionNonce: recovered.sessionNonce,
            nowUnixSeconds: fixture.now + 4
        )
    }

    @Test("Corrupt launch metadata is preserved and fails closed to originals")
    func corruptLaunchMetadataFallsBackToOriginals() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-corrupt-launch-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        try Data("{\"broken\":true}".utf8).write(
            to: store.activeURL.appendingPathComponent("active-state.json")
        )
        let runtime = try makeRuntime(fixture)
        let coordinator = PatchLaunch.Coordinator(
            activation: makeController(fixture, store: store, runtime: runtime),
            crashGuard: .init(store: store)
        )

        let stateRecovery = try coordinator.prepareLaunch(
            nowUnixSeconds: fixture.now
        )
        #expect(stateRecovery.activeGenerationID == nil)
        #expect(stateRecovery.recoveryIssues.contains {
            $0.code == .activationStateReset
        })
        #expect(try store.activeState() == nil)

        try Data("{\"broken\":true}".utf8).write(
            to: store.activeURL.appendingPathComponent("crash-guard.json"),
            options: .atomic
        )
        let journalRecovery = try coordinator.prepareLaunch(
            nowUnixSeconds: fixture.now + 1
        )
        #expect(journalRecovery.activeGenerationID == nil)
        #expect(journalRecovery.recoveryIssues.contains {
            $0.code == .crashGuardJournalReset
        })
        let evidence = try FileManager.default.contentsOfDirectory(
            at: store.quarantineURL,
            includingPropertiesForKeys: nil
        )
        #expect(evidence.filter { $0.lastPathComponent.hasPrefix("state-") }.count == 2)
    }
}
}

private struct CorruptingSignatureProvider: PatchPackage.SignatureProviding {
    var base: PatchPackage.Signer
    var certificate: PatchPackage.SigningCertificate { base.certificate }

    func sign(
        _ request: PatchPackage.SigningRequest
    ) throws -> PatchPackage.SignatureEnvelope {
        var envelope = try base.sign(request)
        envelope.signature[envelope.signature.startIndex] ^= 0x01
        return envelope
    }
}

private func makeRuntime(
    _ fixture: PatchTests.PatchFixture,
    registry: Runtime.GenerationRegistry = .init()
) throws -> Runtime.Engine {
    let originals = try Runtime.OriginalCatalog([
        .init(
            index: fixture.entry,
            parameterTypes: [.int64],
            resultType: .int64,
            invoke: { arguments in .returned(arguments.first) }
        ),
    ])
    return .init(
        registry: registry,
        originals: originals,
        shellInterfaceHash: fixture.shellHash
    )
}

private func makeController(
    _ fixture: PatchTests.PatchFixture,
    store: PatchStore.Storage,
    runtime: Runtime.Engine
) -> PatchActivation.Controller {
    .init(
        runtime: runtime,
        store: store,
        shell: fixture.shell,
        runtimePolicy: .init(),
        trustStore: fixture.trustStore,
        targetContext: fixture.targetContext,
        acceptancePolicy: fixture.acceptancePolicy
    )
}

private func pending(
    generation: UInt64,
    parent: UInt64?,
    packageID: String,
    packageHash: Core.Digest
) -> PatchStore.PendingActivation {
    .init(
        targetGenerationID: .init(rawValue: generation),
        parentGenerationID: parent.map(Runtime.GenerationID.init(rawValue:)),
        packageID: packageID,
        packageHash: packageHash,
        signerKeyID: "leaf-1",
        nonce: UUID(),
        createdAtUnixSeconds: 100 + Int64(generation)
    )
}

private func activeState(
    _ pending: PatchStore.PendingActivation
) -> PatchStore.ActiveState {
    .init(
        generationID: pending.targetGenerationID,
        parentGenerationID: pending.parentGenerationID,
        packageID: pending.packageID,
        packageHash: pending.packageHash,
        signerKeyID: pending.signerKeyID,
        activationNonce: pending.nonce,
        committedAtUnixSeconds: pending.createdAtUnixSeconds
    )
}

private func swappingFirstTwoPayloadRecords(in bytes: Data) throws -> Data {
    guard bytes.count >= 28 else {
        throw PatchPackage.Error.malformedContainer("truncated test container")
    }
    let manifestLength = Int(littleEndianUInt32(bytes, at: 12))
    guard littleEndianUInt32(bytes, at: 16) == 2 else {
        throw PatchPackage.Error.malformedContainer("test container needs two payloads")
    }
    let firstStart = 28 + manifestLength
    let firstLength = try payloadRecordLength(in: bytes, at: firstStart)
    let secondStart = firstStart + firstLength
    let secondLength = try payloadRecordLength(in: bytes, at: secondStart)
    let suffixStart = secondStart + secondLength
    guard suffixStart <= bytes.count else {
        throw PatchPackage.Error.malformedContainer("truncated test payload table")
    }

    var reordered = Data(bytes[..<firstStart])
    reordered.append(bytes[secondStart..<suffixStart])
    reordered.append(bytes[firstStart..<secondStart])
    reordered.append(bytes[suffixStart...])
    return reordered
}

private func payloadRecordLength(in bytes: Data, at offset: Int) throws -> Int {
    let fixedLength = 44
    guard offset >= 0, offset <= bytes.count - fixedLength else {
        throw PatchPackage.Error.malformedContainer("truncated test payload record")
    }
    let pathLength = Int(littleEndianUInt16(bytes, at: offset))
    let payloadLength = littleEndianUInt64(bytes, at: offset + 4)
    guard payloadLength <= UInt64(Int.max) else {
        throw PatchPackage.Error.malformedContainer("oversized test payload record")
    }
    let withPath = fixedLength.addingReportingOverflow(pathLength)
    let total = withPath.partialValue.addingReportingOverflow(Int(payloadLength))
    guard !withPath.overflow, !total.overflow,
          offset <= bytes.count - total.partialValue
    else {
        throw PatchPackage.Error.malformedContainer("truncated test payload record")
    }
    return total.partialValue
}

private func littleEndianUInt16(_ bytes: Data, at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func littleEndianUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { result, byte in
        result | UInt32(bytes[offset + byte]) << UInt32(byte * 8)
    }
}

private func littleEndianUInt64(_ bytes: Data, at offset: Int) -> UInt64 {
    (0..<8).reduce(0) { result, byte in
        result | UInt64(bytes[offset + byte]) << UInt64(byte * 8)
    }
}
