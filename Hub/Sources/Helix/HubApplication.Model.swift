#if os(macOS)
import AppKit
import Combine
import Foundation
import HelixHubCore
import UniformTypeIdentifiers

extension HubApplication {
struct Notice: Identifiable {
    enum Kind { case information, error }

    var id = UUID()
    var kind: Kind
    var title: String
    var message: String
}

@MainActor
final class Model: ObservableObject {
    @Published var projects: [Hub.ProjectRecord] = []
    @Published var selectedProjectID: String?
    @Published var editor: Editor?
    @Published var projectCandidates: [Hub.ProjectCandidate] = []
    @Published var serviceState: Hub.ServiceViewState?
    @Published var isWorking = false
    @Published var operationLabel: String?
    @Published var notice: Notice?
    @Published private(set) var isRotatingPairingCode = false

    private var store: Hub.ProjectStore?
    private var service: Hub.ServiceController?
    private var refreshTask: Task<Void, Never>?
    private var didStart = false

    var selectedProject: Hub.ProjectRecord? {
        projects.first { $0.id == selectedProjectID }
    }

    var pairingCode: String? {
        serviceState?.currentInvitation?.code.description
    }

    var pairingExpiresAt: Date? {
        serviceState?.currentInvitation?.expiresAt
    }

    var pairingScopeName: String? {
        guard let state = serviceState, state.currentInvitation != nil else { return nil }
        if state.currentInvitationMatches(projectURL: nil) {
            return "Any registered build"
        }
        return projects.first(where: {
            state.currentInvitationMatches(projectURL: $0.projectURL)
        })?.name ?? "Scoped build"
    }

    var serviceIsRunning: Bool {
        serviceState?.service.state.rawValue == "running"
    }

    var connectedAppCount: Int {
        serviceState?.service.openConnectionCount ?? 0
    }

    func run() async {
        guard !didStart else { return }
        didStart = true
        do {
            store = try Hub.ProjectStore.applicationSupport()
            await reloadProjects()
        } catch {
            present(error, title: "Project Registry Unavailable")
        }
        do {
            let controller = try Hub.ServiceController()
            service = controller
            serviceState = try await controller.start()
            try await synchronizePairingCode(forceRotation: false)
        } catch {
            present(error, title: "Helix Service Could Not Start")
        }

        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
                if service != nil, !isRotatingPairingCode {
                    try await synchronizePairingCode(forceRotation: false)
                }
            } catch is CancellationError {
                break
            } catch {
                operationLabel = "Service refresh failed: \(Self.message(error))"
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Xcode project, workspace, or source directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["xcodeproj", "xcworkspace"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await locateProject(from: url) }
    }

    func chooseCandidate(_ candidate: Hub.ProjectCandidate) {
        projectCandidates = []
        Task { await openEditor(projectURL: candidate.projectURL) }
    }

    func cancelCandidateSelection() {
        projectCandidates = []
    }

    func selectProject(id: String?) {
        guard selectedProjectID != id else { return }
        selectedProjectID = id
        rotatePairingCode()
    }

    func configureSelectedProject() {
        guard let selectedProject else { return }
        Task {
            await openEditor(
                projectURL: selectedProject.projectURL,
                record: selectedProject
            )
        }
    }

    func closeEditor() {
        editor = nil
    }

    func install() {
        guard let editor, !isWorking else { return }
        let selections: [Hub.WorkflowSelection]
        do {
            selections = try editor.selections()
        } catch {
            present(error, title: "Configuration Is Incomplete")
            return
        }
        isWorking = true
        operationLabel = "Inspecting exact Xcode build settings…"
        Task {
            defer { isWorking = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let draft = try Hub.DraftResolver().resolve(
                        project: editor.project,
                        selections: selections,
                        integrationRoot: editor.integrationRoot
                    )
                    let plan = try Hub.OnboardingPlanner().plan(draft)
                    let installation = try Hub.ProjectInstaller().install(plan)
                    return (draft, installation)
                }.value
                operationLabel = "Saving project registration…"
                guard let store else {
                    throw Hub.Error.storageFailure("project registry is unavailable")
                }
                let record = try await store.register(installation: result.1)
                await reloadProjects(selecting: record.id)
                rotatePairingCode()
                self.editor = .init(
                    project: result.0.project,
                    draft: result.0,
                    requirements: result.1.requirements
                )
                operationLabel = "Configuration applied successfully."
                notice = .init(
                    kind: .information,
                    title: "Helix Is Configured",
                    message: completionMessage(result.1)
                )
            } catch {
                operationLabel = "Configuration failed. No partial project write was kept."
                present(error, title: "Helix Configuration Failed")
            }
        }
    }

