import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixInterface
import HelixPatch
import HelixRuntime
import HelixVerifier
import HelixVM
import Testing
@testable import HelixReleaseTools

enum ReleaseToolsTests {}

extension ReleaseToolsTests {
@Suite("Signed release pipeline")
struct Pipeline {
    @Test("Quick-patch recipes resolve archived Xcode identity and local trust safely")
    func quickPatchRecipeAndDevelopmentIdentity() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let identity = try ReleasePipeline.DevelopmentIdentity(
            bundleID: fixture.archive.metadata.bundleID,
            nowUnixSeconds: fixture.now
        )
        #expect(identity.certificate.issuerKeyID == identity.trustedRoot.keyID)
        let leafPublicKey = try identity.signingKey.privateKey().publicKeyRepresentation
        #expect(identity.certificate.publicKey == leafPublicKey)

        let recipe = ReleasePipeline.QuickPatchRecipe(
            packageID: "HLX-quick-patch-test",
            campaignID: "quick-patch-test",
            revision: 7,
            validityDurationSeconds: 3_600,
            purpose: "verify Xcode patch recipe resolution",
            incidentID: "INC-QUICK-7",
            ownerTeam: "Helix",
            distributionPolicyApprovalID: "internal-demo",
            maximumTestedOSVersion: .init(18),
            rollout: .init(
                cohortSalt: Data(repeating: 0x44, count: 32),
                percentageBasisPoints: 10_000
            ),
            approvalPolicyID: "local-development",
            antiRollbackCounter: 7
        )
        let configuration = try recipe.resolve(
            archive: fixture.archive,
            certificate: identity.certificate,
            marketingVersion: "1.0",
            architecture: "arm64",
            platform: .iOS,
            nowUnixSeconds: fixture.now
        )
        #expect(configuration.target.machOUUID == fixture.archive.metadata.machOUUIDs[0])
        #expect(configuration.security.signerKeyID == identity.certificate.keyID)
        #expect(configuration.expiresAtUnixSeconds == fixture.now + 3_600)
    }

    @Test("Changed Swift source becomes a verified and signed HLXP artifact")
    func buildsSignedPackage() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("public func transform(_ x: Int) -> Int { x + 27 }\n".utf8)
            .write(to: fixture.sourceURL)

        let artifact = try ReleasePipeline.Builder().build(fixture.request())
        let rebuilt = try ReleasePipeline.Builder().build(fixture.request())
        #expect(artifact.report.packageID == fixture.configuration.packageID)
        #expect(artifact.report.changedFunctions.count == 1)
        #expect(artifact.report.packageSHA256 == .sha256(artifact.packageBytes))
        #expect(artifact.report.bytecodeSHA256 == .sha256(artifact.compilation.bytecode))
        // CryptoKit may hedge Ed25519 signatures, so reproducibility applies to
        // the compiled payload and signed manifest rather than envelope bytes.
        #expect(rebuilt.compilation.bytecode == artifact.compilation.bytecode)
        #expect(rebuilt.package.manifest == artifact.package.manifest)
        #expect(rebuilt.package.payloads == artifact.package.payloads)

        let decoded = try PatchPackage.Container.decode(artifact.packageBytes)
        #expect(decoded.manifest.payloads.count == 1)
        let payload = try #require(decoded.payloads[fixture.configuration.payloadPath])
        let bytecode = try Bytecode.Decoder.decode(payload)
        #expect(bytecode.module.entries.count == 1)

        let verified = try PatchPackage.Verifier().verify(
            bytes: artifact.packageBytes,
            trustStore: try .init(roots: [fixture.root]),
            targetContext: fixture.targetContext,
            acceptancePolicy: .init(
                acceptedDistributionPolicies: [.internalHLBC],
                approvedDistributionPolicyIDs: ["release-approval"]
            ),
            antiRollbackState: nil,
            nowUnixSeconds: fixture.now
        )
        #expect(verified.selectedPayloads.map(\.path) == [fixture.configuration.payloadPath])

