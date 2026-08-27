import Foundation
import HelixBytecode
import HelixCore
import HelixRuntime
import HelixVerifier
import HelixVM
import Testing
@testable import HelixPatch

enum PatchTests {}

extension PatchTests {
@Suite("Signed patch package and activation")
struct Security {
    @Test("A pristine store persists its first launch journal without an active patch")
    func pristineStoreLaunchJournal() throws {
        let directory = try temporaryDirectory(prefix: "helix-pristine-crash-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let guardrail = CrashProtection.Guard(store: store)

        let decision = try guardrail.beginLaunch(
            activeGenerationID: nil,
            parentGenerationID: nil,
            nowUnixSeconds: 100
        )
        guard case let .continueLaunch(sessionNonce) = decision else {
            Issue.record("expected a normal first launch")
            return
        }
        try guardrail.markHealthy(
            sessionNonce: sessionNonce,
            nowUnixSeconds: 101
        )

        let journal: CrashProtection.Journal? = try store.readInternalState(
            CrashProtection.Journal.self,
            name: "crash-guard.json"
        )
        #expect(journal?.health == .healthy)
        #expect(journal?.activeGenerationID == nil)
    }

    @Test("A canonical package verifies against its root, target, policy, and rollout")
    func signedRoundTrip() throws {
        let fixture = try PatchFixture()
        let package = try fixture.package(revision: 7)
        let first = try package.encoded()
        let second = try package.encoded()
        #expect(first == second)

        let verified = try fixture.verify(first)
        #expect(verified.package.manifest.revision == 7)
        #expect(verified.selectedPayloads.map(\.path) == ["variants/fixture.hlbc"])
        #expect(verified.packageHash == Core.Digest.sha256(first))
    }

    @Test("Payload and signature tampering are rejected before activation")
    func rejectsTampering() throws {
        let fixture = try PatchFixture()
        let package = try fixture.package(revision: 1)
        var payloadTamper = try package.encoded()
        let payload = fixture.bytecode
        let range = try #require(payloadTamper.range(of: payload))
        payloadTamper[range.lowerBound] ^= 0x01
        #expect(throws: PatchPackage.Error.self) {
            _ = try PatchPackage.Container.decode(payloadTamper)
        }

        var signatureTamper = package
        signatureTamper.signatureEnvelope.signature[0] ^= 0x01
        let signatureBytes = try signatureTamper.encoded()
        #expect(throws: PatchPackage.Error.invalidPackageSignature) {
            _ = try fixture.verify(signatureBytes)
        }
    }

