import Foundation
import HelixCore

extension Pairing {
/// Security and lifetime policy enforced by ``Authority``.
public struct AuthorityConfiguration: Hashable, Sendable {
    /// Lifetime of an activated code, in seconds.
    public var invitationLifetime: TimeInterval
    /// Maximum delay between reserving a code and binding the final Shell.
    public var reservationLifetime: TimeInterval
    /// Lifetime of an authenticated reconnect lease.
    public var leaseLifetime: TimeInterval
    /// Failed attempts permitted per invitation and source window.
    public var maximumFailedAttempts: Int
    /// Rolling window used to count failures from one network source.
    public var attemptWindow: TimeInterval
    /// Duration for which a source remains locked after reaching the limit.
    public var lockoutDuration: TimeInterval

    public init(
        invitationLifetime: TimeInterval = 120,
        reservationLifetime: TimeInterval = 24 * 60 * 60,
        leaseLifetime: TimeInterval = 30 * 60,
        maximumFailedAttempts: Int = 5,
        attemptWindow: TimeInterval = 60,
        lockoutDuration: TimeInterval = 30
    ) {
        self.invitationLifetime = invitationLifetime
        self.reservationLifetime = reservationLifetime
        self.leaseLifetime = leaseLifetime
        self.maximumFailedAttempts = maximumFailedAttempts
        self.attemptWindow = attemptWindow
        self.lockoutDuration = lockoutDuration
    }

    /// Rejects unsafe or nonsensical policy values.
    public func validate() throws {
        guard invitationLifetime.isFinite, (10...600).contains(invitationLifetime),
              reservationLifetime.isFinite, (60...7 * 24 * 60 * 60).contains(reservationLifetime),
              leaseLifetime.isFinite, (60...24 * 60 * 60).contains(leaseLifetime),
              (1...20).contains(maximumFailedAttempts),
              attemptWindow.isFinite, (1...600).contains(attemptWindow),
              lockoutDuration.isFinite, (1...600).contains(lockoutDuration)
        else {
            throw DevProtocol.Error.malformedMessage(
                "pairing authority configuration is invalid"
            )
        }
    }
}

/// The identities and secret-bearing grant produced by first-time redemption.
public struct EstablishedSession: Sendable {
    public var grant: Pairing.SessionGrant
    public var shellIdentity: DevProtocol.ShellIdentity
    public var peerIdentity: DevProtocol.PeerIdentity

    public init(
        grant: Pairing.SessionGrant,
        shellIdentity: DevProtocol.ShellIdentity,
        peerIdentity: DevProtocol.PeerIdentity
    ) {
        self.grant = grant
        self.shellIdentity = shellIdentity
        self.peerIdentity = peerIdentity
    }
}

/// The authenticated state restored from an existing reconnect lease.
public struct ResumedSession: Sendable {
    public var grant: Pairing.ResumeGrant
    public var shellIdentity: DevProtocol.ShellIdentity
    public var peerIdentity: DevProtocol.PeerIdentity
    public var sessionSecret: Data

