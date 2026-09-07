#if os(macOS)
import Foundation
@testable import HelixHubCore
import HelixBuildTools
import HelixCore
import HelixDevTools
import HelixPatch
import HelixReleaseTools
import HelixCLIKit
import Testing

@Suite("Helix Hub project installation", .serialized)
struct ProjectInstallationTests {
    @Test("Checked-in integration kits retain current artifacts and ownership")
    func checkedInKitOwnership() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Demo", "Tests/Fixtures/LiveReloadE2E"] {
            let root = repository.appendingPathComponent(path)
            let planURL = root.appendingPathComponent(".helix/xcode/HostPlan.json")
            let plan = try XcodeIntegration.HostPlanCodec.decode(Data(contentsOf: planURL))
            let generated = try XcodeIntegration.KitGenerator().generate(plan: plan)
            let integrationRoot = root.appendingPathComponent(plan.integrationRoot)
            let ownership = try Hub.GeneratedFileManifest.decode(
                Data(contentsOf: integrationRoot.appendingPathComponent(Hub.GeneratedFileManifest.fileName)), for: plan)
            let expectedPaths = Set(generated.artifacts.keys.map { plan.integrationRoot + "/" + $0 })
            #expect(expectedPaths.isSubset(of: Set(ownership.files.map(\.path))))
            for (relativePath, data) in generated.artifacts {
                #expect(try Data(contentsOf: integrationRoot.appendingPathComponent(relativePath)) == data,
                        "Generated fixture drift: \(path)/\(relativePath)")
            }
            for file in ownership.files {
                let url = root.appendingPathComponent(file.path)
                let data = try Data(contentsOf: url)
                #expect(UInt64(data.count) == file.byteCount, "\(path)/\(file.path)")
                #expect(Core.Digest.sha256(data) == file.sha256, "\(path)/\(file.path)")
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == file.permissions)
            }
        }
    }

    @Test("Headless inspection and installation use the transactional Hub path")
    func installsThroughCLI() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let settings = #"CLANG_CXX_LIBRARY = "libc++"; LD_RUNPATH_SEARCH_PATHS = ("@executable_path/Frameworks", ); EXCLUDED_SOURCE_FILE_NAMES = "*.xcassets";"#
        let untouched = (0..<100).map {
            "    UNTOUCHED\($0) = {\n      isa = XCBuildConfiguration;\n      buildSettings = { \(settings) };\n      name = Other\($0);\n    };"
        }.joined(separator: "\n")
        var originalText = try String(contentsOf: projectFile, encoding: .utf8)
        originalText = originalText.replacingOccurrences(of: "CLF = {isa = XCBuildConfiguration; buildSettings = {};",
            with: "CLF = {isa = XCBuildConfiguration; buildSettings = { \(settings) };")
        originalText = originalText.replacingOccurrences(of: "objects = {", with: "objects = {\n" + untouched)
        try Data(originalText.utf8).write(to: projectFile)
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let planned = try Hub.OnboardingPlanner().plan(.init(project: project,
            capabilities: try .init([.liveReload]), profiles: [.init(id: "live", capability: .liveReload,
                applicationTargetName: "LiveApp", featureTargetName: "LiveFeature", featureModuleName: "LiveFeature",
                schemeName: "Live", configurationName: "Debug", bundleIdentifier: "dev.example.live", namespaceSeed: "fixture")]))
        var plan = planned.hostPlan
        plan.profiles[0].deviceNativeMatrixQualified = true
        let input = root.appendingPathComponent("InputPlan.json")
        try XcodeIntegration.HostPlanCodec.encode(plan).write(to: input)
        let app = CLI.Application(currentDirectoryURL: root)
        let inspection = app.run(["xcode", "inspect", "--project", projectURL.path, "--json"])
        #expect(inspection.exitCode == 0)
        let inspected = try JSONDecoder().decode(CLI.XcodeProjectInspection.self, from: Data(inspection.standardOutput.utf8))
        #expect(inspected.targets.contains { $0.name == "LiveFeature" && $0.configurations.contains("Debug") })
        let arguments = ["xcode", "install", "--project", projectURL.path, "--plan", input.path, "--json"]
        let first = app.run(arguments)
        #expect(first.exitCode == 0, "\(first.standardError)")
        let report = try JSONDecoder().decode(CLI.XcodeInstallationReport.self, from: Data(first.standardOutput.utf8))
        #expect(report.writtenRelativePaths.contains("Example.xcodeproj/project.pbxproj"))
        let projectData = try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj"))
        let installedText = String(decoding: projectData, as: UTF8.self)
        #expect(installedText.contains(untouched))
        #expect(installedText.contains(settings))
        _ = try PropertyListSerialization.propertyList(from: projectData, format: nil)
        let lint = try ProcessExecution.Runner().run(executable: URL(fileURLWithPath: "/usr/bin/plutil"),
            arguments: ["-lint", projectFile.path])
        #expect(lint.status == 0, "\(lint.standardError)")
        #expect(app.run(arguments).exitCode == 0)
        #expect(try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")) == projectData)
        #expect(try XcodeIntegration.HostPlanCodec.decode(Data(contentsOf: URL(fileURLWithPath: report.hostPlanPath))) == plan)
        plan.profiles[0].applicationTargetName = "MissingApp"
        try XcodeIntegration.HostPlanCodec.encode(plan).write(to: input)
        #expect(app.run(arguments).exitCode != 0)
        #expect(try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")) == projectData)
        plan.profiles[0].applicationTargetName = "LiveApp"
        plan.profiles[0].workflow = .hotPatch
        plan.profiles[0].deviceNativeMatrixQualified = nil
        plan.profiles[0].patch = .init(actionTargetName: "Patch", actionSchemeName: "Patch",
            recipePath: ".helix/MissingRecipe.json", signingCertificatePath: ".helix/Certificate.json",
            trustedRootPath: ".helix/TrustedRoot.json")
        try XcodeIntegration.HostPlanCodec.encode(plan).write(to: input)
        let missingAssets = app.run(arguments)
        #expect(missingAssets.exitCode != 0)
        #expect(missingAssets.standardError.contains("quick-patch recipe"))
        #expect(try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")) == projectData)
    }

    @Test("Fresh project receives both workflows idempotently")
    func installsBothWorkflows() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        var draft = Hub.OnboardingDraft(
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
        draft.profiles[1].indexing = .init(include: ["Sources/Feature/**"], failurePolicy: .excludeUnresolved)
        draft.profiles[1].deviceNativeMatrixQualified = true
        draft.runtimePackageRequirement = .init(kind: .revision, value: String(repeating: "a", count: 40))
        let plan = try Hub.OnboardingPlanner().plan(draft)
        let installer = Hub.ProjectInstaller()
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
            removalPlan: first.hostPlan,
            capabilities: first.capabilities,
            requirements: first.requirements,
            developmentIdentityProfiles: first.developmentIdentityProfiles
        )
        let restored = try Hub.DraftLoader().load(project: installed, record: record)
        #expect(restored.capabilities == draft.capabilities)
        #expect(restored.runtimePackageRequirement == draft.runtimePackageRequirement)
        #expect(restored.integrationRoot == draft.integrationRoot)
        #expect(restored.profiles.map(\.id) == ["hot", "live"])
        #expect(restored.profiles.map(\.featureTargetName) == ["HotFeature", "LiveFeature"])
        #expect(restored.profiles.first?.patch?.createDevelopmentIdentity == true)
        #expect(restored.profiles[1].indexing == draft.profiles[1].indexing)
        #expect(restored.profiles[1].deviceNativeMatrixQualified == true)
        #expect(try Hub.OnboardingPlanner().plan(restored).hostPlan == plan.hostPlan)
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
            "${SRCROOT:?}/.helix/xcode/Profiles/live/bridge.sh"
        ))
        #expect(projectText.contains("productName = HelixAppIntegration"))
        #expect(projectText.components(
            separatedBy: "productName = HelixAppIntegration"
        ).count - 1 == 2)
        #expect(projectText.components(
            separatedBy: "productName = HelixDevSupport"
        ).count - 1 == 1)
        #expect(projectText.contains("$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"))
        #expect(projectText.contains("NSBonjourServices"))
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
        func dependencyTargets(targetID: String) -> [String] {
            let identifiers = objects[targetID]?.dictionary?["dependencies"]?
                .array?.compactMap(\.string) ?? []
            return identifiers.compactMap {
                objects[$0]?.dictionary?["target"]?.string
            }
        }
        #expect(dependencyTargets(targetID: "HOTAPP") == ["HOTFEATURE"])
        #expect(dependencyTargets(targetID: "LIVEAPP") == ["LIVEFEATURE"])
        #expect(phaseNames(targetID: "HOTFEATURE") == [
            "PBXSourcesBuildPhase", "Helix Prepare (Generated)",
        ])
        #expect(phaseNames(targetID: "LIVEFEATURE") == [
            "PBXSourcesBuildPhase", "Helix Prepare (Generated)",
        ])
        #expect(phaseNames(targetID: "HOTAPP") == [
            "Helix Bridge (Generated)",
            "Embed Helix Runtime Resources (Generated)",
            "PBXSourcesBuildPhase",
            "PBXFrameworksBuildPhase",
        ])
        #expect(phaseNames(targetID: "LIVEAPP") == [
            "Helix Bridge (Generated)",
            "PBXSourcesBuildPhase",
            "PBXFrameworksBuildPhase",
            "Embed App Content",
            "Embed Helix Development Support (Generated)",
            "Configure Helix Development Info.plist (Generated)",
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
        #expect(!first.writtenRelativePaths.contains(
            ".helix/xcode/ProjectConfigurations/live-Application-Info.plist"
        ))
        let liveApplicationConfiguration = String(
            decoding: try Data(contentsOf: root.appendingPathComponent(
                ".helix/xcode/ProjectConfigurations/live-Application-Debug.xcconfig"
            )),
            as: UTF8.self
        )
        #expect(!liveApplicationConfiguration.contains("GENERATE_INFOPLIST_FILE"))
        #expect(!liveApplicationConfiguration.contains("INFOPLIST_FILE"))

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
            removalPlan: first.hostPlan,
            capabilities: first.capabilities,
            requirements: first.requirements,
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

    @Test("One App target receives both workflows without source edits")
    func installsSharedApplicationTarget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let plan = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.hotPatch, .liveReload]),
            profiles: [
                .init(
                    id: "hot",
                    capability: .hotPatch,
                    applicationTargetName: "HotApp",
                    featureTargetName: "HotApp",
                    featureModuleName: "HotApp",
                    schemeName: "Hot",
                    configurationName: "Release",
                    bundleIdentifier: "dev.example.hot",
                    namespaceSeed: "example-hot",
                    patch: .init()
                ),
                .init(
                    id: "live",
                    capability: .liveReload,
                    applicationTargetName: "HotApp",
                    featureTargetName: "HotApp",
                    featureModuleName: "HotApp",
                    schemeName: "Hot",
                    configurationName: "Debug",
                    bundleIdentifier: "dev.example.hot",
                    namespaceSeed: "example-live"
                ),
            ]
        ))
        let installer = Hub.ProjectInstaller()
        _ = try installer.install(plan)
        _ = try installer.install(plan)

        let installed = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        #expect(installed.target(named: "HotApp")?.packageProducts
            == ["HelixAppIntegration", "HelixDevSupport"])
        #expect(installed.target(named: "HotApp")?
            .baseConfigurationPaths["Debug"]?
            .contains("live-Target-Debug.xcconfig") == true)
        #expect(installed.target(named: "HotApp")?
            .baseConfigurationPaths["Release"]?
            .contains("hot-Target-Release.xcconfig") == true)
        let text = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")),
            as: UTF8.self
        )
        let triggerPath = ".helix/xcode/" + XcodeIntegration.CompilerCapture
            .targetTriggerPath(targetName: "HotApp")
        #expect(text.components(separatedBy: "Helix Refresh (Generated)").count - 1 == 2)
        #expect(!text.contains("Helix Prepare (Generated)"))
        #expect(!text.contains("Helix Bridge (Generated)"))
        #expect(!text.contains("HelixBridge.o in Frameworks"))
        #expect(!text.contains("HelixBootstrap.o in Frameworks"))
        #expect(text.components(
            separatedBy: "path = \(triggerPath);"
        ).count - 1 == 1)
        #expect(text.components(
            separatedBy: "$(SRCROOT)/\(triggerPath)"
        ).count - 1 == 2)
        #expect(text.components(
            separatedBy: "${SRCROOT:?}/\(triggerPath)"
        ).count - 1 == 2)
        #expect(!text.contains("Profiles/live/Compiler/HelixBuildTrigger_"))
        #expect(!text.contains("Profiles/hot/Compiler/HelixBuildTrigger_"))
        #expect(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(triggerPath).path))
        #expect(text.components(separatedBy: "productName = HelixAppIntegration").count - 1 == 1)
        #expect(text.components(separatedBy: "productName = HelixDevSupport").count - 1 == 1)
        #expect(!text.contains("HelixDevSupport in Frameworks"))
        let debugWrapper = String(
            decoding: try Data(contentsOf: root.appendingPathComponent(
                ".helix/xcode/ProjectConfigurations/live-Target-Debug.xcconfig"
            )),
            as: UTF8.self
        )
        #expect(debugWrapper.contains("Profiles/live/Feature.xcconfig"))
        #expect(debugWrapper.contains("Profiles/live/Application.xcconfig"))
        #expect(debugWrapper.contains("Profiles/live/Compiler/swiftc"))
        let liveApplication = String(
            decoding: try Data(contentsOf: root.appendingPathComponent(
                ".helix/xcode/Profiles/live/Application.xcconfig"
            )),
            as: UTF8.self
        )
        #expect(liveApplication.contains("-framework HelixDevSupport"))
        let scheme = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent(
                "xcshareddata/xcschemes/Hot.xcscheme"
            )),
            as: UTF8.self
        )
        #expect(scheme.components(separatedBy: "Helix Hub: Audit hot").count - 1 == 1)
        #expect(scheme.components(separatedBy: "Helix Hub: Register live").count - 1 == 1)
        #expect(scheme.contains("<LaunchAction buildConfiguration=\"Debug\""))
        #expect(scheme.contains("<ArchiveAction buildConfiguration=\"Debug\""))
        #expect(text.contains("HelixPatchPolicy.json"))
    }

    @Test("Reconfiguration removes stale mappings without touching scheme settings")
    func reconfiguresInstalledWorkflows() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        var projectSource = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        projectSource = projectSource.replacingOccurrences(
            of: "FRLIVE = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Live/Sources/Live.swift; sourceTree = SOURCE_ROOT; };",
            with: """
            FRLIVE = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Live/Sources/Live.swift; sourceTree = SOURCE_ROOT; };
                BASECONFIG = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = \"<group>\"; };
            """
        )
        projectSource = projectSource.replacingOccurrences(
            of: "MAIN = {isa = PBXGroup; children = (FRHOT, FRLIVE, ); sourceTree = \"<group>\"; };",
            with: """
            MAIN = {isa = PBXGroup; children = (FRHOT, FRLIVE, CONFIGGROUP, ); sourceTree = \"<group>\"; };
                CONFIGGROUP = {isa = PBXGroup; children = (BASECONFIG, ); path = Configurations; sourceTree = \"<group>\"; };
            """
        )
        projectSource = projectSource.replacingOccurrences(
            of: "CHA = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };",
            with: "CHA = {isa = XCBuildConfiguration; baseConfigurationReference = BASECONFIG; buildSettings = {}; name = Debug; };"
        )
        try Data(projectSource.utf8).write(to: projectFile)
        let baseConfiguration = root.appendingPathComponent(
            "Configurations/Base.xcconfig"
        )
        try FileManager.default.createDirectory(
            at: baseConfiguration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("PRODUCT_NAME = Original\n".utf8).write(to: baseConfiguration)
        let installer = Hub.ProjectInstaller()
        let initialProject = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let initial = try Hub.OnboardingPlanner().plan(.init(
            project: initialProject,
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
        ))
        _ = try installer.install(initial)
        let developerNote = root.appendingPathComponent(
            ".helix/xcode/developer-note.txt"
        )
        try Data("preserve me".utf8).write(to: developerNote)

        let installedProject = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let replacement = try Hub.OnboardingPlanner().plan(.init(
            project: installedProject,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotApp",
                featureModuleName: "HotApp",
                schemeName: "Hot",
                configurationName: "Release",
                bundleIdentifier: "dev.example.hot",
                namespaceSeed: "example-live"
            )]
        ))
        _ = try installer.install(replacement)
        _ = try installer.install(replacement)

        let reconfigured = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        #expect(reconfigured.target(named: "HotFeature")?
            .baseConfigurationPaths["Debug"] == nil)
        #expect(reconfigured.target(named: "LiveFeature")?
            .baseConfigurationPaths["Debug"] == nil)
        #expect(reconfigured.target(named: "LiveApp")?
            .baseConfigurationPaths["Debug"] == nil)
        #expect(reconfigured.target(named: "HotApp")?
            .baseConfigurationPaths["Debug"] == "Configurations/Base.xcconfig")
        #expect(reconfigured.target(named: "HotApp")?
            .baseConfigurationPaths["Release"]?
            .contains("live-Target-Release.xcconfig") == true)
        #expect(reconfigured.target(named: "LiveApp")?.packageProducts.isEmpty == true)
        #expect(reconfigured.target(named: "HotApp")?.packageProducts
            == ["HelixAppIntegration", "HelixDevSupport"])
        #expect(reconfigured.target(named: "HelixPatchAction") == nil)

        let projectText = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        #expect(projectText.contains(
            "baseConfigurationReference = BASECONFIG"
        ))
        #expect(projectText.components(
            separatedBy: "Helix Refresh (Generated)"
        ).count - 1 == 1)
        let triggerName = URL(fileURLWithPath: XcodeIntegration.CompilerCapture
            .targetTriggerPath(targetName: "HotApp")).lastPathComponent
        #expect(projectText.components(
            separatedBy: triggerName
        ).count - 1 == 3)
        #expect(!projectText.contains("Profiles/live/Compiler/HelixBuildTrigger_"))
        #expect(!projectText.contains("Profiles/hot/Compiler/HelixBuildTrigger_"))
        #expect(!projectText.contains("Helix Bridge (Generated)"))
        #expect(!projectText.contains("Helix Prepare (Generated)"))
        #expect(!projectText.contains("Embed Helix Runtime Resources (Generated)"))
        var reconfiguredParser = try Hub.OpenStep.Parser(
            data: Data(projectText.utf8)
        )
        let reconfiguredRoot = try #require(
            try reconfiguredParser.parse().dictionary
        )
        let reconfiguredObjects = try #require(
            reconfiguredRoot["objects"]?.dictionary
        )
        #expect(reconfiguredObjects["HOTAPP"]?.dictionary?["dependencies"]?
            .array?.isEmpty == true)
        #expect(reconfiguredObjects["LIVEAPP"]?.dictionary?["dependencies"]?
            .array?.isEmpty == true)

        let hotSchemeURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes/Hot.xcscheme"
        )
        let hotScheme = String(
            decoding: try Data(contentsOf: hotSchemeURL),
            as: UTF8.self
        )
        #expect(hotScheme.components(
            separatedBy: "Helix Hub: Register live"
        ).count - 1 == 1)
        #expect(!hotScheme.contains("Helix Hub: Audit"))
        #expect(hotScheme.contains("<LaunchAction buildConfiguration=\"Debug\""))
        #expect(hotScheme.contains("<ArchiveAction buildConfiguration=\"Debug\""))

        let liveScheme = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent(
                "xcshareddata/xcschemes/Live.xcscheme"
            )),
            as: UTF8.self
        )
        #expect(!liveScheme.contains("Helix Hub:"))
        #expect(!FileManager.default.fileExists(atPath: projectURL
            .appendingPathComponent(
                "xcshareddata/xcschemes/Helix Build Patch.xcscheme"
            ).path))
        let stored = try XcodeIntegration.HostPlanCodec.decode(Data(
            contentsOf: root.appendingPathComponent(".helix/xcode/HostPlan.json")
        ))
        #expect(stored.profiles.map(\.workflow) == [.liveReload])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ".helix/xcode/Profiles/hot/Profile.xcconfig"
        ).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ".helix/xcode/ProjectConfigurations/hot-Feature-Debug.xcconfig"
        ).path))
        #expect(String(
            decoding: try Data(contentsOf: developerNote),
            as: UTF8.self
        ) == "preserve me")
    }

    @Test("Generated phase names do not claim a developer-owned build phase")
    func preservesDeveloperPhaseWithGeneratedName() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        var source = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        source = source.replacingOccurrences(
            of: "/* Begin PBXNativeTarget section */",
            with: """
            /* Begin PBXShellScriptBuildPhase section */
                USERHELIX = {isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Helix Refresh (Generated)"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "echo user-owned"; showEnvVarsInLog = 0; };
            /* End PBXShellScriptBuildPhase section */
            /* Begin PBXNativeTarget section */
            """
        )
        source = source.replacingOccurrences(
            of: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, );",
            with: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (USERHELIX, SPHA, );"
        )
        try Data(source.utf8).write(to: projectFile)

        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotApp",
                featureModuleName: "HotApp",
                schemeName: "Hot",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.hot",
                namespaceSeed: "example-live"
            )]
        ))
        let installer = Hub.ProjectInstaller()
        let installation = try installer.install(onboarding)
        _ = try installer.install(onboarding)

        var installedText = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        #expect(installedText.contains("echo user-owned"))
        #expect(installedText.contains("# Generated by Helix Hub. Do not edit."))
        #expect(installedText.components(
            separatedBy: "Helix Refresh (Generated)"
        ).count - 1 == 2)

        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            removalPlan: installation.hostPlan,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            developmentIdentityProfiles: installation.developmentIdentityProfiles
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )

        installedText = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        #expect(installedText.contains("echo user-owned"))
        #expect(installedText.contains("Helix Refresh (Generated)"))
        #expect(!installedText.contains("# Generated by Helix Hub. Do not edit."))
    }

    @Test("Development support is configuration-scoped despite stale Xcode linkage")
    func normalizesStaleDevelopmentSupportLinkage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        var source = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        source = source.replacingOccurrences(
            of: "BFLIVE = {isa = PBXBuildFile; fileRef = FRLIVE; };",
            with: """
            BFLIVE = {isa = PBXBuildFile; fileRef = FRLIVE; };
                DEVLINK = {isa = PBXBuildFile; productRef = DEVPRODUCT; };
                DEVEMBED = {isa = PBXBuildFile; productRef = DEVPRODUCT; };
            """
        )
        source = source.replacingOccurrences(
            of: "/* Begin PBXNativeTarget section */",
            with: """
            /* Begin PBXFrameworksBuildPhase section */
                DEVFRAMEWORKS = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (DEVLINK, ); runOnlyForDeploymentPostprocessing = 0; };
            /* End PBXFrameworksBuildPhase section */
            /* Begin PBXCopyFilesBuildPhase section */
                DEVEMBEDPHASE = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (DEVEMBED, ); runOnlyForDeploymentPostprocessing = 0; };
            /* End PBXCopyFilesBuildPhase section */
            /* Begin PBXNativeTarget section */
            """
        )
        source = source.replacingOccurrences(
            of: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = (); name = HotApp; packageProductDependencies = ();",
            with: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, DEVFRAMEWORKS, DEVEMBEDPHASE, ); buildRules = (); dependencies = (); name = HotApp; packageProductDependencies = (DEVPRODUCT, );"
        )
        source = source.replacingOccurrences(
            of: "/* Begin XCLocalSwiftPackageReference section */",
            with: """
            /* Begin XCSwiftPackageProductDependency section */
                DEVPRODUCT = {isa = XCSwiftPackageProductDependency; package = HELIXPACKAGE; productName = HelixDevSupport; };
            /* End XCSwiftPackageProductDependency section */
            /* Begin XCLocalSwiftPackageReference section */
            """
        )
        try Data(source.utf8).write(to: projectFile)

        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotApp",
                featureModuleName: "HotApp",
                schemeName: "Hot",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.hot",
                namespaceSeed: "example-live"
            )]
        ))
        let installer = Hub.ProjectInstaller()
        _ = try installer.install(onboarding)
        _ = try installer.install(onboarding)

        var parser = try Hub.OpenStep.Parser(data: Data(contentsOf: projectFile))
        let rootObject = try #require(try parser.parse().dictionary)
        let objects = try #require(rootObject["objects"]?.dictionary)
        for phaseID in ["DEVFRAMEWORKS", "DEVEMBEDPHASE"] {
            let files = objects[phaseID]?.dictionary?["files"]?
                .array?.compactMap(\.string) ?? []
            let productNames = files.compactMap { buildFileID -> String? in
                guard let productID = objects[buildFileID]?
                    .dictionary?["productRef"]?.string
                else { return nil }
                return objects[productID]?.dictionary?["productName"]?.string
            }
            #expect(!productNames.contains("HelixDevSupport"))
        }
        #expect(objects["DEVLINK"] == nil)
        #expect(objects["DEVEMBED"] == nil)
        let targetObject = try #require(objects["HOTAPP"]?.dictionary)
        let productIDs = targetObject["packageProductDependencies"]?
            .array?.compactMap(\.string) ?? []
        let installedProducts = productIDs.compactMap {
            objects[$0]?.dictionary?["productName"]?.string
        }
        #expect(installedProducts == ["HelixAppIntegration", "HelixDevSupport"])
        #expect(objects["DEVPRODUCT"] == nil)
        let installed = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        #expect(installed.contains("Embed Helix Development Support (Generated)"))
    }

    @Test("Existing App integration linkage is reused and restored")
    func preservesDeveloperRuntimeLinkage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        var source = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        source = source.replacingOccurrences(
            of: "BFLIVE = {isa = PBXBuildFile; fileRef = FRLIVE; };",
            with: """
            BFLIVE = {isa = PBXBuildFile; fileRef = FRLIVE; };
                USERAPPBUILD = {isa = PBXBuildFile; productRef = USERAPPPRODUCT; };
            """
        )
        source = source.replacingOccurrences(
            of: "/* Begin PBXNativeTarget section */",
            with: """
            /* Begin PBXFrameworksBuildPhase section */
                USERFRAMEWORKS = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (USERAPPBUILD, ); runOnlyForDeploymentPostprocessing = 0; };
            /* End PBXFrameworksBuildPhase section */
            /* Begin PBXNativeTarget section */
            """
        )
        source = source.replacingOccurrences(
            of: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = (); name = HotApp; packageProductDependencies = ();",
            with: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, USERFRAMEWORKS, ); buildRules = (); dependencies = (); name = HotApp; packageProductDependencies = (USERAPPPRODUCT, );"
        )
        source = source.replacingOccurrences(
            of: "/* Begin XCLocalSwiftPackageReference section */",
            with: """
            /* Begin XCSwiftPackageProductDependency section */
                USERAPPPRODUCT = {isa = XCSwiftPackageProductDependency; package = HELIXPACKAGE; productName = HelixAppIntegration; };
            /* End XCSwiftPackageProductDependency section */
            /* Begin XCLocalSwiftPackageReference section */
            """
        )
        try Data(source.utf8).write(to: projectFile)

        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotApp",
                featureModuleName: "HotApp",
                schemeName: "Hot",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.hot",
                namespaceSeed: "example-live"
            )]
        ))
        let installer = Hub.ProjectInstaller()
        let installation = try installer.install(onboarding)
        _ = try installer.install(onboarding)

        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            removalPlan: installation.hostPlan,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            developmentIdentityProfiles: installation.developmentIdentityProfiles
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )

        var parser = try Hub.OpenStep.Parser(data: Data(contentsOf: projectFile))
        let rootObject = try #require(try parser.parse().dictionary)
        let objects = try #require(rootObject["objects"]?.dictionary)
        #expect(objects["HOTAPP"]?.dictionary?["packageProductDependencies"]?
            .array?.compactMap(\.string) == ["USERAPPPRODUCT"])
        #expect(objects["USERFRAMEWORKS"]?.dictionary?["files"]?
            .array?.compactMap(\.string) == ["USERAPPBUILD"])
        #expect(objects["USERAPPPRODUCT"]?.dictionary?["productName"]?.string
            == "HelixAppIntegration")
        #expect(objects["USERAPPBUILD"]?.dictionary?["productRef"]?.string
            == "USERAPPPRODUCT")
    }

    @Test("Generated action titles do not claim a developer-owned scheme action")
    func preservesDeveloperSchemeActionWithGeneratedTitle() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let schemeURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes/Hot.xcscheme"
        )
        var schemeSource = String(
            decoding: try Data(contentsOf: schemeURL),
            as: UTF8.self
        )
        schemeSource = schemeSource.replacingOccurrences(
            of: "<BuildActionEntries></BuildActionEntries>",
            with: """
            <PostActions>
              <ExecutionAction ActionType="Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
                <ActionContent title="Helix Hub: Audit hot" scriptText="echo user-owned scheme"/>
              </ExecutionAction>
            </PostActions>
            <BuildActionEntries></BuildActionEntries>
            """
        )
        try Data(schemeSource.utf8).write(to: schemeURL)

        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.hotPatch]),
            profiles: [.init(
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
            )]
        ))
        let installer = Hub.ProjectInstaller()
        let installation = try installer.install(onboarding)
        _ = try installer.install(onboarding)

        var configured = String(
            decoding: try Data(contentsOf: schemeURL),
            as: UTF8.self
        )
        #expect(configured.contains("echo user-owned scheme"))
        #expect(configured.components(
            separatedBy: "Helix Hub: Audit hot"
        ).count - 1 == 2)
        #expect(configured.components(
            separatedBy: "Generated by Helix Hub. Do not edit."
        ).count - 1 == 1)

        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            removalPlan: installation.hostPlan,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            developmentIdentityProfiles: installation.developmentIdentityProfiles
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )

        configured = String(
            decoding: try Data(contentsOf: schemeURL),
            as: UTF8.self
        )
        #expect(configured.contains("echo user-owned scheme"))
        #expect(configured.components(
            separatedBy: "Helix Hub: Audit hot"
        ).count - 1 == 1)
        #expect(!configured.contains("Generated by Helix Hub. Do not edit."))
    }

    @Test("Existing source target dependency is reused and preserved")
    func preservesDeveloperFeatureDependency() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        var source = String(
            decoding: try Data(contentsOf: projectFile),
            as: UTF8.self
        )
        source = source.replacingOccurrences(
            of: "/* Begin PBXNativeTarget section */",
            with: """
            /* Begin PBXContainerItemProxy section */
                USERPROXY = {isa = PBXContainerItemProxy; containerPortal = PROJECT; proxyType = 1; remoteGlobalIDString = HOTFEATURE; remoteInfo = HotFeature; };
            /* End PBXContainerItemProxy section */
            /* Begin PBXTargetDependency section */
                USERDEPENDENCY = {isa = PBXTargetDependency; target = HOTFEATURE; targetProxy = USERPROXY; };
            /* End PBXTargetDependency section */
            /* Begin PBXNativeTarget section */
            """
        )
        source = source.replacingOccurrences(
            of: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = ();",
            with: "HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = (USERDEPENDENCY, );"
        )
        try Data(source.utf8).write(to: projectFile)

        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotFeature",
                featureModuleName: "HotFeature",
                schemeName: "Hot",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.hot",
                namespaceSeed: "example-live"
            )]
        ))
        let installer = Hub.ProjectInstaller()
        let installation = try installer.install(onboarding)
        _ = try installer.install(onboarding)

        func dependencies() throws -> [String] {
            var parser = try Hub.OpenStep.Parser(data: Data(contentsOf: projectFile))
            let root = try #require(try parser.parse().dictionary)
            let objects = try #require(root["objects"]?.dictionary)
            return objects["HOTAPP"]?.dictionary?["dependencies"]?
                .array?.compactMap(\.string) ?? []
        }
        #expect(try dependencies() == ["USERDEPENDENCY"])

        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            removalPlan: installation.hostPlan,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            developmentIdentityProfiles: installation.developmentIdentityProfiles
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )
        #expect(try dependencies() == ["USERDEPENDENCY"])
    }

    @Test("Removing Helix restores the project and preserves developer files")
    func uninstallsOwnedIntegration() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(
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
        ))
        let installer = Hub.ProjectInstaller()
        let installation = try installer.install(onboarding)
        let developerNote = root.appendingPathComponent(
            ".helix/xcode/developer-note.txt"
        )
        try Data("preserve me".utf8).write(to: developerNote)
        let record = try Hub.ProjectRecord(
            name: "Example",
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            removalPlan: installation.hostPlan,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            developmentIdentityProfiles: installation.developmentIdentityProfiles
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )
        try installer.uninstall(
            project: try Hub.ProjectFileParser().parse(projectURL: projectURL),
            record: record
        )

        let restored = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        #expect(restored.targets.allSatisfy {
            !$0.packageProducts.contains("HelixAppIntegration")
                && !$0.packageProducts.contains("HelixDevSupport")
        })
        #expect(restored.target(named: "HelixPatchAction") == nil)
        #expect(restored.targets.allSatisfy { $0.baseConfigurationPaths.isEmpty })
        let projectText = String(
            decoding: try Data(contentsOf: projectURL.appendingPathComponent(
                "project.pbxproj"
            )),
            as: UTF8.self
        )
        #expect(!projectText.contains("Helix "))
        #expect(!projectText.contains("HelixBuildTrigger_"))
        for name in ["Hot", "Live"] {
            let scheme = String(
                decoding: try Data(contentsOf: projectURL.appendingPathComponent(
                    "xcshareddata/xcschemes/\(name).xcscheme"
                )),
                as: UTF8.self
            )
            #expect(!scheme.contains("Helix Hub:"))
        }
        #expect(!FileManager.default.fileExists(atPath: projectURL
            .appendingPathComponent(
                "xcshareddata/xcschemes/Helix Build Patch.xcscheme"
            ).path))
        for path in [
            ".helix/xcode/HostPlan.json",
            ".helix/xcode/IntegrationManifest.json",
            ".helix/xcode/GeneratedFiles.json",
            ".helix/xcode/Profiles/live/Profile.xcconfig",
            ".helix/xcode/ProjectConfigurations/live-Application-Info.plist",
        ] {
            #expect(!FileManager.default.fileExists(atPath: root
                .appendingPathComponent(path).path))
        }
        #expect(String(
            decoding: try Data(contentsOf: developerNote),
            as: UTF8.self
        ) == "preserve me")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Configurations/Helix/QuickPatchRecipe.json"
        ).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ".helix/private/PatchSigningKey.json"
        ).path))
    }

    @Test("Every development build augments the processed plist without copying source metadata")
    func augmentsProcessedInformationPropertyList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-info-plist-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source Info's.plist")
        let productURL = root.appendingPathComponent("Build/Example.app/Info.plist")
        try FileManager.default.createDirectory(
            at: productURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "CFBundleDisplayName": "Example",
            "NSBonjourServices": ["_business._tcp"],
            "NSLocalNetworkUsageDescription": "Find nearby business devices.",
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: original,
            format: .binary,
            options: 0
        )
        try originalData.write(to: sourceURL)
        try originalData.write(to: productURL)

        let first = try runDevelopmentNetworkConfiguration(
            configuration: "Debug",
            productURL: productURL
        )
        #expect(first.status == 0, Comment(rawValue: first.standardError))
        #expect(try Data(contentsOf: sourceURL) == originalData)
        let configured = try propertyList(at: productURL)
        #expect(configured["NSBonjourServices"] as? [String]
            == ["_business._tcp", "_helix._tcp"])
        #expect(configured["NSLocalNetworkUsageDescription"] as? String
            == "Find nearby business devices.")
        #expect(configured["CFBundleDisplayName"] as? String == "Example")

        var updated = original
        updated["CFBundleDisplayName"] = "Updated by the product"
        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .binary,
            options: 0
        )
        try updatedData.write(to: sourceURL)
        // Simulate Xcode producing the next build from the product's current plist.
        try updatedData.write(to: productURL)
        let second = try runDevelopmentNetworkConfiguration(
            configuration: "Debug",
            productURL: productURL
        )
        #expect(second.status == 0, Comment(rawValue: second.standardError))
        #expect(try Data(contentsOf: sourceURL) == updatedData)
        let refreshed = try propertyList(at: productURL)
        #expect(refreshed["CFBundleDisplayName"] as? String
            == "Updated by the product")
        #expect(refreshed["NSBonjourServices"] as? [String]
            == ["_business._tcp", "_helix._tcp"])
    }

    @Test("Xcode-generated plists receive development declarations idempotently")
    func augmentsGeneratedInformationPropertyList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-generated-info-plist-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let productURL = root.appendingPathComponent("Build/Generated.app/Info.plist")
        try FileManager.default.createDirectory(
            at: productURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let generatedData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "dev.example.generated"],
            format: .binary,
            options: 0
        )
        try generatedData.write(to: productURL)

        for _ in 0..<2 {
            let result = try runDevelopmentNetworkConfiguration(
                configuration: "Debug",
                productURL: productURL
            )
            #expect(result.status == 0, Comment(rawValue: result.standardError))
        }
        let configured = try propertyList(at: productURL)
        #expect(configured["CFBundleIdentifier"] as? String == "dev.example.generated")
        #expect(configured["NSBonjourServices"] as? [String] == ["_helix._tcp"])
        #expect(configured["NSLocalNetworkUsageDescription"] as? String
            == Hub.DevelopmentNetworkConfiguration.usageDescription)
    }

    @Test("Development plist setup is scoped and rejects invalid product declarations")
    func validatesDevelopmentInformationPropertyList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-invalid-info-plist-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let productURL = root.appendingPathComponent("Build/Invalid.app/Info.plist")
        try FileManager.default.createDirectory(
            at: productURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let invalidData = try PropertyListSerialization.data(
            fromPropertyList: ["NSBonjourServices": "_business._tcp"],
            format: .xml,
            options: 0
        )
        try invalidData.write(to: productURL)

        let release = try runDevelopmentNetworkConfiguration(
            configuration: "Release",
            productURL: productURL
        )
        #expect(release.status == 0)
        #expect(try Data(contentsOf: productURL) == invalidData)
        let debug = try runDevelopmentNetworkConfiguration(
            configuration: "Debug",
            productURL: productURL
        )
        #expect(debug.status != 0)
        #expect(debug.standardError.contains("NSBonjourServices must be an array"))

        let missingURL = root.appendingPathComponent("Build/Missing.app/Info.plist")
        try FileManager.default.createDirectory(
            at: missingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let missing = try runDevelopmentNetworkConfiguration(
            configuration: "Debug",
            productURL: missingURL
        )
        #expect(missing.status != 0)
        #expect(missing.standardError.contains("processed App Info.plist"))

        let linkedURL = root.appendingPathComponent("Build/Linked.app/Info.plist")
        let externalURL = root.appendingPathComponent("External.plist")
        try FileManager.default.createDirectory(
            at: linkedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try invalidData.write(to: externalURL)
        try FileManager.default.createSymbolicLink(
            atPath: linkedURL.path,
            withDestinationPath: externalURL.path
        )
        let linked = try runDevelopmentNetworkConfiguration(
            configuration: "Debug",
            productURL: linkedURL
        )
        #expect(linked.status != 0)
        #expect(linked.standardError.contains("processed App Info.plist"))
        #expect(try Data(contentsOf: externalURL) == invalidData)
    }

    @Test("A normal App receives a runnable shared scheme automatically")
    func createsSharedApplicationScheme() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let schemes = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        for name in ["Hot", "Live"] {
            try FileManager.default.removeItem(
                at: schemes.appendingPathComponent("\(name).xcscheme")
            )
        }
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        #expect(project.sharedSchemes.isEmpty)
        let plan = try Hub.OnboardingPlanner().plan(.init(
            project: project,
            capabilities: try .init([.liveReload]),
            profiles: [.init(
                id: "live",
                capability: .liveReload,
                applicationTargetName: "HotApp",
                featureTargetName: "HotApp",
                featureModuleName: "HotApp",
                schemeName: "HotApp",
                configurationName: "Debug",
                bundleIdentifier: "dev.example.live",
                namespaceSeed: "example-live"
            )]
        ))
        let installer = Hub.ProjectInstaller()
        _ = try installer.install(plan)
        _ = try installer.install(plan)

        let schemeURL = schemes.appendingPathComponent("HotApp.xcscheme")
        let scheme = String(
            decoding: try Data(contentsOf: schemeURL),
            as: UTF8.self
        )
        #expect(scheme.contains("BuildableProductRunnable"))
        #expect(scheme.contains("BlueprintIdentifier=\"HOTAPP\""))
        #expect(scheme.contains("buildConfiguration=\"Debug\""))
        #expect(scheme.components(
            separatedBy: "Helix Hub: Register live"
        ).count - 1 == 1)
    }

    @Test("PBX edits distinguish top-level targets from TargetAttributes entries")
    func editsTopLevelPBXObjectOnly() throws {
        let input = """
        {
          objects = {
            PROJECT = {
              isa = PBXProject;
              attributes = {
                TargetAttributes = {
                  TARGET = { CreatedOnToolsVersion = 26.0; };
                };
              };
            };
            TARGET = {
              isa = PBXNativeTarget;
              name = Before;
            };
          };
          rootObject = PROJECT;
        }
        """
        var document = try Hub.PBXProjectDocument(data: Data(input.utf8))
        try document.updateObject("TARGET") { target in
            target["name"] = .string("After")
        }

        let output = try document.serialized()
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains(
            "TARGET = { CreatedOnToolsVersion = 26.0; };"
        ))
        var parser = try Hub.OpenStep.Parser(data: output)
        let root = try #require(try parser.parse().dictionary)
        let objects = try #require(root["objects"]?.dictionary)
        #expect(objects["TARGET"]?.dictionary?["name"]?.string == "After")
        let attributes = objects["PROJECT"]?.dictionary?["attributes"]?.dictionary
        let targetAttributes = attributes?["TargetAttributes"]?.dictionary
        #expect(
            targetAttributes?["TARGET"]?.dictionary?["CreatedOnToolsVersion"]?.string
                == "26.0"
        )
    }

    @Test("Repeated configuration names report object identities instead of trapping")
    func duplicateConfigurationNames() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj")
        let pbx = project.appendingPathComponent("project.pbxproj")
        let text = try String(contentsOf: pbx, encoding: .utf8)
            .replacingOccurrences(of: "buildConfigurations = (CLF, );", with: "buildConfigurations = (CLF, CLA, );")
        try Data(text.utf8).write(to: pbx)
        do {
            _ = try Hub.ProjectFileParser().parse(projectURL: project)
            Issue.record("Expected duplicate configuration rejection")
        } catch {
            let message = String(describing: error)
            for fact in ["CLLF", "Debug", "CLF", "CLA"] { #expect(message.contains(fact), "\(message)") }
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

    @Test("Failed generated-file cleanup restores earlier deletions")
    func rollsBackFileDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-deletion-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("a-victim.txt")
        try Data("owned generated content".utf8).write(to: victim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: victim.path
        )
        let linkTarget = root.appendingPathComponent("link-target.txt")
        try Data("outside deletion set".utf8).write(to: linkTarget)
        let link = root.appendingPathComponent("z-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: linkTarget.path
        )

        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction().commit(
                root: root,
                mutations: [],
                deletions: ["a-victim.txt", "z-link"]
            )
        }
        #expect(String(
            decoding: try Data(contentsOf: victim),
            as: UTF8.self
        ) == "owned generated content")
        #expect(permissions(victim) == 0o640)
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(String(
            decoding: try Data(contentsOf: linkTarget),
            as: UTF8.self
        ) == "outside deletion set")
    }

    @Test("Dangling symbolic links cannot become generated files or deletions")
    func rejectsDanglingSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-dangling-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("generated.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: root.appendingPathComponent("missing.txt").path
        )

        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction().commit(
                root: root,
                mutations: [.init(
                    relativePath: "generated.txt",
                    data: Data("new".utf8),
                    permissions: 0o644
                )]
            )
        }
        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction().commit(
                root: root,
                mutations: [],
                deletions: ["generated.txt"]
            )
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path
        ).hasSuffix("missing.txt"))
    }

    @Test("Runtime pins update only owned references and reject conflicting package authority")
    func pinsRuntimePackage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: projectFile)
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        var onboarding = try Hub.OnboardingPlanner().plan(.init(project: project, capabilities: .init([.liveReload]),
            profiles: [.init(id: "live", capability: .liveReload, applicationTargetName: "LiveApp",
                featureTargetName: "LiveFeature", featureModuleName: "LiveFeature", schemeName: "Live",
                configurationName: "Debug", bundleIdentifier: "dev.example.live", namespaceSeed: "pin-fixture")]))
        let revision = String(repeating: "a", count: 40)
        onboarding.hostPlan.runtimePackageRequirement = .init(kind: .revision, value: revision)
        let extra = "EXTRA_PRODUCT = {isa = XCSwiftPackageProductDependency; package = HELIXPACKAGE; productName = HelixAppIntegration; };"
        try Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "objects = {", with: "objects = {\n" + extra).utf8).write(to: projectFile)
        let localBytes = try Data(contentsOf: projectFile)
        do {
            _ = try Hub.ProjectInstaller().install(onboarding)
            Issue.record("An explicit remote pin cannot silently use a local package")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("HELIXPACKAGE") && text.contains("XCLocalSwiftPackageReference"))
            #expect(text.contains(revision) && text.contains("HostPlan.runtimePackageRequirement"))
        }
        #expect(try Data(contentsOf: projectFile) == localBytes)
        try original.write(to: projectFile)
        let installer = Hub.ProjectInstaller()
        _ = try installer.install(onboarding)
        var parser = try Hub.OpenStep.Parser(data: Data(contentsOf: projectFile))
        let objects = try #require(try parser.parse().dictionary?["objects"]?.dictionary)
        let remotes = objects.filter { $0.value.dictionary?["isa"]?.string == "XCRemoteSwiftPackageReference" }
        try #require(remotes.count == 1)
        let ownedID = try #require(remotes.keys.first)
        #expect(remotes[ownedID]?.dictionary?["requirement"]?.dictionary?["revision"]?.string == revision)
        onboarding.hostPlan.runtimePackageRequirement = .init(kind: .exactVersion, value: "1.2.3")
        let installed = try installer.install(onboarding)
        let versionBytes = try Data(contentsOf: projectFile)
        #expect(String(decoding: versionBytes, as: UTF8.self).contains("exactVersion"))
        // Existing user-owned references are reusable only when already equal.
        try Data(String(decoding: versionBytes, as: UTF8.self).replacingOccurrences(of: ownedID, with: "USER_RUNTIME_REFERENCE").utf8).write(to: projectFile)
        _ = try installer.install(onboarding)
        let userBytes = try Data(contentsOf: projectFile)
        let planBytes = try Data(contentsOf: installed.hostPlanURL)
        onboarding.hostPlan.runtimePackageRequirement = .init(kind: .revision, value: revision)
        do {
            _ = try installer.install(onboarding)
            Issue.record("Conflicting user package policy must fail before publication")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("USER_RUNTIME_REFERENCE") && text.contains("1.2.3") && text.contains(revision))
        }
        #expect(try Data(contentsOf: projectFile) == userBytes)
        #expect(try Data(contentsOf: installed.hostPlanURL) == planBytes)
        onboarding.hostPlan.runtimePackageRequirement = .init(kind: .exactVersion, value: "1.2.3")
        try Data(String(decoding: userBytes, as: UTF8.self).replacingOccurrences(of: "objects = {", with: "objects = {\n" + extra).utf8).write(to: projectFile)
        let ambiguousBytes = try Data(contentsOf: projectFile)
        do {
            _ = try installer.install(onboarding)
            Issue.record("Multiple runtime authorities must not choose the first")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("ambiguous") && text.contains("USER_RUNTIME_REFERENCE") && text.contains("HELIXPACKAGE"))
        }
        #expect(try Data(contentsOf: projectFile) == ambiguousBytes)
    }

    @Test("Headless uninstall validates the applied plan and preserves source, private keys and developer files")
    func uninstallsThroughCLI() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(project: project, capabilities: .init([.liveReload]),
            profiles: [.init(id: "live", capability: .liveReload, applicationTargetName: "LiveApp",
                featureTargetName: "LiveFeature", featureModuleName: "LiveFeature", schemeName: "Live",
                configurationName: "Debug", bundleIdentifier: "dev.example.live", namespaceSeed: "uninstall-fixture")]))
        let installed = try Hub.ProjectInstaller().install(onboarding)
        let backup = root.appendingPathComponent("RemovalPlan.json")
        try XcodeIntegration.HostPlanCodec.encode(onboarding.hostPlan).write(to: backup)
        let note = root.appendingPathComponent(".helix/xcode/developer-note.txt")
        try Data("preserve note".utf8).write(to: note)
        let key = root.appendingPathComponent("SigningKey.json")
        try Data("preserve key".utf8).write(to: key)
        let source = root.appendingPathComponent("Live/Sources/Live.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("public func live() -> Int { 42 }\n".utf8)
        try sourceBytes.write(to: source)
        let installedPBX = try Data(contentsOf: projectFile)
        var wrong = onboarding.hostPlan
        wrong.profiles[0].namespaceSeed = "wrong-backup"
        try XcodeIntegration.HostPlanCodec.encode(wrong).write(to: backup)
        let app = CLI.Application(currentDirectoryURL: root)
        let arguments = ["xcode", "uninstall", "--project", projectURL.path, "--plan", backup.path, "--json"]
        let rejected = app.run(arguments)
        #expect(rejected.exitCode != 0)
        #expect(rejected.standardError.contains("wrong-backup") && rejected.standardError.contains("uninstall-fixture"))
        #expect(try Data(contentsOf: projectFile) == installedPBX)
        try XcodeIntegration.HostPlanCodec.encode(onboarding.hostPlan).write(to: backup)
        let removed = app.run(arguments)
        #expect(removed.exitCode == 0, "\(removed.standardError)")
        let report = try JSONDecoder().decode(CLI.XcodeUninstallationReport.self, from: Data(removed.standardOutput.utf8))
        #expect(report.projectPath == projectURL.path && report.hostPlanPath == installed.hostPlanURL.path)
        #expect(!FileManager.default.fileExists(atPath: installed.hostPlanURL.path))
        #expect(app.run(arguments).exitCode == 0)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try Data(contentsOf: note) == Data("preserve note".utf8))
        #expect(try Data(contentsOf: key) == Data("preserve key".utf8))
        #expect(!String(decoding: try Data(contentsOf: projectFile), as: UTF8.self).contains("Helix Prepare"))
    }

    @Test("Install and both removal entry points reject a competing project operation without writes")
    func coordinatesProjectOperations() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj")
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
        let onboarding = try Hub.OnboardingPlanner().plan(.init(project: project, capabilities: .init([.liveReload]),
            profiles: [.init(id: "live", capability: .liveReload, applicationTargetName: "LiveApp",
                featureTargetName: "LiveFeature", featureModuleName: "LiveFeature", schemeName: "Live",
                configurationName: "Debug", bundleIdentifier: "dev.example.live", namespaceSeed: "lock-fixture")]))
        let installer = Hub.ProjectInstaller()
        let lock = try Hub.ProjectOperationLock(projectURL: projectURL)
        defer { lock.unlock() }
        let original = try Data(contentsOf: projectFile)
        #expect(throws: Hub.Error.self) { try installer.install(onboarding) }
        #expect(throws: Hub.Error.self) { try installer.uninstall(project: project, plan: onboarding.hostPlan) }
        #expect(try Data(contentsOf: projectFile) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".helix/xcode/HostPlan.json").path))
        let alias = root.appendingPathComponent("Alias.xcodeproj")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: projectURL)
        #expect(throws: Hub.Error.self) { try Hub.ProjectOperationLock(projectURL: alias) }
        let independent = root.appendingPathComponent("Other.xcodeproj")
        try FileManager.default.createDirectory(at: independent, withIntermediateDirectories: false)
        let independentLock = try Hub.ProjectOperationLock(projectURL: independent)
        independentLock.unlock()
        lock.unlock()
        let installed = try installer.install(onboarding)
        let held = try Hub.ProjectOperationLock(projectURL: projectURL)
        defer { held.unlock() }
        let record = try Hub.ProjectRecord(name: project.name, projectURL: projectURL, hostPlanURL: installed.hostPlanURL,
            removalPlan: installed.hostPlan, capabilities: installed.capabilities, requirements: [], developmentIdentityProfiles: [])
        let installedBytes = try Data(contentsOf: projectFile)
        #expect(throws: Hub.Error.self) { try installer.uninstall(project: project, record: record) }
        #expect(try Data(contentsOf: projectFile) == installedBytes)
        held.unlock()
        try installer.uninstall(project: project, plan: onboarding.hostPlan)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-install-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
        let projectText = pbxproj.replacingOccurrences(
            of: "__HELIX_REPOSITORY__",
            with: repository
        )
        try Data(projectText.utf8).write(
            to: project.appendingPathComponent("project.pbxproj")
        )
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

    private func runDevelopmentNetworkConfiguration(
        configuration: String,
        productURL: URL
    ) throws -> ProcessExecution.Result {
        let productDirectory = productURL.deletingLastPathComponent()
        let targetBuildDirectory = productDirectory.deletingLastPathComponent()
        return try ProcessExecution.Runner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                Hub.DevelopmentNetworkConfiguration().script(
                    configurationName: "Debug"
                ),
            ],
            environment: [
                "CONFIGURATION": configuration,
                "TARGET_BUILD_DIR": targetBuildDirectory.path,
                "INFOPLIST_PATH": productDirectory.lastPathComponent
                    + "/" + productURL.lastPathComponent,
            ],
            workingDirectory: targetBuildDirectory
        )
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
        /* Begin PBXCopyFilesBuildPhase section */
            USEREMBED = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (); name = "Embed App Content"; runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXCopyFilesBuildPhase section */
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
            HOTAPP = {isa = PBXNativeTarget; buildConfigurationList = CLHA; buildPhases = (SPHA, ); buildRules = (); dependencies = (); name = HotApp; packageProductDependencies = (); productName = HotApp; productType = "com.apple.product-type.application"; };
            LIVEFEATURE = {isa = PBXNativeTarget; buildConfigurationList = CLLF; buildPhases = (SPLIVE, ); buildRules = (); dependencies = (); name = LiveFeature; productName = LiveFeature; productType = "com.apple.product-type.framework"; };
            LIVEAPP = {isa = PBXNativeTarget; buildConfigurationList = CLLA; buildPhases = (SPLA, USEREMBED, ); buildRules = (); dependencies = (); name = LiveApp; productName = LiveApp; productType = "com.apple.product-type.application"; };
        /* End PBXNativeTarget section */
        /* Begin PBXProject section */
            PROJECT = {isa = PBXProject; buildConfigurationList = CLPROJECT; mainGroup = MAIN; packageReferences = (HELIXPACKAGE, ); targets = (HOTFEATURE, HOTAPP, LIVEFEATURE, LIVEAPP, ); };
        /* End PBXProject section */
        /* Begin XCBuildConfiguration section */
            CHF = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CHA = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CHARELEASE = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
            CLF = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CLA = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CPROJECT = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            CPROJECTRELEASE = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
        /* End XCBuildConfiguration section */
        /* Begin XCConfigurationList section */
            CLHF = {isa = XCConfigurationList; buildConfigurations = (CHF, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLHA = {isa = XCConfigurationList; buildConfigurations = (CHA, CHARELEASE, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLLF = {isa = XCConfigurationList; buildConfigurations = (CLF, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLLA = {isa = XCConfigurationList; buildConfigurations = (CLA, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
            CLPROJECT = {isa = XCConfigurationList; buildConfigurations = (CPROJECT, CPROJECTRELEASE, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        /* End XCConfigurationList section */
        /* Begin XCLocalSwiftPackageReference section */
            HELIXPACKAGE = {isa = XCLocalSwiftPackageReference; relativePath = "__HELIX_REPOSITORY__"; };
        /* End XCLocalSwiftPackageReference section */
          };
          rootObject = PROJECT;
        }
        """
    }
}
#endif
