import Foundation

extension SwiftFrontend.Driver {
    final class PluginResourceCache: @unchecked Sendable {
        struct Key: Hashable {
            var compiler: URL
            var environment: [String: String]
        }
        private let lock = NSLock()
        private var values: [Key: URL] = [:]

        func resolve(_ key: Key, load: () throws -> URL) rethrows -> URL {
            if let value = lock.withLock({ values[key] }) { return value }
            let value = try load()
            return lock.withLock {
                if let existing = values[key] { return existing }
                values[key] = value
                return value
            }
        }
    }

    func defaultPluginArguments(existing: [String]) throws -> [String] {
        let resource = try pluginResourceCache.resolve(
            .init(compiler: compilerURL, environment: environment)
        ) {
            try pluginResourceDirectory()
        }
        return Self.pluginArguments(resourceDirectory: resource, existing: existing)
    }

    private func pluginResourceDirectory() throws -> URL {
        var resource = compilerURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/swift", isDirectory: true)
        if compilerURL.deletingLastPathComponent().path == "/usr/bin"
            || !FileManager.default.fileExists(atPath: resource.path) {
            // /usr/bin/swiftc is an Xcode shim; its own directory is not the
            // selected toolchain. Ask that exact executable with its environment.
            let output = try run(arguments: ["-print-target-info"])
            guard output.terminationStatus == 0,
                  let data = output.standardOutput.data(using: .utf8),
                  let document = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let paths = document["paths"] as? [String: Any],
                  let path = paths["runtimeResourcePath"] as? String,
                  path.hasPrefix("/")
            else {
                throw SwiftFrontend.Error.launchFailed(
                    "cannot resolve the captured compiler's plugin resource directory"
                )
            }
            resource = URL(fileURLWithPath: path, isDirectory: true)
        }
        return resource
    }

    static func pluginArguments(
        resourceDirectory: URL,
        existing: [String]
    ) -> [String] {
        let usr = resourceDirectory.deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = usr.appendingPathComponent("bin/swift-plugin-server")
        let inProcess = resourceDirectory.appendingPathComponent(
            "host/libSwiftInProcPluginServer.dylib"
        )
        var result: [String] = []
        func append(_ flag: String, _ value: String) {
            guard !existing.indices.contains(where: {
                existing[$0] == flag && $0 + 1 < existing.count
                    && existing[$0 + 1] == value
            }) else { return }
            result.append(contentsOf: [flag, value])
        }
        for directory in [
            resourceDirectory.appendingPathComponent("host/plugins"),
            usr.appendingPathComponent("local/lib/swift/host/plugins"),
        ] where FileManager.default.fileExists(atPath: directory.path) {
            append("-plugin-path", directory.path)
            if FileManager.default.isExecutableFile(atPath: server.path) {
                append("-external-plugin-path", "\(directory.path)#\(server.path)")
            }
        }
        if !existing.contains("-in-process-plugin-server-path"),
           FileManager.default.fileExists(atPath: inProcess.path) {
            append("-in-process-plugin-server-path", inProcess.path)
        }
        return result
    }
}