    @Test("Payload descriptors are validated before a package is signed")
    func rejectsInvalidDescriptorBeforeSigning() throws {
        let fixture = try PatchFixture()
        var manifest = try fixture.package(revision: 2).manifest
        manifest.payloads[0].byteLength += 1

        #expect(throws: PatchPackage.Error.payloadLengthMismatch("variants/fixture.hlbc")) {
            try PatchPackage.Container.signed(
                manifest: manifest,
                payloads: ["variants/fixture.hlbc": fixture.bytecode],
                signer: fixture.signer
            )
        }
    }

    @Test("Target compatibility is checked even when rollout is paused")
    func targetPrecedesRollout() throws {
        let fixture = try PatchFixture()
        let original = try fixture.package(revision: 3)
        var manifest = original.manifest
        manifest.rollout.percentageBasisPoints = 0
        let paused = try PatchPackage.Container.signed(
            manifest: manifest,
            payloads: original.payloads,
            signer: fixture.signer
        )
        var wrongTarget = fixture.targetContext
        wrongTarget.bundleID = "dev.helix.wrong-target"

        #expect(throws: PatchPackage.Error.targetMismatch) {
            _ = try PatchPackage.Verifier().verify(
                bytes: paused.encoded(),
                trustStore: fixture.trustStore,
                targetContext: wrongTarget,
                acceptancePolicy: fixture.acceptancePolicy,
                antiRollbackState: nil,
                nowUnixSeconds: fixture.now
            )
        }
    }

    @Test("Native capability manifest identity is signed and target-bound")
    func nativeCapabilityIdentityIsAuthenticated() throws {
        let fixture = try PatchFixture()
        let package = try fixture.package(revision: 8)

        var wrongRuntime = fixture.targetContext
        wrongRuntime.nativeCapabilityManifestHash = .sha256(
            "different-native-capability-manifest"
        )
        #expect(throws: PatchPackage.Error.targetMismatch) {
            _ = try PatchPackage.Verifier().verify(
                bytes: package.encoded(),
                trustStore: fixture.trustStore,
                targetContext: wrongRuntime,
                acceptancePolicy: fixture.acceptancePolicy,
                antiRollbackState: nil,
                nowUnixSeconds: fixture.now
            )
        }

        var tampered = package
        tampered.manifest.targets[0].nativeCapabilityManifestHash = .sha256(
            "tampered-native-capability-manifest"
        )
        #expect(throws: PatchPackage.Error.invalidPackageSignature) {
            _ = try fixture.verify(tampered.encoded())
        }
    }

    @Test("Conflicting rollout lists are rejected before signing")
    func rejectsConflictingRolloutLists() throws {
        let fixture = try PatchFixture()
        let original = try fixture.package(revision: 4)
        var manifest = original.manifest
        manifest.rollout.installationAllowlist = ["installation-A"]
        manifest.rollout.installationDenylist = ["installation-A"]

        #expect(throws: PatchPackage.Error.invalidManifest(
            "rollout installation lists conflict or contain an empty ID"
        )) {
            try PatchPackage.Container.signed(
                manifest: manifest,
                payloads: original.payloads,
                signer: fixture.signer
            )
        }
    }

    @Test("App Store distribution remains policy-blocked even with a valid signature")
    func productionChannelIsDefaultDenied() throws {
        let fixture = try PatchFixture()
        let bytes = try fixture.package(
            revision: 1,
            distributionPolicy: .appStoreHLBC,
            approvalID: "approval-app-store"
        ).encoded()
        let policy = PatchPackage.AcceptancePolicy(
            acceptedDistributionPolicies: [.appStoreHLBC],
            approvedDistributionPolicyIDs: ["approval-app-store"],
            productionChannelEnabled: false
        )

        #expect(throws: PatchPackage.Error.distributionPolicyDenied(.appStoreHLBC)) {
            _ = try fixture.verify(bytes, acceptancePolicy: policy)
        }
    }

    @Test("An older signed revision cannot roll back a campaign")
    func rejectsRollbackRevision() throws {
        let fixture = try PatchFixture()
        let bytes = try fixture.package(revision: 4).encoded()
        let state = PatchPackage.AntiRollbackState(
            campaignID: fixture.campaignID,
            shellInterfaceHash: fixture.shellHash,
            highestSeenRevision: 5,
            highestSeenCounter: 5
        )

        #expect(throws: PatchPackage.Error.rollbackRevision(highestSeen: 5, received: 4)) {
            _ = try fixture.verify(bytes, antiRollbackState: state)
        }
    }

    @Test("Anti-rollback state cannot cross Shell identities")
    func rejectsAntiRollbackStateFromAnotherShell() throws {
        let fixture = try PatchFixture()
        let bytes = try fixture.package(revision: 4).encoded()
        let state = PatchPackage.AntiRollbackState(
            campaignID: fixture.campaignID,
            shellInterfaceHash: .sha256("another-shell")
        )

        #expect(throws: PatchPackage.Error.invalidManifest(
            "anti-rollback state Shell interface mismatch"
        )) {
            _ = try fixture.verify(bytes, antiRollbackState: state)
        }
    }

    @Test("A verified HLBC package commits one complete generation and executes")
    func activatesVerifiedHLBC() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-patch-activation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try makeActivationHarness(
            fixture: fixture,
            rootURL: directory
        )
        let bytes = try fixture.package(revision: 1).encoded()
        let result = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )

        #expect(result.activatedEntryIndices == [fixture.entry])
        #expect(harness.registry.snapshot().activeGenerationID == .init(rawValue: 1))
        #expect(FileManager.default.fileExists(atPath: result.verifiedPackageURL.path))
        #expect(try harness.store.activeState()?.generationID == .init(rawValue: 1))

        let image = try #require(result.generationLease.generation.images.first)
        let input = try VM.Integer(signed: 41, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: image,
                arguments: [.integer(input)]
            ) == .returned(.integer(input))
        )
    }

    @Test("Reapplying the exact active package does not create another generation")
    func identicalPackageActivationIsIdempotent() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-patch-idempotency")
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try makeActivationHarness(
            fixture: fixture,
            rootURL: directory
        )
        let bytes = try fixture.package(revision: 1).encoded()
        let first = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        let replay = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 2),
            expectedActiveID: .init(rawValue: 1),
            nowUnixSeconds: fixture.now + 1
        )
        let staleReplay = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 3),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now + 2
        )

        #expect(first.generationLease.generation.id == .init(rawValue: 1))
        #expect(replay.generationLease.generation.id == .init(rawValue: 1))
        #expect(staleReplay.generationLease.generation.id == .init(rawValue: 1))
        #expect(replay.verifiedPackageURL == first.verifiedPackageURL)
        #expect(replay.activatedEntryIndices == [fixture.entry])
        let snapshot = harness.registry.snapshot()
        #expect(snapshot.activeGenerationID == .init(rawValue: 1))
        #expect(snapshot.highestActivatedGenerationID == .init(rawValue: 1))
        #expect(snapshot.loadedGenerationIDs == [.init(rawValue: 1)])
        #expect(try harness.store.activeState()?.generationID == .init(rawValue: 1))
    }

    @Test("Reapplying the active package still enforces current validity")
    func identicalPackageReplayDoesNotBypassVerification() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-patch-expired-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try makeActivationHarness(
            fixture: fixture,
            rootURL: directory
        )
        let bytes = try fixture.package(revision: 1).encoded()
        _ = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )

        #expect(throws: PatchPackage.Error.expired) {
            _ = try harness.controller.installAndActivate(
                packageBytes: bytes,
                generationID: .init(rawValue: 2),
                expectedActiveID: .init(rawValue: 1),
                nowUnixSeconds: fixture.now + 1_001
                    + fixture.acceptancePolicy.clockSkewAllowanceSeconds
            )
        }

        let snapshot = harness.registry.snapshot()
        #expect(snapshot.activeGenerationID == .init(rawValue: 1))
        #expect(snapshot.highestActivatedGenerationID == .init(rawValue: 1))
        #expect(snapshot.loadedGenerationIDs == [.init(rawValue: 1)])
        #expect(try harness.store.activeState()?.generationID == .init(rawValue: 1))
    }

    @Test("Activation rejects divergent runtime and persistent active state")
    func rejectsDivergentActiveState() throws {
        let fixture = try PatchFixture()
        let directory = try temporaryDirectory(prefix: "helix-patch-state-divergence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try makeActivationHarness(
            fixture: fixture,
            rootURL: directory
        )
        let bytes = try fixture.package(revision: 1).encoded()
        _ = try harness.controller.installAndActivate(
            packageBytes: bytes,
            generationID: .init(rawValue: 1),
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        #expect(
            try harness.store.rollbackToLastKnownGood(
                expectedActiveID: .init(rawValue: 1)
            ) == nil
        )

        #expect(throws: PatchPackage.Error.activationPersistence(
            "memory and persistent active generations disagree"
        )) {
            _ = try harness.controller.installAndActivate(
                packageBytes: bytes,
                generationID: .init(rawValue: 2),
                expectedActiveID: .init(rawValue: 1),
                nowUnixSeconds: fixture.now + 1
            )
        }

        let snapshot = harness.registry.snapshot()
        #expect(snapshot.activeGenerationID == .init(rawValue: 1))
        #expect(snapshot.highestActivatedGenerationID == .init(rawValue: 1))
        #expect(snapshot.loadedGenerationIDs == [.init(rawValue: 1)])
        #expect(try harness.store.activeState() == nil)
    }

    @Test("Interrupted activation and repeated unclean launch choose the conservative parent")
    func recoversActivationAndCrashLoop() throws {
        let directory = try temporaryDirectory(prefix: "helix-crash-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PatchStore.Storage(rootURL: directory)
        let parentPending = PatchStore.PendingActivation(
            targetGenerationID: .init(rawValue: 1),
            parentGenerationID: nil,
            packageID: "HLX-parent",
            packageHash: .sha256("parent"),
            signerKeyID: "leaf-1",
            nonce: UUID(),
            createdAtUnixSeconds: 99
        )
        try store.beginActivation(parentPending)
        try store.commitActivation(
            .init(
                generationID: parentPending.targetGenerationID,
                parentGenerationID: nil,
                packageID: parentPending.packageID,
                packageHash: parentPending.packageHash,
                signerKeyID: parentPending.signerKeyID,
                activationNonce: parentPending.nonce,
                committedAtUnixSeconds: 99
            )
        )
        try store.markActiveHealthy(
            expectedActiveID: parentPending.targetGenerationID,
            nowUnixSeconds: 99
        )
        let pending = PatchStore.PendingActivation(
            targetGenerationID: .init(rawValue: 2),
            parentGenerationID: .init(rawValue: 1),
            packageID: "HLX-fixture",
            packageHash: .sha256("fixture"),
            signerKeyID: "leaf-1",
            nonce: UUID(),
            createdAtUnixSeconds: 100
        )
        try store.beginActivation(pending)
        #expect(
            try store.recoverInterruptedActivation()
                == .init(
                    interruptedTarget: .init(rawValue: 2),
                    conservativeRollbackTarget: .init(rawValue: 1),
                    packageID: "HLX-fixture",
                    packageHash: .sha256("fixture")
                )
        )

        let guardrail = CrashProtection.Guard(store: store, uncleanLaunchThreshold: 1)
        _ = try guardrail.beginLaunch(
            activeGenerationID: .init(rawValue: 1),
            parentGenerationID: nil,
            activePackageHash: parentPending.packageHash,
            nowUnixSeconds: 101
        )
        let decision = try guardrail.beginLaunch(
            activeGenerationID: .init(rawValue: 1),
            parentGenerationID: nil,
            activePackageHash: parentPending.packageHash,
            nowUnixSeconds: 102
        )
        guard case let .rollback(interrupted, target, nonce) = decision else {
            Issue.record("expected Crash Guard rollback")
            return
        }
        #expect(interrupted == .init(rawValue: 1))
        #expect(target == nil)
        try guardrail.markHealthy(sessionNonce: nonce, nowUnixSeconds: 103)
    }

    private func makeActivationHarness(
        fixture: PatchFixture,
        rootURL: URL
    ) throws -> (
        store: PatchStore.Storage,
        registry: Runtime.GenerationRegistry,
        controller: PatchActivation.Controller
    ) {
        let store = try PatchStore.Storage(rootURL: rootURL)
        let registry = Runtime.GenerationRegistry()
        let originals = try Runtime.OriginalCatalog([
            .init(
                index: fixture.entry,
                parameterTypes: [.int64],
                resultType: .int64,
                invoke: { arguments in .returned(arguments.first) }
            ),
        ])
        let runtime = Runtime.Engine(
            registry: registry,
            originals: originals,
            shellInterfaceHash: fixture.shellHash
        )
        return (
            store,
            registry,
            PatchActivation.Controller(
                runtime: runtime,
                store: store,
                shell: fixture.shell,
                runtimePolicy: .init(),
                trustStore: fixture.trustStore,
                targetContext: fixture.targetContext,
                acceptancePolicy: fixture.acceptancePolicy
            )
        )
    }
}
}

