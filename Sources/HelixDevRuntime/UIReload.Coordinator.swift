#if canImport(UIKit) && canImport(SwiftUI)
import HelixDevProtocol
import HelixLiveReloadAPI
import SwiftUI
import UIKit

/// Coordinates UIKit and SwiftUI presentation refresh after new code activates.
public enum UIReload {}

extension UIReload {
/// A combined UIKit and SwiftUI refresh result.
public struct Report: Sendable {
    /// The protocol-level outcome sent back to the development daemon.
    public var status: DevProtocol.UIReloadStatus
    /// Number of displayed UIKit instances and active SwiftUI boundaries matched.
    public var matchedTargetCount: Int
    /// Number of matched targets that successfully received refresh work.
    public var refreshedTargetCount: Int
    /// Non-fatal conditions that may require a developer-initiated refresh.
    public var warnings: [String]
    /// Validation or refresh failures encountered by either UI framework.
    public var errors: [String]

    /// Creates an aggregate UI refresh report.
    public init(
        status: DevProtocol.UIReloadStatus,
        matchedTargetCount: Int,
        refreshedTargetCount: Int,
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.status = status
        self.matchedTargetCount = matchedTargetCount
        self.refreshedTargetCount = refreshedTargetCount
        self.warnings = warnings
        self.errors = errors
    }
}

/// Routes one activated generation to UIKit and SwiftUI reload coordinators.
///
/// ``DevRuntime/ApplicationSession`` creates and wires this coordinator by
/// default. Construct one directly only when customizing reload behavior or
/// observing reports:
///
/// ```swift
/// let reload = UIReload.Coordinator { context, report in
///     print("generation \(context.generationID): \(report.status)")
/// }
/// ```
@MainActor
public final class Coordinator {
    /// Callback invoked on the main actor after a report is finalized.
    public typealias ReportHandler = @MainActor (
        LiveReload.Context,
        UIReload.Report
    ) -> Void

    /// Coordinator responsible for displayed UIKit instances.
    public let uiKit: UIKitReload.Coordinator
    /// Coordinator responsible for registered SwiftUI boundaries.
    public let swiftUI: SwiftUIReload.Coordinator
    /// Most recently finalized report, including a manual refresh report.
    public private(set) var latestReport: UIReload.Report?
    /// Most recent valid generation context eligible for manual refresh.
    public private(set) var latestContext: LiveReload.Context?
    /// Callback invoked whenever ``latestReport`` changes.
    public var reportHandler: ReportHandler

    /// Creates a coordinator from the configured framework-specific coordinators.
    ///
    /// - Parameters:
    ///   - uiKit: UIKit instance discovery and refresh behavior.
    ///   - swiftUI: SwiftUI boundary publication behavior.
    ///   - reportHandler: Callback invoked for every completed request.
    public init(
        uiKit: UIKitReload.Coordinator = .init(),
        swiftUI: SwiftUIReload.Coordinator = .init(),
        reportHandler: @escaping ReportHandler = { _, _ in }
    ) {
        self.uiKit = uiKit
        self.swiftUI = swiftUI
        self.reportHandler = reportHandler
    }

