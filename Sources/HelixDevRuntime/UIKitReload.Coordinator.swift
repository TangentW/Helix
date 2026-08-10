#if canImport(UIKit)
import Foundation
import HelixDevProtocol
import HelixLiveReloadAPI
import ObjectiveC
import UIKit

public enum UIKitReload {}

extension UIKitReload {
public enum ResolutionScope: Sendable {
    case visibleOnly
    case allLoaded
}

@MainActor
public struct AnyFactory {
    public var id: LiveReload.FactoryID
    public var make: (UIViewController) throws -> UIViewController

    public init(
        id: LiveReload.FactoryID,
        make: @escaping (UIViewController) throws -> UIViewController
    ) {
        self.id = id
        self.make = make
    }
}

@MainActor
public final class FactoryRegistry {
    private var factories: [LiveReload.FactoryID: UIKitReload.AnyFactory] = [:]
    private var containerAdapters: [ObjectIdentifier: any LiveReload.ContainerAdapter] = [:]

    public init() {}

    public func register(_ factory: UIKitReload.AnyFactory) {
        factories[factory.id] = factory
    }

    public func registerContainerAdapter(
        _ adapter: any LiveReload.ContainerAdapter,
        for containerType: UIViewController.Type
    ) {
        containerAdapters[ObjectIdentifier(containerType)] = adapter
    }

    func factory(for id: LiveReload.FactoryID) -> UIKitReload.AnyFactory? {
        factories[id]
    }

    func adapter(for controller: UIViewController) -> (any LiveReload.ContainerAdapter)? {
        var current: AnyClass? = type(of: controller)
        while let type = current {
            if let adapter = containerAdapters[ObjectIdentifier(type)] { return adapter }
            current = class_getSuperclass(type)
        }
        return nil
    }
}

@MainActor
public struct InstanceResolver {
    public init() {}

    public func windows(
        scope: UIKitReload.ResolutionScope
    ) -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }
        let windows = scenes.flatMap(\.windows)
        switch scope {
        case .visibleOnly:
            return windows.filter { !$0.isHidden && $0.alpha > 0 }
        case .allLoaded:
            return windows
        }
    }

    public func controllers(
        scope: UIKitReload.ResolutionScope
    ) -> [UIViewController] {
        controllers(in: windows(scope: scope), scope: scope)
    }

    public func controllers(
        in windows: [UIWindow],
        scope: UIKitReload.ResolutionScope
    ) -> [UIViewController] {
        var result: [UIViewController] = []
        var seen = Set<ObjectIdentifier>()
        for window in windows {
            guard let root = window.rootViewController else { continue }
            traverse(root, result: &result, seen: &seen)
        }
        return result.filter { controller in
            guard controller.isViewLoaded else { return false }
            switch scope {
            case .visibleOnly:
                return controller.viewIfLoaded?.window != nil
            case .allLoaded:
                return true
            }
        }
    }

    public func views(
        in controllers: [UIViewController],
        windows: [UIWindow] = []
    ) -> [UIView] {
        var result: [UIView] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ view: UIView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            result.append(view)
            view.subviews.forEach(walk)
        }
        windows.forEach(walk)
        controllers.compactMap(\.viewIfLoaded).forEach(walk)
        return result
    }

    private func traverse(
        _ controller: UIViewController,
        result: inout [UIViewController],
        seen: inout Set<ObjectIdentifier>
    ) {
        guard seen.insert(ObjectIdentifier(controller)).inserted else { return }
        result.append(controller)
        if let presented = controller.presentedViewController {
            traverse(presented, result: &result, seen: &seen)
        }
        if let navigation = controller as? UINavigationController {
            navigation.viewControllers.forEach {
                traverse($0, result: &result, seen: &seen)
            }
        }
        if let tab = controller as? UITabBarController {
            (tab.viewControllers ?? []).forEach {
                traverse($0, result: &result, seen: &seen)
            }
        }
        if let split = controller as? UISplitViewController {
            split.viewControllers.forEach {
                traverse($0, result: &result, seen: &seen)
            }
        }
        controller.children.forEach {
            traverse($0, result: &result, seen: &seen)
        }
    }
}

