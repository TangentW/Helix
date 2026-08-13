#if os(macOS)
import Foundation
import HelixHubCore

enum HubApplication {}

extension HubApplication {
struct WorkflowForm: Hashable, Sendable, Identifiable {
    var capability: Hub.Capability
    var isEnabled: Bool
    var isInstalled: Bool
    var profileID: String
    var applicationTargetName: String
    var featureTargetName: String
    var schemeName: String
    var configurationName: String
    var featureModuleName: String
    var bundleIdentifier: String
    var namespaceSeed: String
    var patch: Hub.PatchDraft?

    var id: Hub.Capability { capability }

    var expectedRuntimeProduct: String {
        capability == .hotPatch ? "HelixAppRuntime" : "HelixDevAppRuntime"
    }

    func selection() -> Hub.WorkflowSelection {
        .init(
            capability: capability,
            profileID: profileID,
            applicationTargetName: applicationTargetName,
            featureTargetName: featureTargetName,
            schemeName: schemeName,
            configurationName: configurationName,
            featureModuleName: featureModuleName,
            bundleIdentifier: bundleIdentifier,
            namespaceSeed: namespaceSeed,
            patch: patch
        )
    }
}

struct Editor: Hashable, Sendable, Identifiable {
    var project: Hub.XcodeProject
    var forms: [WorkflowForm]
    var integrationRoot: String
    var requirements: [Hub.Requirement]
    var id: String { project.projectURL.path }

    init(project: Hub.XcodeProject) {
        self.project = project
        integrationRoot = ".helix/xcode"
        requirements = []
        forms = Self.recommendedForms(project: project, enabled: Set(Hub.Capability.allCases))
    }

    init(project: Hub.XcodeProject, draft: Hub.OnboardingDraft, requirements: [Hub.Requirement]) {
        self.project = project
        integrationRoot = draft.integrationRoot
        self.requirements = requirements
        let installed = Dictionary(uniqueKeysWithValues: draft.profiles.map { profile in
            (profile.capability, WorkflowForm(
                capability: profile.capability,
                isEnabled: true,
                isInstalled: true,
                profileID: profile.id,
                applicationTargetName: profile.applicationTargetName,
                featureTargetName: profile.featureTargetName,
                schemeName: profile.schemeName,
                configurationName: profile.configurationName,
                featureModuleName: profile.featureModuleName,
                bundleIdentifier: profile.bundleIdentifier,
                namespaceSeed: profile.namespaceSeed,
                patch: profile.patch
            ))
        })
        let missing = Self.recommendedForms(
            project: project,
            enabled: [],
            applicationTargetsToAvoid: Set(installed.values.map(\.applicationTargetName))
        )
        let missingByCapability = Dictionary(uniqueKeysWithValues: missing.map {
            ($0.capability, $0)
        })
        forms = Hub.Capability.allCases.compactMap { capability in
            installed[capability] ?? missingByCapability[capability]
        }
    }

    var applicationTargets: [Hub.XcodeTarget] {
        project.targets.filter { $0.kind == .application }
    }

    var featureTargets: [Hub.XcodeTarget] {
        project.targets.filter {
            !$0.sourceFiles.isEmpty
                && ![.application, .testBundle, .aggregate].contains($0.kind)
        }
    }

    var selectedForms: [WorkflowForm] {
        forms.filter(\.isEnabled)
    }

    var hasInstalledCapabilities: Bool {
        forms.contains(where: \.isInstalled)
    }

    var validationMessages: [String] {
        var result: [String] = []
        let selected = selectedForms
        if selected.isEmpty {
            result.append("Select Hot Patch, Live Reload, or both.")
        }
        for form in selected {
            if project.target(named: form.applicationTargetName)?.kind != .application {
                result.append("\(form.capability.displayName) needs an App target.")
            }
            if !featureTargets.contains(where: { $0.name == form.featureTargetName }) {
                result.append("\(form.capability.displayName) needs a Swift Feature target.")
            }
            if !project.sharedSchemes.contains(where: { $0.name == form.schemeName }) {
                result.append("\(form.capability.displayName) needs a shared Xcode scheme.")
            }
            if !configurationNames(for: form).contains(form.configurationName) {
                result.append(
                    "\(form.capability.displayName) needs one configuration shared by its App and Feature targets."
                )
            }
            if form.profileID.isEmpty || form.namespaceSeed.isEmpty {
                result.append("\(form.capability.displayName) has incomplete identity settings.")
            }
        }
        if selected.count == 2,
           Set(selected.map(\.applicationTargetName)).count != selected.count {
            result.append(
                "Hot Patch and Live Reload need distinct App targets so development code never enters the release image."
            )
        }
        if Set(selected.map(\.schemeName)).count != selected.count {
            result.append("Each workflow needs its own shared scheme.")
        }
        return Array(Set(result)).sorted()
    }

    var canInstall: Bool { validationMessages.isEmpty }

