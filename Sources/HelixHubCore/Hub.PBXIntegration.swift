#if os(macOS)
import Foundation
import HelixBuildTools
import HelixCore

extension Hub {
struct PBXIntegration {
    struct Output {
        var projectData: Data
        var wrappers: [String: Data]
        var patchTargetIDs: [String: String]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        plan: XcodeIntegration.HostPlan,
        previousPlan: XcodeIntegration.HostPlan? = nil,
        project: Hub.XcodeProject
    ) throws -> Output {
        let projectFile = project.projectURL.appendingPathComponent("project.pbxproj")
        let data = try boundedFile(projectFile, maximumBytes: Hub.OpenStep.maximumDocumentBytes)
        var document = try Hub.PBXProjectDocument(data: data)
        var wrappers: [String: Data] = [:]
        var patchTargetIDs: [String: String] = [:]
        let integrationRoots = Set(
            [plan.integrationRoot, previousPlan?.integrationRoot].compactMap { $0 }
        )
        let configuredConfigurations = try configuredConfigurationIDs(
            plan: plan,
            project: project,
            document: document
        )
        try restoreUnusedBaseConfigurations(
            excluding: configuredConfigurations,
            integrationRoots: integrationRoots,
            project: project,
            document: &document
        )
        try removeOwnedCompilerTriggers(
            integrationRoots: integrationRoots,
            document: &document
        )
        try removeOwnedIntegrationPhases(document: &document)
        try removeObsoletePatchActions(
            previousPlan: previousPlan,
            currentPlan: plan,
            document: &document
        )
        try reconcileOwnedFeatureDependencies(
            retaining: desiredFeatureDependencies(plan: plan, project: project),
            document: &document
        )
        try removeInactiveOwnedRuntimeProducts(
            plan: plan,
            project: project,
            document: &document
        )
        for targetName in Set(plan.profiles.map(\.applicationTargetName)).sorted() {
            guard let target = project.target(named: targetName) else {
                throw Hub.Error.integrationConflict(
                    "application target \(targetName) no longer exists"
                )
            }
            try ensureRuntimeProduct(target: target, requirement: plan.runtimePackageRequirement, document: &document)
            if plan.profiles.contains(where: {
                $0.applicationTargetName == targetName && $0.workflow == .liveReload
            }) {
                try ensureDevelopmentSupportProduct(
                    target: target, requirement: plan.runtimePackageRequirement,
                    document: &document
                )
            }
        }
        pruneUnreferencedRuntimeProducts(document: &document)

        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            guard let featureTarget = project.target(named: feature.targetName),
                let appTarget = project.target(named: profile.applicationTargetName)
            else {
                throw Hub.Error.integrationConflict(
                    "profile \(profile.id) targets no longer match the Xcode project"
                )
            }
            let featureConfiguration =
                "\(plan.integrationRoot)/Profiles/\(profile.id)/Feature.xcconfig"
            let applicationConfiguration =
                "\(plan.integrationRoot)/Profiles/\(profile.id)/Application.xcconfig"
            if featureTarget.id == appTarget.id {
                let triggerPath = compilerTriggerPath(
                    targetName: appTarget.name,
                    plan: plan
                )
                let wrapper = try configureBase(
                    role: "Target",
                    target: appTarget,
                    profile: profile,
                    generatedPaths: [featureConfiguration, applicationConfiguration],
                    additionalSettings: sameTargetCompilerSettings(profile: profile),
                    plan: plan,
                    project: project,
                    document: &document
                )
                wrappers[wrapper.path] = wrapper.data
                try ensureCompilerTrigger(
                    targetID: appTarget.id,
                    path: triggerPath,
                    document: &document
                )
                let refreshPhaseID = identifier(
                    component: "refresh-phase:\(appTarget.id):\(profile.id)"
                )
                try document.addObject(
                    refreshPhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Helix Refresh (Generated)",
                        script: """
                        set -eu
                        if [ "${CONFIGURATION:-}" != \(shellLiteral(profile.configurationName)) ]; then
                            exit 0
                        fi
                        /usr/bin/touch "${SRCROOT:?}/\(triggerPath)"
                        """,
                        inputs: [],
                        outputs: [
                            "$(SRCROOT)/\(triggerPath)",
                        ],
                        alwaysOutOfDate: true
                    )
                )
                try installPhases(
                    [refreshPhaseID],
                    targetID: appTarget.id,
                    placement: .beforeSources,
                    document: &document
                )
            } else {
                try ensureFeatureDependency(
                    applicationTarget: appTarget,
                    featureTarget: featureTarget,
                    document: &document
                )
                let featureWrapper = try configureBase(
                    role: "Feature",
                    target: featureTarget,
                    profile: profile,
                    generatedPaths: [featureConfiguration],
                    additionalSettings: nil,
                    plan: plan,
                    project: project,
                    document: &document
                )
                wrappers[featureWrapper.path] = featureWrapper.data
                let appWrapper = try configureBase(
                    role: "Application",
                    target: appTarget,
                    profile: profile,
                    generatedPaths: [applicationConfiguration],
                    additionalSettings: nil,
                    plan: plan,
                    project: project,
                    document: &document
                )
                wrappers[appWrapper.path] = appWrapper.data

                let preparePhaseID = identifier(
                    component: "prepare-phase:\(featureTarget.id):\(profile.id)"
                )
                try document.addObject(
                    preparePhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Helix Prepare (Generated)",
                        script: phaseInvocation(
                            plan: plan,
                            profile: profile,
                            phase: "prepare",
                            useExec: true
                        ),
                        inputs: [],
                        outputs: [],
                        alwaysOutOfDate: true
                    )
                )
                try installPhases(
                    [preparePhaseID],
                    targetID: featureTarget.id,
                    placement: .afterSources,
                    document: &document
                )

