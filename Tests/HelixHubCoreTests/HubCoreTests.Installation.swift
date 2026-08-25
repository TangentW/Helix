#if os(macOS)
import Foundation
@testable import HelixHubCore
import HelixBuildTools
import HelixCore
import HelixDevTools
import HelixPatch
import HelixReleaseTools
import Testing

@Suite("Helix Hub project installation", .serialized)
struct ProjectInstallationTests {
    @Test("Fresh project receives both workflows idempotently")
    func installsBothWorkflows() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let draft = Hub.OnboardingDraft(
            project: project,
            capabilities: try .init([.hotPatch, .liveReload]),
            profiles: [
                .init(
                    id: "hot",
                    capability: .hotPatch,
                    applicationTargetName: "HotApp",
                    featureTargetName: "HotFeature",
                    featureModuleName: "HotFeature",
                    schemeName: "Hot",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.example.hot",
                    namespaceSeed: "example-hot",
                    patch: .init()
                ),
                .init(
                    id: "live",
                    capability: .liveReload,
                    applicationTargetName: "LiveApp",
                    featureTargetName: "LiveFeature",
                    featureModuleName: "LiveFeature",
                    schemeName: "Live",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.example.live",
                    namespaceSeed: "example-live"
                ),
            ]
        )
        let plan = try Hub.OnboardingPlanner().plan(draft)
        let installer = generatedInfoPlistInstaller()
        let first = try installer.install(plan)
        #expect(first.capabilities == [.hotPatch, .liveReload])
        #expect(first.writtenRelativePaths.contains(".helix/xcode/HostPlan.json"))
        let keyURL = root.appendingPathComponent(".helix/private/PatchSigningKey.json")
        let firstKey = try Data(contentsOf: keyURL)