    func configurationNames(for form: WorkflowForm) -> [String] {
        guard let app = project.target(named: form.applicationTargetName),
              let feature = project.target(named: form.featureTargetName)
        else { return [] }
        return Array(Set(app.configurationNames).intersection(feature.configurationNames))
            .sorted()
    }

    mutating func setEnabled(_ enabled: Bool, capability: Hub.Capability) {
        guard let index = forms.firstIndex(where: { $0.capability == capability }),
              !forms[index].isInstalled || enabled
        else { return }
        forms[index].isEnabled = enabled
    }

    mutating func normalize(_ capability: Hub.Capability) {
        guard let index = forms.firstIndex(where: { $0.capability == capability }) else {
            return
        }
        let options = configurationNames(for: forms[index])
        if !options.contains(forms[index].configurationName) {
            forms[index].configurationName = Self.preferredConfiguration(options)
        }
    }

    func selections() throws -> [Hub.WorkflowSelection] {
        guard validationMessages.isEmpty else {
            throw Hub.Error.invalidOnboarding(validationMessages.joined(separator: " "))
        }
        return selectedForms.map { $0.selection() }
    }

    private static func recommendedForms(
        project: Hub.XcodeProject,
        enabled: Set<Hub.Capability>,
        applicationTargetsToAvoid: Set<String> = []
    ) -> [WorkflowForm] {
        let applications = project.targets.filter { $0.kind == .application }
        let features = project.targets.filter {
            !$0.sourceFiles.isEmpty
                && ![.application, .testBundle, .aggregate].contains($0.kind)
        }
        var usedApplications = applicationTargetsToAvoid
        return Hub.Capability.allCases.map { capability in
            let app = rankedTargets(
                applications,
                capability: capability,
                expectedProduct: capability == .hotPatch
                    ? "HelixAppRuntime" : "HelixDevAppRuntime",
                avoiding: usedApplications
            ).first ?? applications.first
            if let app { usedApplications.insert(app.name) }
            let feature = rankedTargets(features, capability: capability).first
                ?? features.first
            let scheme = rankedSchemes(project.sharedSchemes, capability: capability).first
                ?? project.sharedSchemes.first
            let configurations = app.map { app in
                feature.map {
                    Array(Set(app.configurationNames).intersection($0.configurationNames)).sorted()
                } ?? []
            } ?? []
            let profileID = capability == .hotPatch ? "hot-patch" : "live-reload"
            return .init(
                capability: capability,
                isEnabled: enabled.contains(capability),
                isInstalled: false,
                profileID: profileID,
                applicationTargetName: app?.name ?? "",
                featureTargetName: feature?.name ?? "",
                schemeName: scheme?.name ?? "",
                configurationName: preferredConfiguration(configurations),
                featureModuleName: "",
                bundleIdentifier: "",
                namespaceSeed: "\(project.name)-\(profileID)",
                patch: capability == .hotPatch ? .init() : nil
            )
        }
    }

    private static func rankedTargets(
        _ values: [Hub.XcodeTarget],
        capability: Hub.Capability,
        expectedProduct: String? = nil,
        avoiding: Set<String> = []
    ) -> [Hub.XcodeTarget] {
        return values.sorted { lhs, rhs in
            let lhsScore = targetScore(
                lhs,
                capability: capability,
                expectedProduct: expectedProduct,
                avoiding: avoiding
            )
            let rhsScore = targetScore(
                rhs,
                capability: capability,
                expectedProduct: expectedProduct,
                avoiding: avoiding
            )
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            return lhsScore == rhsScore ? lhsName < rhsName : lhsScore > rhsScore
        }
    }

    private static func targetScore(
        _ target: Hub.XcodeTarget,
        capability: Hub.Capability,
        expectedProduct: String?,
        avoiding: Set<String>
    ) -> Int {
        var score = nameScore(target.name, capability: capability)
        if avoiding.contains(target.name) { score -= 100 }
        if let expectedProduct, target.packageProducts.contains(expectedProduct) {
            score += 100
        }
        return score
    }

    private static func rankedSchemes(
        _ values: [Hub.XcodeScheme],
        capability: Hub.Capability
    ) -> [Hub.XcodeScheme] {
        values.sorted { lhs, rhs in
            let lhsScore = nameScore(lhs.name, capability: capability)
            let rhsScore = nameScore(rhs.name, capability: capability)
            return lhsScore == rhsScore
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhsScore > rhsScore
        }
    }

    private static func nameScore(
        _ name: String,
        capability: Hub.Capability
    ) -> Int {
        let normalized = name.lowercased()
        let words = capability == .hotPatch
            ? ["hot", "patch", "release"] : ["live", "reload", "dev", "debug"]
        return words.reduce(0) { $0 + (normalized.contains($1) ? 10 : 0) }
    }

    private static func preferredConfiguration(_ values: [String]) -> String {
        values.first(where: { $0.caseInsensitiveCompare("Debug") == .orderedSame })
            ?? values.first ?? ""
    }
}
}
#endif
