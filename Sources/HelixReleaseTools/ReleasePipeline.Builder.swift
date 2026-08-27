import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import HelixPatch
import HelixVerifier

extension ReleasePipeline {
public struct BuildRequest: Sendable {
    public var configuration: ReleasePipeline.Configuration
    public var archive: InterfaceArchive.Archive
    public var sources: ReleaseCompiler.SourceSet
    public var selectedFunctionKeys: Set<Core.FunctionKey>?
    public var compilerURL: URL
    public var signingService: any PatchPackage.SignatureProviding
    public var trustedRoot: PatchPackage.TrustedRoot
    public var invocationObserver: SwiftFrontend.InvocationObserver?

    public var certificate: PatchPackage.SigningCertificate {
        signingService.certificate
    }

    public init(
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive,
        sourceFiles: [URL],
        selectedFunctionKeys: Set<Core.FunctionKey>? = nil,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        certificate: PatchPackage.SigningCertificate,
        signingKey: ReleasePipeline.SigningKeyDocument,
        trustedRoot: PatchPackage.TrustedRoot,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.configuration = configuration
        self.archive = archive
        sources = .files(sourceFiles)
        self.selectedFunctionKeys = selectedFunctionKeys
        self.compilerURL = compilerURL
        signingService = ReleasePipeline.LocalSigningService(
            certificate: certificate,
            signingKey: signingKey
        )
        self.trustedRoot = trustedRoot
        self.invocationObserver = invocationObserver
    }

    public init(
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive,
        sourceMappings: [String: URL],
        selectedFunctionKeys: Set<Core.FunctionKey>? = nil,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        certificate: PatchPackage.SigningCertificate,
        signingKey: ReleasePipeline.SigningKeyDocument,
        trustedRoot: PatchPackage.TrustedRoot,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.configuration = configuration
        self.archive = archive
        sources = .mappings(sourceMappings)
        self.selectedFunctionKeys = selectedFunctionKeys
        self.compilerURL = compilerURL
        signingService = ReleasePipeline.LocalSigningService(
            certificate: certificate,
            signingKey: signingKey
        )
        self.trustedRoot = trustedRoot
        self.invocationObserver = invocationObserver
    }

    public init(
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive,
        sourceFiles: [URL],
        selectedFunctionKeys: Set<Core.FunctionKey>? = nil,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        signingService: any PatchPackage.SignatureProviding,
        trustedRoot: PatchPackage.TrustedRoot,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.configuration = configuration
        self.archive = archive
        sources = .files(sourceFiles)
        self.selectedFunctionKeys = selectedFunctionKeys
        self.compilerURL = compilerURL
        self.signingService = signingService
        self.trustedRoot = trustedRoot
        self.invocationObserver = invocationObserver
    }

    public init(
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive,
        sourceMappings: [String: URL],
        selectedFunctionKeys: Set<Core.FunctionKey>? = nil,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        signingService: any PatchPackage.SignatureProviding,
        trustedRoot: PatchPackage.TrustedRoot,
        invocationObserver: SwiftFrontend.InvocationObserver? = nil
    ) {
        self.configuration = configuration
        self.archive = archive
        sources = .mappings(sourceMappings)
        self.selectedFunctionKeys = selectedFunctionKeys
        self.compilerURL = compilerURL
        self.signingService = signingService
        self.trustedRoot = trustedRoot
        self.invocationObserver = invocationObserver
    }
}

public struct BuildArtifact: Sendable {
    public var compilation: ReleaseCompiler.BuildResult
    public var package: PatchPackage.Container
    public var packageBytes: Data
    public var report: ReleasePipeline.Report
}

public struct Builder: Sendable {
    public init() {}

