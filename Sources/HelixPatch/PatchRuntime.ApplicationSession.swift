import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixRuntime
import HelixVerifier
#endif

extension PatchRuntime {
/// The application-owned entry point for production HLBC hot patching.
///
/// `ApplicationSession` loads the hidden Bridge linked into the App, validates
/// the running executable against the frozen Shell contract, restores the last
/// committed generation, and owns installation, rollback, and crash protection.
/// Keep one instance alive for the application process lifetime.
///
/// ```swift
/// let session = try PatchRuntime.ApplicationSession(
///     installationID: installationID,
///     storeRootURL: patchStoreURL,
///     trustStore: trustStore,
///     acceptancePolicy: acceptancePolicy,
///     nowUnixSeconds: Int64(Date().timeIntervalSince1970)
/// )
/// ```
///
/// Calls that mutate activation state are serialized. Package verification is
/// fail-closed: an invalid signature, target, policy, rollout, or revision does
/// not replace the active generation.
public final class ApplicationSession: @unchecked Sendable {
    /// The frozen Shell contract embedded in the linked Bridge.
    public let build: PatchRuntime.BuildContract
    /// Identity measured from the currently running App executable.
    public let process: PatchRuntime.ProcessIdentity
    /// The verified HLBC execution engine.
    public let runtime: Runtime.Engine
    /// Durable activation, rollback, and crash-protection storage.
    public let store: PatchStore.Storage
    /// The lower-level package verification and activation controller.
    public let activation: PatchActivation.Controller
    /// Launch recovery and health coordinator.
    public let launch: PatchLaunch.Coordinator
    /// Recovery result produced while this session was initialized.
    public let launchResult: PatchLaunch.Result

    private let operationLock = NSLock()

