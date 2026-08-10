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
public final class TypeRegistry {
    private var controllerTypes: [LiveReload.NominalTypeID: UIViewController.Type] = [:]
    private var viewTypes: [LiveReload.NominalTypeID: UIView.Type] = [:]

    public init() {}

    public func register(
        _ type: UIViewController.Type,
        for id: LiveReload.NominalTypeID
    ) {
        controllerTypes[id] = type
        viewTypes.removeValue(forKey: id)
    }

    public func register(
        _ type: UIView.Type,
        for id: LiveReload.NominalTypeID
    ) {
        viewTypes[id] = type
        controllerTypes.removeValue(forKey: id)
    }

    public func controllerType(for id: LiveReload.NominalTypeID) -> UIViewController.Type? {
        controllerTypes[id]
    }

    public func viewType(for id: LiveReload.NominalTypeID) -> UIView.Type? {
        viewTypes[id]
    }

    public var registeredTypeIDs: Set<LiveReload.NominalTypeID> {
        Set(controllerTypes.keys).union(viewTypes.keys)
    }

    public func contains(_ id: LiveReload.NominalTypeID) -> Bool {
        controllerTypes[id] != nil || viewTypes[id] != nil
    }
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

    public func controllers(
        matching type: UIViewController.Type?,
        scope: UIKitReload.ResolutionScope
    ) -> [UIViewController] {
        var result: [UIViewController] = []
        var seen = Set<ObjectIdentifier>()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        for scene in scenes {
            for window in scene.windows {
                guard let root = window.rootViewController else { continue }
                traverse(root, result: &result, seen: &seen)
            }
        }
        return result.filter { controller in
            guard controller.isViewLoaded else { return false }
            if let type, !controller.isKind(of: type) { return false }
            switch scope {
            case .visibleOnly:
                return controller.viewIfLoaded?.window != nil
            case .allLoaded:
                return true
            }
        }
    }

    public func views(
        matching type: UIView.Type,
        in controllers: [UIViewController]
    ) -> [UIView] {
        var result: [UIView] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ view: UIView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            if view.isKind(of: type) { result.append(view) }
            view.subviews.forEach(walk)
        }
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
    public var warnings: [String]
    public var errors: [String]

    public init(
        status: DevProtocol.UIReloadStatus,
        matchedInstanceCount: Int,
        refreshedInstanceCount: Int,
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.status = status
        self.matchedInstanceCount = matchedInstanceCount
        self.refreshedInstanceCount = refreshedInstanceCount
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
    public let typeRegistry: UIKitReload.TypeRegistry
    public let factoryRegistry: UIKitReload.FactoryRegistry
    public var resolutionScope: UIKitReload.ResolutionScope
    public var broadDataReloadEnabled: Bool
    public var guardrail: LiveReload.Guard

    private let resolver = UIKitReload.InstanceResolver()

    public init(
        typeRegistry: UIKitReload.TypeRegistry = .init(),
        factoryRegistry: UIKitReload.FactoryRegistry = .init(),
        resolutionScope: UIKitReload.ResolutionScope = .visibleOnly,
        broadDataReloadEnabled: Bool = false,
        guardrail: LiveReload.Guard = .shared
    ) {
        self.typeRegistry = typeRegistry
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
        typealias ControllerAction = (UIViewController, ReloadPlanning.Action)
        typealias ViewAction = (UIView, ReloadPlanning.Action)
        var controllerActions: [ObjectIdentifier: ControllerAction] = [:]
        var viewActions: [ObjectIdentifier: ViewAction] = [:]
        var conflictedControllers = Set<ObjectIdentifier>()
        var conflictedViews = Set<ObjectIdentifier>()
        var allControllers: [UIViewController]?
        var warnings: [String] = []
        var errors = plan.warnings

        for action in plan.actions {
            if let controllerType = typeRegistry.controllerType(for: action.nominalTypeID) {
                let controllers = resolver.controllers(
                    matching: controllerType,
                    scope: resolutionScope
                )
                for controller in controllers {
                    let id = ObjectIdentifier(controller)
                    guard !conflictedControllers.contains(id) else { continue }
                    if let existing = controllerActions[id] {
                        do {
                            controllerActions[id] = (
                                controller,
                                try ReloadPlanning.Planner().mergeForInstance(
                                    existing.1,
                                    action
                                )
                            )
                        } catch {
                            controllerActions.removeValue(forKey: id)
                            conflictedControllers.insert(id)
                            errors.append("\(type(of: controller)): \(error)")
                        }
                    } else {
                        controllerActions[id] = (controller, action)
                    }
                }
                continue
            }
            if let viewType = typeRegistry.viewType(for: action.nominalTypeID) {
                let controllers: [UIViewController]
                if let cached = allControllers {
                    controllers = cached
                } else {
                    let resolved = resolver.controllers(matching: nil, scope: resolutionScope)
                    allControllers = resolved
                    controllers = resolved
                }
                for view in resolver.views(matching: viewType, in: controllers) {
                    let id = ObjectIdentifier(view)
                    guard !conflictedViews.contains(id) else { continue }
                    if let existing = viewActions[id] {
                        do {
                            viewActions[id] = (
                                view,
                                try ReloadPlanning.Planner().mergeForInstance(
                                    existing.1,
                                    action
                                )
                            )
                        } catch {
                            viewActions.removeValue(forKey: id)
                            conflictedViews.insert(id)
                            errors.append("\(type(of: view)): \(error)")
                        }
                    } else {
                        viewActions[id] = (view, action)
                    }
                }
                continue
            }
            warnings.append("no UIKit type is registered for \(action.nominalTypeID)")
        }

        let matched = controllerActions.count + viewActions.count
        var refreshed = 0
        for (controller, action) in controllerActions.values {
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
        for (view, action) in viewActions.values {
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
        let controllers = resolver.controllers(matching: nil, scope: .visibleOnly)
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
