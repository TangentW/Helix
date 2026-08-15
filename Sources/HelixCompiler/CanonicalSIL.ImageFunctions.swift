import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
enum ImageFunctions {
    struct Discovered: Sendable {
        var function: CanonicalSIL.Function
        var kind: Bytecode.FunctionKind
    }

    struct Signature: Equatable, Sendable {
        var parameters: [Bytecode.ValueType]
        var parameterConventions: [Bytecode.ParameterConvention]
        var result: Bytecode.ValueType
        var effects: Core.Effects
    }

    enum DiscoveryError: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupported(symbol: String, reason: String)

        var description: String {
            switch self {
            case let .unsupported(symbol, reason):
                "image-local function \(symbol) is unsupported: \(reason)"
            }
        }
    }

    /// Finds image-local implementation dependencies reachable from the
    /// supplied roots. The caller classifies both compiler-generated helpers
    /// and ordinary patch-local declarations because an App archive and a
    /// standalone source compilation have different trust boundaries.
    static func discover(
        in file: CanonicalSIL.File,
        startingAt rootSymbols: Set<String>,
        excluding excludedSymbols: Set<String>,
        kindForSymbol: (String) -> Bytecode.FunctionKind?
    ) throws -> [String: Discovered] {
        var pending = try rootSymbols.sorted().flatMap { symbol in
            try file.function(mangledName: symbol)
                .map { try references(in: $0.body, kindForSymbol: kindForSymbol) }
                ?? []
        }
        var visited = Set<String>()
        var kindBySymbol: [String: Bytecode.FunctionKind] = [:]
        var result: [String: Discovered] = [:]

        while let reference = pending.popLast() {
            let symbol = reference.symbol
            if let existingKind = kindBySymbol[symbol], existingKind != reference.kind {
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "different callers use it as incompatible function roles"
                )
            }
            kindBySymbol[symbol] = reference.kind
            guard visited.insert(symbol).inserted,
                  !excludedSymbols.contains(symbol)
            else { continue }
            guard let function = file.function(mangledName: symbol) else {
                // A generated symbol without a body remains eligible for a
                // separately frozen Shell binding. Lowering reports an
                // actionable unbound-callee diagnostic when none exists.
                continue
            }
            result[symbol] = .init(function: function, kind: reference.kind)
            pending.append(
                contentsOf: try references(
                    in: function.body,
                    kindForSymbol: kindForSymbol
                )
            )
        }
        return result
    }

    static func signature(
        of function: CanonicalSIL.Function,
        environment: CanonicalSIL.TypeEnvironment,
        symbol: String,
        kind: Bytecode.FunctionKind
    ) throws -> Signature {
        do {
            let parsed = try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).parseFunctionType(function.loweredType)
            guard !parsed.effects.isAsync else {
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "async helpers require a suspension-aware call contract"
                )
            }
            var effects = parsed.effects
            if let context = try environment.hostedMethodContext(for: function),
               try environment.hostedMethodRequiresMainActor(context) {
                effects.requiresMainActor = true
            }
            let normalized = try CanonicalSIL.MutableCaptures.normalize(
                body: function.body,
                role: kind,
                parameters: parsed.parameters,
                parameterConventions: parsed.parameterConventions,
                erasedPhysicalIndices: Set(
                    parsed.erasedMetatypes.map(\.physicalIndex)
                ),
                hasIndirectResult: parsed.hasIndirectResult,
                hasIndirectError: parsed.indirectErrorType != nil
            )
            return .init(
                parameters: normalized.parameters,
                parameterConventions: normalized.parameterConventions,
                result: parsed.result,
                effects: effects
            )
        } catch let error as DiscoveryError {
            throw error
        } catch {
            throw DiscoveryError.unsupported(
                symbol: symbol,
                reason: "its lowered signature is not fully concrete: \(error)"
            )
        }
    }

    private enum ReferenceUsage: Hashable {
        case closureConstruction
        case directCall
    }

    private static func references(
        in body: String,
        kindForSymbol: (String) -> Bytecode.FunctionKind?
    ) throws -> [(symbol: String, kind: Bytecode.FunctionKind)] {
        var symbolByValue: [String: String] = [:]
        var usageBySymbol: [String: Set<ReferenceUsage>] = [:]

        for rawLine in body.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let marker = line.range(of: "function_ref @"),
               let result = silResultValue(in: line) {
                let suffix = line[marker.upperBound...]
                let end = suffix.firstIndex { $0 == " " || $0 == ":" }
                    ?? suffix.endIndex
                let symbol = String(suffix[..<end])
                if !symbol.isEmpty { symbolByValue[result] = symbol }
                continue
            }
            for marker in [" = begin_borrow ", " = copy_value ", " = move_value "] {
                guard line.contains(marker),
                      let result = silResultValue(in: line),
                      let source = silValue(after: marker, in: line),
                      let symbol = symbolByValue[source]
                else { continue }
                symbolByValue[result] = symbol
            }
            if let source = silValue(after: "partial_apply", in: line)
                ?? silValue(after: "thin_to_thick_function", in: line),
               let symbol = symbolByValue[source] {
                usageBySymbol[symbol, default: []].insert(.closureConstruction)
                continue
            }
            if let source = silValue(after: "apply", in: line),
               let symbol = symbolByValue[source] {
                usageBySymbol[symbol, default: []].insert(.directCall)
            }
        }

        return ReleaseCompiler.ImplementationFingerprint
            .referencedSymbols(in: body).sorted().compactMap { symbol in
                guard let fallback = kindForSymbol(symbol) else { return nil }
                let usages = usageBySymbol[symbol, default: []]
                // Swift routinely materializes a no-capture closure for
                // lifetime/debug semantics while devirtualizing its actual
                // invocation to the same function_ref. Closure eligibility is
                // therefore additive, not an exclusive invocation mode.
                let kind: Bytecode.FunctionKind = usages.contains(
                    .closureConstruction
                ) ? .closureBody : fallback
                return (symbol, kind)
            }
    }

    private static func silResultValue(in line: String) -> String? {
        guard let equals = line.range(of: " =") else { return nil }
        let value = line[..<equals.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return value.first == "%" ? value : nil
    }

    private static func silValue(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let suffix = line[range.upperBound...]
        guard let percent = suffix.firstIndex(of: "%") else { return nil }
        let tail = suffix[percent...]
        let end = tail.dropFirst().firstIndex { !$0.isNumber } ?? tail.endIndex
        let value = String(tail[..<end])
        return value.count > 1 ? value : nil
    }
}
}
