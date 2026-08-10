#if canImport(SwiftUI)
import HelixDevProtocol
import HelixLiveReloadAPI
import SwiftUI

public enum SwiftUIReload {}

extension SwiftUIReload {
public struct Report: Sendable {
    public var status: DevProtocol.UIReloadStatus
    public var matchedBoundaryCount: Int
    public var refreshedBoundaryCount: Int
    public var warnings: [String]
    public var errors: [String]

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

@MainActor
public final class Coordinator {
    public let pulse: LiveReload.Pulse

    public init(pulse: LiveReload.Pulse = .shared) {
        self.pulse = pulse
    }

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
