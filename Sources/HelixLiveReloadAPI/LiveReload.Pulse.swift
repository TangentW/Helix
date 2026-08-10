#if canImport(SwiftUI)
import Combine
import Foundation
import SwiftUI

extension LiveReload {
public enum SwiftUIRefreshMode: String, Codable, Hashable, Sendable {
    /// Re-evaluates the existing identity tree and preserves local @State.
    case invalidateBody
    /// Changes the boundary identity and intentionally resets local @State.
    case recreateSubtree
}

@MainActor
public final class Pulse: ObservableObject {
    public struct Snapshot: Hashable, Sendable {
        public let sequence: UInt64
        public let context: LiveReload.Context?
        public let affectedNominalTypes: Set<LiveReload.NominalTypeID>

        public init(
            sequence: UInt64 = 0,
            context: LiveReload.Context? = nil,
            affectedNominalTypes: Set<LiveReload.NominalTypeID> = []
        ) {
            self.sequence = sequence
            self.context = context
            self.affectedNominalTypes = affectedNominalTypes
        }
    }

    public struct BoundaryToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    public struct AdvanceResult: Hashable, Sendable {
        public let didPublish: Bool
        public let matchedBoundaryCount: Int
        public let sequence: UInt64
    }

    @MainActor
    public final class Signal: ObservableObject {
        @Published public fileprivate(set) var sequence: UInt64 = 0

        fileprivate func advance(to sequence: UInt64) {
            self.sequence = sequence
        }
    }

    public static let shared = LiveReload.Pulse()

    @Published public private(set) var snapshot = Snapshot()

    private enum SignalKey: Hashable {
        case all
        case type(LiveReload.NominalTypeID)
    }

    private struct Registration {
        var key: SignalKey
        var mode: LiveReload.SwiftUIRefreshMode
    }

    private var signals: [SignalKey: LiveReload.Pulse.Signal] = [:]
    private var registrations: [LiveReload.Pulse.BoundaryToken: Registration] = [:]

    public init() {}

    @discardableResult
    public func registerBoundary(
        for nominalTypeID: LiveReload.NominalTypeID? = nil,
        mode: LiveReload.SwiftUIRefreshMode = .invalidateBody
    ) -> LiveReload.Pulse.BoundaryToken {
        let token = BoundaryToken(rawValue: UUID())
        let signalKey = key(for: nominalTypeID)
        _ = signal(for: nominalTypeID)
        registrations[token] = .init(key: signalKey, mode: mode)
        return token
    }

    public func unregisterBoundary(_ token: LiveReload.Pulse.BoundaryToken) {
        registrations.removeValue(forKey: token)
    }

    public var activeBoundaryCount: Int { registrations.count }

    public var registeredTypeIDs: Set<LiveReload.NominalTypeID> {
        Set(registrations.values.compactMap {
            guard case let .type(id) = $0.key else { return nil }
            return id
        })
    }

    public var hasCatchAllBoundary: Bool {
        registrations.values.contains { $0.key == .all }
    }

    public func containsBoundary(for id: LiveReload.NominalTypeID) -> Bool {
        hasCatchAllBoundary || registeredTypeIDs.contains(id)
    }

    public func matchingBoundaryCount(
        affectedNominalTypes: Set<LiveReload.NominalTypeID>
    ) -> Int {
        registrations.values.reduce(into: 0) { count, registration in
            if matches(
                registration.key,
                affectedNominalTypes: affectedNominalTypes
            ) {
                count += 1
            }
        }
    }

    public func refreshSequence(for nominalTypeID: LiveReload.NominalTypeID?) -> UInt64 {
        signals[key(for: nominalTypeID)]?.sequence ?? 0
    }

