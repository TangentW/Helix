#if os(macOS)
import Foundation
import HelixBuildTools
import HelixCore
import HelixPatch
import HelixReleaseTools

extension Hub {
public struct InstallationResult: Hashable, Sendable {
    public var projectURL: URL
    public var hostPlanURL: URL
    public var capabilities: [Hub.Capability]
    public var requirements: [Hub.Requirement]
    public var featureTargetNames: [String: String]
    public var developmentIdentityProfiles: [String]
    public var writtenRelativePaths: [String]

    public init(
        projectURL: URL,
        hostPlanURL: URL,
        capabilities: [Hub.Capability],
        requirements: [Hub.Requirement],
        featureTargetNames: [String: String],
        developmentIdentityProfiles: [String],
        writtenRelativePaths: [String]
    ) {
        self.projectURL = projectURL
        self.hostPlanURL = hostPlanURL
        self.capabilities = capabilities
        self.requirements = requirements
        self.featureTargetNames = featureTargetNames
        self.developmentIdentityProfiles = developmentIdentityProfiles
        self.writtenRelativePaths = writtenRelativePaths
    }
}

/// Applies one complete Hub onboarding plan atomically. Generated Swift stays
/// exclusively in DerivedData; only xcconfig references and build phases enter
/// the PBX graph.
public struct ProjectInstaller: Sendable {
    typealias TargetSettingsResolver = @Sendable (
        _ project: Hub.XcodeProject,
        _ targetName: String,
        _ configurationName: String
    ) throws -> Hub.TargetSettings

    private let targetSettingsResolver: TargetSettingsResolver

    public init() {
        let inspector = Hub.ProjectInspector()
        targetSettingsResolver = { project, targetName, configurationName in
            try inspector.settings(
                project: project,
                targetName: targetName,
                configurationName: configurationName
            )
        }
    }

    init(targetSettingsResolver: @escaping TargetSettingsResolver) {
        self.targetSettingsResolver = targetSettingsResolver
    }