    /// Creates the production runtime graph from the hidden Bridge linked by
    /// the Helix Xcode phase. Application code supplies only product policy and
    /// storage values; it never imports or references generated Swift code.
    ///
    /// - Parameters:
    ///   - installationID: A stable, non-secret identifier used for rollout
    ///     selection. Persist it across launches for one App installation.
    ///   - storeRootURL: A private Application Support directory owned by Helix.
    ///   - trustStore: Trusted signing roots and current revocation state.
    ///   - acceptancePolicy: Product policy for distribution and OS qualification.
    ///   - resourceCeiling: Maximum VM resources accepted from any package.
    ///   - nowUnixSeconds: Current wall-clock time used for validity and recovery.
    ///   - bridgeProvider: An explicit provider for tests. Production code should
    ///     use the default linked provider.
    ///   - process: An explicit process identity for tests. Production code
    ///     should let Helix inspect the main bundle.
    /// - Throws: ``PatchRuntime/Error`` or a package/store error when the linked
    ///   Shell, running process, or persisted state is invalid.
    public convenience init(
        installationID: String,
        storeRootURL: URL,
        trustStore: PatchPackage.TrustStore,
        acceptancePolicy: PatchPackage.AcceptancePolicy,
        resourceCeiling: Core.ResourceLimits = .init(),
        nowUnixSeconds: Int64,
        bridgeProvider: Runtime.BridgeProvider? = nil,
        process: PatchRuntime.ProcessIdentity? = nil
    ) throws {
        let provider: Runtime.BridgeProvider
        if let bridgeProvider {
            provider = bridgeProvider
        } else {
            provider = try Runtime.LinkedBridge.load()
        }
        let runtime = try provider.makeRuntime()
        try self.init(
            build: PatchRuntime.BuildContract(bridge: provider.descriptor),
            process: process,
            installationID: installationID,
            runtime: runtime,
            shell: provider.makeShellInterface(),
            installBridge: provider.install(on:),
            storeRootURL: storeRootURL,
            trustStore: trustStore,
            acceptancePolicy: acceptancePolicy,
            resourceCeiling: resourceCeiling,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    /// Creates a session from explicitly assembled Runtime components.
    ///
    /// This initializer is intended for tests, alternate build adapters, and
    /// Helix integration tooling. Applications using the Xcode integration
    /// should use the linked-Bridge convenience initializer.
    public init(
        build: PatchRuntime.BuildContract,
        process: PatchRuntime.ProcessIdentity? = nil,
        installationID: String,
        runtime: Runtime.Engine,
        shell: Verification.ShellInterface,
        installBridge: (Runtime.Engine) throws -> Void,
        storeRootURL: URL,
        trustStore: PatchPackage.TrustStore,
        acceptancePolicy: PatchPackage.AcceptancePolicy,
        resourceCeiling: Core.ResourceLimits = .init(),
        nowUnixSeconds: Int64
    ) throws {
        try build.validate()
        let process = try process ?? .current()
        try process.validate()
        guard process.bundleID == build.bundleID else {
            throw PatchRuntime.Error.buildMismatch("bundle ID")
        }
        guard runtime.shellInterfaceHash == build.shellInterfaceHash,
              shell.interfaceHash == build.shellInterfaceHash
        else {
            throw PatchRuntime.Error.runtimeShellMismatch
        }
        try runtime.validateNativeCapabilities(
            against: build.nativeCapabilityManifest,
            shell: shell
        )
        try installBridge(runtime)
        guard Runtime.Bridge.shared.installedInterfaceHash == build.shellInterfaceHash else {
            throw PatchRuntime.Error.bridgeNotInstalled
        }
        let store = try PatchStore.Storage(rootURL: storeRootURL)
        let target = try build.targetContext(
            process: process,
            installationID: installationID
        )
        let activation = PatchActivation.Controller(
            runtime: runtime,
            store: store,
            shell: shell,
            runtimePolicy: build.runtimePolicy(resourceCeiling: resourceCeiling),
            trustStore: trustStore,
            targetContext: target,
            acceptancePolicy: acceptancePolicy
        )
        let launch = PatchLaunch.Coordinator(
            activation: activation,
            crashGuard: .init(store: store)
        )
        self.build = build
        self.process = process
        self.runtime = runtime
        self.store = store
        self.activation = activation
        self.launch = launch
        launchResult = try launch.prepareLaunch(nowUnixSeconds: nowUnixSeconds)
    }

    /// Verifies and atomically activates an in-memory `.hlxp` package.
    ///
    /// ```swift
    /// let result = try session.install(
    ///     packageBytes: downloadedBytes,
    ///     nowUnixSeconds: now
    /// )
    /// print(result.activatedEntryIndices)
    /// ```
    ///
    /// - Parameters:
    ///   - packageBytes: The complete encoded patch package.
    ///   - nowUnixSeconds: Current wall-clock time for validity checks.
    /// - Returns: The committed generation and activated entry inventory.
    ///   Reinstalling the exact active package returns its existing generation
    ///   without allocating or publishing another generation.
    public func install(
        packageBytes: Data,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result {
        try operationLock.withLock {
            let active = runtime.registry.snapshot().activeGenerationID
            let result = try activation.installAndActivate(
                packageBytes: packageBytes,
                generationID: try nextGenerationID(),
                expectedActiveID: active,
                nowUnixSeconds: nowUnixSeconds
            )
            try retargetCrashGuardAfterNewActivation(
                result,
                previousActiveID: active,
                nowUnixSeconds: nowUnixSeconds
            )
            return result
        }
    }

    /// Streams, verifies, and atomically activates a package from a local file.
    ///
    /// This is suitable after an application-owned downloader has placed a
    /// package in a private inbox. The file still passes through the same size,
    /// digest, signature, policy, and anti-rollback verification as bytes.
    ///
    /// - Parameters:
    ///   - localPackageURL: A regular file containing one complete `.hlxp`.
    ///   - expectedSHA256: An optional transport digest checked before activation.
    ///   - nowUnixSeconds: Current wall-clock time for validity checks.
    public func install(
        localPackageURL: URL,
        expectedSHA256: Core.Digest? = nil,
        nowUnixSeconds: Int64
    ) throws -> PatchActivation.Result {
        try operationLock.withLock {
            let artifact = try PatchDownload.LocalFileTransport().receive(
                from: localPackageURL,
                into: store,
                expectedSHA256: expectedSHA256
            )
            let active = runtime.registry.snapshot().activeGenerationID
            let result = try activation.installAndActivate(
                artifact: artifact,
                generationID: try nextGenerationID(),
                expectedActiveID: active,
                nowUnixSeconds: nowUnixSeconds
            )
            try retargetCrashGuardAfterNewActivation(
                result,
                previousActiveID: active,
                nowUnixSeconds: nowUnixSeconds
            )
            return result
        }
    }

    /// Rolls back the active patch to its committed parent generation.
    ///
    /// - Parameter nowUnixSeconds: Current wall-clock time for crash-journal
    ///   retargeting.
    /// - Returns: Rollback details, or `nil` when the original App body is
    ///   already active.
    public func rollback(nowUnixSeconds: Int64) throws -> PatchActivation.RollbackResult? {
        try operationLock.withLock {
            guard let active = runtime.registry.snapshot().activeGenerationID else {
                return nil
            }
            let result = try activation.rollbackActive(expectedActiveID: active)
            try retargetCrashGuard(nowUnixSeconds: nowUnixSeconds)
            return result
        }
    }

    /// Marks this launch and its active generation healthy.
    ///
    /// Call this after the application's own startup health gate has passed.
    /// Calling it too early weakens automatic crash-loop rollback.
    ///
    /// - Parameter nowUnixSeconds: Current wall-clock time recorded in the
    ///   launch and activation journals.
    public func markHealthy(nowUnixSeconds: Int64) throws {
        try operationLock.withLock {
            try launch.markHealthy(
                sessionNonce: launchResult.sessionNonce,
                nowUnixSeconds: nowUnixSeconds
            )
            if runtime.registry.snapshot().activeGenerationID != nil {
                try activation.markActiveHealthy(nowUnixSeconds: nowUnixSeconds)
            }
        }
    }

    private func retargetCrashGuardAfterNewActivation(
        _ result: PatchActivation.Result,
        previousActiveID: Runtime.GenerationID?,
        nowUnixSeconds: Int64
    ) throws {
        // Replaying the exact active package is a read-only activation result.
        guard result.generationLease.generation.id != previousActiveID else { return }
        try retargetCrashGuard(nowUnixSeconds: nowUnixSeconds)
    }

    private func retargetCrashGuard(nowUnixSeconds: Int64) throws {
        try launch.crashGuard.retargetAfterRollback(
            sessionNonce: launchResult.sessionNonce,
            activeState: try store.activeState(),
            nowUnixSeconds: nowUnixSeconds
        )
    }

    private func nextGenerationID() throws -> Runtime.GenerationID {
        let highest = runtime.registry.snapshot().highestActivatedGenerationID?.rawValue ?? 0
        guard highest < UInt64.max else {
            throw PatchRuntime.Error.generationIdentifierExhausted
        }
        return .init(rawValue: highest + 1)
    }
}
}

extension PatchRuntime.BuildContract {
/// Creates the exact package-verification target for this running process.
///
/// This advanced helper is used by ``PatchRuntime/ApplicationSession`` and by
/// custom Runtime composition roots.
public func targetContext(
    process: PatchRuntime.ProcessIdentity,
    installationID: String
) throws -> PatchPackage.TargetContext {
    try validate()
    try process.validate()
    guard process.bundleID == bundleID else {
        throw PatchRuntime.Error.buildMismatch("bundle ID")
    }
    guard !installationID.isEmpty, installationID.utf8.count <= 4_096 else {
        throw PatchRuntime.Error.invalidProcessIdentity("installation ID is invalid")
    }
    return .init(
        bundleID: bundleID,
        marketingVersion: process.marketingVersion,
        buildNumber: buildNumber,
        shellNamespaceID: shellNamespaceID,
        machOUUID: process.executableUUID,
        shellInterfaceHash: shellInterfaceHash,
        nativeCapabilityManifestHash: try nativeCapabilityManifestHash(),
        architecture: process.architecture,
        platform: process.platform,
        operatingSystemVersion: process.operatingSystemVersion,
        compatibility: compatibility,
        installationID: installationID
    )
}
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
