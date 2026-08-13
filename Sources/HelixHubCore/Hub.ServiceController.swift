#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import HelixCore
import HelixDevProtocol
import HelixDevTools

extension Hub {
public enum ServiceMode: String, Hashable, Sendable {
    case stopped
    case embedded
    case external
}

public struct ServiceLogEntry: Hashable, Sendable, Identifiable {
    public enum Level: String, Hashable, Sendable {
        case information
        case success
        case warning
        case error
    }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: Level,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct ServiceViewState: Hashable, Sendable {
    public var mode: Hub.ServiceMode
    public var service: DevSession.ServiceSnapshot
    public var manualInvitations: [DevSession.ManualInvitation]
    public var buildContexts: [DevSession.BuildContext]
    public var recentEvents: [Hub.ServiceLogEntry]

    public var currentInvitation: DevSession.ManualInvitation? {
        manualInvitations.first
    }

    /// Returns whether the displayed code is restricted to the selected
    /// project. Passing `nil` intentionally represents an unscoped code.
    public func currentInvitationMatches(projectURL: URL?) -> Bool {
        guard let currentInvitation else { return false }
        let expected = projectURL.map {
            Core.Digest.sha256($0.standardizedFileURL.path)
        }
        return currentInvitation.workspacePathHash == expected
    }

    public init(
        mode: Hub.ServiceMode,
        service: DevSession.ServiceSnapshot,
        manualInvitations: [DevSession.ManualInvitation],
        buildContexts: [DevSession.BuildContext],
        recentEvents: [Hub.ServiceLogEntry]
    ) {
        self.mode = mode
        self.service = service
        self.manualInvitations = manualInvitations
        self.buildContexts = buildContexts
        self.recentEvents = recentEvents
    }
}

/// Shared orchestration facade for GUI and non-GUI Hub frontends. The service
/// may be embedded in the current process or already owned by `helix hub run`;
/// both modes expose the same owner-authenticated control API.
public actor ServiceController {
    typealias ServiceFactory = @Sendable (
        @escaping DevSession.Service.EventHandler
    ) throws -> DevSession.Service

    private let serviceFactory: ServiceFactory
    private let controlClient: HubControl.Client
    private let log: ServiceLog
    private var ownedService: DevSession.Service?
    private var mode = Hub.ServiceMode.stopped

    public init() throws {
        let log = ServiceLog()
        self.log = log
        controlClient = try .applicationSupport()
        serviceFactory = { handler in
            try DevSession.Service.persistent(eventHandler: handler)
        }
    }

    init(
        controlClient: HubControl.Client,
        serviceFactory: @escaping ServiceFactory,
        log: ServiceLog = .init()
    ) {
        self.controlClient = controlClient
        self.serviceFactory = serviceFactory
        self.log = log
    }

    @discardableResult
    public func start() async throws -> Hub.ServiceViewState {
        if mode != .stopped { return try await refresh() }
        let log = self.log
        let service = try serviceFactory { event in
            await log.record(event)
        }
        do {
            _ = try await service.start()
            ownedService = service
            mode = .embedded
        } catch HubControl.Error.serviceAlreadyRunning {
            await service.stop()
            ownedService = nil
            _ = try await controlClient.serviceSnapshot()
            mode = .external
            await log.append(
                level: .information,
                message: "Connected to the Helix service already running for this user."
            )
        } catch {
            await service.stop()
            ownedService = nil
            mode = .stopped
            throw error
        }
        return try await refresh()
    }

    public func refresh(
        projectURL: URL? = nil
    ) async throws -> Hub.ServiceViewState {
        if mode == .stopped {
            do {
                _ = try await controlClient.serviceSnapshot()
                mode = .external
            } catch {
                return await stoppedState()
            }
        }
        let workspaceHash = projectURL.map {
            Core.Digest.sha256($0.standardizedFileURL.path)
        }
        do {
            let serviceSnapshot: DevSession.ServiceSnapshot
            let invitations: [DevSession.ManualInvitation]
            let contexts: [DevSession.BuildContext]
            if let ownedService {
                serviceSnapshot = await ownedService.snapshot()
                invitations = await ownedService.manualInvitations()
                contexts = await ownedService.buildContexts(
                    workspacePathHash: workspaceHash
                )
            } else {
                async let snapshotValue = controlClient.serviceSnapshot()
                async let invitationValue = controlClient.manualInvitations()
                async let contextValue = controlClient.buildContexts(
                    workspacePathHash: workspaceHash
                )
                (serviceSnapshot, invitations, contexts) = try await (
                    snapshotValue, invitationValue, contextValue
                )
            }
            return .init(
                mode: mode,
                service: serviceSnapshot,
                manualInvitations: invitations,
                buildContexts: contexts,
                recentEvents: await log.entries()
            )
        } catch {
            if mode == .external { mode = .stopped }
            throw error
        }
    }

    /// Replaces every displayed manual code with one fresh invitation. Passing
    /// a project restricts redemption to Build Contexts registered for it.
    @discardableResult
    public func rotatePairingCode(
        projectURL: URL? = nil
    ) async throws -> DevSession.ManualInvitation {
        guard mode != .stopped else { throw DevSession.ServiceError.notRunning }
        let existing: [DevSession.ManualInvitation]
        if let ownedService {
            existing = await ownedService.manualInvitations()
            for invitation in existing {
                await ownedService.cancelManualInvitation(
                    invitationID: invitation.reservation.invitationID
                )
            }
        } else {
            existing = try await controlClient.manualInvitations()
            for invitation in existing {
                try await controlClient.cancelManualInvitation(
                    invitationID: invitation.reservation.invitationID
                )
            }
        }
        let workspaceHash = projectURL.map {
            Core.Digest.sha256($0.standardizedFileURL.path)
        }
        let invitation: DevSession.ManualInvitation
        if let ownedService {
            invitation = try await ownedService.createManualInvitation(
                workspacePathHash: workspaceHash
            )
        } else {
            invitation = try await controlClient.createManualInvitation(
                workspacePathHash: workspaceHash
            )
        }
        let message = projectURL.map {
            "Created a pairing code restricted to \($0.lastPathComponent)."
        } ?? "Created a new four-character pairing code."
        await log.append(level: .information, message: message)
        return invitation
    }

    public func cancelPairingCode(
        invitationID: DevProtocol.InvitationID
    ) async throws {
        guard mode != .stopped else { return }
        if let ownedService {
            await ownedService.cancelManualInvitation(invitationID: invitationID)
        } else {
            try await controlClient.cancelManualInvitation(
                invitationID: invitationID
            )
        }
    }

    /// Stops only a service embedded by this controller. An independently
    /// launched headless service is never terminated by a thin GUI frontend.
    public func stop() async {
        if let ownedService { await ownedService.stop() }
        ownedService = nil
        mode = .stopped
    }

    private func stoppedState() async -> Hub.ServiceViewState {
        .init(
            mode: .stopped,
            service: .init(
                state: .stopped,
                endpoint: nil,
                openConnectionCount: 0,
                pendingPairingCount: 0
            ),
            manualInvitations: [],
            buildContexts: [],
            recentEvents: await log.entries()
        )
    }
}
}

actor ServiceLog {
    private var values: [Hub.ServiceLogEntry] = []
    private let capacity = 200

    func entries() -> [Hub.ServiceLogEntry] { values }

    func append(level: Hub.ServiceLogEntry.Level, message: String) {
        values.append(.init(level: level, message: String(message.prefix(4_096))))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    func record(_ event: DevSession.ServiceEvent) {
        switch event {
        case .listening:
            append(level: .success, message: "Helix is listening over TLS and Bonjour.")
        case .localControlRequest:
            break
        case .pairingStarted:
            append(level: .information, message: "Authenticating an App pairing request.")
        case .paired:
            append(level: .success, message: "An App connected to its exact Dev Shell.")
        case let .pairingRejected(rejection):
            append(level: .error, message: "Pairing rejected: \(rejection.detail)")
        case let .contextRegistered(context):
            append(level: .success, message: "Registered \(context.scheme) Build Context.")
        case .contextRemoved:
            append(level: .warning, message: "A superseded Build Context was removed.")
        case let .session(event):
            record(event)
        case .stopped:
            append(level: .information, message: "Helix service stopped.")
        }
    }

    private func record(_ event: DevSession.HostEvent) {
        switch event {
        case .authenticating:
            append(level: .information, message: "Authenticating the Dev Protocol session.")
        case let .connected(_, identity):
            append(
                level: .success,
                message: "Connected process \(identity.processID) for live reload."
            )
        case .pipeline:
            append(level: .information, message: "Live Reload pipeline state changed.")
        case let .result(_, result):
            switch result {
            case .activation:
                append(level: .success, message: "Live Reload patch activated.")
            case .noSemanticChange:
                append(level: .information, message: "Saved source has no semantic change.")
            case let .rebuildRequired(diagnostic):
                append(level: .warning, message: diagnostic.description)
            case let .failed(diagnostic):
                append(level: .error, message: diagnostic.description)
            case .superseded:
                append(level: .information, message: "An older reload was superseded.")
            }
        case .disconnected:
            append(level: .warning, message: "The App disconnected.")
        case let .connectionRejected(_, reason):
            append(level: .error, message: "Connection rejected: \(reason)")
        }
    }
}
#endif
