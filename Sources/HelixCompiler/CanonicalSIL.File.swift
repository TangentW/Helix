import Foundation
import HelixBytecode
import HelixCore

public enum CanonicalSIL {}

extension CanonicalSIL {
public enum InstructionFamily: Int, CaseIterable, Sendable {
    case functionReference
    case methodReference
    case application
    case valueForwarding
    case enumConstruction
    case globalAccess
    case structConstruction
    case existentialReference
}

public struct Function: Hashable, Sendable {
    public var mangledName: String
    public var loweredType: String
    public var body: String {
        didSet {
            bodyLines = Self.splitBody(body)
            instructionLineIndices = Self.indexInstructions(bodyLines)
        }
    }
    /// Pre-split normalized instructions. Frontend adapters often perform
    /// several independent provenance queries over one function; retaining
    /// this derived view avoids repeatedly allocating the same line array.
    public private(set) var bodyLines: [String]
    private var instructionLineIndices: [[Int]]
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
        bodyLines = Self.splitBody(body)
        instructionLineIndices = Self.indexInstructions(bodyLines)
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
        var lower = debugLineLocations.startIndex
        var upper = debugLineLocations.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if debugLineLocations[middle].line < line {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < debugLineLocations.endIndex,
              debugLineLocations[lower].line == line
        else { return nil }
        return debugLineLocations[lower].location
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
        bodyLines = Self.splitBody(body)
        instructionLineIndices = Self.indexInstructions(bodyLines)
        self.isolation = isolation
        self.declarationLocation = declarationLocation
        self.debugLineLocations = debugLineLocations
        hasStrippedDebugMetadata = true
        self.isExternalDefinition = isExternalDefinition
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mangledName == rhs.mangledName
            && lhs.loweredType == rhs.loweredType
            && lhs.body == rhs.body
            && lhs.isolation == rhs.isolation
            && lhs.declarationLocation == rhs.declarationLocation
            && lhs.debugLineLocations == rhs.debugLineLocations
            && lhs.hasStrippedDebugMetadata == rhs.hasStrippedDebugMetadata
            && lhs.isExternalDefinition == rhs.isExternalDefinition
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mangledName)
        hasher.combine(loweredType)
        hasher.combine(body)
        hasher.combine(isolation)
        hasher.combine(declarationLocation)
        hasher.combine(debugLineLocations)
        hasher.combine(hasStrippedDebugMetadata)
        hasher.combine(isExternalDefinition)
    }

    /// Returns zero-based line indices for a coarse SIL instruction family.
    /// The index is derived from `body` and deliberately excluded from value
    /// identity. Consumers still parse the selected lines fail-closed.
    public func bodyLineIndices(
        for family: CanonicalSIL.InstructionFamily
    ) -> [Int] {
        instructionLineIndices[family.rawValue]
    }

    private static func splitBody(_ body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func indexInstructions(_ lines: [String]) -> [[Int]] {
        var result = Array(
            repeating: [Int](),
            count: CanonicalSIL.InstructionFamily.allCases.count
        )
        for (index, line) in lines.enumerated() {
            func record(_ family: CanonicalSIL.InstructionFamily) {
                result[family.rawValue].append(index)
            }
            if line.contains(" = function_ref @") {
                record(.functionReference)
            }
            if line.contains("_method ") {
                record(.methodReference)
            }
            if line.contains("apply ") {
                record(.application)
            }
            if line.contains("begin_borrow ")
                || line.contains("copy_value ")
                || line.contains("move_value ")
                || line.contains("begin_access [read] ")
                || line.contains("begin_access [modify] ") {
                record(.valueForwarding)
            }
            if line.contains(" = enum $") {
                record(.enumConstruction)
            }
            if line.contains("global_addr @")
                || line.contains("global_value @") {
                record(.globalAccess)
            }
            if line.contains(" = struct $") {
                record(.structConstruction)
            }
            if line.contains("init_existential_ref") {
                record(.existentialReference)
            }
        }
        return result
    }
}

public struct File: Sendable {
    public var functions: [CanonicalSIL.Function] {
        didSet { uniqueFunctionIndices = Self.indexFunctions(functions) }
    }
    private var uniqueFunctionIndices: [String: Int] = [:]
    public var typeEnvironment: CanonicalSIL.TypeEnvironment
    public let clangMembers: [String: [CanonicalSIL.ClangMember]]
    let protocolConformances: CanonicalSIL.ProtocolConformance.Environment
    private let protocolDispatchInventory: CanonicalSIL.ProtocolConformance
        .StaticDispatch.Inventory
    private let sourceModuleByFile: [String: String]

    public init(text: String) throws {
        self = try CanonicalSIL.Inspection.parse(text, collectFailures: false).requireFile()
    }

    init(parsedFunctions: [CanonicalSIL.Function],
        parsedConformances: CanonicalSIL.ProtocolConformance.Environment,
        rawTypeEnvironment: CanonicalSIL.TypeEnvironment, sourceModules: [String: String],
        clangMembers: [String: [CanonicalSIL.ClangMember]] = [:]
    ) throws {
        let dispatchInventory = CanonicalSIL.ProtocolConformance
            .StaticDispatch.Inventory(
            conformances: parsedConformances,
            availableFunctions: parsedFunctions,
        )
        let dispatch = CanonicalSIL.ProtocolConformance.StaticDispatch.Rewriter(
            inventory: dispatchInventory,
            typeEnvironment: rawTypeEnvironment
        )
        functions = parsedFunctions.map { dispatch.rewrite($0) }
        // Dispatch rewriting changes function bodies, not the declaration
        // inventory. Reuse that inventory and refresh only affected factories.
        typeEnvironment = functions == parsedFunctions ? rawTypeEnvironment
            : try rawTypeEnvironment.replacingFactoryCandidates(functions)
        protocolConformances = parsedConformances
        protocolDispatchInventory = dispatchInventory
        sourceModuleByFile = sourceModules
        self.clangMembers = clangMembers
        uniqueFunctionIndices = Self.indexFunctions(functions)
    }

