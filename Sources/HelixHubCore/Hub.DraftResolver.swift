#if os(macOS)
import Foundation
import HelixBuildTools

extension Hub {
/// One workflow selection collected by a GUI or another thin frontend.
public struct WorkflowSelection: Hashable, Sendable, Identifiable {
    public var capability: Hub.Capability
    public var profileID: String
    public var applicationTargetName: String
    public var featureTargetName: String
    public var schemeName: String
    public var configurationName: String
    public var featureModuleName: String?
    public var bundleIdentifier: String?
    public var namespaceSeed: String?
    public var patch: Hub.PatchDraft?
    public var id: Hub.Capability { capability }

    public init(
        capability: Hub.Capability,
        profileID: String? = nil,
        applicationTargetName: String,
        featureTargetName: String,
        schemeName: String,
        configurationName: String,
        featureModuleName: String? = nil,
        bundleIdentifier: String? = nil,
        namespaceSeed: String? = nil,
        patch: Hub.PatchDraft? = nil
    ) {
        self.capability = capability
        self.profileID = profileID ?? capability.defaultProfileID
        self.applicationTargetName = applicationTargetName
        self.featureTargetName = featureTargetName
        self.schemeName = schemeName
        self.configurationName = configurationName
        self.featureModuleName = featureModuleName
        self.bundleIdentifier = bundleIdentifier
        self.namespaceSeed = namespaceSeed
        self.patch = patch
    }
}

/// Resolves editable frontend selections against Xcode's actual build settings.
/// It centralizes target identity inference so GUI and future headless clients
/// produce the same canonical onboarding draft.
public struct DraftResolver: Sendable {
    public var inspector: Hub.ProjectInspector

    private struct SettingsIdentity: Hashable {
        var targetName: String
        var configurationName: String
    }

    public init(inspector: Hub.ProjectInspector = .init()) {
        self.inspector = inspector
    }

    public func resolve(
        project: Hub.XcodeProject,
        selections: [Hub.WorkflowSelection],
        integrationRoot: String = ".helix/xcode"
    ) throws -> Hub.OnboardingDraft {
        guard !selections.isEmpty,
              Set(selections.map(\.capability)).count == selections.count,
              Set(selections.map(\.profileID)).count == selections.count
        else {
            throw Hub.Error.invalidOnboarding(
                "select each workflow at most once and give it a unique profile ID"
            )
        }
        var settingsByIdentity: [SettingsIdentity: Hub.TargetSettings] = [:]
        func settings(
            targetName: String,
            configurationName: String
        ) throws -> Hub.TargetSettings {
            let identity = SettingsIdentity(
                targetName: targetName,
                configurationName: configurationName
            )
            if let existing = settingsByIdentity[identity] {
                return existing
            }
            let resolved = try inspector.settings(
                project: project,
                targetName: targetName,
                configurationName: configurationName
            )
            settingsByIdentity[identity] = resolved
            return resolved
        }
        var profiles: [Hub.ProfileDraft] = []
        for selection in selections.sorted(by: {
            $0.capability.rawValue < $1.capability.rawValue
        }) {
            let application = try settings(
                targetName: selection.applicationTargetName,
                configurationName: selection.configurationName
            )
            let feature = try settings(
                targetName: selection.featureTargetName,
                configurationName: selection.configurationName
            )
            guard let bundleIdentifier = normalized(selection.bundleIdentifier)
                ?? application.bundleIdentifier
            else {
                throw Hub.Error.projectInspectionFailed(
                    "\(selection.applicationTargetName) has no resolved bundle identifier"
                )
            }
            let patch: Hub.PatchDraft?
            switch selection.capability {
            case .hotPatch:
                patch = selection.patch ?? .init()
            case .liveReload:
                guard selection.patch == nil else {
                    throw Hub.Error.invalidOnboarding(
                        "Live Reload cannot contain Hot Patch settings"
                    )
                }
                patch = nil
            }
            profiles.append(.init(
                id: selection.profileID,
                capability: selection.capability,
                applicationTargetName: selection.applicationTargetName,
                featureTargetName: selection.featureTargetName,
                featureModuleName: normalized(selection.featureModuleName)
                    ?? feature.moduleName,
                schemeName: selection.schemeName,
                configurationName: selection.configurationName,
                bundleIdentifier: bundleIdentifier,
                namespaceSeed: normalized(selection.namespaceSeed)
                    ?? "\(project.name)-\(selection.profileID)",
                patch: patch
            ))
        }
        return .init(
            project: project,
            capabilities: try .init(profiles.map(\.capability)),
            profiles: profiles,
            integrationRoot: integrationRoot
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// Restores a GUI-editable draft from the generated Host Plan. The registry
/// only locates that plan; target identity has one canonical source of truth.
public struct DraftLoader: Sendable {
    public init() {}

    public func load(
        project: Hub.XcodeProject,
        record: Hub.ProjectRecord
    ) throws -> Hub.OnboardingDraft {
        let data = try boundedFile(
            record.hostPlanURL,
            constrainedTo: project.sourceRootURL
        )
        let plan = try XcodeIntegration.HostPlanCodec.decode(data)
        let expectedProject = project.projectURL.standardizedFileURL
        guard expectedProject == record.projectURL.standardizedFileURL,
              project.sourceRootURL.appendingPathComponent(plan.projectPath)
                .standardizedFileURL == expectedProject
        else {
            throw Hub.Error.integrationConflict(
                "stored Host Plan belongs to a different Xcode project"
            )
        }
        var profiles: [Hub.ProfileDraft] = []
        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            guard project.target(named: feature.targetName) != nil
            else {
                throw Hub.Error.integrationConflict(
                    "stored source target \(feature.targetName) is unavailable"
                )
            }
            let capability: Hub.Capability = profile.workflow == .hotPatch
                ? .hotPatch : .liveReload
            let patch = profile.patch.map {
                Hub.PatchDraft(
                    actionTargetName: $0.actionTargetName,
                    actionSchemeName: $0.actionSchemeName,
                    recipePath: $0.recipePath,
                    signingCertificatePath: $0.signingCertificatePath,
                    trustedRootPath: $0.trustedRootPath,
                    privateKeyPath: $0.privateKeyPath,
                    outputRoot: $0.outputRoot,
                    simulatorInboxPath: $0.simulatorInboxPath,
                    createDevelopmentIdentity: record.developmentIdentityProfiles
                        .contains(profile.id)
                )
            }
            profiles.append(.init(
                id: profile.id,
                capability: capability,
                applicationTargetName: profile.applicationTargetName,
                featureTargetName: feature.targetName,
                featureModuleName: feature.moduleName,
                schemeName: profile.schemeName,
                configurationName: profile.configurationName,
                bundleIdentifier: profile.bundleIdentifier,
                namespaceSeed: profile.namespaceSeed,
                patch: patch
            ))
        }
        return .init(
            project: project,
            capabilities: try .init(profiles.map(\.capability)),
            profiles: profiles,
            integrationRoot: plan.integrationRoot
        )
    }

    private func boundedFile(_ url: URL, constrainedTo root: URL) throws -> Data {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw Hub.Error.integrationConflict(
                "stored Host Plan resolves outside the selected project"
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= 8 * 1_024 * 1_024
        else {
            throw Hub.Error.integrationConflict("stored Host Plan is missing or oversized")
        }
        return try Data(contentsOf: resolvedURL, options: .mappedIfSafe)
    }
}
}

private extension Hub.Capability {
    var defaultProfileID: String {
        switch self {
        case .hotPatch: "hot-patch"
        case .liveReload: "live-reload"
        }
    }
}
#endif