    @discardableResult
    public func advance(
        _ context: LiveReload.Context,
        affectedNominalTypes: Set<LiveReload.NominalTypeID>
    ) throws -> LiveReload.Pulse.AdvanceResult {
        try context.validate()
        if let active = snapshot.context {
            guard context.generationID >= active.generationID else {
                throw LiveReload.ValidationError.invalidContext(
                    "a SwiftUI pulse cannot move to an older generation"
                )
            }
            if context.generationID == active.generationID, context.reason != .manual {
                guard context == active else {
                    throw LiveReload.ValidationError.invalidContext(
                        "a generation cannot be reused for a different automatic reload context"
                    )
                }
                return .init(
                    didPublish: false,
                    matchedBoundaryCount: 0,
                    sequence: snapshot.sequence
                )
            }
        }
        let next = snapshot.sequence.addingReportingOverflow(1)
        guard !next.overflow else {
            throw LiveReload.ValidationError.invalidContext(
                "SwiftUI pulse sequence is exhausted"
            )
        }
        let matched = matchingBoundaryCount(
            affectedNominalTypes: affectedNominalTypes
        )
        let nextSnapshot = Snapshot(
            sequence: next.partialValue,
            context: context,
            affectedNominalTypes: affectedNominalTypes
        )
        snapshot = nextSnapshot
        for (key, signal) in signals where matches(
            key,
            affectedNominalTypes: affectedNominalTypes
        ) {
            signal.advance(to: nextSnapshot.sequence)
        }
        return .init(
            didPublish: true,
            matchedBoundaryCount: matched,
            sequence: nextSnapshot.sequence
        )
    }

    fileprivate func signal(
        for nominalTypeID: LiveReload.NominalTypeID?
    ) -> LiveReload.Pulse.Signal {
        let key = key(for: nominalTypeID)
        if let signal = signals[key] { return signal }
        let signal = LiveReload.Pulse.Signal()
        signals[key] = signal
        return signal
    }

    private func key(for id: LiveReload.NominalTypeID?) -> SignalKey {
        id.map(SignalKey.type) ?? .all
    }

    private func matches(
        _ key: SignalKey,
        affectedNominalTypes: Set<LiveReload.NominalTypeID>
    ) -> Bool {
        guard !affectedNominalTypes.isEmpty else { return true }
        switch key {
        case .all:
            return true
        case let .type(id):
            return affectedNominalTypes.contains(id)
        }
    }
}

public struct SwiftUIBoundary<Content: View>: View {
    private let pulse: LiveReload.Pulse
    private let nominalTypeID: LiveReload.NominalTypeID?
    private let mode: LiveReload.SwiftUIRefreshMode
    private let content: Content

    @ObservedObject private var signal: LiveReload.Pulse.Signal
    @SwiftUI.State private var registrationToken: LiveReload.Pulse.BoundaryToken?

    @MainActor
    public init(
        pulse: LiveReload.Pulse = .shared,
        nominalTypeID: LiveReload.NominalTypeID? = nil,
        mode: LiveReload.SwiftUIRefreshMode = .invalidateBody,
        @ViewBuilder content: () -> Content
    ) {
        self.pulse = pulse
        self.nominalTypeID = nominalTypeID
        self.mode = mode
        self.content = content()
        _signal = ObservedObject(wrappedValue: pulse.signal(for: nominalTypeID))
        _registrationToken = SwiftUI.State(initialValue: nil)
    }

    public var body: some View {
        renderedContent
            .onAppear {
                guard registrationToken == nil else { return }
                registrationToken = pulse.registerBoundary(
                    for: nominalTypeID,
                    mode: mode
                )
            }
            .onDisappear {
                guard let registrationToken else { return }
                pulse.unregisterBoundary(registrationToken)
                self.registrationToken = nil
            }
    }

    @ViewBuilder
    private var renderedContent: some View {
        switch mode {
        case .invalidateBody:
            content
        case .recreateSubtree:
            content.id(signal.sequence)
        }
    }
}
}

public extension View {
    @MainActor
    func liveReloadBoundary(
        for nominalTypeID: LiveReload.NominalTypeID? = nil,
        mode: LiveReload.SwiftUIRefreshMode = .invalidateBody,
        pulse: LiveReload.Pulse = .shared
    ) -> some View {
        LiveReload.SwiftUIBoundary(
            pulse: pulse,
            nominalTypeID: nominalTypeID,
            mode: mode
        ) {
            self
        }
    }
}
#endif
