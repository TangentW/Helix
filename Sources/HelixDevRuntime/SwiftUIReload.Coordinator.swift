#if canImport(SwiftUI)
import HelixDevProtocol
import HelixLiveReloadAPI
import SwiftUI

/// Development-time orchestration for SwiftUI Live Reload boundaries.
public enum SwiftUIReload {}

extension SwiftUIReload {
/// Outcome of publishing a generation to active SwiftUI boundaries.
public struct Report: Sendable {
    /// Protocol-level refresh outcome.
    public var status: DevProtocol.UIReloadStatus
    /// Number of active boundary registrations matched by the changed types.
    public var matchedBoundaryCount: Int
    /// Number of matching registrations that received a new pulse.
    public var refreshedBoundaryCount: Int
    /// Non-fatal target-resolution details.
    public var warnings: [String]
    /// Invalid hints, contexts, or pulse transitions.
    public var errors: [String]

    /// Creates a SwiftUI refresh report.
    public init(
        status: DevProtocol.UIReloadStatus,
        matchedBoundaryCount: Int,
        refreshedBoundaryCount: Int,
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.status = status
        self.matchedBoundaryCount = matchedBoundaryCount
        self.refreshedBoundaryCount = refreshedBoundaryCount
        self.warnings = warnings
        self.errors = errors
    }
}

/// Publishes activated generations through a `LiveReload.Pulse`.
///
/// Applications usually establish targets with
/// `View/liveReloadBoundary(for:mode:pulse:)`; the default application session
/// invokes this coordinator automatically.
@MainActor
public final class Coordinator {
    /// Pulse shared with the SwiftUI boundaries managed by this coordinator.
    public let pulse: LiveReload.Pulse

    /// Creates a coordinator.
    ///
    /// Pass a dedicated pulse for previews or tests; production development
    /// sessions normally use `LiveReload.Pulse.shared`.
    public init(pulse: LiveReload.Pulse = .shared) {
        self.pulse = pulse
    }

    /// Publishes a targeted refresh derived from compiler reload hints.
    ///
    /// Observe-only actions are ignored. Changed nominal type identities are
    /// matched against active boundaries, and the returned report identifies
    /// missing boundaries instead of silently claiming success.
    ///
    /// - Parameters:
    ///   - context: Metadata for the generation that is already active.
    ///   - hints: Compiler-produced reload policies and target identities.
    public func reload(
        context: LiveReload.Context,
        hints: [DevProtocol.ReloadHint]
    ) -> SwiftUIReload.Report {
        do {
            try context.validate()
        } catch {
            return .init(
                status: .failed,
                matchedBoundaryCount: 0,
                refreshedBoundaryCount: 0,
                errors: [String(describing: error)]
            )
        }
        let plan = ReloadPlanning.Planner().plan(hints)
        let actions = plan.actions.filter { $0.policy != .observeOnly }
        guard !actions.isEmpty else {
            return .init(
                status: plan.warnings.isEmpty ? .notRequested : .failed,
                matchedBoundaryCount: 0,
                refreshedBoundaryCount: 0,
                errors: plan.warnings
            )
        }

        let affectedTypes = Set(actions.map(\.nominalTypeID))
        let matched = pulse.matchingBoundaryCount(
            affectedNominalTypes: affectedTypes
        )
        let unmatched = affectedTypes.filter { !pulse.containsBoundary(for: $0) }
        var warnings = unmatched.sorted { $0.description < $1.description }.map {
            "no active SwiftUI live-reload boundary is registered for \($0)"
        }
        guard matched > 0 else {
            if warnings.isEmpty {
                warnings.append("no active SwiftUI live-reload boundary matches this generation")
            }
            return .init(
                status: plan.warnings.isEmpty ? .manualRefreshRequired : .failed,
                matchedBoundaryCount: 0,
                refreshedBoundaryCount: 0,
                warnings: warnings,
                errors: plan.warnings
            )
        }

        do {
            let result = try pulse.advance(
                context,
                affectedNominalTypes: affectedTypes
            )
            return .init(
                status: !plan.warnings.isEmpty
                    ? .failed
                    : (result.didPublish ? .refreshed : .notRequested),
                matchedBoundaryCount: matched,
                refreshedBoundaryCount: result.didPublish
                    ? result.matchedBoundaryCount
                    : 0,
                warnings: warnings,
                errors: plan.warnings
            )
        } catch {
            return .init(
                status: .failed,
                matchedBoundaryCount: matched,
                refreshedBoundaryCount: 0,
                warnings: warnings,
                errors: plan.warnings + [String(describing: error)]
            )
        }
    }

    /// Publishes a catch-all refresh to every active SwiftUI boundary.
    ///
    /// The supplied context is copied with its reason changed to `.manual`, so
    /// repeated manual refreshes of the same active generation remain valid.
    public func manualReload(
        context: LiveReload.Context
    ) -> SwiftUIReload.Report {
        let matched = pulse.activeBoundaryCount
        guard matched > 0 else {
            return .init(
                status: .manualRefreshRequired,
                matchedBoundaryCount: 0,
                refreshedBoundaryCount: 0
            )
        }
        var manualContext = context
        manualContext.reason = .manual
        do {
            let result = try pulse.advance(
                manualContext,
                affectedNominalTypes: []
            )
            return .init(
                status: result.didPublish ? .refreshed : .notRequested,
                matchedBoundaryCount: matched,
                refreshedBoundaryCount: result.matchedBoundaryCount
            )
        } catch {
            return .init(
                status: .failed,
                matchedBoundaryCount: matched,
                refreshedBoundaryCount: 0,
                errors: [String(describing: error)]
            )
        }
    }
}
}
#endif