    public init(
        grant: Pairing.ResumeGrant,
        shellIdentity: DevProtocol.ShellIdentity,
        peerIdentity: DevProtocol.PeerIdentity,
        sessionSecret: Data
    ) {
        self.grant = grant
        self.shellIdentity = shellIdentity
        self.peerIdentity = peerIdentity
        self.sessionSecret = sessionSecret
    }
}

/// Owns one-time invitations, online-attempt limits, and reconnect leases.
///
/// All mutations are actor-isolated so two peers cannot redeem the same code or
/// resume with the same proof concurrently.
public actor Authority {
    private struct InvitationState: Sendable {
        var invitation: Pairing.Invitation
        var failedAttempts: Int
    }

    private struct LeaseState: Sendable {
        var shellIdentity: DevProtocol.ShellIdentity
        var peerIdentity: DevProtocol.PeerIdentity
        var sessionSecret: Data
        var expiresAt: Date
        var consumedResumeProofs: Set<Core.Digest>
    }

    private struct SourceFailureState: Sendable {
        var failedAttempts: Int
        var lastFailureAt: Date
        var blockedUntil: Date?
    }

    /// Immutable security policy for this authority.
    public let configuration: Pairing.AuthorityConfiguration
    private var reservations: [DevProtocol.InvitationID: Pairing.Reservation] = [:]
    private var invitations: [DevProtocol.InvitationID: InvitationState] = [:]
    private var leases: [DevProtocol.LeaseID: LeaseState] = [:]
    private var invitationByCode: [Pairing.Code: DevProtocol.InvitationID] = [:]
    private var sourceFailures: [Pairing.RateLimitKey: SourceFailureState] = [:]

    /// Creates an empty authority after validating its policy.
    public init(configuration: Pairing.AuthorityConfiguration = .init()) throws {
        try configuration.validate()
        self.configuration = configuration
    }

    /// Reserves a code before the final executable UUID is available.
    public func reserve(
        kind: Pairing.Kind,
        now: Date = Date()
    ) throws -> Pairing.Reservation {
        purge(now: now)
        let code = try uniqueCode()
        let reservation = Pairing.Reservation(
            invitationID: .init(rawValue: UUID()),
            code: code,
            kind: kind,
            reservedAt: now
        )
        try reservation.validate()
        reservations[reservation.invitationID] = reservation
        invitationByCode[code] = reservation.invitationID
        return reservation
    }

    /// Registers a reservation created by another same-user Helix process.
    public func register(
        _ reservation: Pairing.Reservation,
        now: Date = Date()
    ) throws {
        purge(now: now)
        try reservation.validate()
        let maximumAge = reservationLifetime(for: reservation.kind)
        guard reservation.reservedAt <= now,
              now.timeIntervalSince(reservation.reservedAt) <= maximumAge,
              reservations[reservation.invitationID] == nil,
              invitations[reservation.invitationID] == nil,
              invitationByCode[reservation.code] == nil
        else {
            throw Pairing.Failure(
                reason: .invalidInvitation,
                detail: "invitation reservation is stale or already registered"
            )
        }
        reservations[reservation.invitationID] = reservation
        invitationByCode[reservation.code] = reservation.invitationID
    }

    /// Binds a reserved code to the exact linked Shell identity.
    public func activate(
        invitationID: DevProtocol.InvitationID,
        shellIdentity: DevProtocol.ShellIdentity,
        now: Date = Date()
    ) throws -> Pairing.Invitation {
        purge(now: now, preservingReservationID: invitationID)
        try shellIdentity.validate()
        guard let reservation = reservations[invitationID] else {
            throw Pairing.Failure(
                reason: .invalidInvitation,
                detail: "invitation reservation is unavailable"
            )
        }
        let maximumAge = reservationLifetime(for: reservation.kind)
        guard reservation.reservedAt <= now,
              now.timeIntervalSince(reservation.reservedAt) <= maximumAge
        else {
            invalidate(invitationID: invitationID)
            throw Pairing.Failure(
                reason: reservation.kind == .manual
                    ? .expiredInvitation : .invalidInvitation,
                detail: "invitation reservation expired"
            )
        }
        let expiresAt = reservation.kind == .manual
            ? reservation.reservedAt.addingTimeInterval(configuration.invitationLifetime)
            : now.addingTimeInterval(configuration.invitationLifetime)
        let invitation = Pairing.Invitation(
            reservation: reservation,
            shellIdentity: shellIdentity,
            expiresAt: expiresAt
        )
        try invitation.validate()
        reservations[invitationID] = nil
        invitations[invitationID] = .init(
            invitation: invitation,
            failedAttempts: 0
        )
        return invitation
    }

    /// Creates and activates an invitation when the final Shell is already known.
    public func issue(
        kind: Pairing.Kind,
        shellIdentity: DevProtocol.ShellIdentity,
        now: Date = Date()
    ) throws -> Pairing.Invitation {
        let reservation = try reserve(kind: kind, now: now)
        return try activate(
            invitationID: reservation.invitationID,
            shellIdentity: shellIdentity,
            now: now
        )
    }

    /// Consumes an invitation and creates an authenticated reconnect lease.
    public func redeem(
        _ request: Pairing.RedeemRequest,
        rateLimitKey: Pairing.RateLimitKey,
        tlsExporterHash: Core.Digest,
        now: Date = Date()
    ) throws -> Pairing.EstablishedSession {
        try request.validate()
        let candidateInvitationID = invitationByCode[request.code]
        purge(now: now, preservingInvitationID: candidateInvitationID)
        if let blockedUntil = sourceFailures[rateLimitKey]?.blockedUntil,
           now < blockedUntil {
            throw Pairing.Failure(
                reason: .attemptLimitReached,
                detail: "pairing attempts are temporarily rate limited"
            )
        }
        guard let invitationID = invitationByCode[request.code],
              var state = invitations[invitationID]
        else {
            let reachedLimit = recordFailure(rateLimitKey: rateLimitKey, now: now)
            throw Pairing.Failure(
                reason: reachedLimit ? .attemptLimitReached : .invalidInvitation,
                detail: reachedLimit
                    ? "pairing attempts are temporarily rate limited"
                    : "pairing code is invalid or inactive"
            )
        }
        if now > state.invitation.expiresAt {
            invalidate(invitationID: invitationID)
            throw Pairing.Failure(
                reason: .expiredInvitation,
                detail: "pairing invitation expired"
            )
        }
        guard state.invitation.shellIdentity.matches(request.peerIdentity.build) else {
            state.failedAttempts += 1
            let sourceReachedLimit = recordFailure(rateLimitKey: rateLimitKey, now: now)
            if state.failedAttempts >= configuration.maximumFailedAttempts {
                invalidate(invitationID: invitationID)
                throw Pairing.Failure(
                    reason: .attemptLimitReached,
                    detail: "pairing attempt limit reached"
                )
            }
            invitations[invitationID] = state
            if sourceReachedLimit {
                throw Pairing.Failure(
                    reason: .attemptLimitReached,
                    detail: "pairing attempts are temporarily rate limited"
                )
            }
            throw Pairing.Failure(
                reason: .buildMismatch,
                detail: "App does not match the invitation's exact Dev Shell"
            )
        }

        let leaseID = DevProtocol.LeaseID(rawValue: UUID())
        let secret = try DevProtocol.SecureRandom.bytes(count: 32)
        let serverNonce = try DevProtocol.SecureRandom.bytes(count: 32)
        let expiresAt = now.addingTimeInterval(configuration.leaseLifetime)
        let proof = try Pairing.Proof.sessionGrant(
            request: request,
            shellID: state.invitation.shellIdentity.shellID,
            leaseID: leaseID,
            sessionSecret: secret,
            serverNonce: serverNonce,
            expiresAt: expiresAt,
            tlsExporterHash: tlsExporterHash
        )
        let grant = Pairing.SessionGrant(
            shellID: state.invitation.shellIdentity.shellID,
            leaseID: leaseID,
            sessionSecret: secret,
            serverNonce: serverNonce,
            expiresAt: expiresAt,
            proof: proof
        )
        try grant.validate()
        leases[leaseID] = .init(
            shellIdentity: state.invitation.shellIdentity,
            peerIdentity: request.peerIdentity,
            sessionSecret: secret,
            expiresAt: expiresAt,
            consumedResumeProofs: []
        )
        invalidate(invitationID: invitationID)
        sourceFailures[rateLimitKey] = nil
        return .init(
            grant: grant,
            shellIdentity: state.invitation.shellIdentity,
            peerIdentity: request.peerIdentity
        )
    }

    /// Authenticates a reconnect without exposing or reusing the short code.
    public func resume(
        _ request: Pairing.ResumeRequest,
        tlsExporterHash: Core.Digest,
        now: Date = Date()
    ) throws -> Pairing.ResumedSession {
        purge(now: now)
        try request.validate()
        guard var state = leases[request.leaseID], now <= state.expiresAt,
              state.peerIdentity.peerID == request.peerIdentity.peerID,
              state.shellIdentity.matches(request.peerIdentity.build)
        else {
            throw Pairing.Failure(reason: .invalidLease, detail: "session lease is invalid")
        }
        let expectedRequestProof = try Pairing.Proof.resumeRequest(
            leaseID: request.leaseID,
            peerIdentity: request.peerIdentity,
            clientNonce: request.clientNonce,
            sessionSecret: state.sessionSecret,
            tlsExporterHash: tlsExporterHash
        )
        guard DevProtocol.FrameCodec.constantTimeEqual(
            request.proof,
            expectedRequestProof
        ) else {
            throw Pairing.Failure(reason: .invalidLease, detail: "lease proof is invalid")
        }
        let requestProof = try Core.Digest(bytes: request.proof)
        guard !state.consumedResumeProofs.contains(requestProof) else {
            throw Pairing.Failure(reason: .invalidLease, detail: "lease proof was already consumed")
        }
        let serverNonce = try DevProtocol.SecureRandom.bytes(count: 32)
        let proof = try Pairing.Proof.resumeGrant(
            request: request,
            shellID: state.shellIdentity.shellID,
            serverNonce: serverNonce,
            expiresAt: state.expiresAt,
            sessionSecret: state.sessionSecret,
            tlsExporterHash: tlsExporterHash
        )
        let grant = Pairing.ResumeGrant(
            shellID: state.shellIdentity.shellID,
            leaseID: request.leaseID,
            serverNonce: serverNonce,
            expiresAt: state.expiresAt,
            proof: proof
        )
        try grant.validate()
        state.consumedResumeProofs.insert(requestProof)
        leases[request.leaseID] = state
        return .init(
            grant: grant,
            shellIdentity: state.shellIdentity,
            peerIdentity: request.peerIdentity,
            sessionSecret: state.sessionSecret
        )
    }

    /// Removes a reserved or active invitation immediately.
    public func invalidate(invitationID: DevProtocol.InvitationID) {
        if let reservation = reservations.removeValue(forKey: invitationID) {
            invitationByCode[reservation.code] = nil
        }
        if let state = invitations.removeValue(forKey: invitationID) {
            invitationByCode[state.invitation.code] = nil
        }
    }

    /// Revokes an authenticated reconnect lease immediately.
    public func revoke(leaseID: DevProtocol.LeaseID) {
        leases[leaseID] = nil
    }

    /// Clears every invitation, lease, and rate-limit record.
    public func invalidateAll() {
        reservations.removeAll(keepingCapacity: false)
        invitations.removeAll(keepingCapacity: false)
        leases.removeAll(keepingCapacity: false)
        invitationByCode.removeAll(keepingCapacity: false)
        sourceFailures.removeAll(keepingCapacity: false)
    }

    /// Returns active object counts after purging expired state.
    public func counts(now: Date = Date()) -> (
        reservations: Int,
        invitations: Int,
        leases: Int
    ) {
        purge(now: now)
        return (reservations.count, invitations.count, leases.count)
    }

    private func uniqueCode() throws -> Pairing.Code {
        for _ in 0..<64 {
            let code = try Pairing.Code.random()
            if invitationByCode[code] == nil { return code }
        }
        throw DevProtocol.Error.secureRandomFailed
    }

    @discardableResult
    private func recordFailure(
        rateLimitKey: Pairing.RateLimitKey,
        now: Date
    ) -> Bool {
        var state = sourceFailures[rateLimitKey]
        if let previous = state,
           now.timeIntervalSince(previous.lastFailureAt) <= configuration.attemptWindow {
            state = previous
            state?.failedAttempts += 1
            state?.lastFailureAt = now
        } else {
            state = .init(failedAttempts: 1, lastFailureAt: now, blockedUntil: nil)
        }
        let reachedLimit = state?.failedAttempts ?? 0 >= configuration.maximumFailedAttempts
        if reachedLimit {
            state?.blockedUntil = now.addingTimeInterval(configuration.lockoutDuration)
        }
        sourceFailures[rateLimitKey] = state
        return reachedLimit
    }

    private func purge(
        now: Date,
        preservingReservationID: DevProtocol.InvitationID? = nil,
        preservingInvitationID: DevProtocol.InvitationID? = nil
    ) {
        let expiredReservations = reservations.values.filter {
            now.timeIntervalSince($0.reservedAt) > reservationLifetime(for: $0.kind)
                && $0.invitationID != preservingReservationID
        }
        for reservation in expiredReservations {
            reservations[reservation.invitationID] = nil
            invitationByCode[reservation.code] = nil
        }
        let expiredInvitations = invitations.values.filter {
            now > $0.invitation.expiresAt
                && $0.invitation.invitationID != preservingInvitationID
        }
        for state in expiredInvitations {
            invitations[state.invitation.invitationID] = nil
            invitationByCode[state.invitation.code] = nil
        }
        leases = leases.filter { now <= $0.value.expiresAt }
        sourceFailures = sourceFailures.filter { _, state in
            if let blockedUntil = state.blockedUntil {
                return now < blockedUntil
            }
            return now.timeIntervalSince(state.lastFailureAt) <= configuration.attemptWindow
        }
    }

    private func reservationLifetime(for kind: Pairing.Kind) -> TimeInterval {
        switch kind {
        case .automaticXcode: configuration.reservationLifetime
        case .manual: configuration.invitationLifetime
        }
    }
}
}
