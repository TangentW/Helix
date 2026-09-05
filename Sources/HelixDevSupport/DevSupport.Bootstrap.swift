#if os(iOS)
@_exported import HelixCore
@_exported import HelixDevProtocol
@_exported import HelixDevRuntime
import Foundation
import OSLog

/// Debug-only runtime support linked and embedded automatically by Helix Hub.
public enum DevSupport {}

extension DevSupport {
@MainActor
enum Bootstrap {
    static var session: DevRuntime.ApplicationSession?
    static var didStart = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.helix.integration",
        category: "Helix"
    )

    static func start(deviceNativeMatrixQualified: Bool = false) {
        guard !didStart else { return }
        didStart = true
        do {
            session = try DevRuntime.ApplicationSession(options: .init(
                deviceNativeMatrixQualified: deviceNativeMatrixQualified
            ))
        } catch {
            didStart = false
            logger.error(
                "Automatic Helix Live Reload startup failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
}

/// Stable entry called by the generated Live Reload bootstrap object.
@_cdecl("hlx_dev_runtime_autostart_v1")
public func helixDevRuntimeAutostartV1() {
    Task { @MainActor in
        DevSupport.Bootstrap.start()
    }
}

/// Separate versioned entry preserves the default autostart ABI and policy.
@_cdecl("hlx_dev_runtime_autostart_device_native_qualified_v1")
public func helixDevRuntimeAutostartDeviceNativeQualifiedV1() {
    Task { @MainActor in
        DevSupport.Bootstrap.start(deviceNativeMatrixQualified: true)
    }
}
#endif
