import Foundation
import HelixCore
import HelixDevProtocol

extension DevSession {
/// User-facing manual invitation produced by the Mac-side service.
public struct ManualInvitation: Codable, Hashable, Sendable {
    /// Reserved four-character code and invitation identity.
    public var reservation: Pairing.Reservation
    /// Optional workspace restriction selected in Helix Hub.
    public var workspacePathHash: Core.Digest?
    /// Deadline after which the code is rejected even if never submitted.
    public var expiresAt: Date

    /// Four-character value displayed by Helix Hub.
    public var code: Pairing.Code { reservation.code }

    init(
        reservation: Pairing.Reservation,
        workspacePathHash: Core.Digest?,
        expiresAt: Date
    ) {
        self.reservation = reservation
        self.workspacePathHash = workspacePathHash
        self.expiresAt = expiresAt
    }

    public func validate() throws {
        try reservation.validate()
        guard reservation.kind == .manual,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > reservation.reservedAt
        else {
            throw DevProtocol.Error.malformedMessage(
                "manual pairing invitation is invalid"
            )
        }
    }
}

/// Result of consuming a new invitation and selecting its exact Build Context.
public struct EstablishedAuthorization: Sendable {
    /// Exact compiler and source context selected for the App.
    public var context: DevSession.BuildContext
    /// Secret-bearing pairing result used to start the Dev Protocol.
    public var session: Pairing.EstablishedSession
}

/// Result of authenticating a reconnect lease and selecting its exact context.
public struct ResumedAuthorization: Sendable {
    /// Same exact compiler and source context selected on first pairing.
    public var context: DevSession.BuildContext
    /// Authenticated lease result used to resume the Dev Protocol.
    public var session: Pairing.ResumedSession
}

/// Unifies manual and Xcode pairing over one exact-build registry.
public actor ConnectionBroker {
    public let registry: DevSession.ContextRegistry
    public let authority: Pairing.Authority

    private var manualInvitationsByCode: [Pairing.Code: DevSession.ManualInvitation] = [:]

    /// Creates a broker from independently reusable registry and authority actors.
    public init(
        registry: DevSession.ContextRegistry,
        authority: Pairing.Authority
    ) {
        self.registry = registry
        self.authority = authority
    }

    /// Reserves a short-lived code for explicit entry in an App debug page.
    public func createManualInvitation(
        workspacePathHash: Core.Digest? = nil,
        now: Date = Date()
    ) async throws -> DevSession.ManualInvitation {
        await purgeManualInvitations(now: now)
        let reservation = try await authority.reserve(kind: .manual, now: now)
        let configuration = await authority.configuration
        let invitation = DevSession.ManualInvitation(
            reservation: reservation,
            workspacePathHash: workspacePathHash,
            expiresAt: now.addingTimeInterval(configuration.invitationLifetime)
        )
        manualInvitationsByCode[reservation.code] = invitation
        return invitation
    }

    /// Lists active manual invitations newest-first for presentation by a UI.
    public func manualInvitations(now: Date = Date()) async -> [DevSession.ManualInvitation] {
        await purgeManualInvitations(now: now)
        return manualInvitationsByCode.values.sorted {
            $0.reservation.reservedAt > $1.reservation.reservedAt
        }
    }

    /// Cancels a displayed manual invitation.
    public func cancelManualInvitation(
        invitationID: DevProtocol.InvitationID
    ) async {
        if let invitation = manualInvitationsByCode.values.first(where: {
            $0.reservation.invitationID == invitationID
        }) {
            manualInvitationsByCode[invitation.code] = nil
        }
        await authority.invalidate(invitationID: invitationID)
    }

    /// Clears transient invitations and leases when the owning service stops.
    public func invalidateAll() async {
        manualInvitationsByCode.removeAll(keepingCapacity: false)
        await authority.invalidateAll()
    }

    /// Reserves the code embedded by an Xcode build before final linking.
    public func reserveAutomaticInvitation(
        reusing existing: Pairing.Reservation? = nil,
        now: Date = Date()
    ) async throws -> Pairing.Reservation {
        try await authority.reserve(
            kind: .automaticXcode,
            reusing: existing,
            now: now
        )
    }

    /// Imports an automatic reservation created by another same-user process.
    public func registerAutomaticReservation(
        _ reservation: Pairing.Reservation,
        now: Date = Date()
    ) async throws {
        guard reservation.kind == .automaticXcode else {
            throw Pairing.Failure(
                reason: .invalidInvitation,
                detail: "only Xcode reservations may be registered through this API"
            )
        }
        try await authority.register(reservation, now: now)
    }

    /// Binds an Xcode reservation after its exact Build Context is registered.
    public func activateAutomaticInvitation(
        invitationID: DevProtocol.InvitationID,
        shellID: DevProtocol.ShellID,
        now: Date = Date()
    ) async throws -> Pairing.Invitation {
        guard let context = await registry.context(shellID: shellID) else {
            throw Pairing.Failure(
                reason: .buildMismatch,
                detail: "the linked Shell has no registered Build Context"
            )
        }
        return try await authority.activate(
            invitationID: invitationID,
            shellIdentity: context.shellIdentity,
            now: now
        )
    }

    /// Consumes either invitation form and returns the exact compiler context.
    public func redeem(
        _ request: Pairing.RedeemRequest,
        rateLimitKey: Pairing.RateLimitKey,
        tlsExporterHash: Core.Digest,
        now: Date = Date()
    ) async throws -> DevSession.EstablishedAuthorization {
        if let manual = manualInvitationsByCode[request.code], now > manual.expiresAt {
            manualInvitationsByCode[manual.code] = nil
            await authority.invalidate(
                invitationID: manual.reservation.invitationID
            )
            throw Pairing.Failure(
                reason: .expiredInvitation,
                detail: "manual pairing code expired"
            )
        }
        await purgeManualInvitations(now: now)
        if let manual = manualInvitationsByCode[request.code],
           let context = await registry.resolve(request.peerIdentity.build),
           manual.workspacePathHash == nil
                || manual.workspacePathHash == context.workspacePathHash {
            _ = try await authority.activate(
                invitationID: manual.reservation.invitationID,
                shellIdentity: context.shellIdentity,
                now: now
            )
            manualInvitationsByCode[manual.code] = nil
        }

        let session = try await authority.redeem(
            request,
            rateLimitKey: rateLimitKey,
            tlsExporterHash: tlsExporterHash,
            now: now
        )
        guard let context = await registry.context(
            shellID: session.shellIdentity.shellID
        ), context.shellIdentity == session.shellIdentity else {
            await authority.revoke(leaseID: session.grant.leaseID)
            throw Pairing.Failure(
                reason: .buildMismatch,
                detail: "the paired Shell Build Context is unavailable"
            )
        }
        return .init(context: context, session: session)
    }

    /// Authenticates a lease and resolves the same exact compiler context.
    public func resume(
        _ request: Pairing.ResumeRequest,
        tlsExporterHash: Core.Digest,
        now: Date = Date()
    ) async throws -> DevSession.ResumedAuthorization {
        let session = try await authority.resume(
            request,
            tlsExporterHash: tlsExporterHash,
            now: now
        )
        guard let context = await registry.context(
            shellID: session.shellIdentity.shellID
        ), context.shellIdentity == session.shellIdentity else {
            await authority.revoke(leaseID: request.leaseID)
            throw Pairing.Failure(
                reason: .buildMismatch,
                detail: "the resumed Shell Build Context is unavailable"
            )
        }
        return .init(context: context, session: session)
    }

    private func purgeManualInvitations(now: Date) async {
        let expired = manualInvitationsByCode.values.filter { now > $0.expiresAt }
        for invitation in expired {
            manualInvitationsByCode[invitation.code] = nil
            await authority.invalidate(
                invitationID: invitation.reservation.invitationID
            )
        }
    }
}
}
