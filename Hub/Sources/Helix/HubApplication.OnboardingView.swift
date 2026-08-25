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
                Text("Enable Helix for \(editor.project.name)")
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
            Label("Ready without project setup", systemImage: "wand.and.stars")
                .font(.headline)
            Text(
                "Choose the workflows and click Enable Helix. Hub detects the App, sources, scheme, configurations, module, and bundle identity; links one integration product; and starts the runtime automatically."
            )
            .foregroundStyle(.secondary)
            Text(
                "Generated Bridge code and build artifacts stay in DerivedData. Existing project settings are wrapped and preserved."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
            Button(actionLabel) {
                model.install()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canInstall || model.isWorking)
        }
    }

    private var actionLabel: String {
        if editor.selectedForms.isEmpty, editor.hasInstalledCapabilities {
            return "Remove Helix"
        }
        return editor.hasInstalledCapabilities ? "Apply Changes" : "Enable Helix"
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
            $0.supportsSourceCompilation
                && ![.testBundle, .aggregate].contains($0.kind)
        }
    }

    private var configurations: [String] {
        guard let app = project.target(named: form.applicationTargetName),
              let feature = project.target(named: form.featureTargetName)
        else { return [] }
        return Array(Set(app.configurationNames).intersection(feature.configurationNames))
            .sorted()
    }

    private var schemeNames: [String] {
        Array(Set(
            project.sharedSchemes.map(\.name)
                + [form.schemeName, form.applicationTargetName]
                    .filter { !$0.isEmpty }
        )).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle(isOn: $form.isEnabled) {
                        Label(
                            form.capability.displayName,
                            systemImage: form.capability == .hotPatch
                                ? "bandage.fill" : "bolt.fill"
                        )
                        .font(.title3.bold())
                    }
                    .toggleStyle(.switch)
                    Spacer()
                    if form.isInstalled {
                        Label("Currently configured", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if form.isEnabled {
                    Divider()
                    detectedMapping
                    runtimeStatus
                    DisclosureGroup("Review or change detected Xcode mapping") {
                        selectionGrid
                            .padding(.top, 8)
                    }
                    if form.capability == .hotPatch {
                        DisclosureGroup("Advanced Hot Patch option") {
                            Toggle(
                                "Create a local development signing identity",
                                isOn: Binding(
                                    get: { form.patch?.createDevelopmentIdentity ?? true },
                                    set: {
                                        if form.patch == nil { form.patch = .init() }
                                        form.patch?.createDevelopmentIdentity = $0
                                    }
                                )
                            )
                            .padding(.top, 8)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    private var detectedMapping: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Detected automatically", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text(
                "\(form.applicationTargetName) · \(form.configurationName) · \(form.schemeName)"
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var selectionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            pickerRow("App target", selection: $form.applicationTargetName, values: appTargets.map(\.name))
            pickerRow("Source target", selection: $form.featureTargetName, values: featureTargets.map(\.name))
            pickerRow("Run scheme", selection: $form.schemeName, values: schemeNames)
            pickerRow("Configuration", selection: $form.configurationName, values: configurations)
        }
        .onChange(of: form.applicationTargetName) { normalizeConfiguration() }
        .onChange(of: form.featureTargetName) { normalizeConfiguration() }
    }

    private var runtimeStatus: some View {
        let linked = project.target(named: form.applicationTargetName)?
            .linksRuntimeProduct(form.expectedRuntimeProduct) == true
        let color: Color = linked ? .green : .blue
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: linked ? "checkmark.circle.fill" : "plus.circle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked
                    ? "\(form.expectedRuntimeProduct) is linked"
                    : "\(form.expectedRuntimeProduct) will be linked automatically")
                    .font(.subheadline.weight(.semibold))
                Text(
                    linked
                        ? "Hub will preserve the current dependency linkage."
                        : "Hub owns the package linkage; no App source import or initialization is required."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
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
            "Build signed patches for a specific App build; Hub captures its compiler and binary identity automatically."
        case .liveReload:
            "Save Swift code and see the running Debug App update through the authenticated local session."
        }
    }

    private func normalizeConfiguration() {
        if !configurations.contains(form.configurationName) {
            let preferred = form.capability == .hotPatch ? "Release" : "Debug"
            form.configurationName = configurations.first(where: {
                $0.caseInsensitiveCompare(preferred) == .orderedSame
            }) ?? configurations.first ?? ""
        }
    }
}
}
#endif
