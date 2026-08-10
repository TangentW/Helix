import HelixDevProtocol
import HelixLiveReloadAPI

/// Conversion of compiler reload hints into deterministic per-type UI actions.
public enum ReloadPlanning {}

extension ReloadPlanning {
/// One merged UI action for a nominal Swift type.
public struct Action: Hashable, Sendable {
    /// Stable identity of the affected view or view-controller type.
    public var nominalTypeID: LiveReload.NominalTypeID
    /// Strongest safe reload policy selected for the type.
    public var policy: LiveReload.Policy
    /// Union of invalidation operations when the selected policy is `.invalidate`.
    public var invalidationHints: LiveReload.InvalidationHints
    /// Factory required when the selected policy is `.recreate`.
    public var factoryID: LiveReload.FactoryID?

    /// Creates an explicit reload action.
    public init(
        nominalTypeID: LiveReload.NominalTypeID,
        policy: LiveReload.Policy,
        invalidationHints: LiveReload.InvalidationHints = [],
        factoryID: LiveReload.FactoryID? = nil
    ) {
        self.nominalTypeID = nominalTypeID
        self.policy = policy
        self.invalidationHints = invalidationHints
        self.factoryID = factoryID
    }
}

/// Deterministic plan plus validation or merge warnings.
public struct Result: Hashable, Sendable {
    /// Valid, non-conflicting actions sorted by nominal type description.
    public var actions: [ReloadPlanning.Action]
    /// Invalid hints or conflicts omitted from ``actions``.
    public var warnings: [String]
}

/// Validates, groups, and merges compiler-produced reload hints.
///
/// Policies escalate from `.observeOnly` through `.invalidate` and `.invokeHook`
/// to `.recreate`. Conflicting recreation factories remove the unsafe target
/// rather than selecting one arbitrarily.
public struct Planner: Sendable {
    /// Creates a stateless planner.
    public init() {}

    /// Produces one deterministic action per valid nominal type identity.
    public func plan(_ hints: [DevProtocol.ReloadHint]) -> ReloadPlanning.Result {
        var actions: [LiveReload.NominalTypeID: ReloadPlanning.Action] = [:]
        var conflicts = Set<LiveReload.NominalTypeID>()
        var warnings: [String] = []
        for hint in hints {
            do {
                try hint.validate()
            } catch {
                warnings.append(String(describing: error))
                continue
            }
            // Model/service changes intentionally have no UI target.
            guard let nominalTypeID = hint.nominalTypeID else { continue }
            let next = ReloadPlanning.Action(
                nominalTypeID: nominalTypeID,
                policy: hint.policy,
                invalidationHints: hint.invalidationHints,
                factoryID: hint.factoryID
            )
            guard let current = actions[nominalTypeID] else {
                actions[nominalTypeID] = next
                continue
            }
            do {
                actions[nominalTypeID] = try merge(current, next)
            } catch {
                actions.removeValue(forKey: nominalTypeID)
                conflicts.insert(nominalTypeID)
                warnings.append(String(describing: error))
            }
        }
        for conflict in conflicts { actions.removeValue(forKey: conflict) }
        return .init(
            actions: actions.values.sorted {
                $0.nominalTypeID.description < $1.nominalTypeID.description
            },
            warnings: warnings.sorted()
        )
    }

    /// Merges two actions for the same nominal type using policy escalation.
    ///
    /// - Throws: ``Error/differentTypes`` or
    ///   ``Error/conflictingFactories(_:)`` when no safe merge exists.
    public func merge(
        _ lhs: ReloadPlanning.Action,
        _ rhs: ReloadPlanning.Action
    ) throws -> ReloadPlanning.Action {
        guard lhs.nominalTypeID == rhs.nominalTypeID else {
            throw ReloadPlanning.Error.differentTypes
        }
        if lhs.policy == .recreate, rhs.policy == .recreate,
           lhs.factoryID != rhs.factoryID
        {
            throw ReloadPlanning.Error.conflictingFactories(lhs.nominalTypeID)
        }
        let selected = rank(lhs.policy) >= rank(rhs.policy) ? lhs : rhs
        var result = selected
        if lhs.policy == .invalidate, rhs.policy == .invalidate {
            result.invalidationHints = lhs.invalidationHints.union(rhs.invalidationHints)
        }
        if result.policy == .recreate {
            result.factoryID = lhs.factoryID ?? rhs.factoryID
        } else {
            result.factoryID = nil
        }
        return result
    }

    /// UIKit inheritance can make one instance match multiple nominal IDs.
    /// Merge their policies with the same escalation rules while retaining the
    /// first identity only as an internal grouping key.
    public func mergeForInstance(
        _ lhs: ReloadPlanning.Action,
        _ rhs: ReloadPlanning.Action
    ) throws -> ReloadPlanning.Action {
        var normalized = rhs
        normalized.nominalTypeID = lhs.nominalTypeID
        return try merge(lhs, normalized)
    }

    private func rank(_ policy: LiveReload.Policy) -> Int {
        switch policy {
        case .observeOnly: 0
        case .invalidate: 1
        case .invokeHook: 2
        case .recreate: 3
        }
    }
}

/// Reload-hint merge conflicts that make automatic refresh unsafe.
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// Actions for distinct nominal types were passed to ``Planner/merge(_:_:)``.
    case differentTypes
    /// The same type requires two different controller recreation factories.
    case conflictingFactories(LiveReload.NominalTypeID)

    /// Human-readable reload planning failure detail.
    public var description: String {
        switch self {
        case .differentTypes: "cannot merge UI reload actions for different nominal types"
        case let .conflictingFactories(type):
            "reload rules for \(type) reference conflicting recreation factories"
        }
    }
}
}
