#if os(macOS)
import Foundation
import HelixBuildTools

extension Hub {
/// Plans the Info.plist changes required by authenticated local development.
///
/// Existing plists are merged in place so business Bonjour services survive.
/// Targets that rely on Xcode's generated plist receive a minimal Hub-owned
/// input; Xcode continues to add the target's ordinary `INFOPLIST_KEY_*` values.
struct DevelopmentNetworkConfiguration {
    struct Plan: Sendable {
        var mutations: [Hub.FileMutation]
        var applicationBuildSettings: String?
    }

    static let serviceType = "_helix._tcp"
    static let usageDescription =
        "Helix connects this development build to the Mac on your local network."

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func plan(
        profile: XcodeIntegration.Profile,
        project: Hub.XcodeProject,
        settings: Hub.TargetSettings,
        integrationRoot: String
    ) throws -> Plan {
        guard profile.workflow == .liveReload else {
            return .init(mutations: [], applicationBuildSettings: nil)
        }
        if let url = settings.informationPropertyListURL {
            guard fileManager.fileExists(atPath: url.path) else {
                throw Hub.Error.projectInspectionFailed(
                    "configured Info.plist does not exist: `\(url.path)`"
                )
            }
            let path = try relative(url, to: project.sourceRootURL)
            let propertyList = try mergingExistingPropertyList(at: url)
            return .init(
                mutations: [
                    .init(
                        relativePath: path,
                        data: propertyList.data,
                        permissions: propertyList.permissions
                    ),
                ],
                applicationBuildSettings: nil
            )
        }
        guard settings.generatesInformationPropertyList else {
            throw Hub.Error.projectInspectionFailed(
                "`\(profile.applicationTargetName)` has no readable Info.plist and "
                    + "does not enable GENERATE_INFOPLIST_FILE"
            )
        }
        let relativePath = profileInfoPlistPath(
            profile: profile,
            integrationRoot: integrationRoot
        )
        return .init(
            mutations: [
                .init(
                    relativePath: relativePath,
                    data: try encodedPropertyList([:]),
                    permissions: 0o644
                ),
            ],
            applicationBuildSettings: """
            // Helix owns the local-development network declarations.
            GENERATE_INFOPLIST_FILE = NO
            INFOPLIST_FILE = $(SRCROOT)/\(relativePath)
            """
        )
    }

    private func mergingExistingPropertyList(
        at url: URL
    ) throws -> (data: Data, permissions: Int) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= 8 * 1_024 * 1_024,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              (0...0o777).contains(permissions)
        else {
            throw Hub.Error.projectInspectionFailed(
                "Info.plist is not a bounded regular file: `\(url.path)`"
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw Hub.Error.projectInspectionFailed(
                "Info.plist is malformed: `\(url.path)`"
            )
        }
        guard let dictionary = value as? [String: Any] else {
            throw Hub.Error.projectInspectionFailed("Info.plist root must be a dictionary")
        }
        return (try encodedPropertyList(dictionary), permissions)
    }

    private func encodedPropertyList(_ original: [String: Any]) throws -> Data {
        var dictionary = original
        var services: [String]
        switch dictionary["NSBonjourServices"] {
        case nil:
            services = []
        case let value as [String]:
            services = value
        default:
            throw Hub.Error.projectInspectionFailed(
                "NSBonjourServices must be an array of strings"
            )
        }
        var seen: Set<String> = []
        services = services.filter { !$0.isEmpty && seen.insert($0).inserted }
        if seen.insert(Self.serviceType).inserted {
            services.append(Self.serviceType)
        }
        dictionary["NSBonjourServices"] = services

        if let description = dictionary["NSLocalNetworkUsageDescription"] {
            guard let value = description as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Hub.Error.projectInspectionFailed(
                    "NSLocalNetworkUsageDescription must be a nonempty string"
                )
            }
        } else {
            dictionary["NSLocalNetworkUsageDescription"] = Self.usageDescription
        }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
        } catch {
            throw Hub.Error.projectInspectionFailed(
                "Info.plist contains a value that cannot be serialized"
            )
        }
    }

    private func relative(_ url: URL, to root: URL) throws -> String {
        let root = root.standardizedFileURL
        let url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw Hub.Error.projectInspectionFailed(
                "Info.plist resolves outside the selected source root"
            )
        }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    private func profileInfoPlistPath(
        profile: XcodeIntegration.Profile,
        integrationRoot: String
    ) -> String {
        "\(integrationRoot)/ProjectConfigurations/"
            + "\(profile.id)-Application-Info.plist"
    }
}
}
#endif
