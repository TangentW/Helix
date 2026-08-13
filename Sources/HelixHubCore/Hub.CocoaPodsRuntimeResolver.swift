import Foundation

extension Hub {
/// Resolves App-facing Helix Pods through the target's xcconfig include graph.
///
/// CocoaPods links a generated aggregate target rather than writing each Pod
/// into `packageProductDependencies`. Its target xcconfig is therefore the
/// authoritative, target-specific source for this read-only Hub status check.
struct CocoaPodsRuntimeResolver: Sendable {
    private static let supportedProducts = [
        "HelixAppRuntime",
        "HelixDevAppRuntime",
    ]
    private static let maximumFiles = 64
    private static let maximumTotalBytes = 8 * 1_024 * 1_024

    private let sourceRootURL: URL
    private let resolvedSourceRootURL: URL

    init(sourceRootURL: URL) {
        self.sourceRootURL = sourceRootURL.standardizedFileURL
        resolvedSourceRootURL = sourceRootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func products(referencedBy paths: [String]) -> [String] {
        var pending = paths.compactMap {
            resolve($0, relativeTo: sourceRootURL)
        }
        var visited = Set<String>()
        var matches = Set<String>()
        var totalBytes = 0

        while let url = pending.popLast(), visited.count < Self.maximumFiles {
            let key = url.path
            guard visited.insert(key).inserted,
                  let data = boundedData(at: url, remainingBytes: Self.maximumTotalBytes - totalBytes)
            else { continue }
            totalBytes += data.count
            let text = String(decoding: data, as: UTF8.self)
            let linkerSettings = otherLinkerFlags(in: text)
            for product in Self.supportedProducts where links(product, in: linkerSettings) {
                matches.insert(product)
            }
            guard totalBytes < Self.maximumTotalBytes else { break }
            pending.append(contentsOf: includes(in: text, from: url))
        }
        return matches.sorted()
    }

    private func links(_ product: String, in settings: String) -> Bool {
        let tokens = settings.split(whereSeparator: \.isWhitespace).map {
            String($0).replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
        }
        for index in tokens.indices {
            if tokens[index] == "-l\(product)" { return true }
            if tokens[index] == "-framework",
               tokens.indices.contains(index + 1),
               tokens[index + 1] == product {
                return true
            }
        }
        return false
    }

    private func otherLinkerFlags(in text: String) -> String {
        var logicalLines: [String] = []
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            current += line
            if current.hasSuffix("\\") {
                current.removeLast()
                current.append(" ")
            } else {
                logicalLines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { logicalLines.append(current) }
        return logicalLines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"),
                  !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=")
            else { return nil }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "OTHER_LDFLAGS" || key.hasPrefix("OTHER_LDFLAGS[") else {
                return nil
            }
            return String(trimmed[trimmed.index(after: separator)...])
        }.joined(separator: " ")
    }

    private func includes(in text: String, from sourceURL: URL) -> [URL] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("#include ") || value.hasPrefix("#include? "),
                  let opening = value.firstIndex(of: "\"")
            else { return nil }
            let remainder = value[value.index(after: opening)...]
            guard let closing = remainder.firstIndex(of: "\"") else { return nil }
            let path = String(remainder[..<closing])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return resolve(path, relativeTo: sourceURL.deletingLastPathComponent())
        }
    }

    private func resolve(_ path: String, relativeTo baseURL: URL) -> URL? {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.contains("$("),
              !path.contains("${")
        else { return nil }
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : baseURL.appendingPathComponent(path)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let root = resolvedSourceRootURL.path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    private func boundedData(at url: URL, remainingBytes: Int) -> Data? {
        guard remainingBytes > 0,
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
              ]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= remainingBytes
        else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
}
