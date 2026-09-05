import Foundation

extension BuildCapture {
public enum SearchPaths {
    static let flags = ["-Fsystem", "-F", "-I"]

    static func attached(_ argument: String) -> (flag: String, path: String)? {
        for flag in flags where argument.hasPrefix(flag) && argument != flag {
            return (flag, String(argument.dropFirst(flag.count)))
        }
        return nil
    }

    static func isRuntimePath(_ argument: String) -> Bool {
        ["@executable_path", "@loader_path", "@rpath"].contains {
            argument == $0 || argument.hasPrefix($0 + "/")
        }
    }

    /// Search roots are advisory. Keep them in the compiler/cache inputs so
    /// creating a previously missing directory invalidates cached facts.
    public static func warnings(arguments: [String], workingDirectory: URL) -> [String] {
        let arguments = arguments.filter { $0 != "-Xcc" && $0 != "-Xfrontend" }
        var result: [String] = []
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let entry: (flag: String, path: String)?
            if flags.contains(argument), index + 1 < arguments.count {
                entry = (argument, arguments[index + 1])
                index += 2
            } else {
                entry = attached(argument)
                index += 1
            }
            guard let entry, seen.insert(entry.flag + "\u{0}" + entry.path).inserted else { continue }
            let url = entry.path.hasPrefix("/") ? URL(fileURLWithPath: entry.path)
                : workingDirectory.appendingPathComponent(entry.path)
            let runtime = isRuntimePath(entry.path)
            guard runtime || !FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let setting = entry.flag == "-I" ? "SWIFT_INCLUDE_PATHS/HEADER_SEARCH_PATHS" : "FRAMEWORK_SEARCH_PATHS"
            let reason = runtime ? "dyld runpath belongs in LD_RUNPATH_SEARCH_PATHS" : "missing or unreadable search root"
            result.append("warning: [HLXBLD001] \(entry.flag) \(String(reflecting: entry.path)) (\(setting)): \(reason); skipped during input discovery\n")
        }
        return result
    }
}
}
