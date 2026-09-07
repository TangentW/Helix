#if os(macOS)
import AppKit
import Combine
import Foundation
import HelixHubCore
import UniformTypeIdentifiers

extension HubApplication {
struct Notice: Equatable, Identifiable {
    enum Kind: Equatable { case information, error }
    enum Recovery: Equatable {
        case retryService
        case retryPairingCode
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var message: String
    var recovery: Recovery? = nil
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
    @Published private(set) var isStartingService = false
    @Published private(set) var isRotatingPairingCode = false

    private var store: Hub.ProjectStore?
    private var service: (any ServiceControlling)?
    private var refreshTask: Task<Void, Never>?
    private var didInitialize = false
    private let projectStoreFactory: () throws -> Hub.ProjectStore
    private let serviceFactory: () throws -> any ServiceControlling

    init(
        projectStoreFactory: @escaping () throws -> Hub.ProjectStore = {
            try Hub.ProjectStore.applicationSupport()
        },
        serviceFactory: @escaping () throws -> any ServiceControlling = {
            try ServiceClient()
        }
    ) {
        self.projectStoreFactory = projectStoreFactory
        self.serviceFactory = serviceFactory
    }

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
        guard !didInitialize else { return }
        didInitialize = true
        do {
            store = try projectStoreFactory()
            await reloadProjects()
        } catch {
            present(error, title: "Project Registry Unavailable")
        }
        await startService()
    }

    func retryService() async {
        await startService()
    }

    func recover(_ recovery: Notice.Recovery) {
        switch recovery {
        case .retryService:
            Task { await retryService() }
        case .retryPairingCode:
            Task { await retryPairingCode() }
        }
    }

    func dismissNotice(id: UUID) {
        guard notice?.id == id else { return }
        notice = nil
    }

    private func startService() async {
        guard !isStartingService, !isRotatingPairingCode else { return }
        isStartingService = true
        operationLabel = "Starting the Helix service…"
        await stopRefreshLoop()
        if let service { await service.stop() }
        service = nil
        serviceState = nil
        defer { isStartingService = false }

        do {
            let client = try serviceFactory()
            do {
                serviceState = try await client.start()
            } catch {
                await client.stop()
                throw error
            }
            service = client
        } catch {
            operationLabel = "Helix service is offline."
            present(
                error,
                title: "Helix Service Could Not Start",
                recovery: .retryService
            )
            return
        }

        do {
            try await synchronizePairingCode(forceRotation: false)
            operationLabel = "Helix service is ready."
            if notice?.recovery == .retryService {
                notice = nil
            }
        } catch {
            operationLabel = "Helix service is running, but pairing needs attention."
            present(
                error,
                title: "Pairing Code Could Not Be Created",
                recovery: .retryPairingCode
            )
        }
        startRefreshLoop()
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    private func stopRefreshLoop() async {
        guard let refreshTask else { return }
        refreshTask.cancel()
        // Prevent an in-flight refresh from publishing state while another
        // operation replaces the controller or its pairing code.
        await refreshTask.value
        self.refreshTask = nil
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
                if service != nil,
                   !isRotatingPairingCode,
                   notice?.recovery != .retryPairingCode {
                    try await synchronizePairingCode(forceRotation: false)
                }
            } catch is CancellationError {
                break
            } catch {
                serviceState = nil
                operationLabel = "Helix service needs attention."
                present(
                    error,
                    title: "Helix Service Needs Attention",
                    recovery: .retryService
                )
                break
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
        if selections.isEmpty {
            uninstall(editor)
            return
        }
        isWorking = true
        operationLabel = "Inspecting exact Xcode build settings…"
        var projectWasConfigured = false
        Task {
            defer { isWorking = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var draft = try Hub.DraftResolver().resolve(
                        project: editor.project,
                        selections: selections,
                        integrationRoot: editor.integrationRoot
                    )
                    draft.runtimePackageRequirement = editor.runtimePackageRequirement
                    let plan = try Hub.OnboardingPlanner().plan(draft)
                    let installation = try Hub.ProjectInstaller().install(plan)
                    return (draft, installation)
                }.value
                projectWasConfigured = true
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
                if projectWasConfigured {
                    operationLabel = "Xcode integration was applied; Hub registration needs retry."
                    present(
                        error,
                        title: "Project Configured, Registration Not Saved"
                    )
                } else {
                    operationLabel = "Configuration failed. No partial project write was kept."
                    present(error, title: "Helix Configuration Failed")
                }
            }
        }
    }

