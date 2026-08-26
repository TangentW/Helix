import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Runtime {
/// Runtime platform facts used to recheck catalog availability on-device.
public struct NativeEnvironment: Hashable, Sendable {
    public var platform: String
    public var version: Core.SemanticVersion

    public init(platform: String, version: Core.SemanticVersion) {
        self.platform = platform
        self.version = version
    }

    public static var current: Self {
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let version = Core.SemanticVersion(
            UInt16(clamping: operatingSystem.majorVersion),
            UInt16(clamping: operatingSystem.minorVersion),
            UInt16(clamping: operatingSystem.patchVersion)
        )
        #if targetEnvironment(macCatalyst)
        return .init(platform: "macCatalyst", version: version)
        #elseif os(iOS)
        return .init(platform: "iOS", version: version)
        #elseif os(tvOS)
        return .init(platform: "tvOS", version: version)
        #elseif os(watchOS)
        return .init(platform: "watchOS", version: version)
        #elseif os(visionOS)
        return .init(platform: "visionOS", version: version)
        #else
        return .init(platform: "macOS", version: version)
        #endif
    }
}
}
