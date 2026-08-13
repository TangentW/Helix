import Foundation
import HelixBuildTools
import HelixCore
import HelixPatch
import HelixReleaseTools

extension Hub {
/// Editable GUI model for one workflow profile.
public struct ProfileDraft: Hashable, Sendable, Identifiable {
    public var id: String
    public var capability: Hub.Capability
    public var applicationTargetName: String
    public var featureTargetName: String
    public var featureModuleName: String
    public var schemeName: String
    public var configurationName: String
    public var bundleIdentifier: String
    public var namespaceSeed: String
    public var patch: Hub.PatchDraft?

    public init(
        id: String,
        capability: Hub.Capability,
        applicationTargetName: String,
        featureTargetName: String,
        featureModuleName: String,
        schemeName: String,
        configurationName: String,
        bundleIdentifier: String,
        namespaceSeed: String,
        patch: Hub.PatchDraft? = nil
    ) {
        self.id = id
        self.capability = capability
        self.applicationTargetName = applicationTargetName
        self.featureTargetName = featureTargetName
        self.featureModuleName = featureModuleName
        self.schemeName = schemeName
        self.configurationName = configurationName
        self.bundleIdentifier = bundleIdentifier
        self.namespaceSeed = namespaceSeed
        self.patch = patch
    }
}

/// Hot Patch-only project paths and local development trust preference.
public struct PatchDraft: Hashable, Sendable {
    public var actionTargetName: String
    public var actionSchemeName: String
    public var recipePath: String
    public var signingCertificatePath: String
    public var trustedRootPath: String
    public var privateKeyPath: String
    public var outputRoot: String
    public var simulatorInboxPath: String?
    public var createDevelopmentIdentity: Bool

    public init(
        actionTargetName: String = "HelixPatchAction",
        actionSchemeName: String = "Helix Build Patch",
        recipePath: String = "Configurations/Helix/QuickPatchRecipe.json",
        signingCertificatePath: String = ".helix/private/SigningCertificate.json",
        trustedRootPath: String = ".helix/private/TrustedRoot.json",
        privateKeyPath: String = ".helix/private/PatchSigningKey.json",
        outputRoot: String = ".helix/patches",
        simulatorInboxPath: String? = "Documents/Helix/Current.hlxp",
        createDevelopmentIdentity: Bool = true
    ) {
        self.actionTargetName = actionTargetName
        self.actionSchemeName = actionSchemeName
        self.recipePath = recipePath
        self.signingCertificatePath = signingCertificatePath
        self.trustedRootPath = trustedRootPath
        self.privateKeyPath = privateKeyPath
        self.outputRoot = outputRoot
        self.simulatorInboxPath = simulatorInboxPath
        self.createDevelopmentIdentity = createDevelopmentIdentity
    }
}

/// Complete non-code onboarding choice produced by the SwiftUI form.
public struct OnboardingDraft: Hashable, Sendable {
    public var project: Hub.XcodeProject
    public var capabilities: Hub.CapabilitySelection
    public var profiles: [Hub.ProfileDraft]
    public var integrationRoot: String

    public init(
        project: Hub.XcodeProject,
        capabilities: Hub.CapabilitySelection,
        profiles: [Hub.ProfileDraft],
        integrationRoot: String = ".helix/xcode"
    ) {
        self.project = project
        self.capabilities = capabilities
        self.profiles = profiles
        self.integrationRoot = integrationRoot
    }
}

public struct Requirement: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case information
        case actionRequired
        case blocking
    }

    public var code: String
    public var severity: Severity
    public var summary: String
    public var detail: String
    public var id: String { code }

    public init(code: String, severity: Severity, summary: String, detail: String) {
        self.code = code
        self.severity = severity
        self.summary = summary
        self.detail = detail
    }
}

/// Deterministic installation input. `artifacts` are public project files;
/// private signing material is created only by the transactional installer.
public struct OnboardingPlan: Sendable {
    public var project: Hub.XcodeProject
    public var hostPlan: XcodeIntegration.HostPlan
    public var featureTargetNames: [String: String]
    public var artifacts: [String: Data]
    public var requirements: [Hub.Requirement]
    public var developmentIdentityProfiles: [String]

    public init(
        project: Hub.XcodeProject,
        hostPlan: XcodeIntegration.HostPlan,
        featureTargetNames: [String: String],
        artifacts: [String: Data],
        requirements: [Hub.Requirement],
        developmentIdentityProfiles: [String]
    ) {
        self.project = project
        self.hostPlan = hostPlan
        self.featureTargetNames = featureTargetNames
        self.artifacts = artifacts
        self.requirements = requirements
        self.developmentIdentityProfiles = developmentIdentityProfiles
    }
}

/// Converts GUI selections into the same canonical Host Plan consumed by CLI,
/// Xcode phases, and headless automation.
public struct OnboardingPlanner: Sendable {
    public init() {}