    public func build(_ request: ReleasePipeline.BuildRequest) throws -> ReleasePipeline.BuildArtifact {
        try request.archive.validate()
        try validate(request)
        let nativeCapabilityManifest = try request.archive
            .nativeCapabilityManifest()
        let nativeCapabilityManifestHash = try nativeCapabilityManifest
            .contentHash()

        let compilation = try ReleaseCompiler.Driver().build(
            .init(
                archive: request.archive,
                sources: request.sources,
                selectedFunctionKeys: request.selectedFunctionKeys,
                compilerURL: request.compilerURL,
                enforceToolchainFingerprint: true,
                requestedResources: request.configuration.requestedResources,
                invocationObserver: request.invocationObserver
            )
        )
        try verifyBytecode(compilation, archive: request.archive)

        let changed = try compilation.changedFunctions.map { record -> ReleasePipeline.ChangedFunction in
            guard let entryIndex = record.entryIndex,
                  let bodyFingerprint = compilation.bodyFingerprints[record.key]
            else {
                throw ReleasePipeline.Error.selfVerificationFailed(
                    "compiled function is missing its entry or body fingerprint"
                )
            }
            return .init(
                functionKey: record.key,
                entryIndex: entryIndex,
                declaration: record.canonicalDeclaration,
                bodyFingerprint: bodyFingerprint
            )
        }.sorted {
            if $0.entryIndex != $1.entryIndex { return $0.entryIndex < $1.entryIndex }
            return $0.functionKey.rawValue < $1.functionKey.rawValue
        }

        let target = try makeTarget(
            configuration: request.configuration,
            archive: request.archive
        )
        let descriptor = PatchPackage.PayloadDescriptor(
            backend: .hlbc,
            targetIndex: 0,
            path: request.configuration.payloadPath,
            byteLength: UInt64(compilation.bytecode.count),
            sha256: .sha256(compilation.bytecode),
            changedFunctionKeys: changed.map(\.functionKey),
            entryIndices: changed.map(\.entryIndex),
            capabilities: compilation.module.capabilities,
            quotas: request.configuration.requestedResources
        )
        let manifest = PatchPackage.Manifest(
            packageID: request.configuration.packageID,
            campaignID: request.configuration.campaignID,
            revision: request.configuration.revision,
            createdAtUnixSeconds: request.configuration.createdAtUnixSeconds,
            notBeforeUnixSeconds: request.configuration.notBeforeUnixSeconds,
            expiresAtUnixSeconds: request.configuration.expiresAtUnixSeconds,
            purpose: request.configuration.purpose,
            incidentID: request.configuration.incidentID,
            ownerTeam: request.configuration.ownerTeam,
            distributionPolicy: request.configuration.distributionPolicy,
            distributionPolicyApprovalID: request.configuration.distributionPolicyApprovalID,
            targets: [target],
            payloads: [descriptor],
            rollout: request.configuration.rollout,
            rollback: request.configuration.rollback,
            security: request.configuration.security
        )
        let package = try PatchPackage.Container.signed(
            manifest: manifest,
            payloads: [descriptor.path: compilation.bytecode],
            signer: request.signingService
        )
        let packageBytes = try package.encoded()
        try verifyPackage(
            packageBytes,
            configuration: request.configuration,
            archive: request.archive,
            trustedRoot: request.trustedRoot
        )

        let report = ReleasePipeline.Report(
            packageID: manifest.packageID,
            packageSHA256: .sha256(packageBytes),
            packageByteLength: UInt64(packageBytes.count),
            bytecodeSHA256: descriptor.sha256,
            bytecodeByteLength: descriptor.byteLength,
            shellInterfaceHash: request.archive.shellInterfaceHash,
            nativeCapabilityManifestHash: nativeCapabilityManifestHash,
            toolchainFingerprint: compilation.toolchain.fingerprint,
            capabilities: compilation.module.capabilities.sorted(),
            changedFunctions: changed,
            signingKeyID: request.certificate.keyID,
            signingRootKeyID: request.trustedRoot.keyID
        )
        return .init(
            compilation: compilation,
            package: package,
            packageBytes: packageBytes,
            report: report
        )
    }

    private func validate(_ request: ReleasePipeline.BuildRequest) throws {
        let configuration = request.configuration
        guard configuration.schemaVersion == ReleasePipeline.Configuration.currentSchemaVersion else {
            throw ReleasePipeline.Error.invalidConfiguration("unsupported schema version")
        }
        guard configuration.distributionPolicy != .appStoreHLBC else {
            throw ReleasePipeline.Error.appStoreDistributionBlocked
        }
        guard configuration.distributionPolicy == .internalHLBC
                || configuration.distributionPolicy == .enterpriseHLBC
        else {
            throw ReleasePipeline.Error.invalidConfiguration(
                "the HLBC release builder accepts only internal or enterprise distribution"
            )
        }
        guard request.archive.metadata.machOUUIDs.contains(configuration.target.machOUUID) else {
            throw ReleasePipeline.Error.targetUUIDNotInArchive(configuration.target.machOUUID)
        }
        guard configuration.target.maximumTestedOSVersion >= request.archive.metadata.minimumOS else {
            throw ReleasePipeline.Error.invalidConfiguration(
                "maximum tested OS is older than the Shell minimum OS"
            )
        }
        try validateTargetTriple(
            request.archive.metadata.targetTriple,
            target: configuration.target
        )
        guard configuration.security.signerKeyID == request.certificate.keyID else {
            throw ReleasePipeline.Error.signerKeyIDMismatch(
                expected: configuration.security.signerKeyID,
                actual: request.certificate.keyID
            )
        }
        guard request.certificate.issuerKeyID == request.trustedRoot.keyID else {
            throw ReleasePipeline.Error.rootKeyIDMismatch(
                expected: request.certificate.issuerKeyID,
                actual: request.trustedRoot.keyID
            )
        }
    }

