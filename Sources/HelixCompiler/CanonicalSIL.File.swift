import Foundation
import HelixBytecode
import HelixCore

public enum CanonicalSIL {}

extension CanonicalSIL {
public struct Function: Hashable, Sendable {
    public var mangledName: String
    public var loweredType: String
    public var body: String
    public var isolation: CanonicalSIL.FunctionIsolation
    public var declarationLocation: Core.SourceLocation?
    var debugLineLocations: [CanonicalSIL.DebugLineLocation]
    var hasStrippedDebugMetadata: Bool
    var isExternalDefinition: Bool

    public init(
        mangledName: String,
        loweredType: String,
        body: String,
        isolation: CanonicalSIL.FunctionIsolation = .unspecified
    ) {
        self.mangledName = mangledName
        self.loweredType = loweredType
        self.body = body
        self.isolation = isolation
        declarationLocation = nil
        debugLineLocations = []
        hasStrippedDebugMetadata = false
        isExternalDefinition = false
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
        isolation: CanonicalSIL.FunctionIsolation,
        declarationLocation: Core.SourceLocation?,
        debugLineLocations: [CanonicalSIL.DebugLineLocation],
        isExternalDefinition: Bool = false
    ) {
        self.mangledName = mangledName
        self.loweredType = loweredType
        self.body = body
        self.isolation = isolation
        self.declarationLocation = declarationLocation
        self.debugLineLocations = debugLineLocations
        hasStrippedDebugMetadata = true
        self.isExternalDefinition = isExternalDefinition
    }
}

public struct File: Sendable {
    public var functions: [CanonicalSIL.Function]
    public var typeEnvironment: CanonicalSIL.TypeEnvironment
    let protocolConformances: CanonicalSIL.ProtocolConformance.Environment
    private let protocolDispatch: CanonicalSIL.ProtocolConformance
        .StaticDispatch.Rewriter
    private let sourceModuleByFile: [String: String]

    public init(text: String) throws {
        let scopes = try CanonicalSIL.DebugMetadata.scopes(in: text)
        let sourceModules = try CanonicalSIL.DebugMetadata.sourceModules(in: text)
        let scopeLocations = Dictionary(
            uniqueKeysWithValues: scopes.map { ($0.id, $0.location) }
        )
        var declarationLocations: [String: Core.SourceLocation] = [:]
        for scope in scopes {
            guard let symbol = scope.parentSymbol else { continue }
            if let existing = declarationLocations[symbol], existing != scope.location {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "function @\(symbol) has conflicting declaration locations"
                )
            }
            declarationLocations[symbol] = scope.location
        }
        let parsedFunctions = try Self.extractFunctions(
            text,
            scopeLocations: scopeLocations,
            declarationLocations: declarationLocations
        )
        let parsedConformances = try CanonicalSIL.ProtocolConformance
            .Environment(text: text)
        let dispatch = CanonicalSIL.ProtocolConformance.StaticDispatch.Rewriter(
            conformances: parsedConformances,
            availableFunctions: parsedFunctions
        )
        functions = parsedFunctions.map { dispatch.rewrite($0) }
        typeEnvironment = try .init(text: text, functions: functions)
        protocolConformances = parsedConformances
        protocolDispatch = dispatch
        sourceModuleByFile = sourceModules
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

    func materializeGenericFunction(
        _ function: CanonicalSIL.Function,
        arguments: String
    ) throws -> CanonicalSIL.GenericFunction.Materialized {
        var materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: arguments
        )
        materialized.function = protocolDispatch.rewrite(
            materialized.function,
            moduleName: owningModule(of: function)
        )
        return materialized
    }

    func owningModule(
        of function: CanonicalSIL.Function
    ) -> String? {
        if let encoded = CanonicalSIL.SymbolIdentity.moduleName(
            of: function.mangledName
        ) {
            return encoded
        }
        return function.declarationLocation.flatMap {
            sourceModuleByFile[$0.file]
        }
    }

    /// Swift manglings for declarations in extensions can begin with the
    /// extended foreign type rather than the source module. The frontend's
    /// exact file-ID mapping and local witness tables provide bounded ownership
    /// evidence without admitting serialized bodies from imported modules.
    func isCurrentModuleDefinition(
        mangledName: String,
        moduleName: String
    ) -> Bool {
        guard let function = function(mangledName: mangledName) else {
            return false
        }
        if owningModule(of: function) == moduleName {
            return !function.isExternalDefinition
        }
        if protocolConformances.containsWitnessTarget(
            mangledName,
            moduleName: moduleName
        ) {
            return !function.isExternalDefinition
        }
        return false
    }

    private static func extractFunctions(
        _ text: String,
        scopeLocations: [UInt32: Core.SourceLocation],
        declarationLocations: [String: Core.SourceLocation]
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
            let prefix = line[..<nameRange.lowerBound]
            let isExternalDefinition = prefix.contains("public_external")
                || prefix.contains("package_external")
            var isolation: CanonicalSIL.FunctionIsolation = .unspecified
            var commentIndex = index
            while commentIndex > 0 {
                commentIndex -= 1
                let comment = lines[commentIndex]
                    .trimmingCharacters(in: .whitespaces)
                guard comment.hasPrefix("//") else { break }
                if let parsed = CanonicalSIL.FunctionIsolation.parse(
                    comment: comment
                ) {
                    isolation = parsed
                    break
                }
            }
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
                    isolation: isolation,
                    declarationLocation: declarationLocations[name],
                    debugLineLocations: debugLineLocations,
                    isExternalDefinition: isExternalDefinition
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
