import Foundation

extension BuildCache.CompilerInputs {
enum ExternalReferences {}
}

extension BuildCache.CompilerInputs.ExternalReferences {
static func overlayPaths(
    _ data: Data,
    relativeTo directory: URL
) throws -> [String] {
    guard data.count <= 16 * 1_024 * 1_024 else {
        throw BuildCache.Error.io("VFS overlay exceeds 16 MiB")
    }
    let root = try JSONSerialization.jsonObject(with: data)
    var paths = Set<String>()
    var visited = 0
    var pending: [Any] = [root]
    while let value = pending.popLast() {
        visited += 1
        guard visited <= 1_000_000 else {
            throw BuildCache.Error.io("VFS overlay is too complex")
        }
        if let dictionary = value as? [String: Any] {
            if let external = dictionary["external-contents"] {
                guard let path = external as? String,
                      let absolute = normalizedPath(path, relativeTo: directory)
                else {
                    throw BuildCache.Error.io("VFS overlay path is invalid")
                }
                paths.insert(absolute)
            }
            pending.append(contentsOf: dictionary.values)
        } else if let array = value as? [Any] {
            pending.append(contentsOf: array)
        }
    }
    guard paths.count <= 100_000 else {
        throw BuildCache.Error.io("VFS overlay references too many paths")
    }
    return paths.sorted()
}

static func headerMapPaths(
    _ data: Data,
    relativeTo directory: URL
) throws -> [String] {
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
    var result = Set<String>()
    var populatedBuckets = 0
    for bucket in 0..<bucketCount {
        let offset = 24 + bucket * 12
        guard readUInt32(bytes, at: offset) != 0 else { continue }
        populatedBuckets += 1
        let prefix = try string(at: readUInt32(bytes, at: offset + 4))
        let suffix = try string(at: readUInt32(bytes, at: offset + 8))
        guard let absolute = normalizedPath(
            prefix + suffix,
            relativeTo: directory
        ) else {
            throw BuildCache.Error.io("header map value path is invalid")
        }
        result.insert(absolute)
    }
    guard populatedBuckets == entryCount else {
        throw BuildCache.Error.io("header map entry count is invalid")
    }
    return result.sorted()
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