extension PatchTests {
struct PatchFixture {
    let now: Int64 = 2_000_000_000
    let campaignID = "checkout-incident"
    let shellHash = Core.Digest.sha256("patch-shell")
    let namespace = Core.ShellNamespaceID.derive(
        bundleID: "dev.helix.fixture",
        buildNumber: "42",
        seed: "patch-tests"
    )
    let machOUUID = UUID(uuidString: "2A6AC14E-5984-4AE5-A562-0E8BC5276425")!
    let compatibility = Core.Compatibility(
        runtime: Core.Versions.runtime,
        bytecode: Core.Versions.bytecode,
        interfaceArchive: Core.Versions.interfaceArchive,
        compilerFingerprint: "swift-patch-fixture"
    )
    let entry = Core.EntryIndex(rawValue: 7)
    let functionKey: Core.FunctionKey
    let bytecode: Data
    let shell: Verification.ShellInterface
    let signer: PatchPackage.Signer
    let revocationKey: PatchPackage.PrivateKey
    let trustStore: PatchPackage.TrustStore
    let targetContext: PatchPackage.TargetContext
    let acceptancePolicy: PatchPackage.AcceptancePolicy

    init() throws {
        functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        let module = Bytecode.Module(
            name: "PatchFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            functions: [function],
            entries: [
                .init(entryIndex: entry, functionKey: functionKey, functionID: function.id),
            ]
        )
        bytecode = try Bytecode.Encoder.encode(module)
        shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    parameterConventions: function.parameterConventions,
                    resultType: .int64
                ),
            ]
        )

        let rootKey = PatchPackage.PrivateKey()
        let leafKey = PatchPackage.PrivateKey()
        let policies: Set<Core.DistributionPolicy> = [
            .internalHLBC, .enterpriseHLBC, .appStoreHLBC,
        ]
        let certificate = try PatchPackage.SigningCertificate.issue(
            keyID: "leaf-1",
            leafPublicKey: leafKey.publicKeyRepresentation,
            issuerKeyID: "root-1",
            issuerPrivateKey: rootKey,
            validFromUnixSeconds: now - 10_000,
            validUntilUnixSeconds: now + 10_000,
            allowedDistributionPolicies: policies,
            allowedBackends: [.hlbc],
            allowedBundleIDs: ["dev.helix.fixture"],
            maximumPayloadBytes: 1_024 * 1_024
        )
        signer = try PatchPackage.Signer(certificate: certificate, privateKey: leafKey)
        revocationKey = PatchPackage.PrivateKey()
        trustStore = try PatchPackage.TrustStore(
            roots: [
                .init(
                    keyID: "root-1",
                    publicKey: rootKey.publicKeyRepresentation,
                    validFromUnixSeconds: now - 20_000,
                    validUntilUnixSeconds: now + 20_000,
                    allowedDistributionPolicies: policies,
                    allowedBackends: [.hlbc]
                ),
            ],
            revocationAuthorities: [
                .init(
                    keyID: "revocation-1",
                    publicKey: revocationKey.publicKeyRepresentation,
                    validFromUnixSeconds: now - 20_000,
                    validUntilUnixSeconds: now + 20_000
                ),
            ]
        )
        targetContext = .init(
            bundleID: "dev.helix.fixture",
            marketingVersion: "1.0",
            buildNumber: "42",
            shellNamespaceID: namespace,
            machOUUID: machOUUID,
            shellInterfaceHash: shellHash,
            nativeCapabilityManifestHash: .sha256("fixture-native-capabilities"),
            architecture: "arm64",
            platform: .iOSSimulator,
            operatingSystemVersion: .init(18, 0, 0),
            compatibility: compatibility,
            installationID: "install-A"
        )
        acceptancePolicy = .init(
            acceptedDistributionPolicies: [.internalHLBC],
            approvedDistributionPolicyIDs: ["approval-internal"]
        )
    }

    func package(
        revision: UInt64,
        distributionPolicy: Core.DistributionPolicy = .internalHLBC,
        approvalID: String = "approval-internal",
        rollback: PatchPackage.RollbackPlan = .init()
    ) throws -> PatchPackage.Container {
        let target = PatchPackage.Target(
            bundleID: targetContext.bundleID,
            marketingVersion: targetContext.marketingVersion,
            buildNumber: targetContext.buildNumber,
            shellNamespaceID: namespace,
            machOUUID: machOUUID,
            shellInterfaceHash: shellHash,
            nativeCapabilityManifestHash:
                targetContext.nativeCapabilityManifestHash,
            architecture: targetContext.architecture,
            platform: targetContext.platform,
            minimumOSVersion: .init(17, 0, 0),
            maximumTestedOSVersion: .init(18, 9, 0),
            compatibility: compatibility
        )
        let descriptor = PatchPackage.PayloadDescriptor(
            backend: .hlbc,
            targetIndex: 0,
            path: "variants/fixture.hlbc",
            byteLength: UInt64(bytecode.count),
            sha256: .sha256(bytecode),
            changedFunctionKeys: [functionKey],
            entryIndices: [entry],
            capabilities: [.baselineV1],
            quotas: .init()
        )
        let manifest = PatchPackage.Manifest(
            packageID: "HLX-2026-\(revision)",
            campaignID: campaignID,
            revision: revision,
            createdAtUnixSeconds: now - 100,
            notBeforeUnixSeconds: now - 10,
            expiresAtUnixSeconds: now + 1_000,
            purpose: "repair identity fixture",
            incidentID: "INC-42",
            ownerTeam: "Helix",
            distributionPolicy: distributionPolicy,
            distributionPolicyApprovalID: approvalID,
            targets: [target],
            payloads: [descriptor],
            rollout: .init(
                cohortSalt: Data(repeating: 0x42, count: 32),
                percentageBasisPoints: 10_000
            ),
            rollback: rollback,
            security: .init(
                signerKeyID: "leaf-1",
                approvalPolicyID: "two-person",
                antiRollbackCounter: revision
            )
        )
        return try .signed(
            manifest: manifest,
            payloads: [descriptor.path: bytecode],
            signer: signer
        )
    }

    func verify(
        _ bytes: Data,
        acceptancePolicy: PatchPackage.AcceptancePolicy? = nil,
        antiRollbackState: PatchPackage.AntiRollbackState? = nil
    ) throws -> PatchPackage.VerifiedPackage {
        try PatchPackage.Verifier().verify(
            bytes: bytes,
            trustStore: trustStore,
            targetContext: targetContext,
            acceptancePolicy: acceptancePolicy ?? self.acceptancePolicy,
            antiRollbackState: antiRollbackState,
            nowUnixSeconds: now
        )
    }
}
}

func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
