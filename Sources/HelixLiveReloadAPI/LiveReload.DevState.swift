import Foundation

extension LiveReload {
/// Debug-oriented side storage for values that cannot be added to an already
/// instantiated Swift object's frozen layout.
///
/// Native Live Reload can replace method bodies but cannot change the stored
/// layout of an existing object. Use `DevState` for temporary development-only
/// state introduced while iterating, then move the property into the real type
/// on the next normal build.
///
/// ```swift
/// extension ProfileViewController {
///     var previewCount: Int {
///         get { LiveReload.DevState.shared[self, key: "previewCount", default: 0] }
///         set { LiveReload.DevState.shared[self, key: "previewCount", default: 0] = newValue }
///     }
/// }
/// ```
@MainActor
public final class DevState {
    /// The process-wide development side store.
    public static let shared = LiveReload.DevState()

    private final class OwnerReference {
        weak var value: AnyObject?

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    private struct Bucket {
        var owner: OwnerReference
        var values: [String: Any]
    }

    private var buckets: [ObjectIdentifier: Bucket] = [:]

    /// Creates an independent side store, primarily for tests or isolation.
    public init() {}

    /// Reads or writes a value associated with an object and static key.
    ///
    /// The default value is created lazily. Entries are removed after their
    /// weakly held owner is released.
    public subscript<Value>(
        _ owner: AnyObject,
        key key: StaticString,
        default makeDefault: @autoclosure () -> Value
    ) -> Value {
        get {
            removeReleasedOwners()
            let ownerID = ObjectIdentifier(owner)
            let storageKey = String(describing: key)
            if let value = buckets[ownerID]?.values[storageKey] as? Value {
                return value
            }
            let value = makeDefault()
            var bucket = buckets[ownerID] ?? .init(
                owner: .init(owner),
                values: [:]
            )
            bucket.values[storageKey] = value
            buckets[ownerID] = bucket
            return value
        }
        set {
            removeReleasedOwners()
            let ownerID = ObjectIdentifier(owner)
            var bucket = buckets[ownerID] ?? .init(
                owner: .init(owner),
                values: [:]
            )
            bucket.values[String(describing: key)] = newValue
            buckets[ownerID] = bucket
        }
    }

    /// Removes every development value associated with `owner` immediately.
    public func removeAllValues(for owner: AnyObject) {
        buckets.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// The number of still-live owners with side-storage buckets.
    public var liveOwnerCount: Int {
        removeReleasedOwners()
        return buckets.count
    }

    private func removeReleasedOwners() {
        buckets = buckets.filter { $0.value.owner.value != nil }
    }
}
}