                let bridgePhaseID = identifier(
                    component: "bridge-phase:\(appTarget.id):\(profile.id)"
                )
                try document.addObject(
                    bridgePhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Helix Bridge (Generated)",
                        script: phaseInvocation(
                            plan: plan,
                            profile: profile,
                            phase: "bridge",
                            useExec: true
                        ),
                        inputs: [],
                        outputs: [
                            "$(BUILT_PRODUCTS_DIR)/HelixGenerated/\(profile.id)/Bridge/HelixBridge.o",
                            "$(BUILT_PRODUCTS_DIR)/HelixGenerated/\(profile.id)/Bridge/HelixBootstrap.o",
                        ],
                        alwaysOutOfDate: true
                    )
                )
                try installPhases(
                    [bridgePhaseID],
                    targetID: appTarget.id,
                    placement: .beforeSources,
                    document: &document
                )
            }
            if profile.workflow == .liveReload {
                let networkPhaseID = identifier(
                    component: "development-network-phase:\(appTarget.id):\(profile.id)"
                )
                try document.addObject(
                    networkPhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Configure Helix Development Info.plist (Generated)",
                        script: Hub.DevelopmentNetworkConfiguration().script(
                            configurationName: profile.configurationName
                        ),
                        inputs: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"],
                        outputs: [],
                        alwaysOutOfDate: true
                    )
                )
                let supportPhaseID = identifier(
                    component: "dev-support-phase:\(appTarget.id):\(profile.id)"
                )
                try document.addObject(
                    supportPhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Embed Helix Development Support (Generated)",
                        script: developmentSupportScript(profile: profile),
                        inputs: [
                            "$(BUILT_PRODUCTS_DIR)/PackageFrameworks/"
                                + "\(Self.developmentSupportProductName).framework",
                        ],
                        outputs: [
                            "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/"
                                + "\(Self.developmentSupportProductName).framework",
                        ],
                        alwaysOutOfDate: true
                    )
                )
                // The processed plist may depend on embedded App content. Keep
                // both finalizers after every existing embed and copy phase.
                try installPhases(
                    [supportPhaseID, networkPhaseID],
                    targetID: appTarget.id,
                    placement: .endOfTarget,
                    document: &document
                )
            }
            let appRequiresTrust = plan.profiles.contains {
                $0.applicationTargetName == appTarget.name && $0.patch != nil
            }
            if appRequiresTrust {
                let trustPhaseID = identifier(
                    component: "trust-phase:\(appTarget.id)"
                )
                try document.addObject(
                    trustPhaseID,
                    isa: "PBXShellScriptBuildPhase",
                    fields: shellPhase(
                        name: "Embed Helix Runtime Resources (Generated)",
                        script: """
                        set -eu
                        if [ -z "${HELIX_PATCH_TRUSTED_ROOT:-}" ] || [ -z "${HELIX_PATCH_RECIPE:-}" ]; then
                            exit 0
                        fi
                        /bin/mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
                        /usr/bin/install -m 0444 "$HELIX_PATCH_TRUSTED_ROOT" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HelixTrustedRoot.json"
                        /usr/bin/install -m 0444 "$HELIX_PATCH_RECIPE" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HelixPatchPolicy.json"

                        """,
                        inputs: [],
                        outputs: [],
                        alwaysOutOfDate: true
                    )
                )
                try installPhases(
                    [trustPhaseID],
                    targetID: appTarget.id,
                    placement: .beforeSources,
                    document: &document
                )
            }
            if profile.patch != nil {
                patchTargetIDs[profile.id] = try configurePatchAction(
                    profile: profile,
                    plan: plan,
                    project: project,
                    document: &document
                )
            }
        }
        pruneUnreferencedOwnedConfigurationReferences(
            integrationRoots: integrationRoots,
            document: &document
        )
        try pruneUnreferencedOwnedRuntimePackage(document: &document)
        return .init(
            projectData: try document.serialized(),
            wrappers: wrappers,
            patchTargetIDs: patchTargetIDs
        )
    }

    func remove(
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject
    ) throws -> Data {
        let projectFile = project.projectURL.appendingPathComponent("project.pbxproj")
        let data = try boundedFile(
            projectFile,
            maximumBytes: Hub.OpenStep.maximumDocumentBytes
        )
        var document = try Hub.PBXProjectDocument(data: data)
        let integrationRoots = Set([plan.integrationRoot])
        try restoreUnusedBaseConfigurations(
            excluding: [],
            integrationRoots: integrationRoots,
            project: project,
            document: &document
        )
        try removeOwnedCompilerTriggers(
            integrationRoots: integrationRoots,
            document: &document
        )
        try removeOwnedIntegrationPhases(document: &document)
        try removePatchActions(
            previousPlan: plan,
            retainingTargetIDs: [],
            document: &document
        )
        try reconcileOwnedFeatureDependencies(
            retaining: [],
            document: &document
        )
        try removeInactiveOwnedRuntimeProducts(
            activeTargetIDs: [],
            liveTargetIDs: [],
            document: &document
        )
        try pruneUnreferencedOwnedRuntimePackage(document: &document)
        pruneUnreferencedOwnedConfigurationReferences(
            integrationRoots: integrationRoots,
            document: &document
        )
        return try document.serialized()
    }

    private struct FeatureDependencyKey: Hashable {
        var applicationTargetID: String
        var featureTargetID: String
    }

    private func desiredFeatureDependencies(
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject
    ) throws -> Set<FeatureDependencyKey> {
        var result = Set<FeatureDependencyKey>()
        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            guard let applicationTarget = project.target(
                named: profile.applicationTargetName
            ), let featureTarget = project.target(named: feature.targetName) else {
                throw Hub.Error.integrationConflict(
                    "profile \(profile.id) targets no longer match the Xcode project"
                )
            }
            guard applicationTarget.id != featureTarget.id else { continue }
            result.insert(.init(
                applicationTargetID: applicationTarget.id,
                featureTargetID: featureTarget.id
            ))
        }
        return result
    }

    /// Xcode may otherwise build an independent source target and its App in
    /// parallel. Existing developer dependencies are reused; deterministic
    /// Hub-owned records are added only when ordering is absent.
    private func ensureFeatureDependency(
        applicationTarget: Hub.XcodeTarget,
        featureTarget: Hub.XcodeTarget,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let application = try document.object(applicationTarget.id)
        let dependencies = application["dependencies"]?
            .array?.compactMap(\.string) ?? []
        let alreadyOrdered = dependencies.contains { dependencyID in
            guard let dependency = document.objects[dependencyID]?.dictionary else {
                return false
            }
            if dependency["target"]?.string == featureTarget.id { return true }
            guard let proxyID = dependency["targetProxy"]?.string,
                  let proxy = document.objects[proxyID]?.dictionary
            else { return false }
            return proxy["remoteGlobalIDString"]?.string == featureTarget.id
        }
        guard !alreadyOrdered else { return }

        let key = FeatureDependencyKey(
            applicationTargetID: applicationTarget.id,
            featureTargetID: featureTarget.id
        )
        let proxyID = featureDependencyProxyID(key)
        let dependencyID = featureDependencyID(key)
        try document.addObject(
            proxyID,
            isa: "PBXContainerItemProxy",
            fields: [
                "containerPortal": .string(document.projectObjectID),
                "proxyType": .string("1"),
                "remoteGlobalIDString": .string(featureTarget.id),
                "remoteInfo": .string(featureTarget.name),
            ]
        )
        try document.addObject(
            dependencyID,
            isa: "PBXTargetDependency",
            fields: [
                "target": .string(featureTarget.id),
                "targetProxy": .string(proxyID),
            ]
        )
        try document.updateObject(applicationTarget.id) { target in
            var values = target["dependencies"]?.array?.compactMap(\.string) ?? []
            values.removeAll { $0 == dependencyID }
            values.append(dependencyID)
            target["dependencies"] = .strings(values)
        }
    }

    /// Ownership is proven from both deterministic identifiers and the exact
    /// proxy topology, so a developer-authored dependency is never removed.
    private func reconcileOwnedFeatureDependencies(
        retaining desired: Set<FeatureDependencyKey>,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let applicationTargetIDs = document.objects.compactMap {
            identifier, value -> String? in
            value.dictionary?["isa"]?.string == "PBXNativeTarget"
                ? identifier : nil
        }.sorted()
        for applicationTargetID in applicationTargetIDs {
            let target = try document.object(applicationTargetID)
            let dependencies = target["dependencies"]?
                .array?.compactMap(\.string) ?? []
            var removed = Set<String>()
            var proxies = Set<String>()
            for dependencyID in dependencies {
                guard let dependency = document.objects[dependencyID]?.dictionary,
                      dependency["isa"]?.string == "PBXTargetDependency",
                      let featureTargetID = dependency["target"]?.string
                else { continue }
                let key = FeatureDependencyKey(
                    applicationTargetID: applicationTargetID,
                    featureTargetID: featureTargetID
                )
                let proxyID = featureDependencyProxyID(key)
                guard dependencyID == featureDependencyID(key),
                      dependency["targetProxy"]?.string == proxyID,
                      let proxy = document.objects[proxyID]?.dictionary,
                      proxy["isa"]?.string == "PBXContainerItemProxy",
                      proxy["containerPortal"]?.string == document.projectObjectID,
                      proxy["proxyType"]?.string == "1",
                      proxy["remoteGlobalIDString"]?.string == featureTargetID,
                      !desired.contains(key)
                else { continue }
                removed.insert(dependencyID)
                proxies.insert(proxyID)
            }
            guard !removed.isEmpty else { continue }
            try document.updateObject(applicationTargetID) { target in
                target["dependencies"] = .strings(
                    dependencies.filter { !removed.contains($0) }
                )
            }
            for dependencyID in removed { document.removeObject(dependencyID) }
            for proxyID in proxies where !document.objects.values.contains(where: {
                $0.dictionary?["targetProxy"]?.string == proxyID
            }) {
                document.removeObject(proxyID)
            }
        }
    }

    private func featureDependencyID(_ key: FeatureDependencyKey) -> String {
        identifier(
            component: "feature-dependency:\(key.applicationTargetID):"
                + key.featureTargetID
        )
    }

    private func featureDependencyProxyID(_ key: FeatureDependencyKey) -> String {
        identifier(
            component: "feature-dependency-proxy:\(key.applicationTargetID):"
                + key.featureTargetID
        )
    }

    /// Links the one App-facing product through an existing Helix package
    /// reference when possible, otherwise installs the canonical package once.
    /// Product dependencies are target-owned; no user source or build setting
    /// is required to expose the runtime to the hidden Bridge.
    private func ensureRuntimeProduct(
        target: Hub.XcodeTarget,
        requirement: XcodeIntegration.RuntimePackageRequirement?,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let packageID = try runtimePackageReference(
            targetID: target.id, requirement: requirement,
            document: &document
        )
        let runtimeDependencyIDs = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string
                    == "XCSwiftPackageProductDependency",
                  let name = value.dictionary?["productName"]?.string,
                  Self.runtimeProductNames.contains(name)
            else { return nil }
            return identifier
        })
        let currentTarget = try document.object(target.id)
        let currentDependencies = currentTarget["packageProductDependencies"]?
            .array?.compactMap(\.string) ?? []
        let productID = currentDependencies.first { identifier in
            guard let product = document.objects[identifier]?.dictionary else {
                return false
            }
            return product["productName"]?.string == Self.runtimeProductName
                && product["package"]?.string == packageID
        } ?? identifier(component: "runtime-product:\(target.id)")
        try document.addObject(
            productID,
            isa: "XCSwiftPackageProductDependency",
            fields: [
                "package": .string(packageID),
                "productName": .string(Self.runtimeProductName),
            ]
        )
        try document.updateObject(target.id) { object in
            var dependencies = object["packageProductDependencies"]?
                .array?.compactMap(\.string) ?? []
            dependencies.removeAll { runtimeDependencyIDs.contains($0) || $0 == productID }
            dependencies.append(productID)
            object["packageProductDependencies"] = .strings(dependencies)
        }

        let frameworksPhaseID: String
        let updatedTarget = try document.object(target.id)
        if let existing = updatedTarget["buildPhases"]?.array?.compactMap(\.string)
            .first(where: {
                document.objects[$0]?.dictionary?["isa"]?.string
                    == "PBXFrameworksBuildPhase"
            }) {
            frameworksPhaseID = existing
        } else {
            frameworksPhaseID = identifier(component: "frameworks-phase:\(target.id)")
            try document.addObject(
                frameworksPhaseID,
                isa: "PBXFrameworksBuildPhase",
                fields: [
                    "buildActionMask": .string("2147483647"),
                    "files": .array([]),
                    "runOnlyForDeploymentPostprocessing": .string("0"),
                ]
            )
            try installPhases(
                [frameworksPhaseID],
                targetID: target.id,
                placement: .afterSources,
                document: &document
            )
        }
        let frameworkFiles = document.objects[frameworksPhaseID]?
            .dictionary?["files"]?.array?.compactMap(\.string) ?? []
        let existingBuildFileID = frameworkFiles.first { identifier in
            document.objects[identifier]?.dictionary?["productRef"]?.string
                == productID
        }
        let buildFileID = existingBuildFileID
            ?? identifier(component: "runtime-build-file:\(target.id)")
        if existingBuildFileID == nil {
            try document.addObject(
                buildFileID,
                isa: "PBXBuildFile",
                fields: ["productRef": .string(productID)]
            )
        }
        let runtimeBuildFileIDs = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard let referencedProduct = value.dictionary?["productRef"]?.string,
                  runtimeDependencyIDs.contains(referencedProduct)
                    || referencedProduct == productID,
                  identifier != buildFileID
            else { return nil }
            return identifier
        })
        try document.updateObject(frameworksPhaseID) { phase in
            var files = phase["files"]?.array?.compactMap(\.string) ?? []
            files.removeAll {
                runtimeBuildFileIDs.contains($0) || $0 == buildFileID
            }
            files.append(buildFileID)
            phase["files"] = .strings(files)
        }
    }

    private func ensureCompilerTrigger(
        targetID: String,
        path: String,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let target = try document.object(targetID)
        guard let sourcesPhaseID = target["buildPhases"]?.array?
            .compactMap(\.string)
            .first(where: {
                document.objects[$0]?.dictionary?["isa"]?.string
                    == "PBXSourcesBuildPhase"
            })
        else {
            throw Hub.Error.integrationConflict(
                "application target has no Compile Sources phase"
            )
        }
        let referenceID = identifier(
            component: "compiler-trigger-reference:\(targetID)"
        )
        try document.addObject(
            referenceID,
            isa: "PBXFileReference",
            fields: [
                "lastKnownFileType": .string("sourcecode.swift"),
                "path": .string(path),
                "sourceTree": .string("SOURCE_ROOT"),
            ]
        )
        let buildFileID = identifier(
            component: "compiler-trigger-build-file:\(targetID)"
        )
        try document.addObject(
            buildFileID,
            isa: "PBXBuildFile",
            fields: ["fileRef": .string(referenceID)]
        )
        try document.updateObject(sourcesPhaseID) { phase in
            var files = phase["files"]?.array?.compactMap(\.string) ?? []
            files.removeAll { $0 == buildFileID }
            files.append(buildFileID)
            phase["files"] = .strings(files)
        }
    }

    /// Keeps the Debug support product in Xcode's dependency graph without
    /// putting it in the App's unconditional Frameworks phase. The selected
    /// Live Reload xcconfig links it and the generated phase embeds it only for
    /// that configuration.
    private func ensureDevelopmentSupportProduct(
        target: Hub.XcodeTarget,
        requirement: XcodeIntegration.RuntimePackageRequirement?,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let packageID = try runtimePackageReference(
            targetID: target.id, requirement: requirement,
            document: &document
        )
        let currentTarget = try document.object(target.id)
        let dependencies = currentTarget["packageProductDependencies"]?
            .array?.compactMap(\.string) ?? []
        let productID = dependencies.first { identifier in
            guard let product = document.objects[identifier]?.dictionary else {
                return false
            }
            return product["productName"]?.string
                    == Self.developmentSupportProductName
                && product["package"]?.string == packageID
        } ?? identifier(component: "dev-support-product:\(target.id)")
        try document.addObject(
            productID,
            isa: "XCSwiftPackageProductDependency",
            fields: [
                "package": .string(packageID),
                "productName": .string(Self.developmentSupportProductName),
            ]
        )
        let equivalentProductIDs = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string
                    == "XCSwiftPackageProductDependency",
                  value.dictionary?["productName"]?.string
                    == Self.developmentSupportProductName,
                  value.dictionary?["package"]?.string == packageID
            else { return nil }
            return identifier
        })
        try document.updateObject(target.id) { object in
            var values = object["packageProductDependencies"]?
                .array?.compactMap(\.string) ?? []
            values.removeAll { equivalentProductIDs.contains($0) }
            values.append(productID)
            object["packageProductDependencies"] = .strings(values)
        }

        let buildFiles = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard let referencedProduct = value.dictionary?["productRef"]?.string,
                  equivalentProductIDs.contains(referencedProduct)
            else { return nil }
            return identifier
        })
        guard !buildFiles.isEmpty else { return }
        let targetPhaseIDs = Set(
            (try document.object(target.id))["buildPhases"]?
                .array?.compactMap(\.string) ?? []
        )
        for identifier in targetPhaseIDs.sorted() {
            guard let phase = document.objects[identifier]?.dictionary,
                  let kind = phase["isa"]?.string,
                  Self.unconditionalProductPhaseKinds.contains(kind)
            else { continue }
            let files = phase["files"]?.array?.compactMap(\.string) ?? []
            guard files.contains(where: buildFiles.contains) else { continue }
            try document.updateObject(identifier) { phase in
                phase["files"] = .strings(files.filter { !buildFiles.contains($0) })
            }
        }
        let stillReferenced = Set(document.objects.values.flatMap { value in
            value.dictionary?["files"]?.array?.compactMap(\.string) ?? []
        })
        for identifier in buildFiles where !stillReferenced.contains(identifier) {
            document.removeObject(identifier)
        }
    }

    private func compilerTriggerPath(
        targetName: String,
        plan: XcodeIntegration.HostPlan
    ) -> String {
        "\(plan.integrationRoot)/\(XcodeIntegration.CompilerCapture.targetTriggerPath(targetName: targetName))"
    }

    private func sameTargetCompilerSettings(
        profile: XcodeIntegration.Profile
    ) -> String {
        "SWIFT_EXEC = $(HELIX_INTEGRATION_ROOT)/"
            + XcodeIntegration.CompilerCapture.profileProxyPath(
                profileID: profile.id
            )
    }

    private func runtimePackageReference(
        targetID: String,
        requirement: XcodeIntegration.RuntimePackageRequirement?,
        document: inout Hub.PBXProjectDocument
    ) throws -> String {
        let linkedPackages = Set(document.objects.values.compactMap { value -> String? in
            guard let dependency = value.dictionary,
                  dependency["isa"]?.string == "XCSwiftPackageProductDependency",
                  let name = dependency["productName"]?.string,
                  Self.runtimeProductNames.contains(name),
                  let packageID = dependency["package"]?.string,
                  let package = document.objects[packageID]?.dictionary,
                  ["XCLocalSwiftPackageReference", "XCRemoteSwiftPackageReference"].contains(package["isa"]?.string ?? "")
            else { return nil }
            return packageID
        })
        let candidates = linkedPackages.isEmpty ? Set(document.objects.keys.filter { identifier in
            guard let package = document.objects[identifier]?.dictionary,
                  package["isa"]?.string == "XCRemoteSwiftPackageReference",
                  let repository = package["repositoryURL"]?.string
            else { return false }
            return Self.isCanonicalRepository(repository)
        }) : linkedPackages
        func evidence(_ ids: Set<String>) -> String {
            ids.sorted().map { id in
                let package = document.objects[id]!.dictionary!
                return "package \(id): isa=\(package["isa"]?.string ?? "missing"), "
                    + "repository=\(package["repositoryURL"]?.string ?? package["relativePath"]?.string ?? "missing"), "
                    + "requirement=\(String(describing: package["requirement"]))"
            }.joined(separator: "; ")
        }
        guard candidates.count <= 1 else {
            throw Hub.Error.integrationConflict("runtime package authority is ambiguous for target \(targetID), HostPlan.runtimePackageRequirement=\(String(describing: requirement)): \(evidence(candidates))")
        }
        let requested: Hub.OpenStep.Value? = requirement.map { value in
            .dictionary(["kind": .string(value.kind.rawValue),
                value.kind == .revision ? "revision" : "version": .string(value.value)])
        }
        let ownedID = identifier(component: "runtime-package")
        if let existing = candidates.first {
            if let requested {
                let package = document.objects[existing]!.dictionary!
                guard package["isa"]?.string == "XCRemoteSwiftPackageReference",
                      package["repositoryURL"]?.string.map(Self.isCanonicalRepository) == true,
                      package["requirement"] == requested || existing == ownedID
                else {
                    throw Hub.Error.integrationConflict(
                        "HostPlan.runtimePackageRequirement=\(String(describing: requirement)) conflicts for target \(targetID): \(evidence(candidates))")
                }
                // Only the Helix-owned reference may be changed by a new plan.
                // A user-owned reference must already match the explicit policy.
                if package["requirement"] != requested {
                    try document.updateObject(existing) { $0["requirement"] = requested }
                }
            }
            return existing
        }
        try document.addObject(ownedID, isa: "XCRemoteSwiftPackageReference", fields: [
            "repositoryURL": .string(Self.runtimeRepositoryURL),
            "requirement": requested ?? .dictionary(["branch": .string("main"), "kind": .string("branch")]),
        ])
        try document.updateObject(document.projectObjectID) { project in
            var references = project["packageReferences"]?.array?.compactMap(\.string) ?? []
            if !references.contains(ownedID) { references.append(ownedID) }
            project["packageReferences"] = .strings(references)
        }
        return ownedID
    }

    private func pruneUnreferencedRuntimeProducts(
        document: inout Hub.PBXProjectDocument
    ) {
        var referencedProducts = Set<String>()
        let referencedBuildFiles = Set(document.objects.values.flatMap { value in
            value.dictionary?["files"]?.array?.compactMap(\.string) ?? []
        })
        for (identifier, value) in document.objects {
            guard let object = value.dictionary else { continue }
            if ["PBXNativeTarget", "PBXAggregateTarget"].contains(
                object["isa"]?.string ?? ""
            ) {
                referencedProducts.formUnion(
                    object["packageProductDependencies"]?.array?.compactMap(\.string) ?? []
                )
            }
            if object["isa"]?.string == "PBXBuildFile",
               referencedBuildFiles.contains(identifier),
               let product = object["productRef"]?.string {
                referencedProducts.insert(product)
            }
        }
        let obsolete = document.objects.compactMap { identifier, value -> String? in
            guard value.dictionary?["isa"]?.string
                    == "XCSwiftPackageProductDependency",
                  let name = value.dictionary?["productName"]?.string,
                  Self.runtimeProductNames.contains(name),
                  !referencedProducts.contains(identifier)
            else { return nil }
            return identifier
        }
        let obsoleteSet = Set(obsolete)
        let orphanedBuildFiles = document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string == "PBXBuildFile",
                  let product = value.dictionary?["productRef"]?.string,
                  obsoleteSet.contains(product),
                  !referencedBuildFiles.contains(identifier)
            else { return nil }
            return identifier
        }
        for identifier in orphanedBuildFiles { document.removeObject(identifier) }
        for identifier in obsolete { document.removeObject(identifier) }
    }

    private static let runtimeProductName = "HelixAppIntegration"
    private static let developmentSupportProductName = "HelixDevSupport"
    private static let runtimeProductNames: Set<String> = [
        runtimeProductName,
        developmentSupportProductName,
    ]
    private static let unconditionalProductPhaseKinds: Set<String> = [
        "PBXFrameworksBuildPhase",
        "PBXCopyFilesBuildPhase",
    ]
    private static let runtimeRepositoryURL = "https://github.com/TangentW/Helix.git"
    private static let ownedPhaseMarker = "# Generated by Helix Hub. Do not edit."

    private static func isCanonicalRepository(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized == "https://github.com/tangentw/helix.git"
            || normalized == "https://github.com/tangentw/helix"
    }

    private func configuredConfigurationIDs(
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject,
        document: Hub.PBXProjectDocument
    ) throws -> Set<String> {
        var result = Set<String>()
        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            guard let featureTarget = project.target(named: feature.targetName),
                  let applicationTarget = project.target(
                    named: profile.applicationTargetName
                  )
            else {
                throw Hub.Error.integrationConflict(
                    "profile \(profile.id) targets no longer match the Xcode project"
                )
            }
            result.insert(try document.configurationID(
                targetID: applicationTarget.id,
                named: profile.configurationName
            ))
            result.insert(try document.configurationID(
                targetID: featureTarget.id,
                named: profile.configurationName
            ))
        }
        return result
    }

    /// Restores every no-longer-selected configuration before applying the
    /// current plan. The wrapper records both the original PBX reference and
    /// its resolved project path so grouped xcconfig references remain exact.
    private func restoreUnusedBaseConfigurations(
        excluding configuredConfigurationIDs: Set<String>,
        integrationRoots: Set<String>,
        project: Hub.XcodeProject,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let configurations = document.objects.compactMap {
            identifier, value -> (String, String, String)? in
            guard !configuredConfigurationIDs.contains(identifier),
                  let object = value.dictionary,
                  object["isa"]?.string == "XCBuildConfiguration",
                  let referenceID = object["baseConfigurationReference"]?.string,
                  let reference = document.objects[referenceID]?.dictionary,
                  reference["isa"]?.string == "PBXFileReference",
                  reference["sourceTree"]?.string == "SOURCE_ROOT",
                  let path = reference["path"]?.string,
                  isOwnedConfigurationPath(
                    path,
                    integrationRoots: integrationRoots
                  )
            else { return nil }
            return (identifier, referenceID, path)
        }.sorted { $0.0 < $1.0 }

        for (configurationID, referenceID, path) in configurations {
            let original = try originalBaseConfiguration(
                current: .init(identifier: referenceID, path: path),
                integrationRoots: integrationRoots,
                project: project
            )
            let restoredReference = try restoredReferenceID(
                original,
                document: &document
            )
            try document.updateObject(configurationID) { configuration in
                if let restoredReference {
                    configuration["baseConfigurationReference"] = .string(
                        restoredReference
                    )
                } else {
                    configuration.removeValue(forKey: "baseConfigurationReference")
                }
            }
        }
    }

    private func restoredReferenceID(
        _ original: BaseConfigurationReference,
        document: inout Hub.PBXProjectDocument
    ) throws -> String? {
        if let identifier = original.identifier {
            guard let object = document.objects[identifier]?.dictionary,
                  object["isa"]?.string == "PBXFileReference"
            else {
                guard original.path != nil else {
                    throw Hub.Error.integrationConflict(
                        "the original base configuration reference no longer exists"
                    )
                }
                return try restoredReferenceID(
                    .init(identifier: nil, path: original.path),
                    document: &document
                )
            }
            return identifier
        }
        guard let path = original.path else { return nil }
        if let existing = document.objects.keys.sorted().first(where: { identifier in
            guard let object = document.objects[identifier]?.dictionary else {
                return false
            }
            return object["isa"]?.string == "PBXFileReference"
                && object["sourceTree"]?.string == "SOURCE_ROOT"
                && object["path"]?.string == path
        }) {
            return existing
        }
        let identifier = identifier(component: "restored-xcconfig:\(path)")
        try document.addObject(
            identifier,
            isa: "PBXFileReference",
            fields: [
                "lastKnownFileType": .string("text.xcconfig"),
                "path": .string(path),
                "sourceTree": .string("SOURCE_ROOT"),
            ]
        )
        return identifier
    }

    private func removeOwnedCompilerTriggers(
        integrationRoots: Set<String>,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let references = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard let object = value.dictionary,
                  object["isa"]?.string == "PBXFileReference",
                  object["sourceTree"]?.string == "SOURCE_ROOT",
                  let path = object["path"]?.string,
                  integrationRoots.contains(where: {
                    path.hasPrefix($0 + "/")
                  }),
                  path.hasSuffix(".swift"),
                  path.split(separator: "/").last?.hasPrefix(
                    "HelixBuildTrigger_"
                  ) == true
            else { return nil }
            return identifier
        })
        guard !references.isEmpty else { return }
        let buildFiles = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string == "PBXBuildFile",
                  let reference = value.dictionary?["fileRef"]?.string,
                  references.contains(reference)
            else { return nil }
            return identifier
        })
        let phases = document.objects.compactMap { identifier, value -> String? in
            guard let files = value.dictionary?["files"]?.array?.compactMap(\.string),
                  files.contains(where: buildFiles.contains)
            else { return nil }
            return identifier
        }
        for phaseID in phases {
            try document.updateObject(phaseID) { phase in
                let files = phase["files"]?.array?.compactMap(\.string) ?? []
                phase["files"] = .strings(files.filter { !buildFiles.contains($0) })
            }
        }
        for identifier in buildFiles { document.removeObject(identifier) }
        for identifier in references { document.removeObject(identifier) }
    }

    private func removeInactiveOwnedRuntimeProducts(
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let activeTargetIDs = Set(plan.profiles.compactMap {
            project.target(named: $0.applicationTargetName)?.id
        })
        let liveTargetIDs = Set(plan.profiles.compactMap { profile in
            profile.workflow == .liveReload
                ? project.target(named: profile.applicationTargetName)?.id : nil
        })
        try removeInactiveOwnedRuntimeProducts(
            activeTargetIDs: activeTargetIDs,
            liveTargetIDs: liveTargetIDs,
            document: &document
        )
    }

    private func removeInactiveOwnedRuntimeProducts(
        activeTargetIDs: Set<String>,
        liveTargetIDs: Set<String>,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let targetIDs = document.objects.compactMap { identifier, value in
            value.dictionary?["isa"]?.string == "PBXNativeTarget" ? identifier : nil
        }
        for targetID in targetIDs {
            if !activeTargetIDs.contains(targetID) {
                try removeOwnedProduct(
                    productID: identifier(component: "runtime-product:\(targetID)"),
                    buildFileID: identifier(
                        component: "runtime-build-file:\(targetID)"
                    ),
                    targetID: targetID,
                    document: &document
                )
                try removeEmptyOwnedFrameworksPhase(
                    targetID: targetID,
                    document: &document
                )
            }
            if !liveTargetIDs.contains(targetID) {
                try removeOwnedProduct(
                    productID: identifier(component: "dev-support-product:\(targetID)"),
                    buildFileID: nil,
                    targetID: targetID,
                    document: &document
                )
            }
        }
    }

    private func pruneUnreferencedOwnedRuntimePackage(
        document: inout Hub.PBXProjectDocument
    ) throws {
        let packageID = identifier(component: "runtime-package")
        guard document.objects[packageID]?.dictionary?["isa"]?.string
                == "XCRemoteSwiftPackageReference",
              !document.objects.values.contains(where: {
                $0.dictionary?["isa"]?.string
                    == "XCSwiftPackageProductDependency"
                    && $0.dictionary?["package"]?.string == packageID
              })
        else { return }
        if let project = document.objects[document.projectObjectID]?.dictionary {
            let references = project["packageReferences"]?
                .array?.compactMap(\.string) ?? []
            try document.updateObject(document.projectObjectID) { object in
                object["packageReferences"] = .strings(
                    references.filter { $0 != packageID }
                )
            }
        }
        document.removeObject(packageID)
    }

    private func removeOwnedProduct(
        productID: String,
        buildFileID: String?,
        targetID: String,
        document: inout Hub.PBXProjectDocument
    ) throws {
        var buildFiles = Set<String>()
        if let buildFileID { buildFiles.insert(buildFileID) }
        buildFiles.formUnion(document.objects.compactMap {
            identifier, value -> String? in
            value.dictionary?["productRef"]?.string == productID ? identifier : nil
        })
        for phaseID in document.objects.keys.sorted() {
            guard let files = document.objects[phaseID]?.dictionary?["files"]?
                .array?.compactMap(\.string),
                files.contains(where: buildFiles.contains)
            else { continue }
            try document.updateObject(phaseID) { phase in
                phase["files"] = .strings(
                    files.filter { !buildFiles.contains($0) }
                )
            }
        }
        if document.objects[targetID] != nil {
            try document.updateObject(targetID) { target in
                let dependencies = target["packageProductDependencies"]?
                    .array?.compactMap(\.string) ?? []
                target["packageProductDependencies"] = .strings(
                    dependencies.filter { $0 != productID }
                )
            }
        }
        for identifier in buildFiles { document.removeObject(identifier) }
        document.removeObject(productID)
    }

    private func removeEmptyOwnedFrameworksPhase(
        targetID: String,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let phaseID = identifier(component: "frameworks-phase:\(targetID)")
        guard let phase = document.objects[phaseID]?.dictionary,
              phase["isa"]?.string == "PBXFrameworksBuildPhase",
              phase["files"]?.array?.isEmpty != false
        else { return }
        try document.updateObject(targetID) { target in
            let phases = target["buildPhases"]?.array?.compactMap(\.string) ?? []
            target["buildPhases"] = .strings(phases.filter { $0 != phaseID })
        }
        document.removeObject(phaseID)
    }

    private func removeObsoletePatchActions(
        previousPlan: XcodeIntegration.HostPlan?,
        currentPlan: XcodeIntegration.HostPlan,
        document: inout Hub.PBXProjectDocument
    ) throws {
        guard let previousPlan else { return }
        let currentTargetIDs = Set(currentPlan.profiles.compactMap { profile in
            profile.patch.map {
                identifier(component: "patch-target:\(profile.id):\($0.actionTargetName)")
            }
        })
        try removePatchActions(
            previousPlan: previousPlan,
            retainingTargetIDs: currentTargetIDs,
            document: &document
        )
    }

    private func removePatchActions(
        previousPlan: XcodeIntegration.HostPlan,
        retainingTargetIDs: Set<String>,
        document: inout Hub.PBXProjectDocument
    ) throws {
        for profile in previousPlan.profiles {
            guard let patch = profile.patch else { continue }
            let targetID = identifier(
                component: "patch-target:\(profile.id):\(patch.actionTargetName)"
            )
            guard !retainingTargetIDs.contains(targetID),
                  let target = document.objects[targetID]?.dictionary,
                  target["isa"]?.string == "PBXAggregateTarget",
                  target["name"]?.string == patch.actionTargetName
            else { continue }
            let configurationListID = target["buildConfigurationList"]?.string
            let configurationIDs = configurationListID.flatMap {
                document.objects[$0]?.dictionary?["buildConfigurations"]?
                    .array?.compactMap(\.string)
            } ?? []
            try document.updateObject(document.projectObjectID) { project in
                let targets = project["targets"]?.array?.compactMap(\.string) ?? []
                project["targets"] = .strings(targets.filter { $0 != targetID })
            }
            document.removeObject(targetID)
            if let configurationListID { document.removeObject(configurationListID) }
            for identifier in configurationIDs { document.removeObject(identifier) }
        }
    }

    private func pruneUnreferencedOwnedConfigurationReferences(
        integrationRoots: Set<String>,
        document: inout Hub.PBXProjectDocument
    ) {
        let referenced: Set<String> = Set(document.objects.values.compactMap { value in
            guard value.dictionary?["isa"]?.string == "XCBuildConfiguration"
            else { return nil }
            return value.dictionary?["baseConfigurationReference"]?.string
        })
        let obsolete = document.objects.compactMap {
            identifier, value -> String? in
            guard !referenced.contains(identifier),
                  let object = value.dictionary,
                  object["isa"]?.string == "PBXFileReference",
                  object["sourceTree"]?.string == "SOURCE_ROOT",
                  let path = object["path"]?.string,
                  isOwnedConfigurationPath(
                    path,
                    integrationRoots: integrationRoots
                  )
            else { return nil }
            return identifier
        }
        for identifier in obsolete { document.removeObject(identifier) }
    }

    private func isOwnedConfigurationPath(
        _ path: String,
        integrationRoots: Set<String>
    ) -> Bool {
        path.hasSuffix(".xcconfig") && integrationRoots.contains(where: {
            path.hasPrefix($0 + "/ProjectConfigurations/")
        })
    }

    private func configureBase(
        role: String,
        target: Hub.XcodeTarget,
        profile: XcodeIntegration.Profile,
        generatedPaths: [String],
        additionalSettings: String?,
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject,
        document: inout Hub.PBXProjectDocument
    ) throws -> (path: String, data: Data) {
        let wrapperPath = "\(plan.integrationRoot)/ProjectConfigurations/\(profile.id)-\(role)-\(profile.configurationName).xcconfig"
        let configurationID = try document.configurationID(
            targetID: target.id,
            named: profile.configurationName
        )
        let configuration = try document.object(configurationID)
        let currentReference = configuration["baseConfigurationReference"]?.string
        let currentPath = target.baseConfigurationPaths[profile.configurationName]
        if currentReference != nil, currentPath == nil {
            throw Hub.Error.integrationConflict(
                "\(target.name) \(profile.configurationName) uses a base configuration outside the project source root"
            )
        }
        let original = try originalBaseConfiguration(
            current: .init(identifier: currentReference, path: currentPath),
            integrationRoots: Set([plan.integrationRoot]),
            project: project
        )
        let contents = try wrapper(
            original: generatedPaths.contains(original.path ?? "")
                ? .init(identifier: nil, path: nil) : original,
            generatedPaths: generatedPaths,
            wrapperPath: wrapperPath,
            additionalSettings: additionalSettings
        )
        let referenceID = identifier(component: "xcconfig:\(wrapperPath)")
        try document.addObject(
            referenceID,
            isa: "PBXFileReference",
            fields: [
                "lastKnownFileType": .string("text.xcconfig"),
                "path": .string(wrapperPath),
                "sourceTree": .string("SOURCE_ROOT"),
            ]
        )
        try document.updateObject(configurationID) {
            $0["baseConfigurationReference"] = .string(referenceID)
        }
        return (wrapperPath, Data(contents.utf8))
    }

    private struct BaseConfigurationReference {
        var identifier: String?
        var path: String?
    }

    private func originalBaseConfiguration(
        current: BaseConfigurationReference,
        integrationRoots: Set<String>,
        project: Hub.XcodeProject
    ) throws -> BaseConfigurationReference {
        var value = current
        var visited = Set<String>()
        while let path = value.path,
              isOwnedConfigurationPath(path, integrationRoots: integrationRoots) {
            guard visited.insert(path).inserted, visited.count <= 16 else {
                throw Hub.Error.integrationConflict(
                    "generated xcconfig ownership chain is cyclic or too deep"
                )
            }
            let url = project.sourceRootURL.appendingPathComponent(path)
            let data = try boundedFile(url, maximumBytes: 1 * 1_024 * 1_024)
            let text = String(decoding: data, as: UTF8.self)
            value = try decodeOriginalBaseConfiguration(text, wrapperPath: path)
        }
        return value
    }

    private func decodeOriginalBaseConfiguration(
        _ text: String,
        wrapperPath: String
    ) throws -> BaseConfigurationReference {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func marker(_ name: String) -> String? {
            let prefix = "// \(name): "
            return lines.first(where: { $0.hasPrefix(prefix) })
                .map { String($0.dropFirst(prefix.count)) }
        }
        guard let encodedIdentifier = marker("HELIX_ORIGINAL_BASE_REFERENCE"),
              let encodedPath = marker("HELIX_ORIGINAL_BASE_PATH")
        else {
            throw Hub.Error.integrationConflict(
                "existing generated xcconfig has no ownership metadata: \(wrapperPath)"
            )
        }
        let identifier = try decodedMarker(
            encodedIdentifier,
            description: "base configuration reference"
        )
        let path = try decodedMarker(encodedPath, description: "base configuration path")
        guard path.map(isSafeRelativePath) ?? true else {
            throw Hub.Error.integrationConflict(
                "existing generated xcconfig has an unsafe original path"
            )
        }
        return .init(identifier: identifier, path: path)
    }

    private func decodedMarker(_ value: String, description: String) throws -> String? {
        if value == "none" { return nil }
        guard let bytes = Data(base64Encoded: value),
              let decoded = String(data: bytes, encoding: .utf8),
              !decoded.isEmpty
        else {
            throw Hub.Error.integrationConflict(
                "generated xcconfig has invalid \(description) metadata"
            )
        }
        return decoded
    }

    private func wrapper(
        original: BaseConfigurationReference,
        generatedPaths: [String],
        wrapperPath: String,
        additionalSettings: String?
    ) throws -> String {
        guard !generatedPaths.isEmpty,
              Set(generatedPaths).count == generatedPaths.count
        else {
            throw Hub.Error.integrationConflict(
                "generated xcconfig include list is empty or duplicated"
            )
        }
        let referenceMarker = original.identifier.map {
            Data($0.utf8).base64EncodedString()
        } ?? "none"
        let pathMarker = original.path.map {
            Data($0.utf8).base64EncodedString()
        } ?? "none"
        var lines = [
            "// Generated by Helix Hub. Do not edit.",
            "// HELIX_ORIGINAL_BASE_REFERENCE: \(referenceMarker)",
            "// HELIX_ORIGINAL_BASE_PATH: \(pathMarker)",
        ]
        if let originalPath = original.path {
            lines.append("#include? \"\(try includePath(from: wrapperPath, to: originalPath))\"")
        }
        for generatedPath in generatedPaths {
            lines.append(
                "#include \"\(try includePath(from: wrapperPath, to: generatedPath))\""
            )
        }
        if let additionalSettings {
            lines.append("")
            lines.append(additionalSettings.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func includePath(from source: String, to destination: String) throws -> String {
        guard isSafeRelativePath(source), isSafeRelativePath(destination) else {
            throw Hub.Error.integrationConflict("xcconfig include path is unsafe")
        }
        let sourceDirectory = Array(source.split(separator: "/").dropLast())
        let destinationComponents = Array(destination.split(separator: "/"))
        var common = 0
        while common < sourceDirectory.count, common < destinationComponents.count,
              sourceDirectory[common] == destinationComponents[common] {
            common += 1
        }
        let parent = Array(repeating: "..", count: sourceDirectory.count - common)
        let tail = destinationComponents.dropFirst(common).map(String.init)
        return (parent + tail).joined(separator: "/")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum PhasePlacement {
        case beforeSources
        case afterSources
        case endOfTarget
    }

    private func removeOwnedIntegrationPhases(
        document: inout Hub.PBXProjectDocument
    ) throws {
        let names: Set<String> = [
            "Helix Build (Generated)",
            "Helix Refresh (Generated)",
            "Helix Prepare (Generated)",
            "Helix Bridge (Generated)",
            "Embed Helix Development Support (Generated)",
            "Configure Helix Development Info.plist (Generated)",
            "Prepare Helix Development Info.plist (Generated)",
            "Embed Helix Runtime Resources (Generated)",
            "Embed Helix Trust Root (Generated)",
        ]
        let owned: Set<String> = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string == "PBXShellScriptBuildPhase",
                  let name = value.dictionary?["name"]?.string,
                  names.contains(name),
                  value.dictionary?["shellScript"]?.string?.hasPrefix(
                    Self.ownedPhaseMarker + "\n"
                  ) == true
            else { return nil }
            return identifier
        })
        guard !owned.isEmpty else { return }
        let targetIDs = document.objects.compactMap { identifier, value in
            value.dictionary?["isa"]?.string == "PBXNativeTarget"
                ? identifier : nil
        }
        for targetID in targetIDs {
            let target = try document.object(targetID)
            let phases = target["buildPhases"]?.array?.compactMap(\.string) ?? []
            guard phases.contains(where: owned.contains) else { continue }
            try document.updateObject(targetID) { target in
                target["buildPhases"] = .strings(
                    phases.filter { !owned.contains($0) }
                )
            }
        }
        for identifier in owned {
            document.removeObject(identifier)
        }
    }

    private func installPhases(
        _ phaseIDs: [String],
        targetID: String,
        placement: PhasePlacement,
        document: inout Hub.PBXProjectDocument
    ) throws {
        let sources = Set(document.objects.compactMap { identifier, value in
            value.dictionary?["isa"]?.string == "PBXSourcesBuildPhase"
                ? identifier : nil
        })
        try document.updateObject(targetID) { target in
            var phases = target["buildPhases"]?.array?.compactMap(\.string) ?? []
            let owned = Set(phaseIDs)
            phases.removeAll { owned.contains($0) }
            let insertion: Int
            switch placement {
            case .beforeSources:
                insertion = phases.firstIndex { sources.contains($0) } ?? 0
            case .afterSources:
                insertion = phases.lastIndex { sources.contains($0) }
                    .map { phases.index(after: $0) } ?? phases.endIndex
            case .endOfTarget:
                insertion = phases.endIndex
            }
            phases.insert(contentsOf: phaseIDs, at: insertion)
            target["buildPhases"] = .strings(phases)
        }
    }

    private func configurePatchAction(
        profile: XcodeIntegration.Profile,
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject,
        document: inout Hub.PBXProjectDocument
    ) throws -> String {
        guard let patch = profile.patch else {
            throw Hub.Error.invalidOnboarding("Hot Patch profile has no action settings")
        }
        let targetID = identifier(
            component: "patch-target:\(profile.id):\(patch.actionTargetName)"
        )
        for (identifier, value) in document.objects where identifier != targetID {
            let object = value.dictionary
            if ["PBXNativeTarget", "PBXAggregateTarget"].contains(
                object?["isa"]?.string ?? ""
            ), object?["name"]?.string == patch.actionTargetName {
                throw Hub.Error.integrationConflict(
                    "target name \(patch.actionTargetName) is already in use"
                )
            }
        }
        let obsoleteProfileReferenceID = identifier(
            component: "xcconfig:\(plan.integrationRoot):\(profile.id):patch"
        )
        document.removeObject(obsoleteProfileReferenceID)
        document.removeObject(identifier(component: "patch-phase:\(profile.id)"))
        let names = project.configurations.isEmpty
            ? [profile.configurationName] : project.configurations
        var configurationIDs: [String] = []
        for name in names {
            let configurationID = identifier(
                component: "patch-configuration:\(profile.id):\(name)"
            )
            try document.addObject(
                configurationID,
                isa: "XCBuildConfiguration",
                fields: [
                    "buildSettings": .dictionary([
                        "ARCHS": .string("arm64"),
                        "ONLY_ACTIVE_ARCH": .string("YES"),
                        "SDKROOT": .string("iphoneos"),
                        "SUPPORTED_PLATFORMS": .string("iphoneos iphonesimulator"),
                        "SWIFT_EXEC": .string("$(TOOLCHAIN_DIR)/usr/bin/swiftc"),
                    ]),
                    "name": .string(name),
                ]
            )
            configurationIDs.append(configurationID)
        }
        let listID = identifier(
            component: "patch-configuration-list:\(profile.id)"
        )
        try document.addObject(
            listID,
            isa: "XCConfigurationList",
            fields: [
                "buildConfigurations": .strings(configurationIDs),
                "defaultConfigurationIsVisible": .string("0"),
                "defaultConfigurationName": .string(profile.configurationName),
            ]
        )
        try document.addObject(
            targetID,
            isa: "PBXAggregateTarget",
            fields: [
                "buildConfigurationList": .string(listID),
                "buildPhases": .array([]),
                "buildRules": .array([]),
                "dependencies": .array([]),
                "name": .string(patch.actionTargetName),
                "productName": .string(patch.actionTargetName),
            ]
        )
        try document.updateObject(document.projectObjectID) { root in
            var targets = root["targets"]?.array?.compactMap(\.string) ?? []
            targets.removeAll { $0 == targetID }
            targets.append(targetID)
            root["targets"] = .strings(targets)
        }
        return targetID
    }

    private func shellPhase(
        name: String,
        script: String,
        inputs: [String],
        outputs: [String],
        alwaysOutOfDate: Bool
    ) -> [String: Hub.OpenStep.Value] {
        var fields: [String: Hub.OpenStep.Value] = [
            "buildActionMask": .string("2147483647"),
            "files": .array([]),
            "inputPaths": .strings(inputs),
            "name": .string(name),
            "outputPaths": .strings(outputs),
            "runOnlyForDeploymentPostprocessing": .string("0"),
            "shellPath": .string("/bin/sh"),
            "shellScript": .string(Self.ownedPhaseMarker + "\n" + script),
            "showEnvVarsInLog": .string("0"),
        ]
        if alwaysOutOfDate { fields["alwaysOutOfDate"] = .string("1") }
        return fields
    }

    private func phaseInvocation(
        plan: XcodeIntegration.HostPlan,
        profile: XcodeIntegration.Profile,
        phase: String,
        useExec: Bool = false
    ) -> String {
        let relative = "\(plan.integrationRoot)/Profiles/\(profile.id)/\(phase).sh"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return (useExec ? "exec " : "") + "/bin/sh \"${SRCROOT:?}/\(relative)\""
    }

    private func developmentSupportScript(
        profile: XcodeIntegration.Profile
    ) -> String {
        let product = Self.developmentSupportProductName
        return """
        set -eu
        if [ "${CONFIGURATION:-}" != \(shellLiteral(profile.configurationName)) ]; then
            exit 0
        fi
        source_framework="${BUILT_PRODUCTS_DIR:?}/PackageFrameworks/\(product).framework"
        destination_framework="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/\(product).framework"
        if [ ! -d "$source_framework" ]; then
            echo "error: Helix Debug support framework was not built" >&2
            exit 1
        fi
        /bin/mkdir -p "${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
        case "$destination_framework" in
            "${TARGET_BUILD_DIR:?}/"*) ;;
            *) echo "error: invalid Helix Debug support destination" >&2; exit 1 ;;
        esac
        /usr/bin/rsync -a --delete "$source_framework/" "$destination_framework/"
        if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
                --preserve-metadata=identifier,entitlements,flags "$destination_framework"
        fi
        """
    }

    private func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func identifier(component: String) -> String {
        String(Core.Digest.sha256(
            "helix-hub-pbx:\(component)"
        ).hex.prefix(24)).uppercased()
    }

    private func boundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumBytes
        else {
            throw Hub.Error.invalidProject("required project file is missing or oversized")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains("\0")
        else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains("") && !parts.contains(".") && !parts.contains("..")
    }
}
}
#endif