    public func plan(_ draft: Hub.OnboardingDraft) throws -> Hub.OnboardingPlan {
        let selected = Set(draft.capabilities.values)
        let configured = Set(draft.profiles.map(\.capability))
        guard selected == configured,
              draft.profiles.count == configured.count
        else {
            throw Hub.Error.invalidOnboarding(
                "configure exactly one profile for each selected capability"
            )
        }
        var featuresByTarget: [String: XcodeIntegration.Feature] = [:]
        var featureTargetNames: [String: String] = [:]
        var requirements: [Hub.Requirement] = []
        var artifacts: [String: Data] = [:]
        var profiles: [XcodeIntegration.Profile] = []
        var developmentIdentityProfiles: [String] = []
        var applicationTargetsByCapability: [Hub.Capability: String] = [:]

        for profile in draft.profiles.sorted(by: { $0.id < $1.id }) {
            guard let app = draft.project.target(named: profile.applicationTargetName),
                  let featureTarget = draft.project.target(named: profile.featureTargetName)
            else {
                throw Hub.Error.invalidOnboarding(
                    "profile \(profile.id) references a target no longer in the project"
                )
            }
            guard app.kind == .application else {
                throw Hub.Error.invalidOnboarding(
                    "\(profile.applicationTargetName) is not an application target"
                )
            }
            guard draft.project.sharedSchemes.contains(where: {
                $0.name == profile.schemeName
            }) else {
                throw Hub.Error.invalidOnboarding(
                    "scheme \(profile.schemeName) must be shared before Helix can configure it"
                )
            }
            guard app.id != featureTarget.id else {
                throw Hub.Error.invalidOnboarding(
                    "the App and reloadable Feature must be separate targets so their "
                        + "compiler and linker configurations remain isolated"
                )
            }
            guard app.configurationNames.contains(profile.configurationName),
                  featureTarget.configurationNames.contains(profile.configurationName)
            else {
                throw Hub.Error.invalidOnboarding(
                    "\(profile.configurationName) must exist on both App and Feature targets"
                )
            }
            guard !featureTarget.sourceFiles.isEmpty else {
                throw Hub.Error.invalidOnboarding(
                    "Feature target \(featureTarget.name) has no discoverable Swift sources"
                )
            }
            if let prior = applicationTargetsByCapability[profile.capability], prior != app.name {
                throw Hub.Error.invalidOnboarding(
                    "one capability cannot span multiple App targets in one profile"
                )
            }
            applicationTargetsByCapability[profile.capability] = app.name

            let featureID = Self.slug(featureTarget.name)
            let sourceLayout = try Self.sourceLayout(featureTarget.sourceFiles)
            let configurationPath = "Configurations/Helix/\(featureID).yml"
            let feature = XcodeIntegration.Feature(
                id: featureID,
                moduleName: profile.featureModuleName,
                sourceRoot: sourceLayout.root,
                patchConfigurationPath: configurationPath,
                sourceFiles: sourceLayout.files
            )
            if let existing = featuresByTarget[featureTarget.id], existing != feature {
                throw Hub.Error.invalidOnboarding(
                    "Feature target \(featureTarget.name) has conflicting module settings"
                )
            }
            featuresByTarget[featureTarget.id] = feature
            if let existing = featureTargetNames[featureID], existing != featureTarget.name {
                throw Hub.Error.invalidOnboarding(
                    "Feature target names produce the same Helix identifier: \(featureID)"
                )
            }
            featureTargetNames[featureID] = featureTarget.name
            artifacts[configurationPath] = Data(
                Self.configurationYAML(moduleName: feature.moduleName).utf8
            )

            let patchSettings: XcodeIntegration.PatchSettings?
            switch profile.capability {
            case .liveReload:
                guard profile.patch == nil else {
                    throw Hub.Error.invalidOnboarding(
                        "Live Reload profile \(profile.id) cannot contain patch settings"
                    )
                }
                patchSettings = nil
            case .hotPatch:
                guard let patch = profile.patch else {
                    throw Hub.Error.invalidOnboarding(
                        "Hot Patch profile \(profile.id) needs patch action and trust paths"
                    )
                }
                patchSettings = .init(
                    actionTargetName: patch.actionTargetName,
                    actionSchemeName: patch.actionSchemeName,
                    recipePath: patch.recipePath,
                    signingCertificatePath: patch.signingCertificatePath,
                    trustedRootPath: patch.trustedRootPath,
                    privateKeyPath: patch.privateKeyPath,
                    outputRoot: patch.outputRoot,
                    simulatorInboxPath: patch.simulatorInboxPath
                )
                artifacts[patch.recipePath] = try Self.recipe(
                    profileID: profile.id,
                    bundleIdentifier: profile.bundleIdentifier
                )
                if patch.createDevelopmentIdentity {
                    developmentIdentityProfiles.append(profile.id)
                }
            }
            let workflow: XcodeIntegration.Workflow = profile.capability == .hotPatch
                ? .hotPatch : .liveReload
            profiles.append(.init(
                id: profile.id,
                workflow: workflow,
                schemeName: profile.schemeName,
                applicationTargetName: profile.applicationTargetName,
                configurationName: profile.configurationName,
                bundleIdentifier: profile.bundleIdentifier,
                namespaceSeed: profile.namespaceSeed,
                featureID: featureID,
                patch: patchSettings
            ))
            requirements.append(contentsOf: Self.runtimeRequirements(
                app: app,
                workflow: workflow
            ))
        }

        if selected.count == 2,
           let hot = applicationTargetsByCapability[.hotPatch],
           let live = applicationTargetsByCapability[.liveReload],
           hot == live {
            throw Hub.Error.invalidOnboarding(
                "Hot Patch and Live Reload must use distinct App targets: Release must link "
                    + "only HelixAppRuntime while Debug must link only HelixDevAppRuntime"
            )
        }
        let relativeProject = try Self.relative(
            draft.project.projectURL,
            to: draft.project.sourceRootURL
        )
        let hostPlan = XcodeIntegration.HostPlan(
            projectPath: relativeProject,
            integrationRoot: draft.integrationRoot,
            features: Array(featuresByTarget.values),
            profiles: profiles
        )
        do {
            try hostPlan.validate()
        } catch {
            throw Hub.Error.invalidOnboarding(String(describing: error))
        }
        return .init(
            project: draft.project,
            hostPlan: hostPlan,
            featureTargetNames: featureTargetNames,
            artifacts: artifacts,
            requirements: requirements.sorted { $0.code < $1.code },
            developmentIdentityProfiles: developmentIdentityProfiles.sorted()
        )
    }