    public func install(_ onboarding: Hub.OnboardingPlan) throws -> Hub.InstallationResult {
        try onboarding.hostPlan.validate()
        let expectedProject = onboarding.project
        let project = try Hub.ProjectFileParser().parse(projectURL: expectedProject.projectURL)
        guard project.sourceRootURL == expectedProject.sourceRootURL,
              try relative(project.projectURL, to: project.sourceRootURL)
                == onboarding.hostPlan.projectPath
        else {
            throw Hub.Error.integrationConflict(
                "the selected project moved or no longer matches its onboarding plan"
            )
        }
        let sourceRoot = project.sourceRootURL
        var networkMutations: [Hub.FileMutation] = []
        var applicationBuildSettings: [String: String] = [:]
        let networkConfiguration = Hub.DevelopmentNetworkConfiguration()
        for profile in onboarding.hostPlan.profiles where profile.workflow == .liveReload {
            let settings = try targetSettingsResolver(
                project,
                profile.applicationTargetName,
                profile.configurationName
            )
            let networkPlan = try networkConfiguration.plan(
                profile: profile,
                project: project,
                settings: settings,
                integrationRoot: onboarding.hostPlan.integrationRoot
            )
            networkMutations.append(contentsOf: networkPlan.mutations)
            applicationBuildSettings[profile.id] = networkPlan.applicationBuildSettings
        }
        let kit = try XcodeIntegration.KitGenerator().generate(plan: onboarding.hostPlan)
        let integration = try Hub.PBXIntegration().prepare(
            plan: onboarding.hostPlan,
            project: project,
            featureTargetNames: onboarding.featureTargetNames,
            applicationBuildSettings: applicationBuildSettings
        )
        var mutations: [Hub.FileMutation] = []
        let projectRelative = try relative(
            project.projectURL.appendingPathComponent("project.pbxproj"),
            to: sourceRoot
        )
        mutations.append(.init(
            relativePath: projectRelative,
            data: integration.projectData,
            permissions: 0o644
        ))
        mutations.append(contentsOf: try publicArtifactMutations(
            onboarding: onboarding,
            sourceRoot: sourceRoot
        ))
        mutations.append(contentsOf: networkMutations)
        for (path, data) in kit.artifacts {
            mutations.append(.init(
                relativePath: "\(onboarding.hostPlan.integrationRoot)/\(path)",
                data: data,
                permissions: kit.executablePaths.contains(path) ? 0o755 : 0o644
            ))
        }
        for (path, data) in integration.wrappers {
            mutations.append(.init(relativePath: path, data: data, permissions: 0o644))
        }
        for profile in onboarding.hostPlan.profiles {
            guard let scheme = project.sharedSchemes.first(where: {
                $0.name == profile.schemeName
            }),
                let app = project.target(named: profile.applicationTargetName)
            else {
                throw Hub.Error.integrationConflict(
                    "profile \(profile.id) references a missing target or shared scheme"
                )
            }
            let schemeData = try boundedFile(scheme.url, maximumBytes: 8 * 1_024 * 1_024)
            let configured = try Hub.SchemeDocument(data: schemeData).configure(
                profile: profile,
                applicationTarget: app,
                projectName: project.name,
                integrationRoot: onboarding.hostPlan.integrationRoot
            )
            mutations.append(.init(
                relativePath: try relative(scheme.url, to: sourceRoot),
                data: configured,
                permissions: 0o644
            ))
            if let patch = profile.patch,
               let targetID = integration.patchTargetIDs[profile.id] {
                let actionScheme = project.projectURL
                    .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
                    .appendingPathComponent("\(patch.actionSchemeName).xcscheme")
                mutations.append(.init(
                    relativePath: try relative(actionScheme, to: sourceRoot),
                    data: try Hub.SchemeDocument.patchActionScheme(
                        profile: profile,
                        targetID: targetID,
                        applicationTarget: app,
                        projectName: project.name,
                        integrationRoot: onboarding.hostPlan.integrationRoot
                    ),
                    permissions: 0o644
                ))
            }
        }
        mutations.append(contentsOf: try developmentIdentityMutations(
            onboarding: onboarding,
            sourceRoot: sourceRoot
        ))
        let written = try Hub.FileTransaction().commit(
            root: sourceRoot,
            mutations: mutations,
            privateDirectories: onboarding.developmentIdentityProfiles.isEmpty
                ? [] : [".helix/private"]
        )
        let capabilities = onboarding.hostPlan.profiles.map {
            $0.workflow == .hotPatch ? Hub.Capability.hotPatch : .liveReload
        }
        return .init(
            projectURL: project.projectURL,
            hostPlanURL: sourceRoot.appendingPathComponent(
                "\(onboarding.hostPlan.integrationRoot)/HostPlan.json"
            ),
            capabilities: Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue },
            requirements: onboarding.requirements,
            featureTargetNames: onboarding.featureTargetNames,
            developmentIdentityProfiles: onboarding.developmentIdentityProfiles,
            writtenRelativePaths: written
        )
    }

