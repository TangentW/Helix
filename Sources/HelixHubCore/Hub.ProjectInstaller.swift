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
    public var hostPlan: XcodeIntegration.HostPlan
    public var capabilities: [Hub.Capability]
    public var requirements: [Hub.Requirement]
    public var developmentIdentityProfiles: [String]
    public var writtenRelativePaths: [String]

    public init(
        projectURL: URL,
        hostPlanURL: URL,
        hostPlan: XcodeIntegration.HostPlan,
        capabilities: [Hub.Capability],
        requirements: [Hub.Requirement],
        developmentIdentityProfiles: [String],
        writtenRelativePaths: [String]
    ) {
        self.projectURL = projectURL
        self.hostPlanURL = hostPlanURL
        self.hostPlan = hostPlan
        self.capabilities = capabilities
        self.requirements = requirements
        self.developmentIdentityProfiles = developmentIdentityProfiles
        self.writtenRelativePaths = writtenRelativePaths
    }
}

/// Applies one complete Hub onboarding plan atomically. Generated Bridge code
/// stays in DerivedData; the PBX graph receives only generated configuration,
/// phases, runtime products, and one inert compiler-scheduling source per target.
public struct ProjectInstaller: Sendable {
    public init() {}

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
        let previousPlan = try existingHostPlan(
            currentPlan: onboarding.hostPlan,
            sourceRoot: sourceRoot
        )
        let kit = try XcodeIntegration.KitGenerator().generate(plan: onboarding.hostPlan)
        let integration = try Hub.PBXIntegration().prepare(
            plan: onboarding.hostPlan,
            previousPlan: previousPlan,
            project: project
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
        let profilesByScheme = Dictionary(
            grouping: onboarding.hostPlan.profiles,
            by: \.schemeName
        )
        var schemeMutations: [String: Hub.FileMutation] = [:]
        let currentSchemeNames = Set(profilesByScheme.keys)
        let previousSchemeNames = Set(previousPlan?.profiles.map(\.schemeName) ?? [])
        for schemeName in previousSchemeNames.subtracting(currentSchemeNames).sorted() {
            let schemeURL = sharedSchemeURL(named: schemeName, project: project)
            guard FileManager.default.fileExists(atPath: schemeURL.path) else { continue }
            let relativePath = try relative(schemeURL, to: sourceRoot)
            let cleaned = try Hub.SchemeDocument(data: boundedFile(
                schemeURL,
                maximumBytes: 8 * 1_024 * 1_024
            )).removingOwnedActions()
            schemeMutations[relativePath] = .init(
                relativePath: relativePath,
                data: cleaned,
                permissions: 0o644
            )
        }
        for schemeName in profilesByScheme.keys.sorted() {
            guard let profiles = profilesByScheme[schemeName] else {
                throw Hub.Error.integrationConflict(
                    "Helix profile has no scheme configuration"
                )
            }
            var applicationTargets: [String: Hub.XcodeTarget] = [:]
            for profile in profiles {
                guard let app = project.target(named: profile.applicationTargetName) else {
                    throw Hub.Error.integrationConflict(
                        "profile \(profile.id) references a missing App target"
                    )
                }
                applicationTargets[app.name] = app
            }
            guard applicationTargets.count == 1,
                  let applicationTarget = applicationTargets.values.first
            else {
                throw Hub.Error.integrationConflict(
                    "profiles sharing a scheme must use one App target"
                )
            }
            let schemeURL = sharedSchemeURL(named: schemeName, project: project)
            let relativePath = try relative(schemeURL, to: sourceRoot)
            let schemeData: Data
            if let pending = schemeMutations[relativePath] {
                schemeData = pending.data
            } else if FileManager.default.fileExists(atPath: schemeURL.path) {
                schemeData = try boundedFile(
                    schemeURL,
                    maximumBytes: 8 * 1_024 * 1_024
                )
            } else {
                let ordered = profiles.sorted { $0.id < $1.id }
                let launch = ordered.first { $0.workflow == .liveReload }
                    ?? ordered[0]
                let archive = ordered.first { $0.workflow == .hotPatch }
                    ?? launch
                schemeData = try Hub.SchemeDocument.applicationScheme(
                    applicationTarget: applicationTarget,
                    projectName: project.name,
                    launchConfiguration: launch.configurationName,
                    archiveConfiguration: archive.configurationName
                )
            }
            let configured = try Hub.SchemeDocument(data: schemeData).configure(
                profiles: profiles,
                applicationTargets: applicationTargets,
                projectName: project.name,
                integrationRoot: onboarding.hostPlan.integrationRoot
            )
            schemeMutations[relativePath] = .init(
                relativePath: relativePath,
                data: configured,
                permissions: 0o644
            )
        }
        var deletions: [String] = []
        let currentActionSchemeNames = Set(onboarding.hostPlan.profiles.compactMap {
            $0.patch?.actionSchemeName
        })
        let retainedSchemeNames = currentActionSchemeNames.union(currentSchemeNames)
        for profile in previousPlan?.profiles ?? [] {
            guard let patch = profile.patch,
                  !retainedSchemeNames.contains(patch.actionSchemeName)
            else { continue }
            let actionScheme = sharedSchemeURL(
                named: patch.actionSchemeName,
                project: project
            )
            guard FileManager.default.fileExists(atPath: actionScheme.path) else {
                continue
            }
            let document = try Hub.SchemeDocument(data: boundedFile(
                actionScheme,
                maximumBytes: 8 * 1_024 * 1_024
            ))
            guard document.containsOwnedAction(
                titled: "Helix Hub: Build \(profile.id) patch"
            ) else { continue }
            deletions.append(try relative(actionScheme, to: sourceRoot))
        }
        for profile in onboarding.hostPlan.profiles {
            guard let patch = profile.patch,
                  let targetID = integration.patchTargetIDs[profile.id],
                  let app = project.target(named: profile.applicationTargetName)
            else { continue }
                let actionScheme = sharedSchemeURL(
                    named: patch.actionSchemeName,
                    project: project
                )
                if FileManager.default.fileExists(atPath: actionScheme.path) {
                    let existing = try Hub.SchemeDocument(data: boundedFile(
                        actionScheme,
                        maximumBytes: 8 * 1_024 * 1_024
                    ))
                    let priorOwner = previousPlan?.profiles.contains { candidate in
                        candidate.id == profile.id
                            && candidate.patch?.actionSchemeName
                                == patch.actionSchemeName
                    } == true
                    guard priorOwner,
                          existing.containsOwnedAction(
                            titled: "Helix Hub: Build \(profile.id) patch"
                          )
                    else {
                        throw Hub.Error.integrationConflict(
                            "shared scheme \(patch.actionSchemeName) already exists and is not owned by Helix"
                        )
                    }
                }
                let relativePath = try relative(actionScheme, to: sourceRoot)
                schemeMutations[relativePath] = .init(
                    relativePath: relativePath,
                    data: try Hub.SchemeDocument.patchActionScheme(
                        profile: profile,
                        targetID: targetID,
                        applicationTarget: app,
                        projectName: project.name,
                        integrationRoot: onboarding.hostPlan.integrationRoot
                    ),
                    permissions: 0o644
                )
        }
        mutations.append(contentsOf: schemeMutations.values.sorted {
            $0.relativePath < $1.relativePath
        })
        mutations.append(contentsOf: try developmentIdentityMutations(
            onboarding: onboarding,
            sourceRoot: sourceRoot
        ))
        let generatedManifest = try Hub.GeneratedFileManifest(
            plan: onboarding.hostPlan,
            mutations: mutations
        )
        if let previousManifest = existingGeneratedFileManifest(
            plan: previousPlan ?? onboarding.hostPlan,
            sourceRoot: sourceRoot
        ) {
            let retainedPaths = Set(generatedManifest.files.map(\.path))
            deletions.append(contentsOf: previousManifest.files.lazy
                .map(\.path)
                .filter { !retainedPaths.contains($0) })
        }
        mutations.append(.init(
            relativePath: generatedManifestPath(plan: onboarding.hostPlan),
            data: try generatedManifest.encoded(for: onboarding.hostPlan),
            permissions: 0o644
        ))
        let written = try Hub.FileTransaction().commit(
            root: sourceRoot,
            mutations: mutations,
            deletions: Array(Set(deletions)).sorted(),
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
            hostPlan: onboarding.hostPlan,
            capabilities: Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue },
            requirements: onboarding.requirements,
            developmentIdentityProfiles: onboarding.developmentIdentityProfiles,
            writtenRelativePaths: written
        )
    }

    /// Removes Hub-owned Xcode integration while preserving application source,
    /// user schemes, original xcconfig references, and signing materials.
    public func uninstall(
        project expectedProject: Hub.XcodeProject,
        record: Hub.ProjectRecord
    ) throws {
        try record.validate()
        guard record.projectURL == expectedProject.projectURL.standardizedFileURL else {
            throw Hub.Error.integrationConflict(
                "the selected project no longer matches its Hub registration"
            )
        }
        let project = try Hub.ProjectFileParser().parse(
            projectURL: expectedProject.projectURL
        )
        let sourceRoot = project.sourceRootURL
        let plan = record.removalPlan
        try plan.validate()
        guard sourceRoot.appendingPathComponent(plan.projectPath)
                .standardizedFileURL == project.projectURL
        else {
            throw Hub.Error.integrationConflict(
                "stored Host Plan belongs to a different Xcode project"
            )
        }

        let projectRelativePath = try relative(
            project.projectURL.appendingPathComponent("project.pbxproj"),
            to: sourceRoot
        )
        var mutations: [Hub.FileMutation] = [.init(
            relativePath: projectRelativePath,
            data: try Hub.PBXIntegration().remove(plan: plan, project: project),
            permissions: 0o644
        )]
        for schemeName in Set(plan.profiles.map(\.schemeName)).sorted() {
            let schemeURL = sharedSchemeURL(named: schemeName, project: project)
            guard FileManager.default.fileExists(atPath: schemeURL.path) else { continue }
            mutations.append(.init(
                relativePath: try relative(schemeURL, to: sourceRoot),
                data: try Hub.SchemeDocument(data: boundedFile(
                    schemeURL,
                    maximumBytes: 8 * 1_024 * 1_024
                )).removingOwnedActions(),
                permissions: 0o644
            ))
        }
        var deletions: [String] = []
        if let generatedManifest = existingGeneratedFileManifest(
            plan: plan,
            sourceRoot: sourceRoot
        ) {
            deletions.append(contentsOf: generatedManifest.files.map(\.path))
        }
        deletions.append(generatedManifestPath(plan: plan))
        for profile in plan.profiles {
            guard let patch = profile.patch else { continue }
            let schemeURL = sharedSchemeURL(
                named: patch.actionSchemeName,
                project: project
            )
            guard FileManager.default.fileExists(atPath: schemeURL.path) else { continue }
            let scheme = try Hub.SchemeDocument(data: boundedFile(
                schemeURL,
                maximumBytes: 8 * 1_024 * 1_024
            ))
            guard scheme.containsOwnedAction(
                titled: "Helix Hub: Build \(profile.id) patch"
            ) else { continue }
            deletions.append(try relative(schemeURL, to: sourceRoot))
        }
        _ = try Hub.FileTransaction().commit(
            root: sourceRoot,
            mutations: mutations,
            deletions: Array(Set(deletions)).sorted()
        )
    }

    private func generatedManifestPath(
        plan: XcodeIntegration.HostPlan
    ) -> String {
        "\(plan.integrationRoot)/\(Hub.GeneratedFileManifest.fileName)"
    }

    /// A damaged ownership document must never turn into a broad delete. Hub
    /// can still overwrite current generated files and restore the PBX graph;
    /// it simply skips stale-file cleanup until a valid manifest is written.
    private func existingGeneratedFileManifest(
        plan: XcodeIntegration.HostPlan,
        sourceRoot: URL
    ) -> Hub.GeneratedFileManifest? {
        let url = sourceRoot.appendingPathComponent(
            generatedManifestPath(plan: plan)
        )
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? boundedFile(
                url,
                maximumBytes: Hub.GeneratedFileManifest.maximumDocumentBytes
              )
        else { return nil }
        return try? Hub.GeneratedFileManifest.decode(data, for: plan)
    }

    private func existingHostPlan(
        currentPlan: XcodeIntegration.HostPlan,
        sourceRoot: URL
    ) throws -> XcodeIntegration.HostPlan? {
        let url = sourceRoot.appendingPathComponent(
            "\(currentPlan.integrationRoot)/\(XcodeIntegration.HostPlan.defaultFileName)"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let plan: XcodeIntegration.HostPlan
        do {
            plan = try XcodeIntegration.HostPlanCodec.decode(
                boundedFile(url, maximumBytes: 8 * 1_024 * 1_024)
            )
        } catch {
            throw Hub.Error.integrationConflict(
                "existing generated Host Plan is invalid: \(error)"
            )
        }
        guard plan.projectPath == currentPlan.projectPath else {
            throw Hub.Error.integrationConflict(
                "existing generated Host Plan belongs to a different project"
            )
        }
        return plan
    }

    private func sharedSchemeURL(
        named name: String,
        project: Hub.XcodeProject
    ) -> URL {
        project.sharedSchemes.first(where: { $0.name == name })?.url
            ?? project.projectURL
                .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
                .appendingPathComponent("\(name).xcscheme")
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