public struct Report: Sendable {
    public var status: DevProtocol.UIReloadStatus
    public var matchedInstanceCount: Int
    public var refreshedInstanceCount: Int
    public var matchedNominalTypeIDs: Set<LiveReload.NominalTypeID>
    public var unmatchedNominalTypeIDs: Set<LiveReload.NominalTypeID>
    public var warnings: [String]
    public var errors: [String]

    public init(
        status: DevProtocol.UIReloadStatus,
        matchedInstanceCount: Int,
        refreshedInstanceCount: Int,
        matchedNominalTypeIDs: Set<LiveReload.NominalTypeID> = [],
        unmatchedNominalTypeIDs: Set<LiveReload.NominalTypeID> = [],
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.status = status
        self.matchedInstanceCount = matchedInstanceCount
        self.refreshedInstanceCount = refreshedInstanceCount
        self.matchedNominalTypeIDs = matchedNominalTypeIDs
        self.unmatchedNominalTypeIDs = unmatchedNominalTypeIDs
        self.warnings = warnings
        self.errors = errors
    }
}

public struct InvalidationResult: Sendable {
    public var didApply: Bool
    public var warnings: [String]

    public init(didApply: Bool = false, warnings: [String] = []) {
        self.didApply = didApply
        self.warnings = warnings
    }
}

@MainActor
public struct Invalidator {
    public var broadDataReloadEnabled: Bool

    public init(broadDataReloadEnabled: Bool = false) {
        self.broadDataReloadEnabled = broadDataReloadEnabled
    }

    public func invalidate(
        _ view: UIView,
        hints: LiveReload.InvalidationHints,
        allowsImmediateLayout: Bool
    ) -> UIKitReload.InvalidationResult {
        var result = UIKitReload.InvalidationResult()
        if hints.contains(.constraints) {
            view.setNeedsUpdateConstraints()
            result.didApply = true
        }
        if hints.contains(.layout) {
            view.setNeedsLayout()
            result.didApply = true
        }
        if hints.contains(.display) {
            view.setNeedsDisplay()
            result.didApply = true
        }
        let requestsDataReload = hints.contains(.tableData) || hints.contains(.collectionData)
        if requestsDataReload, broadDataReloadEnabled {
            var tableCount = 0
            var collectionCount = 0
            walkSubviews(view) { subview in
                if hints.contains(.tableData), let table = subview as? UITableView {
                    table.reloadData()
                    tableCount += 1
                }
                if hints.contains(.collectionData), let collection = subview as? UICollectionView {
                    collection.reloadData()
                    collectionCount += 1
                }
            }
            if hints.contains(.tableData), tableCount == 0 {
                result.warnings.append("table-data invalidation found no UITableView")
            }
            if hints.contains(.collectionData), collectionCount == 0 {
                result.warnings.append("collection-data invalidation found no UICollectionView")
            }
            result.didApply = result.didApply || tableCount > 0 || collectionCount > 0
        } else if requestsDataReload {
            result.warnings.append(
                "broad table/collection reload is disabled; use LiveReload.Reloadable"
            )
        }
        if hints.contains(.immediateLayout) {
            if allowsImmediateLayout {
                view.layoutIfNeeded()
                result.didApply = true
            } else {
                result.warnings.append(
                    "immediate layout was skipped while a view-controller transition is active"
                )
            }
        }
        return result
    }

    private func walkSubviews(_ root: UIView, body: (UIView) -> Void) {
        body(root)
        root.subviews.forEach { walkSubviews($0, body: body) }
    }
}

@MainActor
public final class Coordinator {
    public let factoryRegistry: UIKitReload.FactoryRegistry
    public var resolutionScope: UIKitReload.ResolutionScope
    public var broadDataReloadEnabled: Bool
    public var guardrail: LiveReload.Guard

    private let resolver = UIKitReload.InstanceResolver()
    private let actionResolver = UIKitReload.InstanceActionResolver()

    public init(
        factoryRegistry: UIKitReload.FactoryRegistry = .init(),
        resolutionScope: UIKitReload.ResolutionScope = .visibleOnly,
        broadDataReloadEnabled: Bool = false,
        guardrail: LiveReload.Guard = .shared
    ) {
        self.factoryRegistry = factoryRegistry
        self.resolutionScope = resolutionScope
        self.broadDataReloadEnabled = broadDataReloadEnabled
        self.guardrail = guardrail
    }