    private func developmentIdentityMutations(
        onboarding: Hub.OnboardingPlan,
        sourceRoot: URL
    ) throws -> [Hub.FileMutation] {
        var result: [Hub.FileMutation] = []
        for profileID in onboarding.developmentIdentityProfiles {
            let profile = try onboarding.hostPlan.profile(id: profileID)
            guard let patch = profile.patch else {
                throw Hub.Error.invalidOnboarding(
                    "development identity requested for non-patch profile \(profileID)"
                )
            }
            let identityPaths = [
                patch.trustedRootPath,
                patch.signingCertificatePath,
                patch.privateKeyPath,
            ]
            let existing = identityPaths.map {
                FileManager.default.fileExists(
                    atPath: sourceRoot.appendingPathComponent($0).path
                )
            }
            if existing.allSatisfy({ $0 }) {
                let rootData = try boundedFile(
                    sourceRoot.appendingPathComponent(patch.trustedRootPath),
                    maximumBytes: 256 * 1_024
                )
                let certificateData = try boundedFile(
                    sourceRoot.appendingPathComponent(patch.signingCertificatePath),
                    maximumBytes: 256 * 1_024
                )
                let privateKeyData = try boundedFile(
                    sourceRoot.appendingPathComponent(patch.privateKeyPath),
                    maximumBytes: 64 * 1_024
                )
                do {
                    let decoder = JSONDecoder()
                    let root = try decoder.decode(
                        PatchPackage.TrustedRoot.self,
                        from: rootData
                    )
                    let certificate = try decoder.decode(
                        PatchPackage.SigningCertificate.self,
                        from: certificateData
                    )
                    let keyDocument = try decoder.decode(
                        ReleasePipeline.SigningKeyDocument.self,
                        from: privateKeyData
                    )
                    let privateKey = try keyDocument.privateKey()
                    _ = try PatchPackage.Signer(
                        certificate: certificate,
                        privateKey: privateKey
                    )
                    let trust = try PatchPackage.TrustStore(roots: [root])
                    try trust.validate(
                        certificate: certificate,
                        bundleIDs: [profile.bundleIdentifier],
                        distributionPolicy: .internalHLBC,
                        backends: [.hlbc],
                        payloadByteCount: 0,
                        nowUnixSeconds: Int64(Date().timeIntervalSince1970)
                    )
                } catch {
                    throw Hub.Error.integrationConflict(
                        "development identity for \(profileID) is invalid: \(error)"
                    )
                }
                result.append(contentsOf: [
                    .init(
                        relativePath: patch.trustedRootPath,
                        data: rootData,
                        permissions: 0o644
                    ),
                    .init(
                        relativePath: patch.signingCertificatePath,
                        data: certificateData,
                        permissions: 0o644
                    ),
                    .init(
                        relativePath: patch.privateKeyPath,
                        data: privateKeyData,
                        permissions: 0o600
                    ),
                ])
                continue
            }
            guard existing.allSatisfy({ !$0 }) else {
                throw Hub.Error.integrationConflict(
                    "development identity for \(profileID) is incomplete; restore or remove all three trust files"
                )
            }
            let identity = try ReleasePipeline.DevelopmentIdentity(
                bundleID: profile.bundleIdentifier,
                nowUnixSeconds: Int64(Date().timeIntervalSince1970)
            )
            result.append(contentsOf: [
                .init(
                    relativePath: patch.trustedRootPath,
                    data: try Core.CanonicalJSON.encode(identity.trustedRoot),
                    permissions: 0o644
                ),
                .init(
                    relativePath: patch.signingCertificatePath,
                    data: try Core.CanonicalJSON.encode(identity.certificate),
                    permissions: 0o644
                ),
                .init(
                    relativePath: patch.privateKeyPath,
                    data: try identity.privateKeyBytes,
                    permissions: 0o600
                ),
            ])
        }
        return result
    }

    /// Configuration and recipe templates become developer-owned after their
    /// first creation. Reconfiguration validates them but never discards edits.
    private func publicArtifactMutations(
        onboarding: Hub.OnboardingPlan,
        sourceRoot: URL
    ) throws -> [Hub.FileMutation] {
        let recipePaths = Set(onboarding.hostPlan.profiles.compactMap {
            $0.patch?.recipePath
        })
        var result: [Hub.FileMutation] = []
        for (path, defaultData) in onboarding.artifacts.sorted(by: { $0.key < $1.key }) {
            let url = sourceRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.append(.init(
                    relativePath: path,
                    data: defaultData,
                    permissions: 0o644
                ))
                continue
            }
            let existing = try boundedFile(url, maximumBytes: 2 * 1_024 * 1_024)
            if recipePaths.contains(path) {
                do {
                    let recipe = try JSONDecoder().decode(
                        ReleasePipeline.QuickPatchRecipe.self,
                        from: existing
                    )
                    try recipe.validate()
                } catch {
                    throw Hub.Error.integrationConflict(
                        "existing patch recipe at \(path) is invalid: \(error)"
                    )
                }
            } else if String(data: existing, encoding: .utf8) == nil {
                throw Hub.Error.integrationConflict(
                    "existing Helix configuration at \(path) is not UTF-8 text"
                )
            }
        }
        return result
    }

    private func relative(_ url: URL, to root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw Hub.Error.integrationConflict("project file is outside the source root")
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func boundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumBytes
        else {
            throw Hub.Error.invalidProject("project file is missing or oversized")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
}
#endif
