import Foundation
import HelixCore
import HelixDevProtocol

public enum BuildCapture {}

extension BuildCapture {
public struct CapturedFrontendJob: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var sourceLine: String

    public init(executable: String, arguments: [String], sourceLine: String) {
        self.executable = executable
        self.arguments = arguments
        self.sourceLine = sourceLine
    }
}

public struct NormalizedFrontendJob: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var moduleName: String
    public var targetTriple: String
    public var sdkPath: String
    public var sourcePaths: [String]
    public var moduleSearchPaths: [String]
    public var primaryFilePaths: [String]

    public init(
        executable: String,
        arguments: [String],
        moduleName: String,
        targetTriple: String,
        sdkPath: String,
        sourcePaths: [String],
        moduleSearchPaths: [String],
        primaryFilePaths: [String]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.moduleName = moduleName
        self.targetTriple = targetTriple
        self.sdkPath = sdkPath
        self.sourcePaths = sourcePaths
        self.moduleSearchPaths = moduleSearchPaths
        self.primaryFilePaths = primaryFilePaths
    }
}

public struct XcodeActivityReader: Sendable {
    public init() {}

    public func latestActivityLog(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "xcactivitylog" || $0.pathExtension == "log" }
        guard let latest = try files.max(by: {
            let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }) else {
            throw BuildCapture.Error.noActivityLog
        }
        return latest
    }

    public func readFrontendJobs(fromText text: String) throws -> [BuildCapture.CapturedFrontendJob] {
        var jobs: [BuildCapture.CapturedFrontendJob] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.contains("swift-frontend") || line.contains("/swiftc ") else { continue }
            let words = try BuildCapture.ShellWords.parse(line)
            guard let executableIndex = words.firstIndex(where: {
                $0.hasSuffix("/swift-frontend") || $0.hasSuffix("/swiftc") || $0 == "swiftc"
            }) else {
                continue
            }
            jobs.append(
                .init(
                    executable: words[executableIndex],
                    arguments: Array(words.dropFirst(executableIndex + 1)),
                    sourceLine: line
                )
            )
        }
        guard !jobs.isEmpty else { throw BuildCapture.Error.noFrontendCommand }
        return jobs
    }

    public func readFrontendJobs(fromActivityLog url: URL) throws -> [BuildCapture.CapturedFrontendJob] {
        let data = try Data(contentsOf: url)
        let expanded: Data
        if data.starts(with: [0x1f, 0x8b]) {
            expanded = try gunzip(url)
        } else {
            expanded = data
        }
        // xcactivitylog is a gzip-compressed activity serialization, not a
        // guaranteed plain-text file. Command payloads remain UTF-8 strings;
        // turning serialization control bytes into record separators preserves
        // those strings without attempting to reverse-engineer unrelated fields.
        let separated = Data(expanded.map { byte in
            switch byte {
            case 0x09, 0x0a, 0x0d, 0x20...0x7e, 0x80...0xff: byte
            default: UInt8(ascii: "\n")
            }
        })
        let text = String(decoding: separated, as: UTF8.self)
        return try readFrontendJobs(fromText: text)
    }

    private func gunzip(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildCapture.Error.malformedCommand(
                String(decoding: error, as: UTF8.self)
            )
        }
        return data
    }
}

public struct FrontendJobNormalizer: Sendable {
    public var maximumResponseFileDepth: Int

    public init(maximumResponseFileDepth: Int = 8) {
        self.maximumResponseFileDepth = maximumResponseFileDepth
    }

