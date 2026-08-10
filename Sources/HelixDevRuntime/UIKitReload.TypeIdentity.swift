#if canImport(UIKit)
import Foundation
import HelixLiveReloadAPI
import ObjectiveC
import UIKit

extension UIKitReload {
/// Reconstructs the same `(module, canonical name)` identity used by the
/// compiler receipt from Swift runtime type names. Nested namespace types are
/// preserved: `Feature.Feature.Screen` becomes module `Feature` and canonical
/// name `Feature.Screen`.
@MainActor
struct TypeIdentityResolver {
    func nominalTypeID(reflectedName: String) -> LiveReload.NominalTypeID? {
        guard reflectedName.utf8.count <= 16 * 1_024,
              let separator = reflectedName.firstIndex(of: "."),
              separator != reflectedName.startIndex
        else { return nil }
        let canonicalStart = reflectedName.index(after: separator)
        guard canonicalStart != reflectedName.endIndex else { return nil }
        let module = String(reflectedName[..<separator])
        let canonicalName = String(reflectedName[canonicalStart...])
        guard [module, canonicalName].allSatisfy({ value in
            !value.isEmpty && value.utf8.count <= 8 * 1_024
                && !value.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                        || CharacterSet.whitespacesAndNewlines.contains($0)
                })
        }) else { return nil }
        return .derive(module: module, canonicalName: canonicalName)
    }

    /// Returns identities from the concrete class through its superclass
    /// chain. This lets a changed base controller or view refresh displayed
    /// subclass instances without any application-owned registration table.
    func nominalTypeIDs(for type: AnyClass) -> [LiveReload.NominalTypeID] {
        var result: [LiveReload.NominalTypeID] = []
        var seenIDs = Set<LiveReload.NominalTypeID>()
        var seenClasses = Set<ObjectIdentifier>()
        var current: AnyClass? = type
        while let candidate = current,
              seenClasses.insert(ObjectIdentifier(candidate)).inserted
        {
            for name in [String(reflecting: candidate), NSStringFromClass(candidate)] {
                guard let id = nominalTypeID(reflectedName: name),
                      seenIDs.insert(id).inserted
                else { continue }
                result.append(id)
            }
            current = class_getSuperclass(candidate)
        }
        return result
    }
}

@MainActor
struct InstanceActionResolver {
    struct ControllerMatch {
        var instance: UIViewController
        var action: ReloadPlanning.Action
    }

    struct ViewMatch {
        var instance: UIView
        var action: ReloadPlanning.Action
    }

    struct ControllerResult {
        var matches: [ControllerMatch]
        var matchedNominalTypeIDs: Set<LiveReload.NominalTypeID>
        var errors: [String]
    }

    struct ViewResult {
        var matches: [ViewMatch]
        var matchedNominalTypeIDs: Set<LiveReload.NominalTypeID>
        var errors: [String]
    }

    private let identities = UIKitReload.TypeIdentityResolver()
    private let planner = ReloadPlanning.Planner()

    func resolve(
        _ actions: [ReloadPlanning.Action],
        in controllers: [UIViewController]
    ) -> ControllerResult {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map {
            ($0.nominalTypeID, $0)
        })
        var cache: [ObjectIdentifier: [LiveReload.NominalTypeID]] = [:]
        var matches: [ControllerMatch] = []
        var matchedTypeIDs = Set<LiveReload.NominalTypeID>()
        var errors: [String] = []
        for controller in controllers {
            let type = type(of: controller)
            let typeKey = ObjectIdentifier(type)
            let typeIDs = cache[typeKey] ?? identities.nominalTypeIDs(for: type)
            cache[typeKey] = typeIDs
            let candidates = typeIDs.compactMap { id -> ReloadPlanning.Action? in
                guard let action = actionsByID[id] else { return nil }
                matchedTypeIDs.insert(id)
                return action
            }
            do {
                if let action = try merge(candidates) {
                    matches.append(.init(instance: controller, action: action))
                }
            } catch {
                errors.append("\(String(reflecting: type)): \(error)")
            }
        }
        return .init(
            matches: matches,
            matchedNominalTypeIDs: matchedTypeIDs,
            errors: errors
        )
    }

    func resolve(
        _ actions: [ReloadPlanning.Action],
        in views: [UIView]
    ) -> ViewResult {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map {
            ($0.nominalTypeID, $0)
        })
        var cache: [ObjectIdentifier: [LiveReload.NominalTypeID]] = [:]
        var matches: [ViewMatch] = []
        var matchedTypeIDs = Set<LiveReload.NominalTypeID>()
        var errors: [String] = []
        for view in views {
            let type = type(of: view)
            let typeKey = ObjectIdentifier(type)
            let typeIDs = cache[typeKey] ?? identities.nominalTypeIDs(for: type)
            cache[typeKey] = typeIDs
            let candidates = typeIDs.compactMap { id -> ReloadPlanning.Action? in
                guard let action = actionsByID[id] else { return nil }
                matchedTypeIDs.insert(id)
                return action
            }
            do {
                if let action = try merge(candidates) {
                    matches.append(.init(instance: view, action: action))
                }
            } catch {
                errors.append("\(String(reflecting: type)): \(error)")
            }
        }
        return .init(
            matches: matches,
            matchedNominalTypeIDs: matchedTypeIDs,
            errors: errors
        )
    }

    private func merge(
        _ actions: [ReloadPlanning.Action]
    ) throws -> ReloadPlanning.Action? {
        guard var result = actions.first else { return nil }
        for action in actions.dropFirst() {
            result = try planner.mergeForInstance(result, action)
        }
        return result
    }
}
}
#endif
