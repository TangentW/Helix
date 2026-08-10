#if canImport(UIKit) && canImport(SwiftUI)
import HelixDevProtocol
import HelixLiveReloadAPI
import SwiftUI
import UIKit

public enum UIReload {}

extension UIReload {
public struct Report: Sendable {
    public var status: DevProtocol.UIReloadStatus
    public var matchedTargetCount: Int
    public var refreshedTargetCount: Int
    public var warnings: [String]
    public var errors: [String]

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

@MainActor
public final class Coordinator {
    public typealias ReportHandler = @MainActor (
        LiveReload.Context,
        UIReload.Report
    ) -> Void

    public let uiKit: UIKitReload.Coordinator
    public let swiftUI: SwiftUIReload.Coordinator
    public private(set) var latestReport: UIReload.Report?
    public private(set) var latestContext: LiveReload.Context?
    public var reportHandler: ReportHandler

    public init(
        uiKit: UIKitReload.Coordinator = .init(),
        swiftUI: SwiftUIReload.Coordinator = .init(),
        reportHandler: @escaping ReportHandler = { _, _ in }
    ) {
        self.uiKit = uiKit
        self.swiftUI = swiftUI
        self.reportHandler = reportHandler
    }

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
        var uiKitHints: [DevProtocol.ReloadHint] = []
        var swiftUIHints: [DevProtocol.ReloadHint] = []
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
            let hasUIKitTarget = uiKit.typeRegistry.contains(id)
            let hasSwiftUITarget = swiftUI.pulse.containsBoundary(for: id)
            if hasUIKitTarget { uiKitHints.append(hint) }
            if hasSwiftUITarget { swiftUIHints.append(hint) }
            if !hasUIKitTarget, !hasSwiftUITarget, hint.policy != .observeOnly {
                warnings.append("no visible UIKit or SwiftUI target is registered for \(id)")
            }
        }

        let uiKitReport = uiKitHints.isEmpty
            ? nil
            : await uiKit.reload(context: context, hints: uiKitHints)
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

    public func activationReloadHandler() -> DevActivation.Controller.ReloadHandler {
        { [weak self] context, hints in
            guard let self else { return .manualRefreshRequired }
            return await self.reload(context: context, hints: hints).status
        }
    }

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
