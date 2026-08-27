#if os(iOS)
@_exported import HelixBytecode
@_exported import HelixCore
@_exported import HelixPatch
@_exported import HelixRuntime
@_exported import HelixVerifier
@_exported import HelixVM
import Foundation
import OSLog
import UIKit

extension AppIntegration {
/// Observable process-level state for diagnostics and Demo controls. Normal
/// applications do not need to read this value or retain a runtime session.
public enum Status: Equatable, Sendable {
    case inactive
    case running
    case failed(String)
}

/// Current automatic integration status.
@MainActor
public static var status: AppIntegration.Status { Bootstrap.status }

/// Automatically retained production session, available to advanced tooling.
@MainActor
public static var patchSession: PatchRuntime.ApplicationSession? {
    Bootstrap.patchSession
}

/// Returns the one process-wide production session retained by the automatic
/// bootstrap. Normal applications do not call this method; it exists for
/// advanced diagnostics and product-owned patch controls that need direct
/// access without constructing a second Runtime or Bridge.
@MainActor
public static func requirePatchSession() throws -> PatchRuntime.ApplicationSession {
    Bootstrap.start()
    guard Bootstrap.status == .running,
          let session = Bootstrap.patchSession
    else {
        if case let .failed(detail) = Bootstrap.status {
            throw SessionAccessError.startupFailed(detail)
        }
        throw SessionAccessError.unavailable
    }
    return session
}

/// Failure to obtain the automatically retained production session.
public enum SessionAccessError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible {
    case unavailable
    case startupFailed(String)

    public var description: String {
        switch self {
        case .unavailable:
            "the automatic Helix production session is unavailable"
        case let .startupFailed(detail):
            "automatic Helix startup failed: \(detail)"
        }
    }
}

}

extension AppIntegration {
@MainActor
enum Bootstrap {
    static var status: AppIntegration.Status = .inactive
    static var patchSession: PatchRuntime.ApplicationSession?
    static var healthConfirmation: HealthConfirmation?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.helix.integration",
        category: "Helix"
    )

    static func start() {
        guard status == .inactive else { return }
        do {
            let session = try makePatchSession()
            try consumePendingPatch(using: session)
            patchSession = session
            healthConfirmation = HealthConfirmation(session: session)
            status = .running
        } catch {
            patchSession = nil
            healthConfirmation = nil
            let detail = String(describing: error)
            status = .failed(detail)
            logger.error("Automatic Helix startup failed: \(detail, privacy: .public)")
        }
    }

    private struct PolicyDocument: Decodable {
        var schemaVersion: UInt16
        var distributionPolicyApprovalID: String
    }

    private static func makePatchSession() throws -> PatchRuntime.ApplicationSession {
        let root: PatchPackage.TrustedRoot = try resource(
            named: "HelixTrustedRoot",
            extension: "json"
        )
        let policy: PolicyDocument = try resource(
            named: "HelixPatchPolicy",
            extension: "json"
        )
        guard policy.schemaVersion == 1,
              !policy.distributionPolicyApprovalID.isEmpty,
              policy.distributionPolicyApprovalID.utf8.count <= 1_024
        else {
            throw BootstrapError.invalidPolicy
        }
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try PatchRuntime.ApplicationSession(
            installationID: installationID(),
            storeRootURL: applicationSupport
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent("PatchStore", isDirectory: true),
            trustStore: PatchPackage.TrustStore(roots: [root]),
            acceptancePolicy: .init(
                acceptedDistributionPolicies: [.internalHLBC],
                approvedDistributionPolicyIDs: [
                    policy.distributionPolicyApprovalID,
                ]
            ),
            nowUnixSeconds: currentUnixTime()
        )
    }

    private static func resource<Value: Decodable>(
        named name: String,
        extension pathExtension: String
    ) throws -> Value {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: pathExtension
        ) else {
            throw BootstrapError.missingResource(name)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 else {
            throw BootstrapError.invalidResource(name)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func installationID() -> String {
        let key = "dev.helix.installation-id.v1"
        if let existing = UserDefaults.standard.string(forKey: key),
           !existing.isEmpty, existing.utf8.count <= 4_096 {
            return existing
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func consumePendingPatch(
        using session: PatchRuntime.ApplicationSession
    ) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let inbox = documents
            .appendingPathComponent("Helix", isDirectory: true)
            .appendingPathComponent("Current.hlxp")
        guard FileManager.default.fileExists(atPath: inbox.path) else { return }
        _ = try session.install(
            localPackageURL: inbox,
            nowUnixSeconds: currentUnixTime()
        )
        try FileManager.default.removeItem(at: inbox)
    }

    private static func currentUnixTime() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    enum BootstrapError: Swift.Error, CustomStringConvertible {
        case missingResource(String)
        case invalidResource(String)
        case invalidPolicy

        var description: String {
            switch self {
            case let .missingResource(name):
                "missing embedded \(name)"
            case let .invalidResource(name):
                "embedded \(name) is empty or oversized"
            case .invalidPolicy:
                "embedded patch policy is invalid"
            }
        }
    }
}
}

extension AppIntegration.Bootstrap {
@MainActor
final class HealthConfirmation: NSObject {
    private let session: PatchRuntime.ApplicationSession
    private var isScheduled = false

    init(session: PatchRuntime.ApplicationSession) {
        self.session = session
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        if UIApplication.shared.applicationState == .active {
            applicationDidBecomeActive()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    @objc private func applicationDidBecomeActive() {
        guard !isScheduled else { return }
        isScheduled = true
        perform(#selector(confirmHealthyLaunch), with: nil, afterDelay: 5)
    }

    @objc private func confirmHealthyLaunch() {
        do {
            try session.markHealthy(
                nowUnixSeconds: Int64(Date().timeIntervalSince1970)
            )
            NotificationCenter.default.removeObserver(self)
        } catch {
            isScheduled = false
        }
    }
}
}

/// Stable symbol invoked by the hidden Bridge bootstrap object during image
/// initialization. Startup is deferred to the main actor so UIKit and the
/// application lifecycle are available before either runtime is constructed.
/// The C ABI spelling is part of the version-1 runtime contract.
@_cdecl("hlx_runtime_autostart_v1")
public func helixAppIntegrationAutostartV1() {
    Task { @MainActor in
        AppIntegration.Bootstrap.start()
    }
}
#endif