    /// Applies daemon-provided reload hints after code activation.
    ///
    /// Hints are routed to UIKit when a displayed instance matches and to
    /// SwiftUI when an active boundary matches. A type may be handled by both.
    /// Invalid hints are reported without preventing other valid targets from
    /// refreshing.
    ///
    /// - Parameters:
    ///   - context: Metadata for the generation that is already active.
    ///   - hints: Compiler-produced presentation refresh instructions.
    /// - Returns: The combined UIKit and SwiftUI result.
    public func reload(
        context: LiveReload.Context,
        hints: [DevProtocol.ReloadHint]
    ) async -> UIReload.Report {
        do {
            try context.validate()
        } catch {
            return finish(
                .init(
                    status: .failed,
                    matchedTargetCount: 0,
                    refreshedTargetCount: 0,
                    errors: [String(describing: error)]
                ),
                context: context,
                remembersContext: false
            )
        }
        var nominalHints: [DevProtocol.ReloadHint] = []
        var swiftUIHints: [DevProtocol.ReloadHint] = []
        var swiftUITargetIDs = Set<LiveReload.NominalTypeID>()
        var warnings: [String] = []
        var errors: [String] = []

        for hint in hints {
            do {
                try hint.validate()
            } catch {
                errors.append(String(describing: error))
                continue
            }
            guard let id = hint.nominalTypeID else { continue }
            nominalHints.append(hint)
            let hasSwiftUITarget = swiftUI.pulse.containsBoundary(for: id)
            if hasSwiftUITarget {
                swiftUIHints.append(hint)
                swiftUITargetIDs.insert(id)
            }
        }

        let uiKitReport = nominalHints.isEmpty
            ? nil
            : await uiKit.reload(context: context, hints: nominalHints)
        let swiftUIReport = swiftUIHints.isEmpty
            ? nil
            : swiftUI.reload(context: context, hints: swiftUIHints)
        if let uiKitReport {
            warnings.append(contentsOf: uiKitReport.warnings)
            errors.append(contentsOf: uiKitReport.errors)
        }
        if let swiftUIReport {
            warnings.append(contentsOf: swiftUIReport.warnings)
            errors.append(contentsOf: swiftUIReport.errors)
        }
        let matchedUIKitTypeIDs = uiKitReport?.matchedNominalTypeIDs ?? []
        var warnedTypeIDs = Set<LiveReload.NominalTypeID>()
        for hint in nominalHints {
            guard let id = hint.nominalTypeID,
                  hint.policy != .observeOnly,
                  !matchedUIKitTypeIDs.contains(id),
                  !swiftUITargetIDs.contains(id),
                  warnedTypeIDs.insert(id).inserted
            else { continue }
            warnings.append(
                "no displayed UIKit instance or active SwiftUI boundary matches \(id)"
            )
        }

        let statuses = [uiKitReport?.status, swiftUIReport?.status].compactMap { $0 }
        let refreshed = (uiKitReport?.refreshedInstanceCount ?? 0)
            + (swiftUIReport?.refreshedBoundaryCount ?? 0)
        let status: DevProtocol.UIReloadStatus
        if !errors.isEmpty || statuses.contains(.failed) {
            status = .failed
        } else if refreshed > 0 {
            status = .refreshed
        } else if !warnings.isEmpty || statuses.contains(.manualRefreshRequired) {
            status = .manualRefreshRequired
        } else {
            status = .notRequested
        }
        let report = UIReload.Report(
            status: status,
            matchedTargetCount: (uiKitReport?.matchedInstanceCount ?? 0)
                + (swiftUIReport?.matchedBoundaryCount ?? 0),
            refreshedTargetCount: refreshed,
            warnings: warnings.sorted(),
            errors: errors.sorted()
        )
        return finish(report, context: context)
    }

    /// Refreshes all eligible targets without relying on compiler hints.
    ///
    /// UIKit invokes `LiveReload.Reloadable` on visible conforming view
    /// controllers, while SwiftUI publishes to every active boundary.
    public func manualReload(
        context: LiveReload.Context
    ) async -> UIReload.Report {
        var manualContext = context
        manualContext.reason = .manual
        let uiKitReport = await uiKit.manualReload(context: manualContext)
        let swiftUIReport = swiftUI.manualReload(context: manualContext)
        let errors = (uiKitReport.errors + swiftUIReport.errors).sorted()
        let warnings = (uiKitReport.warnings + swiftUIReport.warnings).sorted()
        let refreshed = uiKitReport.refreshedInstanceCount
            + swiftUIReport.refreshedBoundaryCount
        let status: DevProtocol.UIReloadStatus
        if !errors.isEmpty {
            status = .failed
        } else if refreshed > 0 {
            status = .refreshed
        } else {
            status = .manualRefreshRequired
        }
        let report = UIReload.Report(
            status: status,
            matchedTargetCount: uiKitReport.matchedInstanceCount
                + swiftUIReport.matchedBoundaryCount,
            refreshedTargetCount: refreshed,
            warnings: warnings,
            errors: errors
        )
        return finish(report, context: manualContext)
    }

    /// Manually refreshes the most recently activated generation.
    ///
    /// Returns `.manualRefreshRequired` when no generation has been observed.
    public func manualReloadLatest() async -> UIReload.Report {
        guard let latestContext else {
            let report = UIReload.Report(
                status: .manualRefreshRequired,
                matchedTargetCount: 0,
                refreshedTargetCount: 0,
                warnings: ["no active generation is available for manual UI reload"]
            )
            latestReport = report
            return report
        }
        return await manualReload(context: latestContext)
    }

    /// Returns the adapter used by ``DevActivation/Controller`` after activation.
    public func activationReloadHandler() -> DevActivation.Controller.ReloadHandler {
        { [weak self] context, hints in
            guard let self else { return .manualRefreshRequired }
            return await self.reload(context: context, hints: hints).status
        }
    }

    /// Returns the adapter used for daemon or debug-overlay manual refresh requests.
    public func manualReloadHandler() -> DevRuntimeSession.Controller.ManualReloadHandler {
        { [weak self] context in
            guard let self else {
                return (.manualRefreshRequired, "UI reload coordinator was released")
            }
            let report = await self.manualReload(context: context)
            let detail = (report.errors + report.warnings).first
            return (report.status, detail)
        }
    }

    private func finish(
        _ report: UIReload.Report,
        context: LiveReload.Context,
        remembersContext: Bool = true
    ) -> UIReload.Report {
        if remembersContext { latestContext = context }
        latestReport = report
        reportHandler(context, report)
        return report
    }
}
}
#endif
