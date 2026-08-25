#if os(macOS)
import SwiftUI
import HelixHubCore

extension HubApplication {
struct OnboardingView: View {
    @Binding var editor: Editor
    @ObservedObject var model: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                introduction
                ForEach($editor.forms) { $form in
                    WorkflowEditor(form: $form, project: editor.project)
                }
                integrationSettings
                validation
                if !editor.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current code-level actions").font(.title3.bold())
                        ForEach(editor.requirements) {
                            RequirementCard(requirement: $0)
                        }
                    }
                }
                footer
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Configure \(editor.project.name)")
                    .font(.largeTitle.bold())
                Text(editor.project.projectURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { model.closeEditor() }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generated Swift stays out of the project navigator", systemImage: "eye.slash")
                .font(.headline)
            Text(
                "Helix writes only owned build settings, build actions, generated integration metadata, and the optional Hot Patch recipe to the source tree. Compiler policy and API discovery are automatic; Bridge Swift is materialized inside DerivedData during the active Xcode build."
            )
            .foregroundStyle(.secondary)
            Text(
                "Both workflows are selected for a new project. Existing workflows remain enabled so reconfiguration cannot silently remove a working integration; a skipped workflow can be added later."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var integrationSettings: some View {
        GroupBox("Integration location") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Project-relative generated-kit directory", text: $editor.integrationRoot)
                    .textFieldStyle(.roundedBorder)
                    .disabled(editor.hasInstalledCapabilities)
                Text(editor.hasInstalledCapabilities
                    ? "This Hub-owned location is locked after the first capability is installed."
                    : "Generated and Hub-owned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var validation: some View {
        if !editor.validationMessages.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Resolve these choices before configuring", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(editor.validationMessages, id: \.self) { message in
                    Text("• \(message)")
                        .font(.callout)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var footer: some View {
        HStack {
            if let label = model.operationLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.closeEditor() }
            Button(editor.forms.contains(where: { $0.isInstalled })
                ? "Apply / Add Capability" : "Configure Project") {
                model.install()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canInstall || model.isWorking)
        }
    }
}

private struct WorkflowEditor: View {
    @Binding var form: HubApplication.WorkflowForm
    var project: Hub.XcodeProject

    private var appTargets: [Hub.XcodeTarget] {
        project.targets.filter { $0.kind == .application }
    }

    private var featureTargets: [Hub.XcodeTarget] {
        project.targets.filter {
            !$0.sourceFiles.isEmpty
                && ![.application, .testBundle, .aggregate].contains($0.kind)
        }
    }

    private var configurations: [String] {
        guard let app = project.target(named: form.applicationTargetName),
              let feature = project.target(named: form.featureTargetName)
        else { return [] }
        return Array(Set(app.configurationNames).intersection(feature.configurationNames))
            .sorted()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { form.isEnabled },
                        set: { if !form.isInstalled { form.isEnabled = $0 } }
                    )) {
                        Label(
                            form.capability.displayName,
                            systemImage: form.capability == .hotPatch
                                ? "bandage.fill" : "bolt.fill"
                        )
                        .font(.title3.bold())
                    }
                    .toggleStyle(.switch)
                    .disabled(form.isInstalled)
                    Spacer()
                    if form.isInstalled {
                        Label("Installed", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if form.isEnabled {
                    Divider()
                    selectionGrid
                    runtimeStatus
                    DisclosureGroup("Advanced identity and paths") {
                        advancedSettings
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    private var selectionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            pickerRow("App target", selection: $form.applicationTargetName, values: appTargets.map(\.name))
            pickerRow("Feature target", selection: $form.featureTargetName, values: featureTargets.map(\.name))
            pickerRow("Shared scheme", selection: $form.schemeName, values: project.sharedSchemes.map(\.name))
            pickerRow("Configuration", selection: $form.configurationName, values: configurations)
        }
        .disabled(form.isInstalled)
        .onChange(of: form.applicationTargetName) { normalizeConfiguration() }
        .onChange(of: form.featureTargetName) { normalizeConfiguration() }
    }

    private var runtimeStatus: some View {
        let linked = project.target(named: form.applicationTargetName)?
            .linksRuntimeProduct(
                form.expectedRuntimeProduct,
                configurationName: form.configurationName
            ) == true
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: linked ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(linked ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked
                    ? "\(form.expectedRuntimeProduct) is linked"
                    : "Add \(form.expectedRuntimeProduct) to \(form.applicationTargetName)")
                    .font(.subheadline.weight(.semibold))
                Text(
                    linked
                        ? "Hub will preserve the current dependency linkage."
                        : "Add the Swift package product or CocoaPod, then initialize its runtime API; Hub never injects hidden application code."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background((linked ? Color.green : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Profile ID") {
                TextField("Profile ID", text: $form.profileID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .disabled(form.isInstalled)
            }
            LabeledContent("Swift module override") {
                TextField("Automatic from Xcode", text: $form.featureModuleName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            LabeledContent("Bundle ID override") {
                TextField("Automatic from Xcode", text: $form.bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            LabeledContent("Namespace seed") {
                TextField("Stable namespace seed", text: $form.namespaceSeed)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            if form.capability == .hotPatch {
                Divider()
                PatchSettings(patch: Binding(
                    get: { form.patch ?? .init() },
                    set: { form.patch = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private func pickerRow(
        _ title: String,
        selection: Binding<String>,
        values: [String]
    ) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                if values.isEmpty { Text("Unavailable").tag("") }
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var description: String {
        switch form.capability {
        case .hotPatch:
            "Build signed HLBC packages against an exact archived Shell for controlled production repair."
        case .liveReload:
            "Watch saved Swift sources, compile HLBC on the Mac, transfer it over the authenticated session, and refresh matching UI instances."
        }
    }

    private func normalizeConfiguration() {
        if !configurations.contains(form.configurationName) {
            form.configurationName = configurations.first(where: {
                $0.caseInsensitiveCompare("Debug") == .orderedSame
            }) ?? configurations.first ?? ""
        }
    }
}

private struct PatchSettings: View {
    @Binding var patch: Hub.PatchDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Create and protect a local development signing identity", isOn: $patch.createDevelopmentIdentity)
            field("Patch action target", text: $patch.actionTargetName)
            field("Patch action scheme", text: $patch.actionSchemeName)
            field("Recipe", text: $patch.recipePath)
            field("Trusted root", text: $patch.trustedRootPath)
            field("Signing certificate", text: $patch.signingCertificatePath)
            field("Private key", text: $patch.privateKeyPath)
            field("Output directory", text: $patch.outputRoot)
            field("Simulator inbox", text: Binding(
                get: { patch.simulatorInboxPath ?? "" },
                set: { patch.simulatorInboxPath = $0.isEmpty ? nil : $0 }
            ))
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 440)
        }
    }
}
}
#endif
