import Foundation
import HelixCore

extension BuildCache {
/// Produces an unambiguous cache identity from a canonical semantic input.
/// Callers own the versioned domain and must include every fact that can
/// change the generated payload.
public static func key<Value: Encodable>(
    domain: String,
    value: Value
) throws -> Core.Digest {
    guard !domain.isEmpty, domain.utf8.count <= 512 else {
        throw BuildCache.Error.io("cache key domain is invalid")
    }
    var hasher = Core.StableHasher(domain: domain)
    hasher.append(try Core.CanonicalJSON.encode(value))
    return hasher.finalize()
}
}
