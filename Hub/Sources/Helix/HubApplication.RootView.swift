#if os(macOS)
import SwiftUI
import HelixHubCore

extension HubApplication {
struct RootView: View {
    @ObservedObject var model: Model

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 640)
        .task { await model.run() }
        .sheet(isPresented: Binding(
            get: { !model.projectCandidates.isEmpty },
            set: { if !$0 { model.cancelCandidateSelection() } }
        )) {
            CandidatePicker(model: model)
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Choose Project", systemImage: "plus") {
                    model.chooseProject()
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedProjectID },
            set: { model.selectProject(id: $0) }
        )) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.body.weight(.medium))
                        HStack(spacing: 5) {
                            ForEach(project.capabilities, id: \.self) { capability in
                                Image(systemName: capability == .hotPatch
                                    ? "bandage.fill" : "bolt.fill")
                                    .help(capability.displayName)
                            }
                            Text(project.projectURL.deletingLastPathComponent().lastPathComponent)
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                    .padding(.vertical, 3)
                }
                Button("Configure Another Project…", systemImage: "folder.badge.plus") {
                    model.chooseProject()
                }
                .buttonStyle(.plain)
            }
            Section("Service") {
                Label(
                    model.serviceIsRunning ? "Running" : "Offline",
                    systemImage: model.serviceIsRunning
                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                Label("\(model.connectedAppCount) connected", systemImage: "iphone")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let label = model.operationLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.bar)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let current = model.editor {
            OnboardingView(
                editor: Binding(
                    get: { model.editor ?? current },
                    set: { model.editor = $0 }
                ),
                model: model
            )
        } else if let project = model.selectedProject {
            ProjectOverview(project: project, model: model)
        } else {
            WelcomeView(model: model)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: HubApplication.Model

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                HubApplication.Brand.Mark()
                    .frame(width: 96, height: 60)
                    .accessibilityHidden(true)
                Text("Helix")
            }
        } description: {
            Text("Configure Hot Patch and Live Reload without adding generated Swift files to your Xcode navigator.")
        } actions: {
            Button("Choose an Xcode Project…") { model.chooseProject() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ProjectOverview: View {
    var project: Hub.ProjectRecord
    @ObservedObject var model: HubApplication.Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name).font(.largeTitle.bold())
                        Text(project.projectURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Configure", systemImage: "slider.horizontal.3") {
                        model.configureSelectedProject()
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack {
                    ForEach(project.capabilities, id: \.self) {
                        HubApplication.CapabilityBadge(capability: $0)
                    }
                }
                HubApplication.PairingCard(model: model)
                if !project.requirements.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Actions still required in code").font(.title2.bold())
                        ForEach(project.requirements) {
                            HubApplication.RequirementCard(requirement: $0)
                        }
                    }
                }
                serviceActivity
                HStack {
                    Button("Open in Xcode", systemImage: "hammer") {
                        model.openSelectedProject()
                    }
                    Button("Reveal Integration", systemImage: "folder") {
                        model.revealIntegration()
                    }
                    Spacer()
                    Button("Forget from Helix", role: .destructive) {
                        model.forgetSelectedProject()
                    }
                    .help("Removes only the Hub registry entry; it does not edit the project.")
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    @ViewBuilder
    private var serviceActivity: some View {
        if let state = model.serviceState {
            VStack(alignment: .leading, spacing: 10) {
                Text("Build contexts").font(.title2.bold())
                if state.buildContexts.isEmpty {
                    Text("Run a configured scheme in Xcode to register its exact Dev Shell.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.buildContexts.enumerated()), id: \.offset) { _, context in
                        HStack {
                            Image(systemName: "shippingbox.fill")
                            VStack(alignment: .leading) {
                                Text(context.scheme).font(.subheadline.weight(.semibold))
                                Text("\(context.moduleName) · \(context.buildConfiguration)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(context.registeredAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                if !state.recentEvents.isEmpty {
                    Divider()
                    Text("Recent activity").font(.headline)
                    ForEach(Array(state.recentEvents.suffix(8).reversed())) { entry in
                        HubApplication.ServiceLogRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct CandidatePicker: View {
    @ObservedObject var model: HubApplication.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a project").font(.title2.bold())
            Text("The selected workspace contains more than one concrete Xcode project.")
                .foregroundStyle(.secondary)
            List(model.projectCandidates) { candidate in
                Button {
                    model.chooseCandidate(candidate)
                } label: {
                    HStack {
                        Image(systemName: "hammer.fill")
                        VStack(alignment: .leading) {
                            Text(candidate.displayName)
                            Text(candidate.projectURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelCandidateSelection() }
            }
        }
        .padding(24)
        .frame(width: 560, height: 360)
    }
}
}
#endif
