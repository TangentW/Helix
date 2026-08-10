#if canImport(SwiftUI)
import Combine
import Foundation
import SwiftUI

extension LiveReload {
/// How a SwiftUI boundary responds to a matching Live Reload generation.
public enum SwiftUIRefreshMode: String, Codable, Hashable, Sendable {
    /// Re-evaluates the existing identity tree and preserves local @State.
    case invalidateBody
    /// Changes the boundary identity and intentionally resets local @State.
    case recreateSubtree
}

/// Publishes targeted generation changes to active SwiftUI boundaries.
///
/// Applications normally use ``SwiftUIBoundary`` or
/// `View/liveReloadBoundary(for:mode:pulse:)` instead of registering boundaries
/// directly. A custom host may inspect ``snapshot`` or call ``advance(_:affectedNominalTypes:)``.
@MainActor
public final class Pulse: ObservableObject {
    /// The latest SwiftUI reload event published by a pulse.
    public struct Snapshot: Hashable, Sendable {
        /// A monotonically increasing presentation sequence.
        public let sequence: UInt64
        /// The generation associated with the sequence, if one has been published.
        public let context: LiveReload.Context?
        /// Nominal type identities affected by the generation.
        public let affectedNominalTypes: Set<LiveReload.NominalTypeID>

        /// Creates a pulse snapshot.
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

    /// An opaque registration token used to unregister a boundary.
    public struct BoundaryToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    /// The result of publishing a context to active SwiftUI boundaries.
    public struct AdvanceResult: Hashable, Sendable {
        /// Whether a new snapshot was published.
        public let didPublish: Bool
        /// The number of active boundary registrations that matched.
        public let matchedBoundaryCount: Int
        /// The resulting pulse sequence.
        public let sequence: UInt64
    }

    /// An observable sequence scoped to one boundary identity.
    @MainActor
    public final class Signal: ObservableObject {
        /// The latest matching pulse sequence.
        @Published public fileprivate(set) var sequence: UInt64 = 0

        fileprivate func advance(to sequence: UInt64) {
            self.sequence = sequence
        }
    }

    /// The process-wide pulse used by default SwiftUI integration.
    public static let shared = LiveReload.Pulse()

    /// The most recently published reload snapshot.
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

    /// Creates an isolated pulse, typically for previews or tests.
    public init() {}

    /// Registers an active SwiftUI reload boundary.
    ///
    /// - Parameters:
    ///   - nominalTypeID: A target type, or `nil` for a catch-all boundary.
    ///   - mode: Whether matching reloads preserve or recreate subtree identity.
    /// - Returns: A token that must be passed to ``unregisterBoundary(_:)``.
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

    /// Removes a previously registered boundary.
    public func unregisterBoundary(_ token: LiveReload.Pulse.BoundaryToken) {
        registrations.removeValue(forKey: token)
    }

    /// The number of currently registered SwiftUI boundaries.
    public var activeBoundaryCount: Int { registrations.count }

    /// Type-specific identities represented by active boundaries.
    public var registeredTypeIDs: Set<LiveReload.NominalTypeID> {
        Set(registrations.values.compactMap {
            guard case let .type(id) = $0.key else { return nil }
            return id
        })
    }

    /// Whether an active boundary accepts every affected type.
    public var hasCatchAllBoundary: Bool {
        registrations.values.contains { $0.key == .all }
    }

    /// Returns whether a type-specific or catch-all boundary can refresh `id`.
    public func containsBoundary(for id: LiveReload.NominalTypeID) -> Bool {
        hasCatchAllBoundary || registeredTypeIDs.contains(id)
    }

    /// Counts registrations that would receive the supplied affected types.
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

    /// Returns the latest matching sequence for a boundary identity.
    public func refreshSequence(for nominalTypeID: LiveReload.NominalTypeID?) -> UInt64 {
        signals[key(for: nominalTypeID)]?.sequence ?? 0
    }

    /// Publishes an activated generation to matching SwiftUI boundaries.
    ///
    /// Duplicate automatic publication of the same context is idempotent.
    /// Reusing a generation ID for different metadata or moving backwards is
    /// rejected.
    ///
    /// - Parameters:
    ///   - context: The generation that is already active.
    ///   - affectedNominalTypes: Types changed by the transaction. An empty set
    ///     matches every boundary.
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

/// A SwiftUI view that subscribes a subtree to Helix Live Reload pulses.
///
/// Prefer `View/liveReloadBoundary(for:mode:pulse:)` for normal composition.
public struct SwiftUIBoundary<Content: View>: View {
    private let pulse: LiveReload.Pulse
    private let nominalTypeID: LiveReload.NominalTypeID?
    private let mode: LiveReload.SwiftUIRefreshMode
    private let content: Content

    @ObservedObject private var signal: LiveReload.Pulse.Signal
    @SwiftUI.State private var registrationToken: LiveReload.Pulse.BoundaryToken?

    /// Creates a reload boundary around `content`.
    ///
    /// - Parameters:
    ///   - pulse: The pulse that publishes activated generations.
    ///   - nominalTypeID: A target type, or `nil` to receive every pulse.
    ///   - mode: Whether local SwiftUI state is preserved or reset.
    ///   - content: The subtree protected by the boundary.
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

    /// SwiftUI subtree whose identity or body invalidation follows matching pulses.
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
    /// Subscribes this SwiftUI subtree to Helix Live Reload.
    ///
    /// ```swift
    /// ProfileScreen()
    ///     .liveReloadBoundary(
    ///         for: .derive(
    ///             module: "ProfileFeature",
    ///             canonicalName: "ProfileFeature.ProfileScreen"
    ///         )
    ///     )
    /// ```
    ///
    /// Use `.invalidateBody` to preserve local `@State`. Select
    /// `.recreateSubtree` only when the edit requires fresh subtree identity.
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