    public func reload(
        context: LiveReload.Context,
        hints: [DevProtocol.ReloadHint]
    ) async -> UIKitReload.Report {
        do {
            try context.validate()
        } catch {
            return .init(
                status: .failed,
                matchedInstanceCount: 0,
                refreshedInstanceCount: 0,
                errors: [String(describing: error)]
            )
        }
        await guardrail.waitUntilUnblocked()
        let plan = ReloadPlanning.Planner().plan(hints)
        guard !plan.actions.isEmpty else {
            return .init(
                status: plan.warnings.isEmpty ? .manualRefreshRequired : .failed,
                matchedInstanceCount: 0,
                refreshedInstanceCount: 0,
                warnings: [
                    "code is active, but no explicit or safely inferred UI reload rule exists",
                ],
                errors: plan.warnings
            )
        }
        let windows = resolver.windows(scope: resolutionScope)
        let controllers = resolver.controllers(in: windows, scope: resolutionScope)
        let controllerResolution = actionResolver.resolve(
            plan.actions,
            in: controllers
        )
        let remainingActions = plan.actions.filter {
            !controllerResolution.matchedNominalTypeIDs.contains($0.nominalTypeID)
        }
        var viewActions: [UIKitReload.InstanceActionResolver.ViewMatch] = []
        var matchedTypeIDs = controllerResolution.matchedNominalTypeIDs
        var warnings: [String] = []
        var errors = plan.warnings + controllerResolution.errors
        if !remainingActions.isEmpty {
            let viewResolution = actionResolver.resolve(
                remainingActions,
                in: resolver.views(in: controllers, windows: windows)
            )
            viewActions = viewResolution.matches
            matchedTypeIDs.formUnion(viewResolution.matchedNominalTypeIDs)
            errors.append(contentsOf: viewResolution.errors)
        }

        let allTypeIDs = Set(plan.actions.map(\.nominalTypeID))
        let unmatchedTypeIDs = allTypeIDs.subtracting(matchedTypeIDs)
        let matched = controllerResolution.matches.count + viewActions.count
        var refreshed = 0
        for match in controllerResolution.matches {
            let controller = match.instance
            let action = match.action
            do {
                switch action.policy {
                case .observeOnly:
                    break
                case .invalidate:
                    let result = invalidate(controller, hints: action.invalidationHints)
                    warnings.append(contentsOf: result.warnings)
                    if result.didApply { refreshed += 1 }
                case .invokeHook:
                    guard let reloadable = controller as? any LiveReload.Reloadable else {
                        warnings.append("\(type(of: controller)) has no LiveReload.Reloadable hook")
                        continue
                    }
                    try reloadable.applyLiveReload(context)
                    refreshed += 1
                case .recreate:
                    guard let factoryID = action.factoryID,
                          let factory = factoryRegistry.factory(for: factoryID)
                    else {
                        errors.append("recreate requires a factory registered in the Dev Shell")
                        continue
                    }
                    try await recreate(controller, factory: factory)
                    refreshed += 1
                }
            } catch {
                errors.append("\(type(of: controller)): \(error)")
            }
        }
        for match in viewActions {
            let view = match.instance
            let action = match.action
            do {
                switch action.policy {
                case .observeOnly:
                    break
                case .invalidate:
                    let result = UIKitReload.Invalidator(
                        broadDataReloadEnabled: broadDataReloadEnabled
                    ).invalidate(
                        view,
                        hints: action.invalidationHints,
                        allowsImmediateLayout: true
                    )
                    warnings.append(contentsOf: result.warnings)
                    if result.didApply { refreshed += 1 }
                case .invokeHook:
                    guard let reloadable = view as? any LiveReload.Reloadable else {
                        warnings.append("\(type(of: view)) has no LiveReload.Reloadable hook")
                        continue
                    }
                    try reloadable.applyLiveReload(context)
                    refreshed += 1
                case .recreate:
                    warnings.append("UIView recreation is unsupported; reload its owning controller")
                }
            } catch {
                errors.append("\(type(of: view)): \(error)")
            }
        }
        let status: DevProtocol.UIReloadStatus
        if !errors.isEmpty {
            status = .failed
        } else if refreshed > 0 {
            status = .refreshed
        } else if plan.actions.allSatisfy({ $0.policy == .observeOnly }) {
            status = .notRequested
        } else {
            status = .manualRefreshRequired
        }
        return .init(
            status: status,
            matchedInstanceCount: matched,
            refreshedInstanceCount: refreshed,
            matchedNominalTypeIDs: matchedTypeIDs,
            unmatchedNominalTypeIDs: unmatchedTypeIDs,
            warnings: warnings,
            errors: errors
        )
    }