    private func uninstall(_ editor: Editor) {
        guard let record = projects.first(where: {
            $0.projectURL == editor.project.projectURL.standardizedFileURL
        }) else {
            present(
                Hub.Error.storageFailure("project registration is unavailable"),
                title: "Helix Could Not Be Removed"
            )
            return
        }
        isWorking = true
        operationLabel = "Removing generated Xcode integration…"
        var projectWasCleaned = false
        Task {
            defer { isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Hub.ProjectInstaller().uninstall(
                        project: editor.project,
                        record: record
                    )
                }.value
                projectWasCleaned = true
                guard let store else {
                    throw Hub.Error.storageFailure(
                        "project registry is unavailable"
                    )
                }
                try await store.remove(id: record.id)
                self.editor = nil
                await reloadProjects()
                rotatePairingCode()
                operationLabel = "Helix was removed from the project."
                notice = .init(
                    kind: .information,
                    title: "Helix Removed",
                    message: "Generated Xcode integration was removed and the project's original settings were restored. Application source and signing materials were preserved."
                )
            } catch {
                if projectWasCleaned {
                    operationLabel = "Xcode integration was removed; registry cleanup needs retry."
                    present(
                        error,
                        title: "Project Cleaned, Registration Still Present"
                    )
                } else {
                    operationLabel = "Removal failed. No partial project write was kept."
                    present(error, title: "Helix Could Not Be Removed")
                }
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
        Task { await replacePairingCode() }
    }

    func retryPairingCode() async {
        await replacePairingCode()
    }

    private func replacePairingCode() async {
        guard service != nil,
              !isStartingService,
              !isRotatingPairingCode
        else { return }
        isRotatingPairingCode = true
        await stopRefreshLoop()
        defer {
            isRotatingPairingCode = false
            startRefreshLoop()
        }
        if var state = serviceState {
            state.manualInvitations = []
            serviceState = state
        }
        do {
            try await synchronizePairingCode(forceRotation: true)
            operationLabel = "Pairing code is ready."
            if notice?.recovery == .retryPairingCode {
                notice = nil
            }
        } catch {
            operationLabel = "Helix service is running, but pairing needs attention."
            present(
                error,
                title: "Pairing Code Could Not Be Created",
                recovery: .retryPairingCode
            )
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
                : "Existing mappings are loaded and can be changed or removed."
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
        try Task.checkCancellation()
        if forceRotation || !state.currentInvitationMatches(projectURL: projectURL) {
            _ = try await service.rotatePairingCode(projectURL: projectURL)
            try Task.checkCancellation()
            state = try await service.refresh(projectURL: projectURL)
            try Task.checkCancellation()
        }
        serviceState = state
    }

    private func completionMessage(_ result: Hub.InstallationResult) -> String {
        if result.requirements.isEmpty {
            return "Xcode integration, build actions, and project configuration are ready. Generated Swift remains in DerivedData."
        }
        return "Project files were configured. Complete the \(result.requirements.count) code-level action(s) shown in Helix before running the App."
    }

    private func present(
        _ error: any Swift.Error,
        title: String,
        recovery: Notice.Recovery? = nil
    ) {
        notice = .init(
            kind: .error,
            title: title,
            message: Self.message(error),
            recovery: recovery
        )
    }

    private static func message(_ error: any Swift.Error) -> String {
        String(String(describing: error).prefix(16_384))
    }
}
}
#endif