    private func validateTargetTriple(
        _ triple: String,
        target: ReleasePipeline.TargetConfiguration
    ) throws {
        let normalized = triple.lowercased()
        guard normalized.hasPrefix(target.architecture.lowercased() + "-") else {
            throw ReleasePipeline.Error.targetTripleMismatch(
                "architecture \(target.architecture) does not match \(triple)"
            )
        }
        guard normalized.contains("-apple-ios") else {
            throw ReleasePipeline.Error.targetTripleMismatch("\(triple) is not an iOS triple")
        }
        let isSimulator = normalized.contains("simulator")
        switch target.platform {
        case .iOS where isSimulator:
            throw ReleasePipeline.Error.targetTripleMismatch("device target uses a simulator triple")
        case .iOSSimulator where !isSimulator:
            throw ReleasePipeline.Error.targetTripleMismatch("simulator target uses a device triple")
        case .iOS, .iOSSimulator:
            break
        }
    }

    private func makeTarget(
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive
    ) throws -> PatchPackage.Target {
        let nativeCapabilityManifest = try archive.nativeCapabilityManifest()
        return .init(
            bundleID: archive.metadata.bundleID,
            marketingVersion: configuration.target.marketingVersion,
            buildNumber: archive.metadata.buildNumber,
            shellNamespaceID: archive.metadata.shellNamespaceID,
            machOUUID: configuration.target.machOUUID,
            shellInterfaceHash: archive.shellInterfaceHash,
            nativeCapabilityManifestHash: try nativeCapabilityManifest
                .contentHash(),
            architecture: configuration.target.architecture,
            platform: configuration.target.platform,
            minimumOSVersion: archive.metadata.minimumOS,
            maximumTestedOSVersion: configuration.target.maximumTestedOSVersion,
            compatibility: archive.compatibility
        )
    }

    private func verifyBytecode(
        _ compilation: ReleaseCompiler.BuildResult,
        archive: InterfaceArchive.Archive
    ) throws {
        let allowedCalls = try archive.nativeCapabilityManifest()
            .nativeCallKeys
        let policy = Core.RuntimePolicy(
            acceptedCapabilities: compilation.module.capabilities,
            resourceCeiling: compilation.module.requestedResources,
            allowedNativeCalls: allowedCalls,
            allowMainActorEntries: compilation.module.capabilities.contains(.mainActorIsolationV1)
        )
        _ = try Verification.Engine().verify(
            bytes: compilation.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: policy
        )
    }

    private func verifyPackage(
        _ bytes: Data,
        configuration: ReleasePipeline.Configuration,
        archive: InterfaceArchive.Archive,
        trustedRoot: PatchPackage.TrustedRoot
    ) throws {
        let trustStore = try PatchPackage.TrustStore(roots: [trustedRoot])
        let target = try makeTarget(
            configuration: configuration,
            archive: archive
        )
        let context = PatchPackage.TargetContext(
            bundleID: target.bundleID,
            marketingVersion: target.marketingVersion,
            buildNumber: target.buildNumber,
            shellNamespaceID: target.shellNamespaceID,
            machOUUID: target.machOUUID,
            shellInterfaceHash: target.shellInterfaceHash,
            nativeCapabilityManifestHash: target.nativeCapabilityManifestHash,
            architecture: target.architecture,
            platform: target.platform,
            operatingSystemVersion: target.minimumOSVersion,
            compatibility: target.compatibility,
            installationID: configuration.rollout.installationAllowlist.sorted().first
                ?? "helix-release-self-check"
        )
        let policy = PatchPackage.AcceptancePolicy(
            acceptedDistributionPolicies: [configuration.distributionPolicy],
            approvedDistributionPolicyIDs: [configuration.distributionPolicyApprovalID]
        )
        do {
            _ = try PatchPackage.Verifier().verify(
                bytes: bytes,
                trustStore: trustStore,
                targetContext: context,
                acceptancePolicy: policy,
                antiRollbackState: nil,
                nowUnixSeconds: configuration.notBeforeUnixSeconds
            )
        } catch PatchPackage.Error.rolloutExcluded {
            // Signature, trust, time, and policy checks precede rollout selection.
        } catch {
            throw ReleasePipeline.Error.selfVerificationFailed(String(describing: error))
        }
    }
}
}