    public func manualReload(
        context: LiveReload.Context
    ) async -> UIKitReload.Report {
        await guardrail.waitUntilUnblocked()
        do {
            try context.validate()
        } catch {
            return .init(
                status: .failed,
                matchedInstanceCount: 0,
                refreshedInstanceCount: 0,
                errors: [String(describing: error)]
            )
        }
        let controllers = resolver.controllers(scope: .visibleOnly)
        var matched = 0
        var refreshed = 0
        var errors: [String] = []
        for controller in controllers {
            guard let reloadable = controller as? any LiveReload.Reloadable else { continue }
            matched += 1
            do {
                try reloadable.applyLiveReload(context)
                refreshed += 1
            } catch {
                errors.append("\(type(of: controller)): \(error)")
            }
        }
        return .init(
            status: !errors.isEmpty
                ? .failed
                : (refreshed > 0 ? .refreshed : .manualRefreshRequired),
            matchedInstanceCount: matched,
            refreshedInstanceCount: refreshed,
            errors: errors
        )
    }

    private func invalidate(
        _ controller: UIViewController,
        hints: LiveReload.InvalidationHints
    ) -> UIKitReload.InvalidationResult {
        guard let view = controller.viewIfLoaded else {
            return .init(warnings: ["\(type(of: controller)) has no loaded view"])
        }
        return UIKitReload.Invalidator(
            broadDataReloadEnabled: broadDataReloadEnabled
        ).invalidate(
            view,
            hints: hints,
            allowsImmediateLayout: controller.transitionCoordinator == nil
        )
    }

    private func recreate(
        _ old: UIViewController,
        factory: UIKitReload.AnyFactory
    ) async throws {
        guard old.transitionCoordinator == nil,
              old.navigationController?.transitionCoordinator == nil,
              old.tabBarController?.transitionCoordinator == nil,
              old.splitViewController?.transitionCoordinator == nil
        else {
            throw UIKitReload.Error.transitionInProgress
        }
        let state = (old as? any LiveReload.StateProviding)?.captureLiveReloadState()
        let replacement = try factory.make(old)

        if let navigation = old.navigationController,
           let index = navigation.viewControllers.firstIndex(where: { $0 === old })
        {
            var controllers = navigation.viewControllers
            controllers[index] = replacement
            navigation.setViewControllers(controllers, animated: false)
        } else if let tab = old.tabBarController,
                  var controllers = tab.viewControllers,
                  let index = controllers.firstIndex(where: { $0 === old })
        {
            let selected = tab.selectedIndex
            controllers[index] = replacement
            tab.setViewControllers(controllers, animated: false)
            tab.selectedIndex = min(selected, controllers.count - 1)
        } else if let split = old.splitViewController,
                  let column = splitColumn(containing: old, in: split)
        {
            split.setViewController(replacement, for: column)
        } else if let presenter = old.presentingViewController,
                  presenter.presentedViewController === old
        {
            await withCheckedContinuation { continuation in
                presenter.dismiss(animated: false) {
                    presenter.present(replacement, animated: false) {
                        continuation.resume()
                    }
                }
            }
        } else if let window = old.viewIfLoaded?.window,
                  window.rootViewController === old
        {
            window.rootViewController = replacement
        } else if let parent = old.parent,
                  let adapter = factoryRegistry.adapter(for: parent)
        {
            try adapter.replace(oldController: old, with: replacement)
        } else {
            throw UIKitReload.Error.containerAdapterMissing
        }

        replacement.loadViewIfNeeded()
        if let state, let provider = replacement as? any LiveReload.StateProviding {
            provider.restoreLiveReloadState(state)
        }
    }

    private func splitColumn(
        containing controller: UIViewController,
        in split: UISplitViewController
    ) -> UISplitViewController.Column? {
        let columns: [UISplitViewController.Column] = [
            .primary, .supplementary, .secondary, .compact,
        ]
        return columns.first { split.viewController(for: $0) === controller }
    }
}

public enum Error: Swift.Error, Equatable, Sendable {
    case transitionInProgress
    case containerAdapterMissing
}
}
#endif
