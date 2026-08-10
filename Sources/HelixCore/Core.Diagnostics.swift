import Foundation

extension Core {
public struct SourceLocation: Codable, Hashable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int
    public var column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String { "\(file):\(line):\(column)" }
}

public enum DiagnosticSeverity: String, Codable, Hashable, Sendable {
    case note
    case warning
    case error
}

public struct Diagnostic: Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var severity: Core.DiagnosticSeverity
    public var message: String
    public var location: Core.SourceLocation?
    public var notes: [String]

    public init(
        code: String,
        severity: Core.DiagnosticSeverity,
        message: String,
        location: Core.SourceLocation? = nil,
        notes: [String] = []
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.location = location
        self.notes = notes
    }

    public var description: String {
        let prefix = location.map { "\($0): " } ?? ""
        return "\(prefix)\(severity.rawValue) [\(code)] \(message)"
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDigestLength(actual: Int)
    case invalidDigestHex(String)
    case invalidCanonicalJSON
    case arithmeticOverflow
    case malformedData(String)

    public var description: String {
        switch self {
        case let .invalidDigestLength(actual):
            "digest must contain \(Core.Digest.byteCount) bytes, got \(actual)"
        case let .invalidDigestHex(value):
            "invalid SHA-256 hex digest: \(value)"
        case .invalidCanonicalJSON:
            "value cannot be encoded as canonical JSON"
        case .arithmeticOverflow:
            "integer arithmetic overflow"
        case let .malformedData(reason):
            "malformed data: \(reason)"
        }
    }
}

public enum CanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else {
            throw Core.Error.invalidCanonicalJSON
        }
        return data
    }
}
}