        // Exercise the complete production path rather than merely decoding the
        // artifact that the release builder produced.
        let record = try #require(fixture.archive.functions.first { $0.patchability.isEligible })
        let entry = try #require(record.entryIndex)
        let originals = try Runtime.OriginalCatalog([
            .init(
                index: entry,
                parameterTypes: record.parameterTypes,
                resultType: record.resultType,
                invoke: { arguments in
                    guard case let .integer(value) = arguments.first else {
                        return .trapped(.nativeFailure("fixture expected one Int64 argument"))
                    }
                    return .returned(.integer(try! VM.Integer(
                        signed: value.signedValue + 1,
                        bitWidth: 64,
                        isSigned: true
                    )))
                }
            ),
        ])
        let runtime = Runtime.Engine(
            originals: originals,
            shellInterfaceHash: fixture.archive.shellInterfaceHash
        )
        let storeURL = fixture.directory.appendingPathComponent(
            "PatchStore",
            isDirectory: true
        )
        let store = try PatchStore.Storage(rootURL: storeURL)
        let controller = PatchActivation.Controller(
            runtime: runtime,
            store: store,
            shell: try Verification.ShellInterface(archive: fixture.archive),
            runtimePolicy: .init(
                acceptedCapabilities: artifact.compilation.module.capabilities,
                resourceCeiling: artifact.compilation.module.requestedResources,
                allowedNativeImports: Set(fixture.archive.nativeImports.compactMap(\.id)),
                allowMainActorEntries: artifact.compilation.module.capabilities
                    .contains(.mainActorIsolationV1)
            ),
            trustStore: try .init(roots: [fixture.root]),
            targetContext: fixture.targetContext,
            acceptancePolicy: .init(
                acceptedDistributionPolicies: [.internalHLBC],
                approvedDistributionPolicyIDs: ["release-approval"]
            )
        )
        let generationID = Runtime.GenerationID(rawValue: 1)
        let activated = try controller.installAndActivate(
            packageBytes: artifact.packageBytes,
            generationID: generationID,
            expectedActiveID: nil,
            nowUnixSeconds: fixture.now
        )
        #expect(activated.activatedEntryIndices == [entry])
        let input = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        #expect(
            runtime.invoke(entry: entry, arguments: [.integer(input)])
                == .returned(.integer(try VM.Integer(signed: 30, bitWidth: 64, isSigned: true)))
        )

        let rollback = try controller.rollbackActive(expectedActiveID: generationID)
        #expect(rollback.deactivatedGenerationID == generationID)
        #expect(rollback.restoredGenerationID == nil)
        #expect(try store.activeState() == nil)
        #expect(
            runtime.invoke(entry: entry, arguments: [.integer(input)])
                == .returned(.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("The release builder refuses the App Store channel before compilation")
    func blocksAppStoreDistribution() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var request = fixture.request()
        request.configuration.distributionPolicy = .appStoreHLBC

        #expect(throws: ReleasePipeline.Error.appStoreDistributionBlocked) {
            try ReleasePipeline.Builder().build(request)
        }
    }

    @Test("The release builder accepts only HLBC distribution policies")
    func rejectsControlledNativeDistribution() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var request = fixture.request()
        request.configuration.distributionPolicy = .controlledNative

        #expect(throws: ReleasePipeline.Error.invalidConfiguration(
            "the HLBC release builder accepts only internal or enterprise distribution"
        )) {
            try ReleasePipeline.Builder().build(request)
        }
    }

    @Test("The release compiler requires the complete physical source set")
    func rejectsDuplicateSources() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("public func transform(_ x: Int) -> Int { x + 5 }\n".utf8)
            .write(to: fixture.sourceURL)
        var request = fixture.request()
        request.sourceFiles = [fixture.sourceURL, fixture.sourceURL]

        #expect(throws: ReleaseCompiler.DriverError.sourceSetMismatch(
            "expected 1 files from HLXI, received 2"
        )) {
            try ReleasePipeline.Builder().build(request)
        }
    }

    @Test("CLI builds the same signed release artifact from files")
    func commandLineBuild() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("public func transform(_ x: Int) -> Int { x + 42 }\n".utf8)
            .write(to: fixture.sourceURL)

        let archiveURL = fixture.directory.appendingPathComponent("Shell.hlxi")
        let configurationURL = fixture.directory.appendingPathComponent("Release.json")
        let certificateURL = fixture.directory.appendingPathComponent("Certificate.json")
        let keyURL = fixture.directory.appendingPathComponent("PrivateKey.json")
        let rootURL = fixture.directory.appendingPathComponent("TrustedRoot.json")
        let outputURL = fixture.directory.appendingPathComponent("Patch.hlxp")
        try InterfaceArchive.Codec.encode(fixture.archive).write(to: archiveURL)
        try Core.CanonicalJSON.encode(fixture.configuration).write(to: configurationURL)
        try Core.CanonicalJSON.encode(fixture.certificate).write(to: certificateURL)
        try Core.CanonicalJSON.encode(fixture.signingKey).write(to: keyURL)
        try Core.CanonicalJSON.encode(fixture.root).write(to: rootURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        let result = CLI.Application(currentDirectoryURL: fixture.directory).run([
            "patch", "build",
            "--archive", archiveURL.lastPathComponent,
            "--config", configurationURL.lastPathComponent,
            "--certificate", certificateURL.lastPathComponent,
            "--private-key", keyURL.lastPathComponent,
            "--trusted-root", rootURL.lastPathComponent,
            "--output", outputURL.lastPathComponent,
            fixture.sourceURL.lastPathComponent,
        ])
        #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
        let bytes = try Data(contentsOf: outputURL)
        let package = try PatchPackage.Container.decode(bytes)
        #expect(package.manifest.packageID == fixture.configuration.packageID)
        #expect(package.manifest.payloads[0].changedFunctionKeys.count == 1)
    }
}
}

