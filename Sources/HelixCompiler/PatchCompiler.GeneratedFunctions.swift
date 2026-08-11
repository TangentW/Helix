import HelixBytecode
import HelixCore

extension PatchCompiler {
enum GeneratedFunctions {
    struct Planned: Sendable {
        var symbol: String
        var id: Bytecode.FunctionID
        var kind: Bytecode.FunctionKind
        var signature: CanonicalSIL.GeneratedFunctions.Signature
        var function: CanonicalSIL.Function
    }

    struct Plan: Sendable {
        var functions: [Planned]
        var directCalls: CanonicalSIL.DirectCallTable
    }

    static func makePlan(
        file: CanonicalSIL.File,
        root: CanonicalSIL.Function,
        rootID: Bytecode.FunctionID,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        directCalls: CanonicalSIL.DirectCallTable
    ) throws -> Plan {
        let rootSymbols: Set<String> = [root.mangledName]
        let discovered: [String: CanonicalSIL.GeneratedFunctions.Discovered]
        do {
            discovered = try CanonicalSIL.GeneratedFunctions.discover(
                in: file,
                startingAt: rootSymbols,
                excluding: directCalls.boundSymbols.union(rootSymbols),
                kindForSymbol: { symbol in
                    kind(for: symbol, rootedAt: rootSymbols)
                }
            )
        } catch let error as CanonicalSIL.GeneratedFunctions.DiscoveryError {
            throw map(error)
        }

        var occupiedIDs = directCalls.functionIDs
        occupiedIDs.insert(rootID)
        var planned: [Planned] = []
        var bindings: [CanonicalSIL.DirectCallBinding] = []
        for symbol in discovered.keys.sorted() {
            guard let item = discovered[symbol] else { continue }
            let signature: CanonicalSIL.GeneratedFunctions.Signature
            do {
                signature = try CanonicalSIL.GeneratedFunctions.signature(
                    of: item.function,
                    environment: typeEnvironment,
                    symbol: symbol
                )
            } catch let error as CanonicalSIL.GeneratedFunctions.DiscoveryError {
                throw map(error)
            }
            let id = try allocateFunctionID(occupied: &occupiedIDs)
            planned.append(
                .init(
                    symbol: symbol,
                    id: id,
                    kind: item.kind,
                    signature: signature,
                    function: item.function
                )
            )
            bindings.append(
                .init(
                    mangledName: symbol,
                    parameterTypes: signature.parameters,
                    parameterConventions: signature.parameterConventions,
                    resultType: signature.result,
                    effects: signature.effects,
                    target: .function(id)
                )
            )
        }
        return try .init(
            functions: planned,
            directCalls: directCalls.adding(bindings)
        )
    }

    private static func kind(
        for symbol: String,
        rootedAt roots: Set<String>
    ) -> Bytecode.FunctionKind? {
        if ReleaseCompiler.ImplementationFingerprint
            .isDefaultArgumentGenerator(symbol) {
            return .concreteSpecialization
        }
        // Default expressions may themselves create closures. Their symbols
        // are rooted in the fA thunk rather than in the App declaration.
        if symbol.contains("fA"), symbol.contains("cfU") || symbol.contains("fU") {
            return .closureBody
        }
        guard roots.contains(where: {
            symbol != $0 && symbol.hasPrefix($0)
        }) else { return nil }
        if symbol.contains("_Tg") || symbol.contains("Tf") {
            return .concreteSpecialization
        }
        if symbol.contains("cfU") || symbol.contains("fU") {
            return .closureBody
        }
        return nil
    }

    private static func allocateFunctionID(
        occupied: inout Set<Bytecode.FunctionID>
    ) throws -> Bytecode.FunctionID {
        var rawValue: UInt32 = 0
        while true {
            let candidate = Bytecode.FunctionID(rawValue: rawValue)
            if occupied.insert(candidate).inserted { return candidate }
            guard rawValue < UInt32.max else {
                throw PatchCompiler.CompilationError.functionIDSpaceExhausted
            }
            rawValue += 1
        }
    }

    private static func map(
        _ error: CanonicalSIL.GeneratedFunctions.DiscoveryError
    ) -> PatchCompiler.CompilationError {
        switch error {
        case let .unsupported(symbol, reason):
            .generatedFunctionUnsupported(symbol, reason: reason)
        }
    }
}

/// Failures while linking compiler-generated implementation dependencies.
public enum CompilationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A reachable helper cannot be represented by the current HLBC profile.
    case generatedFunctionUnsupported(String, reason: String)
    /// Every local HLBC function identifier is already occupied.
    case functionIDSpaceExhausted

    /// Stable diagnostic text suitable for build and Live Reload reporting.
    public var description: String {
        switch self {
        case let .generatedFunctionUnsupported(symbol, reason):
            "compiler-generated function \(symbol) is outside the current HLBC profile: \(reason)"
        case .functionIDSpaceExhausted:
            "the HLBC module has no free function identifier for a generated helper"
        }
    }
}
}
