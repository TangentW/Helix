import Foundation

public enum CLI {}

extension CLI {
public struct Result: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case usage(String)
    case input(String)
    case outputExists(String)
    case invalidOutputExtension(expected: String, actual: String)
    case insecurePrivateKey(String)
    case unsupportedArtifact

    public var description: String {
        switch self {
        case let .usage(reason): reason
        case let .input(reason): "invalid input: \(reason)"
        case let .outputExists(path): "output already exists: \(path); pass --force to replace it"
        case let .invalidOutputExtension(expected, actual):
            "output must use .\(expected), got \(actual.isEmpty ? "no extension" : ".\(actual)")"
        case let .insecurePrivateKey(path):
            "private key file must be a regular file with mode 0600 or stricter: \(path)"
        case .unsupportedArtifact: "input is not a supported HLBC, HLXI, or HLXP artifact"
        }
    }
}
}
