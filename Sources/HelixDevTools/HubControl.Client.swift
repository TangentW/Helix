#if os(macOS) && canImport(Network) && canImport(Security)
import Foundation
import Network
import HelixCore
import HelixDevProtocol

extension HubControl {
/// Minimal client contract consumed by build orchestration.
public protocol ClientProtocol: Sendable {
    func reserveAutomaticInvitation() async throws -> (
        reservation: Pairing.Reservation,
        spkiSHA256: Core.Digest
    )

    func registerAndActivate(
        invitationID: DevProtocol.InvitationID,
        context: DevSession.BuildContext
    ) async throws -> Pairing.Invitation
}

/// Short-lived client used by build phases; no project credential is persisted.
public struct Client: HubControl.ClientProtocol, Sendable {
    public var rendezvousStore: HubControl.RendezvousStore
    public var timeoutNanoseconds: UInt64

    public init(
        rendezvousStore: HubControl.RendezvousStore,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws {
        guard (100_000_000...60_000_000_000).contains(timeoutNanoseconds) else {
            throw HubControl.Error.invalidConfiguration
        }
        self.rendezvousStore = rendezvousStore
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public static func applicationSupport(
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) throws -> Self {
        try .init(
            rendezvousStore: .applicationSupportStore(),
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func reserveAutomaticInvitation() async throws -> (
        reservation: Pairing.Reservation,
        spkiSHA256: Core.Digest
    ) {
        let rendezvous = try rendezvousStore.load()
        let response = try await send(
            .reserveAutomaticInvitation,
            rendezvous: rendezvous
        )
        guard case let .automaticInvitationReserved(reservation) = response else {
            throw HubControl.Error.responseMismatch
        }
        return (reservation, rendezvous.spkiSHA256)
    }

    public func registerAndActivate(
        invitationID: DevProtocol.InvitationID,
        context: DevSession.BuildContext
    ) async throws -> Pairing.Invitation {
        let rendezvous = try rendezvousStore.load()
        let response = try await send(
            .registerAndActivate(invitationID: invitationID, context: context),
            rendezvous: rendezvous
        )
        guard case let .automaticInvitationActivated(invitation) = response else {
            throw HubControl.Error.responseMismatch
        }
        return invitation
    }

    public func serviceSnapshot() async throws -> DevSession.ServiceSnapshot {
        let rendezvous = try rendezvousStore.load()
        guard case let .serviceSnapshot(snapshot) = try await send(
            .serviceSnapshot,
            rendezvous: rendezvous
        ) else { throw HubControl.Error.responseMismatch }
        return snapshot
    }

    public func buildContexts(
        workspacePathHash: Core.Digest? = nil
    ) async throws -> [DevSession.BuildContext] {
        let rendezvous = try rendezvousStore.load()
        guard case let .buildContexts(contexts) = try await send(
            .buildContexts(workspacePathHash: workspacePathHash),
            rendezvous: rendezvous
        ) else { throw HubControl.Error.responseMismatch }
        return contexts
    }

    public func createManualInvitation(
        workspacePathHash: Core.Digest? = nil
    ) async throws -> DevSession.ManualInvitation {
        let rendezvous = try rendezvousStore.load()
        guard case let .manualInvitationCreated(invitation) = try await send(
            .createManualInvitation(workspacePathHash: workspacePathHash),
            rendezvous: rendezvous
        ) else { throw HubControl.Error.responseMismatch }
        return invitation
    }

    public func cancelManualInvitation(
        invitationID: DevProtocol.InvitationID
    ) async throws {
        let rendezvous = try rendezvousStore.load()
        guard case let .manualInvitationCancelled(cancelled) = try await send(
            .cancelManualInvitation(invitationID: invitationID),
            rendezvous: rendezvous
        ), cancelled == invitationID else {
            throw HubControl.Error.responseMismatch
        }
    }

    public func manualInvitations() async throws -> [DevSession.ManualInvitation] {
        let rendezvous = try rendezvousStore.load()
        guard case let .manualInvitations(invitations) = try await send(
            .manualInvitations,
            rendezvous: rendezvous
        ) else { throw HubControl.Error.responseMismatch }
        return invitations
    }

    private func send(
        _ command: HubControl.Command,
        rendezvous: HubControl.Rendezvous
    ) async throws -> HubControl.Success {
        let request = HubControl.Request(
            command: command,
            controlSecret: rendezvous.controlSecret
        )
        guard let port = NWEndpoint.Port(rawValue: rendezvous.port) else {
            throw HubControl.Error.invalidRendezvous
        }
        let transport = NetworkTransport.ByteTransport.pinnedTLSClient(
            host: .ipv4(.loopback),
            port: port,
            expectedSPKIHash: rendezvous.spkiSHA256
        )
        return try await withThrowingTaskGroup(of: HubControl.Success.self) { group in
            group.addTask {
                do {
                    try await transport.start()
                    try await transport.send(
                        NetworkTransport.ConnectionRoute.localControl.preamble
                    )
                    let channel = HubControl.Channel(transport: transport)
                    try await channel.send(request)
                    let response = try await channel.receiveResponse()
                    guard response.requestID == request.requestID else {
                        throw HubControl.Error.responseMismatch
                    }
                    let value: HubControl.Success
                    switch response {
                    case let .success(_, responseValue):
                        value = responseValue
                    case let .failure(_, failure):
                        throw HubControl.Error.requestFailed(
                            code: failure.code,
                            detail: failure.detail
                        )
                    }
                    await transport.close()
                    return value
                } catch {
                    await transport.close()
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await transport.close()
                throw HubControl.Error.serviceUnavailable
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HubControl.Error.serviceUnavailable
            }
            return result
        }
    }
}
}
#endif