extension ReleaseToolsTests {
private struct Fixture {
    let directory: URL
    let sourceURL: URL
    let archive: InterfaceArchive.Archive
    let configuration: ReleasePipeline.Configuration
    let certificate: PatchPackage.SigningCertificate
    let signingKey: ReleasePipeline.SigningKeyDocument
    let root: PatchPackage.TrustedRoot
    let targetContext: PatchPackage.TargetContext
    let now: Int64 = 2_000_000_000

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "public func transform(_ x: Int) -> Int { x + 1 }\n"
        try Data(baseline.utf8).write(to: sourceURL)

        let compiler = ReleaseCompiler.Driver()
        let toolchain = try compiler.toolchainIdentity()
        archive = try Self.makeArchive(
            sourceURL: sourceURL,
            baseline: baseline,
            compilerFingerprint: toolchain.fingerprint
        )

        let rootKey = PatchPackage.PrivateKey()
        let leafKey = PatchPackage.PrivateKey()
        certificate = try .issue(
            keyID: "release-leaf",
            leafPublicKey: leafKey.publicKeyRepresentation,
            issuerKeyID: "release-root",
            issuerPrivateKey: rootKey,
            validFromUnixSeconds: now - 10_000,
            validUntilUnixSeconds: now + 10_000,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc],
            allowedBundleIDs: [archive.metadata.bundleID],
            maximumPayloadBytes: 1_024 * 1_024
        )
        signingKey = .init(rawRepresentation: leafKey.rawRepresentation)
        root = .init(
            keyID: "release-root",
            publicKey: rootKey.publicKeyRepresentation,
            validFromUnixSeconds: now - 20_000,
            validUntilUnixSeconds: now + 20_000,
            allowedDistributionPolicies: [.internalHLBC],
            allowedBackends: [.hlbc]
        )
        let machOUUID = archive.metadata.machOUUIDs[0]
        configuration = .init(
            packageID: "HLX-2026-release-pipeline",
            campaignID: "release-pipeline",
            revision: 1,
            createdAtUnixSeconds: now - 100,
            notBeforeUnixSeconds: now - 10,
            expiresAtUnixSeconds: now + 1_000,
            purpose: "repair release pipeline fixture",
            incidentID: "INC-RELEASE-1",
            ownerTeam: "Helix",
            distributionPolicy: .internalHLBC,
            distributionPolicyApprovalID: "release-approval",
            target: .init(
                marketingVersion: "1.0",
                machOUUID: machOUUID,
                architecture: "arm64",
                platform: .iOS,
                maximumTestedOSVersion: .init(18, 9)
            ),
            rollout: .init(
                cohortSalt: Data(repeating: 0x42, count: 32),
                percentageBasisPoints: 10_000
            ),
            security: .init(
                signerKeyID: certificate.keyID,
                approvalPolicyID: "two-person",
                antiRollbackCounter: 1
            )
        )
        targetContext = .init(
            bundleID: archive.metadata.bundleID,
            marketingVersion: configuration.target.marketingVersion,
            buildNumber: archive.metadata.buildNumber,
            shellNamespaceID: archive.metadata.shellNamespaceID,
            machOUUID: machOUUID,
            shellInterfaceHash: archive.shellInterfaceHash,
            architecture: configuration.target.architecture,
            platform: configuration.target.platform,
            operatingSystemVersion: .init(17),
            compatibility: archive.compatibility,
            installationID: "release-test-installation"
        )
    }

    func request() -> ReleasePipeline.BuildRequest {
        .init(
            configuration: configuration,
            archive: archive,
            sourceFiles: [sourceURL],
            certificate: certificate,
            signingKey: signingKey,
            trustedRoot: root
        )
    }

    private static func makeArchive(
        sourceURL: URL,
        baseline: String,
        compilerFingerprint: String
    ) throws -> InterfaceArchive.Archive {
        let moduleName = "ReleasePipelineFixture"
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphoneos")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: moduleName,
            targetTriple: "arm64-apple-ios15.0",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion
        )
        let sil = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let function = try CanonicalSIL.File(text: sil)
            .uniqueFunction(mangledNameContaining: "transform")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.release-pipeline",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.release-pipeline",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: .sha256("release-pipeline-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Patch.swift
        """)
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: "(Swift.Int) -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> Int"
        )
        return try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: .init(
                    runtime: Core.Versions.runtime,
                    bytecode: Core.Versions.bytecode,
                    interfaceArchive: Core.Versions.interfaceArchive,
                    compilerFingerprint: compilerFingerprint
                ),
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Patch.swift", contentHash: .sha256(Data(baseline.utf8))),
                ],
                declarations: [
                    .init(
                        moduleName: moduleName,
                        sourceFileLogicalID: "Patch.swift",
                        canonicalDeclaration: "func transform(_: Int) -> Int",
                        mangledName: function.mangledName,
                        role: .function,
                        loweredSignature: signature,
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: interface,
                        canonicalSILBody: function.body
                    ),
                ]
            )
        ).archive
    }
}
}
