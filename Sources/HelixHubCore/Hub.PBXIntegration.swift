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
        project: Hub.XcodeProject,
        featureTargetNames: [String: String],
        applicationBuildSettings: [String: String] = [:]
    ) throws -> Output {
        let projectFile = project.projectURL.appendingPathComponent("project.pbxproj")
        let data = try boundedFile(projectFile, maximumBytes: Hub.OpenStep.maximumDocumentBytes)
        var document = try Hub.PBXProjectDocument(data: data)
        var wrappers: [String: Data] = [:]
        var patchTargetIDs: [String: String] = [:]
        try removeOwnedIntegrationPhases(document: &document)

        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            guard let featureTargetName = featureTargetNames[feature.id],
                let featureTarget = project.target(named: featureTargetName),
                let appTarget = project.target(named: profile.applicationTargetName)
            else {
                throw Hub.Error.integrationConflict(
                    "profile \(profile.id) targets no longer match the Xcode project"
                )
            }
            let featureWrapper = try configureBase(
                role: "Feature",
                target: featureTarget,
                profile: profile,
                generatedPath: "\(plan.integrationRoot)/Profiles/\(profile.id)/Feature.xcconfig",
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
                generatedPath: "\(plan.integrationRoot)/Profiles/\(profile.id)/Application.xcconfig",
                additionalSettings: applicationBuildSettings[profile.id],
                plan: plan,
                project: project,
                document: &document
            )
            wrappers[appWrapper.path] = appWrapper.data

            let preparePhaseID = identifier(
                component: "prepare-phase:\(featureTarget.id)"
            )
            try document.addObject(
                preparePhaseID,
                isa: "PBXShellScriptBuildPhase",
                fields: shellPhase(
                    name: "Helix Prepare (Generated)",
                    script: "exec /bin/sh \"${HELIX_INTEGRATION_ROOT:?}/Profiles/${HELIX_PROFILE_ID:?}/prepare.sh\"",
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
                component: "bridge-phase:\(appTarget.id)"
            )
            try document.addObject(
                bridgePhaseID,
                isa: "PBXShellScriptBuildPhase",
                fields: shellPhase(
                    name: "Helix Bridge (Generated)",
                    script: "exec /bin/sh \"${HELIX_INTEGRATION_ROOT:?}/Profiles/${HELIX_PROFILE_ID:?}/bridge.sh\"",
                    inputs: [],
                    outputs: ["$(HELIX_BRIDGE_OBJECT)"],
                    alwaysOutOfDate: true
                )
            )
            var ownedAppPhases = [bridgePhaseID]
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
                        name: "Embed Helix Trust Root (Generated)",
                        script: """
                        set -eu
                        if [ -z "${HELIX_PATCH_TRUSTED_ROOT:-}" ]; then
                            exit 0
                        fi
                        /usr/bin/install -m 0444 "$HELIX_PATCH_TRUSTED_ROOT" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HelixTrustedRoot.json"

                        """,
                        inputs: [],
                        outputs: [],
                        alwaysOutOfDate: true
                    )
                )
                ownedAppPhases.append(trustPhaseID)
            }
            if profile.patch != nil {
                patchTargetIDs[profile.id] = try configurePatchAction(
                    profile: profile,
                    plan: plan,
                    project: project,
                    document: &document
                )
            }
            try installPhases(
                ownedAppPhases,
                targetID: appTarget.id,
                placement: .beforeSources,
                document: &document
            )
        }
        return .init(
            projectData: try document.serialized(),
            wrappers: wrappers,
            patchTargetIDs: patchTargetIDs
        )
    }

    private func configureBase(
        role: String,
        target: Hub.XcodeTarget,
        profile: XcodeIntegration.Profile,
        generatedPath: String,
        additionalSettings: String?,
        plan: XcodeIntegration.HostPlan,
        project: Hub.XcodeProject,
        document: inout Hub.PBXProjectDocument
    ) throws -> (path: String, data: Data) {
        let wrapperPath = "\(plan.integrationRoot)/ProjectConfigurations/\(profile.id)-\(role)-\(profile.configurationName).xcconfig"
        let current = target.baseConfigurationPaths[profile.configurationName]
        let original = try originalBaseConfiguration(
            current: current,
            wrapperPath: wrapperPath,
            project: project
        )
        let contents = try wrapper(
            originalPath: original == generatedPath ? nil : original,
            generatedPath: generatedPath,
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
        let configurationID = try document.configurationID(
            targetID: target.id,
            named: profile.configurationName
        )
        try document.updateObject(configurationID) {
            $0["baseConfigurationReference"] = .string(referenceID)
        }
        return (wrapperPath, Data(contents.utf8))
    }

    private func originalBaseConfiguration(
        current: String?,
        wrapperPath: String,
        project: Hub.XcodeProject
    ) throws -> String? {
        guard current == wrapperPath else { return current }
        let url = project.sourceRootURL.appendingPathComponent(wrapperPath)
        let data = try boundedFile(url, maximumBytes: 1 * 1_024 * 1_024)
        let text = String(decoding: data, as: UTF8.self)
        let prefix = "// HELIX_ORIGINAL_BASE: "
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix(prefix) })
        else {
            throw Hub.Error.integrationConflict(
                "existing generated xcconfig has no ownership metadata: \(wrapperPath)"
            )
        }
        let encoded = String(line.dropFirst(prefix.count))
        if encoded == "none" { return nil }
        guard let bytes = Data(base64Encoded: encoded),
              let path = String(data: bytes, encoding: .utf8),
              isSafeRelativePath(path)
        else {
            throw Hub.Error.integrationConflict(
                "existing generated xcconfig has invalid ownership metadata"
            )
        }
        return path
    }

    private func wrapper(
        originalPath: String?,
        generatedPath: String,
        wrapperPath: String,
        additionalSettings: String?
    ) throws -> String {
        let marker = originalPath.map { Data($0.utf8).base64EncodedString() } ?? "none"
        var lines = [
            "// Generated by Helix Hub. Do not edit.",
            "// HELIX_ORIGINAL_BASE: \(marker)",
        ]
        if let originalPath {
            lines.append("#include? \"\(try includePath(from: wrapperPath, to: originalPath))\"")
        }
        lines.append("#include \"\(try includePath(from: wrapperPath, to: generatedPath))\"")
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
    }

    private func removeOwnedIntegrationPhases(
        document: inout Hub.PBXProjectDocument
    ) throws {
        let names: Set<String> = [
            "Helix Prepare (Generated)",
            "Helix Bridge (Generated)",
            "Embed Helix Trust Root (Generated)",
        ]
        let owned: Set<String> = Set(document.objects.compactMap {
            identifier, value -> String? in
            guard value.dictionary?["isa"]?.string == "PBXShellScriptBuildPhase",
                  let name = value.dictionary?["name"]?.string,
                  names.contains(name)
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
            "shellScript": .string(script),
            "showEnvVarsInLog": .string("0"),
        ]
        if alwaysOutOfDate { fields["alwaysOutOfDate"] = .string("1") }
        return fields
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
