import Foundation
import HelixBytecode
import HelixCore

public enum CanonicalSIL {}

extension CanonicalSIL {
public struct Function: Hashable, Sendable {
    public var mangledName: String
    public var loweredType: String
    public var body: String
    var debugLineLocations: [CanonicalSIL.DebugLineLocation]
    var hasStrippedDebugMetadata: Bool

    public init(mangledName: String, loweredType: String, body: String) {
        self.mangledName = mangledName
        self.loweredType = loweredType
        self.body = body
        debugLineLocations = []
        hasStrippedDebugMetadata = false
    }

    /// Returns the original Swift source location associated with a normalized
    /// SIL body line. Body lines are one-based, matching lowering diagnostics.
    public func sourceLocation(atBodyLine line: Int) -> Core.SourceLocation? {
        guard line > 0 else { return nil }
        return debugLineLocations.first { $0.line == line }?.location
    }

    init(
        mangledName: String,
        loweredType: String,
        body: String,
        debugLineLocations: [CanonicalSIL.DebugLineLocation]
    ) {
        self.mangledName = mangledName
        self.loweredType = loweredType
        self.body = body
        self.debugLineLocations = debugLineLocations
        hasStrippedDebugMetadata = true
    }
}

public struct File: Sendable {
    public var functions: [CanonicalSIL.Function]
    public var typeEnvironment: CanonicalSIL.TypeEnvironment

    public init(text: String) throws {
        let scopeLocations = Dictionary(
            uniqueKeysWithValues: try CanonicalSIL.DebugMetadata.scopes(in: text)
                .map { ($0.id, $0.location) }
        )
        functions = try Self.extractFunctions(text, scopeLocations: scopeLocations)
        typeEnvironment = try .init(text: text, functions: functions)
    }

    public func function(mangledName: String) -> CanonicalSIL.Function? {
        functions.first { $0.mangledName == mangledName }
    }

    public func uniqueFunction(mangledNameContaining fragment: String) throws -> CanonicalSIL.Function {
        let matches = functions.filter { $0.mangledName.contains(fragment) }
        guard matches.count == 1, let match = matches.first else {
            throw CanonicalSIL.LoweringError.functionSelection(
                "expected one SIL function containing \(fragment), found \(matches.count)"
            )
        }
        return match
    }

    private static func extractFunctions(
        _ text: String,
        scopeLocations: [UInt32: Core.SourceLocation]
    ) throws -> [CanonicalSIL.Function] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerRegex = try NSRegularExpression(
            pattern: #"^sil(?:(?:\s+\[[^\]]+\])|(?:\s+(?:public|public_external|hidden|shared|private|package|package_external|non_abi|public_non_abi|serialized)))*\s+@([^\s:]+)\s*:\s*\$(.+)\s*\{$"#
        )
        var result: [CanonicalSIL.Function] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = headerRegex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let typeRange = Range(match.range(at: 2), in: line)
            else {
                index += 1
                continue
            }
            let name = String(line[nameRange])
            let type = String(line[typeRange])
            var bodyLines: [String] = []
            index += 1
            while index < lines.count {
                let bodyLine = lines[index]
                if bodyLine.trimmingCharacters(in: .whitespaces).hasPrefix("} // end sil function") {
                    break
                }
                bodyLines.append(bodyLine)
                index += 1
            }
            guard index < lines.count else {
                throw CanonicalSIL.LoweringError.malformedSIL("unterminated function @\(name)")
            }
            var debugLineLocations: [CanonicalSIL.DebugLineLocation] = []
            let normalizedBody = try bodyLines.enumerated().map { offset, rawLine in
                let parsed = try CanonicalSIL.DebugMetadata.parse(
                    rawLine,
                    scopes: scopeLocations
                )
                if let location = parsed.location {
                    debugLineLocations.append(
                        .init(line: offset + 1, location: location)
                    )
                }
                return parsed.instruction
            }.joined(separator: "\n")
            result.append(
                .init(
                    mangledName: name,
                    loweredType: type,
                    body: normalizedBody,
                    debugLineLocations: debugLineLocations
                )
            )
            index += 1
        }
        return result
    }
}

public enum LoweringError: Error, Equatable, Sendable, CustomStringConvertible {
    case functionSelection(String)
    case malformedSIL(String)
    case unsupportedType(String)
    case unsupportedInstruction(line: Int, text: String)
    case undefinedValue(line: Int, value: String)
    case unboundCallee(line: Int, mangledName: String)
    case unavailableNativeImport(
        line: Int,
        mangledName: String,
        canonicalCallee: String,
        reason: String
    )
    case callSignatureMismatch(
        line: Int,
        mangledName: String,
        detail: String? = nil
    )
    case invalidCallTable(String)

    public var description: String {
        switch self {
        case let .functionSelection(message): "SIL function selection failed: \(message)"
        case let .malformedSIL(message): "malformed canonical SIL: \(message)"
        case let .unsupportedType(type): "unsupported SIL type: \(type)"
        case let .unsupportedInstruction(line, text): "canonical SIL:\(line): unsupported instruction: \(text)"
        case let .undefinedValue(line, value): "canonical SIL:\(line): undefined value \(value)"
        case let .unboundCallee(line, mangledName):
            "canonical SIL:\(line): callee @\(mangledName) is not frozen in the target HLXI; "
                + "export it through the explicit NativeImport Catalog in a future Shell "
                + "(runtime symbol lookup is intentionally unavailable)"
        case let .unavailableNativeImport(line, mangledName, canonicalCallee, reason):
            "canonical SIL:\(line): \(canonicalCallee) (@\(mangledName)) is unavailable: \(reason)"
        case let .callSignatureMismatch(line, mangledName, detail):
            "canonical SIL:\(line): callee @\(mangledName) disagrees with its frozen HLXI signature"
                + (detail.map { ": \($0)" } ?? "")
        case let .invalidCallTable(message): "invalid canonical-SIL call table: \(message)"
        }
    }
}
}