        let installed = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: first.projectURL,
            hostPlanURL: first.hostPlanURL,
            capabilities: first.capabilities,
            requirements: first.requirements,
            featureTargetNames: first.featureTargetNames,
            developmentIdentityProfiles: first.developmentIdentityProfiles
        )
        let restored = try Hub.DraftLoader().load(project: installed, record: record)
        #expect(restored.capabilities == draft.capabilities)
        #expect(restored.integrationRoot == draft.integrationRoot)
        #expect(restored.profiles.map(\.id) == ["hot", "live"])
        #expect(restored.profiles.map(\.featureTargetName) == ["HotFeature", "LiveFeature"])
        #expect(restored.profiles.first?.patch?.createDevelopmentIdentity == true)
        #expect(installed.target(named: "HelixPatchAction")?.kind == .aggregate)
        #expect(
            installed.target(named: "HotFeature")?
                .baseConfigurationPaths["Debug"]?
                .contains("ProjectConfigurations/hot-Feature-Debug.xcconfig") == true
        )
        #expect(
            installed.target(named: "LiveApp")?
                .baseConfigurationPaths["Debug"]?
                .contains("ProjectConfigurations/live-Application-Debug.xcconfig") == true
        )
        let projectText = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")),
            as: UTF8.self
        )
        #expect(projectText.components(separatedBy: "Helix Bridge (Generated)").count - 1 == 2)
        #expect(projectText.components(separatedBy: "Helix Prepare (Generated)").count - 1 == 2)
        #expect(projectText.contains("alwaysOutOfDate = 1"))
        #expect(projectText.contains(
            "${HELIX_INTEGRATION_ROOT:?}/Profiles/${HELIX_PROFILE_ID:?}/bridge.sh"
        ))
        #expect(!projectText.contains("Build Helix Patch (Generated)"))
        #expect(!projectText.contains("$(HELIX_INTEGRATION_ROOT)/Profiles/"))
        #expect(!projectText.contains("HelixBridge.swift"))
        let liveSchemeURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes/Live.xcscheme"
        )
        let liveScheme = String(decoding: try Data(contentsOf: liveSchemeURL), as: UTF8.self)
        #expect(!liveScheme.contains("Helix Hub: Prepare"))
        #expect(liveScheme.components(separatedBy: "Helix Hub: Register live").count - 1 == 1)
        var projectParser = try Hub.OpenStep.Parser(
            data: Data(projectText.utf8)
        )
        let projectRoot = try #require(try projectParser.parse().dictionary)
        let objects = try #require(projectRoot["objects"]?.dictionary)
        func phaseNames(targetID: String) -> [String] {
            let identifiers = objects[targetID]?.dictionary?["buildPhases"]?
                .array?.compactMap(\.string) ?? []
            return identifiers.compactMap { identifier in
                let object = objects[identifier]?.dictionary
                return object?["name"]?.string ?? object?["isa"]?.string
            }
        }
        #expect(phaseNames(targetID: "HOTFEATURE") == [
            "PBXSourcesBuildPhase", "Helix Prepare (Generated)",
        ])
        #expect(phaseNames(targetID: "LIVEFEATURE") == [
            "PBXSourcesBuildPhase", "Helix Prepare (Generated)",
        ])
        #expect(phaseNames(targetID: "HOTAPP") == [
            "Helix Bridge (Generated)",
            "Embed Helix Trust Root (Generated)",
            "PBXSourcesBuildPhase",
        ])
        #expect(phaseNames(targetID: "LIVEAPP") == [
            "Helix Bridge (Generated)", "PBXSourcesBuildPhase",
        ])
        let patchSchemeURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes/Helix Build Patch.xcscheme"
        )
        let patchScheme = String(
            decoding: try Data(contentsOf: patchSchemeURL),
            as: UTF8.self
        )
        #expect(patchScheme.contains("Helix Hub: Build hot patch"))
        #expect(patchScheme.contains("Profiles/hot/patch.sh"))
        #expect(patchScheme.contains("BlueprintName=\"HotApp\""))
        #expect(patchScheme.contains("BlueprintName=\"HelixPatchAction\""))
        #expect(permissions(keyURL) == 0o600)
        #expect(permissions(root.appendingPathComponent(".helix/private")) == 0o700)
        let generatedInfoURL = root.appendingPathComponent(
            ".helix/xcode/ProjectConfigurations/live-Application-Info.plist"
        )
        let generatedInfo = try propertyList(at: generatedInfoURL)
        #expect(generatedInfo["NSBonjourServices"] as? [String] == ["_helix._tcp"])
        #expect(
            generatedInfo["NSLocalNetworkUsageDescription"] as? String
                == Hub.DevelopmentNetworkConfiguration.usageDescription
        )
        let liveApplicationConfiguration = String(
            decoding: try Data(contentsOf: root.appendingPathComponent(
                ".helix/xcode/ProjectConfigurations/live-Application-Debug.xcconfig"
            )),
            as: UTF8.self
        )
        #expect(liveApplicationConfiguration.contains("GENERATE_INFOPLIST_FILE = NO"))
        #expect(liveApplicationConfiguration.contains(
            "live-Application-Info.plist"
        ))

        let recipeURL = root.appendingPathComponent(
            "Configurations/Helix/QuickPatchRecipe.json"
        )
        var recipe = try JSONDecoder().decode(
            ReleasePipeline.QuickPatchRecipe.self,
            from: Data(contentsOf: recipeURL)
        )
        recipe.purpose = "Developer-edited incident purpose"
        let customRecipe = try Core.CanonicalJSON.encode(recipe)
        try customRecipe.write(to: recipeURL)

        _ = try installer.install(plan)
        #expect(try Data(contentsOf: keyURL) == firstKey)
        #expect(try Data(contentsOf: recipeURL) == customRecipe)
        let secondText = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")),
            as: UTF8.self
        )
        #expect(secondText.components(separatedBy: "Helix Bridge (Generated)").count - 1 == 2)
        #expect(secondText.components(separatedBy: "Helix Prepare (Generated)").count - 1 == 2)
        let secondScheme = String(decoding: try Data(contentsOf: liveSchemeURL), as: UTF8.self)
        #expect(secondScheme.components(separatedBy: "Helix Hub: Register live").count - 1 == 1)
        let canonicalPlan = try XcodeIntegration.HostPlanCodec.decode(
            Data(contentsOf: first.hostPlanURL)
        )
        #expect(canonicalPlan == plan.hostPlan)

        let escapedPlanURL = root.deletingLastPathComponent().appendingPathComponent(
            "helix-hub-escaped-plan-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: escapedPlanURL) }
        try Data(contentsOf: first.hostPlanURL).write(to: escapedPlanURL)
        let linkURL = first.hostPlanURL.deletingLastPathComponent()
            .appendingPathComponent("EscapedHostPlan.json")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: escapedPlanURL.path
        )
        let escapedRecord = try Hub.ProjectRecord(
            name: "Example",
            projectURL: first.projectURL,
            hostPlanURL: linkURL,
            capabilities: first.capabilities,
            requirements: first.requirements,
            featureTargetNames: first.featureTargetNames,
            developmentIdentityProfiles: first.developmentIdentityProfiles
        )
        #expect(throws: Hub.Error.self) {
            _ = try Hub.DraftLoader().load(project: installed, record: escapedRecord)
        }
        let xcode = try ProcessExecution.Runner().run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-list", "-project", projectURL.path],
            environment: [:],
            workingDirectory: root
        )
        #expect(
            xcode.status == 0,
            Comment(rawValue: xcode.standardError)
        )
        #expect(xcode.standardOutput.contains("HelixPatchAction"))

        let unrelatedKey = ReleasePipeline.SigningKeyDocument(
            rawRepresentation: PatchPackage.PrivateKey().rawRepresentation
        )
        try Core.CanonicalJSON.encode(unrelatedKey).write(to: keyURL)
        #expect(throws: Hub.Error.self) {
            _ = try installer.install(plan)
        }
    }

    @Test("Existing Info.plist keeps product network declarations")
    func mergesExistingInformationPropertyList() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let infoURL = root.appendingPathComponent("Live/Info.plist")
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "CFBundleDisplayName": "Example",
            "NSBonjourServices": ["_business._tcp", "_helix._tcp", "_business._tcp"],
            "NSLocalNetworkUsageDescription": "Find nearby business devices.",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: original,
            format: .xml,
            options: 0
        ).write(to: infoURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: infoURL.path
        )
        let project = try Hub.ProjectFileParser().parse(
            projectURL: root.appendingPathComponent("Example.xcodeproj")
        )
        let profile = XcodeIntegration.Profile(
            id: "live",
            workflow: .liveReload,
            schemeName: "Live",
            applicationTargetName: "LiveApp",
            configurationName: "Debug",
            bundleIdentifier: "dev.example.live",
            namespaceSeed: "example-live",
            featureID: "livefeature"
        )
        let settings = Hub.TargetSettings(
            targetName: "LiveApp",
            configurationName: "Debug",
            moduleName: "LiveApp",
            bundleIdentifier: "dev.example.live",
            productName: "LiveApp",
            swiftVersion: "6.0",
            sourceRootURL: root,
            informationPropertyListURL: infoURL,
            generatesInformationPropertyList: false
        )
        let result = try Hub.DevelopmentNetworkConfiguration().plan(
            profile: profile,
            project: project,
            settings: settings,
            integrationRoot: ".helix/xcode"
        )
        #expect(result.applicationBuildSettings == nil)
        let mutation = try #require(result.mutations.first)
        #expect(mutation.relativePath == "Live/Info.plist")
        #expect(mutation.permissions == 0o600)
        let merged = try propertyList(mutation.data)
        #expect(
            merged["NSBonjourServices"] as? [String]
                == ["_business._tcp", "_helix._tcp"]
        )
        #expect(
            merged["NSLocalNetworkUsageDescription"] as? String
                == "Find nearby business devices."
        )
        #expect(merged["CFBundleDisplayName"] as? String == "Example")
    }

    @Test("A missing configured Info.plist is never replaced silently")
    func rejectsMissingConfiguredInformationPropertyList() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try Hub.ProjectFileParser().parse(
            projectURL: root.appendingPathComponent("Example.xcodeproj")
        )
        let profile = XcodeIntegration.Profile(
            id: "live",
            workflow: .liveReload,
            schemeName: "Live",
            applicationTargetName: "LiveApp",
            configurationName: "Debug",
            bundleIdentifier: "dev.example.live",
            namespaceSeed: "example-live",
            featureID: "livefeature"
        )
        let settings = Hub.TargetSettings(
            targetName: "LiveApp",
            configurationName: "Debug",
            moduleName: "LiveApp",
            bundleIdentifier: "dev.example.live",
            productName: "LiveApp",
            swiftVersion: "6.0",
            sourceRootURL: root,
            informationPropertyListURL: root.appendingPathComponent("Missing-Info.plist"),
            generatesInformationPropertyList: true
        )

        #expect(throws: Hub.Error.self) {
            _ = try Hub.DevelopmentNetworkConfiguration().plan(
                profile: profile,
                project: project,
                settings: settings,
                integrationRoot: ".helix/xcode"
            )
        }
    }

    @Test("Failed write restores earlier files")
    func rollsBackFileTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-transaction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        try Data("original".utf8).write(to: first)
        try Data("not-a-directory".utf8).write(to: root.appendingPathComponent("z-blocked"))

        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction().commit(
                root: root,
                mutations: [
                    .init(relativePath: "first.txt", data: Data("changed".utf8), permissions: 0o600),
                    .init(relativePath: "z-blocked/child.txt", data: Data("new".utf8), permissions: 0o600),
                ],
                privateDirectories: ["private"]
            )
        }
        #expect(String(decoding: try Data(contentsOf: first), as: UTF8.self) == "original")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("private").path
        ))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-install-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data(pbxproj.utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        for name in ["Hot", "Live"] {
            try Data(scheme(name: name).utf8).write(
                to: schemes.appendingPathComponent("\(name).xcscheme")
            )
        }
        return root
    }

    private func permissions(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private func generatedInfoPlistInstaller() -> Hub.ProjectInstaller {
        Hub.ProjectInstaller { project, targetName, configurationName in
            Hub.TargetSettings(
                targetName: targetName,
                configurationName: configurationName,
                moduleName: targetName,
                bundleIdentifier: "dev.example.live",
                productName: targetName,
                swiftVersion: "6.0",
                sourceRootURL: project.sourceRootURL,
                generatesInformationPropertyList: true
            )
        }
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        try propertyList(Data(contentsOf: url))
    }

    private func propertyList(_ data: Data) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }

    private func scheme(name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries></BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="Debug"/>
          <LaunchAction buildConfiguration="Debug"/>
          <ProfileAction buildConfiguration="Debug"/>
          <AnalyzeAction buildConfiguration="Debug"/>
          <ArchiveAction buildConfiguration="Debug"/>
        </Scheme>
        """
    }

    private var pbxproj: String {
        """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          classes = {};
          objectVersion = 60;
          objects = {
        /* Begin PBXBuildFile section */
            BFHOT = {isa = PBXBuildFile; fileRef = FRHOT; };
            BFLIVE = {isa = PBXBuildFile; fileRef = FRLIVE; };
        /* End PBXBuildFile section */
        /* Begin PBXFileReference section */
            FRHOT = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Hot/Sources/Hot.swift; sourceTree = SOURCE_ROOT; };
            FRLIVE = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Live/Sources/Live.swift; sourceTree = SOURCE_ROOT; };
        /* End PBXFileReference section */
        /* Begin PBXGroup section */
            MAIN = {isa = PBXGroup; children = (FRHOT, FRLIVE, ); sourceTree = "<group>"; };
        /* End PBXGroup section */
        /* Begin PBXSourcesBuildPhase section */
            SPHOT = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFHOT, ); runOnlyForDeploymentPostprocessing = 0; };
            SPLIVE = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BFLIVE, ); runOnlyForDeploymentPostprocessing = 0; };
            SPHA = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
            SPLA = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXSourcesBuildPhase section */
        /* Begin PBXNativeTarget section */
            HOTFEATURE = {isa = PBXNativeTarget; buildConfigurationList = CLHF; buildPhases = (SPHOT, ); buildRules = (); dependencies = (); name = HotFeature; productName = HotFeature; productType = "com.apple.product-type.framework"; };
            HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = (); name = HotApp; productName = HotApp; productType = "com.apple.product-type.application"; };
            LIVEFEATURE = {isa = PBXNativeTarget; buildConfigurationList = CLLF; buildPhases = (SPLIVE, ); buildRules = (); dependencies = (); name = LiveFeature; productName = LiveFeature; productType = "com.apple.product-type.framework"; };
            LIVEAPP = {isa = PBXNativeTarget; buildConfigurationList = CLLA; buildPhases = (SPLA, ); buildRules = (); dependencies = (); name = LiveApp; productName = LiveApp; productType = "com.apple.product-type.application"; };
        /* End PBXNativeTarget section */
        /* Begin PBXProject section */
            PROJECT = {isa = PBXProject; buildConfigurationList = CLPROJECT; mainGroup = MAIN; targets = (HOTFEATURE, HOTAPP, LIVEFEATURE, LIVEAPP, ); };
        /* End PBXProject section */
        /* Begin XCBuildConfiguration section */
            CHF = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CHA = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CLF = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CLA = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CPROJECT = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
        /* End XCBuildConfiguration section */
        /* Begin XCConfigurationList section */
            CLHF = {isa = XCConfigurationList; buildConfigurations = (CHF, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLHA = {isa = XCConfigurationList; buildConfigurations = (CHA, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLLF = {isa = XCConfigurationList; buildConfigurations = (CLF, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLLA = {isa = XCConfigurationList; buildConfigurations = (CLA, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLPROJECT = {isa = XCConfigurationList; buildConfigurations = (CPROJECT, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        /* End XCConfigurationList section */
          };
          rootObject = PROJECT;
        }
        """
    }
}
#endif