    public func function(mangledName: String) -> CanonicalSIL.Function? {
        guard let index = uniqueFunctionIndices[mangledName] else { return nil }
        return functions[index]
    }

    private static func indexFunctions(_ functions: [CanonicalSIL.Function]) -> [String: Int] {
        var indices: [String: Int] = [:]
        var ambiguous = Set<String>()
        for (index, function) in functions.enumerated() {
            let name = function.mangledName
            if indices[name] != nil { ambiguous.insert(name) }
            indices[name] = index
        }
        // The public function array is mutable. Rebuild its derived index on
        // mutation and omit duplicates instead of reviving first-match lookup.
        for name in ambiguous { indices.removeValue(forKey: name) }
        return indices
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
        arguments: String,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> CanonicalSIL.GenericFunction.Materialized {
        var materialized = try CanonicalSIL.GenericFunction.specialize(
            function,
            arguments: arguments,
            conformances: protocolConformances,
            typeEnvironment: typeEnvironment
        )
        materialized.function = rewritingClosedProtocolDispatch(
            in: materialized.function,
            typeEnvironment: typeEnvironment,
            moduleName: owningModule(of: function)
        )
        return materialized
    }

    func specializeGenericFunctionType(
        _ loweredType: String,
        arguments: String,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> String {
        try CanonicalSIL.GenericFunction.specializeLoweredType(
            loweredType,
            arguments: arguments,
            conformances: protocolConformances,
            typeEnvironment: typeEnvironment
        )
    }

    /// Resolves closed witness lookups against the compilation environment in
    /// effect at the call site. Native type identity and kind metadata arrive
    /// after canonical SIL parsing, so an environment-bound rewriter must not
    /// be cached by `File`.
    func rewritingClosedProtocolDispatch(
        in function: CanonicalSIL.Function,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        moduleName: String? = nil
    ) -> CanonicalSIL.Function {
        CanonicalSIL.ProtocolConformance.StaticDispatch.Rewriter(
            inventory: protocolDispatchInventory,
            typeEnvironment: typeEnvironment
        ).rewrite(
            function,
            moduleName: moduleName ?? owningModule(of: function)
        )
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

    static func locateFunctions(_ definitions: [CanonicalSIL.FunctionDefinition],
        scopes: [CanonicalSIL.DebugScope]
    ) throws -> [CanonicalSIL.Function] {
        let scopeLocations = Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0.location) })
        var extractedFunctions = try definitions.map { try $0.function(scopeLocations: scopeLocations) }
        let definedSymbols = Set(extractedFunctions.map(\.mangledName))
        var declarationScopes: [String: CanonicalSIL.DebugScope] = [:]
        for scope in scopes {
            // A debug parent spelling is not a declaration. In particular,
            // __unknown_macro__ can name unrelated scopes in several files.
            // Only a concrete SIL definition can give this map its identity.
            guard let symbol = scope.parentSymbol, definedSymbols.contains(symbol) else { continue }
            if let existing = declarationScopes[symbol], existing.location != scope.location {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "function @\(symbol) has conflicting declaration locations: "
                    + "scope \(existing.id) at \(existing.location.file):\(existing.location.line):\(existing.location.column); "
                    + "scope \(scope.id) at \(scope.location.file):\(scope.location.line):\(scope.location.column)"
                )
            }
            declarationScopes[symbol] = scope
        }
        for index in extractedFunctions.indices {
            extractedFunctions[index].declarationLocation = declarationScopes[
                extractedFunctions[index].mangledName
            ]?.location
        }
        return extractedFunctions.map(CanonicalSIL.OpaqueResult.concretize)
    }

    static func extractFunctionDefinitions(_ text: String) throws -> [CanonicalSIL.FunctionDefinition] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerRegex = try NSRegularExpression(
            pattern: #"^sil(?:(?:\s+\[[^\]]+\])|(?:\s+(?:public|public_external|hidden|shared|private|package|package_external|non_abi|public_non_abi|serialized)))*\s+@([^\s:]+)\s*:\s*\$(.+)\s*\{$"#
        )
        var result: [CanonicalSIL.FunctionDefinition] = []
        var definitionHeaders: [String: (line: Int, type: String)] = [:]
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
            if let existing = definitionHeaders[name] {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "function @\(name) is defined more than once: "
                    + "SIL line \(existing.line), type \(existing.type); "
                    + "SIL line \(index + 1), type \(type)"
                )
            }
            definitionHeaders[name] = (index + 1, type)
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
            result.append(.init(mangledName: name, loweredType: type, bodyLines: bodyLines,
                isolation: isolation, isExternalDefinition: isExternalDefinition))
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
            "canonical SIL:\(line): callee @\(mangledName) is absent from the target HLXI; "
                + "export it through the explicit NativeImport Catalog in a future Shell "
                + "(runtime symbol lookup is intentionally unavailable)"
        case let .unavailableNativeImport(line, mangledName, canonicalCallee, reason):
            "canonical SIL:\(line): \(canonicalCallee) (@\(mangledName)) is unavailable: \(reason)"
        case let .callSignatureMismatch(line, mangledName, detail):
            "canonical SIL:\(line): callee @\(mangledName) disagrees with its captured HLXI signature"
                + (detail.map { ": \($0)" } ?? "")
        case let .invalidCallTable(message): "invalid canonical-SIL call table: \(message)"
        }
    }
}
}
