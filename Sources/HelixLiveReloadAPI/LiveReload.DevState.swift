import Foundation

extension LiveReload {
/// Debug-oriented side storage for values that cannot be added to an already
/// instantiated Swift object's frozen layout.
@MainActor
public final class DevState {
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

    public init() {}

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

    public func removeAllValues(for owner: AnyObject) {
        buckets.removeValue(forKey: ObjectIdentifier(owner))
    }

    public var liveOwnerCount: Int {
        removeReleasedOwners()
        return buckets.count
    }

    private func removeReleasedOwners() {
        buckets = buckets.filter { $0.value.owner.value != nil }
    }
}
}
