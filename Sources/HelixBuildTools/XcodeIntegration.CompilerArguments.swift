import Foundation

extension XcodeIntegration {
/// Selects only semantic inputs from a captured Swift Driver invocation. Build
/// scheduling, source, primary-file, and output arguments must never leak into
/// Helix's whole-module analysis or hidden Bridge compilation.
public enum CompilerArguments {
    public static func semanticArguments(
        from capturedArguments: [String]
    ) throws -> [String] {
        let paired: Set<String> = [
            "-I", "-F", "-Fsystem", "-D", "-Xcc",
            "-module-cache-path", "-sdk-module-cache-path",
            "-plugin-path", "-external-plugin-path",
            "-swift-version", "-strict-concurrency", "-package-name",
            "-module-alias", "-enable-upcoming-feature",
            "-enable-experimental-feature", "-clang-target", "-resource-dir",
            "-vfsoverlay",
            "-import-objc-header", "-pch-output-dir",
            "-cxx-interoperability-mode",
        ]
        let standalone: Set<String> = [
            "-enable-library-evolution", "-enable-testing", "-warnings-as-errors",
            "-suppress-warnings", "-enable-bare-slash-regex",
            "-application-extension",
            // Debug scope provenance participates in declaration resolution.
            // Preserve the selected level, including an explicit later -gnone.
            "-g", "-gline-tables-only", "-gnone",
        ]
        let frontend: Set<String> = [
            "-disable-availability-checking", "-warn-concurrency",
            "-enable-actor-data-race-checks", "-enable-experimental-concurrency",
            "-enable-private-imports", "-enable-implicit-dynamic",
            "-enable-dynamic-replacement-chaining",
        ]
        var result = ["-parse-as-library"]
        var index = 0
        while index < capturedArguments.count {
            let argument = capturedArguments[index]
            if paired.contains(argument) {
                let value = try followingValue(
                    argument,
                    at: index,
                    in: capturedArguments
                )
                result.append(contentsOf: [argument, value])
                index += 2
                continue
            }
            if argument == "-Xfrontend" {
                let value = try followingValue(
                    argument,
                    at: index,
                    in: capturedArguments
                )
                if frontend.contains(value) {
                    result.append(contentsOf: [argument, value])
                }
                index += 2
                continue
            }
            if standalone.contains(argument)
                || argument.hasPrefix("-cxx-interoperability-mode=")
                || argument.hasPrefix("-I/")
                || argument.hasPrefix("-F/")
                || argument.hasPrefix("-Fsystem/")
                || (argument.hasPrefix("-D") && argument.count > 2)
            {
                try validate(argument)
                result.append(argument)
            }
            index += 1
        }
        let missing = [
            "-enable-private-imports",
            "-enable-implicit-dynamic",
            "-enable-dynamic-replacement-chaining",
        ].filter { !containsFrontend($0, in: result) }
        if !missing.isEmpty {
            throw XcodeIntegration.CompilerArgumentError.missing(missing.joined(separator: ", "))
        }
        return result
    }

    public static func moduleSearchArguments(
        from capturedArguments: [String]
    ) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < capturedArguments.count {
            let argument = capturedArguments[index]
            if let prefix = ["-Fsystem/", "-F/", "-I/"].first(where: argument.hasPrefix) {
                let flag = String(prefix.dropLast())
                let path = String(argument.dropFirst(flag.count))
                try validate(path)
                result.append(contentsOf: [flag, path])
                index += 1
                continue
            }
            guard ["-I", "-F", "-Fsystem"].contains(argument) else {
                index += 1
                continue
            }
            let path = try followingValue(
                argument,
                at: index,
                in: capturedArguments
            )
            guard path.hasPrefix("/") else {
                throw XcodeIntegration.CompilerArgumentError.invalid(argument)
            }
            result.append(contentsOf: [argument, path])
            index += 2
        }
        return result
    }

    private static func followingValue(
        _ option: String,
        at index: Int,
        in arguments: [String]
    ) throws -> String {
        guard index + 1 < arguments.count else {
            throw XcodeIntegration.CompilerArgumentError.missing(option)
        }
        let value = arguments[index + 1]
        try validate(value)
        return value
    }

    private static func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 64 * 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw XcodeIntegration.CompilerArgumentError.invalid(value)
        }
    }

    private static func containsFrontend(
        _ value: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.contains { index in
            arguments[index] == "-Xfrontend"
                && index + 1 < arguments.count
                && arguments[index + 1] == value
        }
    }
}

public enum CompilerArgumentError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible
{
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case let .missing(value):
            "captured Swift invocation is missing \(value)"
        case let .invalid(value):
            "captured Swift invocation contains an invalid \(value) argument"
        }
    }
}
}
