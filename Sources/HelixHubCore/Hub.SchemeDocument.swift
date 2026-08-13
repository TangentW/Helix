#if os(macOS)
import Foundation
import HelixBuildTools

extension Hub {
struct SchemeDocument {
    private let document: XMLDocument

    init(data: Data) throws {
        do {
            document = try XMLDocument(
                data: data,
                options: [.nodePreserveWhitespace, .nodePreserveAttributeOrder]
            )
        } catch {
            throw Hub.Error.invalidProject("shared Xcode scheme is malformed XML")
        }
        guard document.rootElement()?.name == "Scheme" else {
            throw Hub.Error.invalidProject("shared Xcode scheme has no Scheme root")
        }
    }

    func configure(
        profile: XcodeIntegration.Profile,
        featureTarget: Hub.XcodeTarget,
        applicationTarget: Hub.XcodeTarget,
        projectName: String,
        integrationRoot: String
    ) throws -> Data {
        let buildAction = try requiredElement("BuildAction")
        setAction(
            owner: buildAction,
            containerName: "PreActions",
            title: "Helix Hub: Prepare \(profile.id)",
            script: phaseScript(
                profile: profile,
                phase: "prepare",
                integrationRoot: integrationRoot
            ),
            target: featureTarget,
            projectName: projectName
        )
        switch profile.workflow {
        case .hotPatch:
            setAction(
                owner: buildAction,
                containerName: "PostActions",
                title: "Helix Hub: Audit \(profile.id)",
                script: phaseScript(
                    profile: profile,
                    phase: "audit",
                    integrationRoot: integrationRoot
                ),
                target: applicationTarget,
                projectName: projectName
            )
            if let launchAction = document.rootElement()?.elements(
                forName: "LaunchAction"
            ).first {
                removeOwnedAction(from: launchAction, containerName: "PreActions")
            }
        case .liveReload:
            removeOwnedAction(from: buildAction, containerName: "PostActions")
            let launchAction = try requiredElement("LaunchAction")
            setAction(
                owner: launchAction,
                containerName: "PreActions",
                title: "Helix Hub: Register \(profile.id)",
                script: phaseScript(
                    profile: profile,
                    phase: "live-register",
                    integrationRoot: integrationRoot
                ),
                target: applicationTarget,
                projectName: projectName
            )
        }
        let result = document.xmlData(options: [.nodePrettyPrint])
        guard result.count <= 8 * 1_024 * 1_024 else {
            throw Hub.Error.invalidProject("shared Xcode scheme is unexpectedly large")
        }
        return result
    }

    static func patchActionScheme(
        profile: XcodeIntegration.Profile,
        targetID: String,
        projectName: String
    ) throws -> Data {
        guard let patch = profile.patch else {
            throw Hub.Error.invalidOnboarding("Hot Patch profile has no action settings")
        }
        let escapedTarget = xml(targetID)
        let escapedName = xml(patch.actionTargetName)
        let escapedProject = xml(projectName)
        let escapedConfiguration = xml(profile.configurationName)
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
          <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="NO">
            <BuildActionEntries>
              <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(escapedTarget)" BuildableName="\(escapedName)" BlueprintName="\(escapedName)" ReferencedContainer="container:\(escapedProject).xcodeproj"/>
              </BuildActionEntry>
            </BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="\(escapedConfiguration)" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
          <LaunchAction buildConfiguration="\(escapedConfiguration)" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"/>
          <ProfileAction buildConfiguration="\(escapedConfiguration)" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
          <AnalyzeAction buildConfiguration="\(escapedConfiguration)"/>
          <ArchiveAction buildConfiguration="\(escapedConfiguration)" revealArchiveInOrganizer="NO"/>
        </Scheme>
        """
        return Data(source.utf8)
    }

    private func requiredElement(_ name: String) throws -> XMLElement {
        guard let value = document.rootElement()?.elements(forName: name).first else {
            throw Hub.Error.invalidProject("shared scheme has no \(name)")
        }
        return value
    }

    private func setAction(
        owner: XMLElement,
        containerName: String,
        title: String,
        script: String,
        target: Hub.XcodeTarget,
        projectName: String
    ) {
        let container: XMLElement
        if let existing = owner.elements(forName: containerName).first {
            container = existing
        } else {
            container = XMLElement(name: containerName)
            owner.insertChild(container, at: 0)
        }
        removeOwnedChildren(from: container)
        container.addChild(executionAction(
            title: title,
            script: script,
            target: target,
            projectName: projectName
        ))
    }

    private func removeOwnedAction(from owner: XMLElement, containerName: String) {
        guard let container = owner.elements(forName: containerName).first else { return }
        removeOwnedChildren(from: container)
        if container.children?.isEmpty != false {
            container.detach()
        }
    }

    private func removeOwnedChildren(from container: XMLElement) {
        for action in container.elements(forName: "ExecutionAction") {
            guard let content = action.elements(forName: "ActionContent").first else {
                continue
            }
            let title = content.attribute(forName: "title")?.stringValue ?? ""
            if title.hasPrefix("Helix Hub:") {
                action.detach()
            }
        }
    }

    private func executionAction(
        title: String,
        script: String,
        target: Hub.XcodeTarget,
        projectName: String
    ) -> XMLElement {
        let execution = XMLElement(name: "ExecutionAction")
        execution.addAttribute(Self.attribute(
            name: "ActionType",
            stringValue: "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction"
        ))
        let content = XMLElement(name: "ActionContent")
        content.addAttribute(Self.attribute(name: "title", stringValue: title))
        content.addAttribute(Self.attribute(name: "scriptText", stringValue: script))
        let environment = XMLElement(name: "EnvironmentBuildable")
        let reference = XMLElement(name: "BuildableReference")
        let attributes = [
            "BuildableIdentifier": "primary",
            "BlueprintIdentifier": target.id,
            "BuildableName": target.buildableName ?? target.productName,
            "BlueprintName": target.name,
            "ReferencedContainer": "container:\(projectName).xcodeproj",
        ]
        for key in attributes.keys.sorted() {
            reference.addAttribute(Self.attribute(
                name: key,
                stringValue: attributes[key] ?? ""
            ))
        }
        environment.addChild(reference)
        content.addChild(environment)
        execution.addChild(content)
        return execution
    }

    private func phaseScript(
        profile: XcodeIntegration.Profile,
        phase: String,
        integrationRoot: String
    ) -> String {
        "/bin/sh \"$SRCROOT/\(integrationRoot)/Profiles/\(profile.id)/\(phase).sh\""
    }

    private static func attribute(name: String, stringValue: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: stringValue) as! XMLNode
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
}
#endif