    func forgetSelectedProject() {
        guard let id = selectedProjectID, let store else { return }
        Task {
            do {
                try await store.remove(id: id)
                editor = nil
                await reloadProjects()
                rotatePairingCode()
            } catch {
                present(error, title: "Project Could Not Be Forgotten")
            }
        }
    }

    func openSelectedProject() {
        guard let url = selectedProject?.projectURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealIntegration() {
        guard let url = selectedProject?.hostPlanURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func rotatePairingCode() {
        guard service != nil, !isRotatingPairingCode else { return }
        isRotatingPairingCode = true
        if var state = serviceState {
            state.manualInvitations = []
            serviceState = state
        }
        Task {
            defer { isRotatingPairingCode = false }
            do {
                try await synchronizePairingCode(forceRotation: true)
            } catch {
                present(error, title: "Pairing Code Could Not Be Created")
            }
        }
    }

    func copyPairingCode() {
        guard let pairingCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
        operationLabel = "Pairing code copied."
    }

    private func locateProject(from url: URL) async {
        isWorking = true
        operationLabel = "Discovering Xcode projects…"
        defer { isWorking = false }
        do {
            let candidates = try await Task.detached(priority: .userInitiated) {
                try Hub.ProjectLocator().locate(from: url)
            }.value
            if candidates.count == 1, let candidate = candidates.first {
                await openEditor(projectURL: candidate.projectURL)
            } else {
                projectCandidates = candidates
                operationLabel = "Choose the concrete project to configure."
            }
        } catch {
            present(error, title: "No Xcode Project Found")
        }
    }

    private func openEditor(
        projectURL: URL,
        record suppliedRecord: Hub.ProjectRecord? = nil
    ) async {
        isWorking = true
        operationLabel = "Reading the Xcode project without modifying it…"
        defer { isWorking = false }
        do {
            let record = suppliedRecord ?? projects.first {
                $0.projectURL.standardizedFileURL == projectURL.standardizedFileURL
            }
            let loaded = try await Task.detached(priority: .userInitiated) {
                let project = try Hub.ProjectFileParser().parse(projectURL: projectURL)
                if let record {
                    let draft = try Hub.DraftLoader().load(project: project, record: record)
                    return Editor(
                        project: project,
                        draft: draft,
                        requirements: record.requirements
                    )
                }
                return Editor(project: project)
            }.value
            editor = loaded
            selectedProjectID = record?.id
            operationLabel = record == nil
                ? "Both capabilities are selected by default."
                : "Existing capabilities are locked on; skipped capabilities can be added."
        } catch {
            present(error, title: "Project Could Not Be Opened")
        }
    }

    private func reloadProjects(selecting id: String? = nil) async {
        guard let store else { return }
        projects = await store.records()
        if let id {
            selectedProjectID = id
        } else if let selectedProjectID,
                  projects.contains(where: { $0.id == selectedProjectID }) {
            self.selectedProjectID = selectedProjectID
        } else {
            selectedProjectID = projects.first?.id
        }
    }

    private func synchronizePairingCode(forceRotation: Bool) async throws {
        guard let service else { return }
        let projectURL = selectedProject?.projectURL
        var state = try await service.refresh(projectURL: projectURL)
        if forceRotation || !state.currentInvitationMatches(projectURL: projectURL) {
            _ = try await service.rotatePairingCode(projectURL: projectURL)
            state = try await service.refresh(projectURL: projectURL)
        }
        serviceState = state
    }

    private func completionMessage(_ result: Hub.InstallationResult) -> String {
        if result.requirements.isEmpty {
            return "Xcode integration, build actions, and project configuration are ready. Generated Swift remains in DerivedData."
        }
        return "Project files were configured. Complete the \(result.requirements.count) code-level action(s) shown in Helix before running the App."
    }

    private func present(_ error: any Swift.Error, title: String) {
        notice = .init(
            kind: .error,
            title: title,
            message: Self.message(error)
        )
    }

    private static func message(_ error: any Swift.Error) -> String {
        String(String(describing: error).prefix(16_384))
    }
}
}
#endif