    public func normalize(
        _ job: BuildCapture.CapturedFrontendJob,
        workingDirectory: URL
    ) throws -> BuildCapture.NormalizedFrontendJob {
        let arguments = try expandFileLists(
            expandResponseFiles(
                job.arguments,
                workingDirectory: workingDirectory,
                depth: 0,
                activePaths: []
            ),
            workingDirectory: workingDirectory
        )
        let module = try value(after: "-module-name", in: arguments)
        let target = try value(after: "-target", in: arguments)
        let sdk = try value(after: "-sdk", in: arguments)
        var sources: [String] = []
        var primary: [String] = []
        var searchPaths: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-primary-file", index + 1 < arguments.count {
                let path = absolute(arguments[index + 1], relativeTo: workingDirectory)
                primary.append(path)
                index += 2
                continue
            }
            if ["-I", "-F", "-Fsystem"].contains(argument), index + 1 < arguments.count {
                searchPaths.append(absolute(arguments[index + 1], relativeTo: workingDirectory))
                index += 2
                continue
            }
            if argument.hasSuffix(".swift"), !argument.hasPrefix("-") {
                sources.append(absolute(argument, relativeTo: workingDirectory))
            }
            index += 1
        }
        sources.append(contentsOf: primary)
        sources = Array(Set(sources)).sorted()
        guard !sources.isEmpty else { throw BuildCapture.Error.missingArgument("Swift source files") }
        return .init(
            executable: job.executable,
            arguments: arguments,
            moduleName: module,
            targetTriple: target,
            sdkPath: sdk,
            sourcePaths: sources,
            moduleSearchPaths: Array(Set(searchPaths)).sorted(),
            primaryFilePaths: Array(Set(primary)).sorted()
        )
    }

    /// File lists are build intermediates and may disappear after DerivedData
    /// cleanup. Expanding them makes the captured job self-contained, just as
    /// response-file expansion does.
    private func expandFileLists(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument == "-filelist" || argument == "-primary-filelist" else {
                result.append(argument)
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw BuildCapture.Error.missingArgument(argument)
            }
            let listPath = absolute(arguments[index + 1], relativeTo: workingDirectory)
            let attributes = try FileManager.default.attributesOfItem(atPath: listPath)
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  size <= 8 * 1_024 * 1_024
            else {
                throw BuildCapture.Error.malformedCommand(
                    "file list exceeds 8 MiB: \(listPath)"
                )
            }
            let contents = try String(contentsOfFile: listPath, encoding: .utf8)
            let paths = try contents
                .split(whereSeparator: \.isNewline)
                .map { line -> String in
                    let value = String(line).trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty,
                          !value.unicodeScalars.contains(where: { $0.value == 0 })
                    else {
                        throw BuildCapture.Error.malformedCommand(
                            "file list contains an empty or NUL path: \(listPath)"
                        )
                    }
                    return absolute(value, relativeTo: workingDirectory)
                }
            guard !paths.isEmpty, paths.count <= 65_536 else {
                throw BuildCapture.Error.malformedCommand(
                    "file list is empty or exceeds the source limit: \(listPath)"
                )
            }
            if argument == "-primary-filelist" {
                for path in paths {
                    result.append("-primary-file")
                    result.append(path)
                }
            } else {
                result.append(contentsOf: paths)
            }
            index += 2
        }
        return result
    }

    private func expandResponseFiles(
        _ arguments: [String],
        workingDirectory: URL,
        depth: Int,
        activePaths: Set<String>
    ) throws -> [String] {
        guard depth <= maximumResponseFileDepth else {
            throw BuildCapture.Error.responseFileTooDeep
        }
        var result: [String] = []
        for argument in arguments {
            guard argument.hasPrefix("@"), argument.count > 1 else {
                result.append(argument)
                continue
            }
            let rawPath = String(argument.dropFirst())
            let path = absolute(rawPath, relativeTo: workingDirectory)
            guard !activePaths.contains(path) else {
                throw BuildCapture.Error.responseFileCycle(path)
            }
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let nested = try BuildCapture.ShellWords.parse(content)
            result.append(
                contentsOf: try expandResponseFiles(
                    nested,
                    workingDirectory: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    depth: depth + 1,
                    activePaths: activePaths.union([path])
                )
            )
        }
        return result
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            throw BuildCapture.Error.missingArgument(flag)
        }
        return arguments[index + 1]
    }

    private func absolute(_ path: String, relativeTo directory: URL) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }
}

enum ShellWords {
    static func parse(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasContent = false

        for character in text {
            if escaped {
                current.append(character)
                hasContent = true
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                    hasContent = true
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasContent = true
            } else if character.isWhitespace {
                if hasContent {
                    words.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(character)
                hasContent = true
            }
        }
        guard quote == nil, !escaped else {
            throw BuildCapture.Error.malformedCommand("unterminated quote or escape")
        }
        if hasContent { words.append(current) }
        return words
    }
}
}
