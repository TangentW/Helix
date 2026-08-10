import Foundation
import HelixCore
import HelixRuntime
import HelixVerifier

extension PatchRuntime {
public final class ApplicationSession: @unchecked Sendable {
    public let build: PatchRuntime.BuildContract
    public let process: PatchRuntime.ProcessIdentity
    public let runtime: Runtime.Engine
    public let store: PatchStore.Storage
    public let activation: PatchActivation.Controller
    public let launch: PatchLaunch.Coordinator
    public let launchResult: PatchLaunch.Result

    private let operationLock = NSLock()

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
            try retargetCrashGuard(nowUnixSeconds: nowUnixSeconds)
            return result
        }
    }

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
            try retargetCrashGuard(nowUnixSeconds: nowUnixSeconds)
            return result
        }
    }

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

    private func retargetCrashGuard(nowUnixSeconds: Int64) throws {
        try launch.crashGuard.retargetAfterRollback(
            sessionNonce: launchResult.sessionNonce,
            activeState: try store.activeState(),
            nowUnixSeconds: nowUnixSeconds
        )
    }

    private func nextGenerationID() throws -> Runtime.GenerationID {
        let highest = runtime.registry.snapshot().loadedGenerationIDs
            .map(\.rawValue).max() ?? 0
        guard highest < UInt64.max else {
            throw PatchRuntime.Error.generationIdentifierExhausted
        }
        return .init(rawValue: highest + 1)
    }
}
}

extension PatchRuntime.BuildContract {
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
