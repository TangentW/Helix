import Foundation

extension BuildCache.CompilerInputs {
enum ExternalReferences {}
}

extension BuildCache.CompilerInputs.ExternalReferences {
struct Manifest {
    struct Reference {
        var logicalID: String
        var path: String
    }

    var identityData: Data
    var references: [Reference]
}

static func overlayManifest(
    _ data: Data,
    relativeTo directory: URL
) throws -> Manifest {
    guard data.count <= 16 * 1_024 * 1_024 else {
        throw BuildCache.Error.io("VFS overlay exceeds 16 MiB")
    }
    let root = try JSONSerialization.jsonObject(with: data)
    var references: [Manifest.Reference] = []
    var visited = 0
    func canonicalize(_ value: Any, depth: Int) throws -> Any {
        visited += 1
        guard visited <= 1_000_000, depth <= 256 else {
            throw BuildCache.Error.io("VFS overlay is too complex")
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                if key == "external-contents" {
                    guard let path = child as? String,
                          let absolute = normalizedPath(
                              path,
                              relativeTo: directory
                          )
                    else {
                        throw BuildCache.Error.io(
                            "VFS overlay path is invalid"
                        )
                    }
                    references.append(.init(
                        logicalID: "external-content[\(references.count)]",
                        path: absolute
                    ))
                    // The referenced bytes are fingerprinted below under the
                    // exact structural occurrence. The host path itself is
                    // not part of portable module identity.
                    result[key] = "<helix-external-content>"
                } else {
                    result[key] = try canonicalize(child, depth: depth + 1)
                }
            }
            return result
        } else if let array = value as? [Any] {
            return try array.map { try canonicalize($0, depth: depth + 1) }
        }
        return value
    }
    let canonical = try canonicalize(root, depth: 0)
    guard references.count <= 100_000,
          JSONSerialization.isValidJSONObject(canonical)
    else {
        throw BuildCache.Error.io("VFS overlay references too many paths")
    }
    return .init(
        identityData: try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys]
        ),
        references: references
    )
}

static func headerMapManifest(
    _ data: Data,
    relativeTo directory: URL
) throws -> Manifest {
    let bytes = Array(data)
    guard bytes.count >= 24,
          readUInt32(bytes, at: 0) == 0x686D_6170,
          readUInt16(bytes, at: 4) == 1,
          let stringsOffset = Int(exactly: readUInt32(bytes, at: 8)),
          let entryCount = Int(exactly: readUInt32(bytes, at: 12)),
          let bucketCount = Int(exactly: readUInt32(bytes, at: 16)),
          entryCount <= bucketCount,
          bucketCount <= 1_000_000,
          stringsOffset >= 24,
          stringsOffset <= bytes.count,
          24 + bucketCount * 12 <= stringsOffset
    else { throw BuildCache.Error.io("header map is invalid") }
    func string(at offset: UInt32) throws -> String {
        guard let relative = Int(exactly: offset),
              relative >= 0,
              relative <= bytes.count - stringsOffset
        else { throw BuildCache.Error.io("header map string offset is invalid") }
        let start = stringsOffset + relative
        guard let end = bytes[start...].firstIndex(of: 0),
              end - start <= 1_048_576,
              let value = String(bytes: bytes[start..<end], encoding: .utf8)
        else { throw BuildCache.Error.io("header map string is invalid") }
        return value
    }
    var mappings: [(key: String, path: String)] = []
    var populatedBuckets = 0
    for bucket in 0..<bucketCount {
        let offset = 24 + bucket * 12
        let keyOffset = readUInt32(bytes, at: offset)
        guard keyOffset != 0 else { continue }
        populatedBuckets += 1
        let key = try string(at: keyOffset)
        let prefix = try string(at: readUInt32(bytes, at: offset + 4))
        let suffix = try string(at: readUInt32(bytes, at: offset + 8))
        guard let absolute = normalizedPath(
            prefix + suffix,
            relativeTo: directory
        ) else {
            throw BuildCache.Error.io("header map value path is invalid")
        }
        mappings.append((key, absolute))
    }
    mappings.sort { ($0.key, $0.path) < ($1.key, $1.path) }
    guard populatedBuckets == entryCount,
          Set(mappings.map(\.key)).count == mappings.count
    else {
        throw BuildCache.Error.io("header map entry count is invalid")
    }
    let identity: [[String: String]] = mappings.map {
        [
            "key": $0.key,
            "external-contents": "<helix-header-content>",
        ]
    }
    return .init(
        identityData: try JSONSerialization.data(
            withJSONObject: identity,
            options: [.sortedKeys]
        ),
        references: mappings.enumerated().map { index, mapping in
            .init(
                logicalID: "header[\(index)]",
                path: mapping.path
            )
        }
    )
}

private static func normalizedPath(
    _ path: String,
    relativeTo directory: URL
) -> String? {
    guard !path.isEmpty, path.utf8.count <= 1_048_576,
          !path.unicodeScalars.contains(where: { $0.value == 0 })
    else { return nil }
    return (path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : directory.appendingPathComponent(path))
        .standardizedFileURL.path
}

private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return .max }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return .max }
    return UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}
}
