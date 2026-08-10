import Foundation
import HelixCore

extension SwiftFrontend {
public enum DynamicReplacement {
    private static let previousMarkerUSR =
        "s:18HelixLiveReloadAPI0bC0O8previousyxxyYaKXElFZ"

    /// Derives a collision-resistant Swift identifier from the declaration
    /// USR. Every generation deliberately reuses this identity so Swift's
    /// dynamic-replacement chain links generations for the same root.
    public static func replacementBaseName(usr: String, baseName: String) -> String {
        "helixReload_\(Core.Digest.sha256(usr).hex.prefix(12))_\(baseName)"
    }

    public static func declarationUSR(mangledName: String) -> String? {
        guard mangledName.hasPrefix("$s") else { return nil }
        return "s:" + mangledName.dropFirst(2)
    }

    public static func isPreviousMarkerUSR(_ usr: String) -> Bool {
        usr == previousMarkerUSR
    }
}
}