    private static func sourceLayout(_ paths: [String]) throws -> (root: String, files: [String]) {
        let components = paths.map { $0.split(separator: "/").map(String.init) }
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
            throw Hub.Error.invalidOnboarding("Feature source paths are malformed")
        }
        var common = Array(components[0].dropLast())
        for path in components.dropFirst() {
            let directory = Array(path.dropLast())
            while !common.isEmpty && !directory.starts(with: common) {
                common.removeLast()
            }
        }
        let root = common.isEmpty ? "." : common.joined(separator: "/")
        let files = components.map { path in
            path.dropFirst(common.count).joined(separator: "/")
        }.sorted()
        guard files.allSatisfy({ !$0.isEmpty && $0.hasSuffix(".swift") }) else {
            throw Hub.Error.invalidOnboarding("Feature source layout is invalid")
        }
        return (root, files)
    }

    private static func configurationYAML(moduleName: String) -> String {
        """
        schema: 1
        modules:
          \(moduleName):
            include:
              - **/*.swift
            entrypoints: all
        """ + "\n"
    }

    private static func recipe(
        profileID: String,
        bundleIdentifier: String
    ) throws -> Data {
        let slug = profileID.uppercased().replacingOccurrences(of: "_", with: "-")
        let salt = Core.Digest.sha256("helix-hub-rollout:\(bundleIdentifier):\(profileID)")
            .data
        let recipe = ReleasePipeline.QuickPatchRecipe(
            packageID: "HLX-\(slug)-001",
            campaignID: "\(profileID)-campaign",
            revision: 1,
            purpose: "Describe the production issue corrected by this patch",
            incidentID: "UNASSIGNED",
            ownerTeam: "Unassigned",
            distributionPolicyApprovalID: "local-internal-approval",
            maximumTestedOSVersion: Core.SemanticVersion(99),
            rollout: .init(cohortSalt: salt, percentageBasisPoints: 10_000),
            approvalPolicyID: "local-development-policy",
            antiRollbackCounter: 1
        )
        try recipe.validate()
        return try Core.CanonicalJSON.encode(recipe)
    }

    private static func runtimeRequirements(
        app: Hub.XcodeTarget,
        workflow: XcodeIntegration.Workflow
    ) -> [Hub.Requirement] {
        let expected = workflow.runtimePackageProduct
        let opposite = workflow == .liveReload ? "HelixAppRuntime" : "HelixDevAppRuntime"
        var result: [Hub.Requirement] = []
        if !app.packageProducts.contains(expected) {
            result.append(.init(
                code: "HLXHUB101-\(Self.slug(app.name))-\(workflow.rawValue)",
                severity: .actionRequired,
                summary: "Link \(expected) to \(app.name)",
                detail: "This is the only code-level Xcode step Hub does not infer: add the "
                    + "Helix package product to the App target, then initialize the matching "
                    + "runtime API in application code."
            ))
        }
        if app.packageProducts.contains(opposite) {
            result.append(.init(
                code: "HLXHUB102-\(Self.slug(app.name))-\(workflow.rawValue)",
                severity: .actionRequired,
                summary: "Remove \(opposite) from \(app.name)",
                detail: "Release and development runtime products cannot coexist in one App "
                    + "image; doing so duplicates modules and leaks development capabilities."
            ))
        }
        return result
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var emittedSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                result.unicodeScalars.append(scalar)
                emittedSeparator = false
            } else if !result.isEmpty, !emittedSeparator {
                result.append("-")
                emittedSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.first?.isLetter == true ? result : "feature-\(result)"
    }

    private static func relative(_ url: URL, to root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw Hub.Error.invalidOnboarding("Xcode project must be inside its source root")
        }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
}
