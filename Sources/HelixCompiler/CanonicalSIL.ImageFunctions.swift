import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
enum ImageFunctions {
    struct Discovered: Sendable {
        var function: CanonicalSIL.Function
        var kind: Bytecode.FunctionKind
        var abiAdapter: CanonicalSIL.DirectCallBinding.ABIAdapter
        var executionEffectEnvelope: Core.Effects? = nil
        /// The source-level symbol named by `function_ref`. A materialized
        /// generic body has a distinct build-time identity but remains bound
        /// to this original callee.
        var bindingSymbol: String? = nil
        var genericSpecialization: CanonicalSIL.GenericFunction.Specialization?
            = nil
    }

    struct Signature: Equatable, Sendable {
        var parameters: [Bytecode.ValueType]
        var parameterConventions: [Bytecode.ParameterConvention]
        var result: Bytecode.ValueType
        var thrownType: Bytecode.ValueType?
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
        environment: CanonicalSIL.TypeEnvironment,
        executionEffectsByRoot: [String: Core.Effects] = [:],
        kindForSymbol: (String) -> Bytecode.FunctionKind?
    ) throws -> [String: Discovered] {
        var pending: [(reference: Reference, authority: RootExecutionAuthority)] = []
        for symbol in rootSymbols.sorted() {
            guard let function = file.function(mangledName: symbol) else {
                continue
            }
            pending.append(contentsOf: try references(
                in: function,
                file: file,
                environment: environment,
                kindForSymbol: kindForSymbol
            ).map {
                ($0, RootExecutionAuthority(effects: executionEffectsByRoot[symbol]))
            })
        }
        var visited = Set<String>()
        var authorityBySymbol: [String: RootExecutionAuthority] = [:]
        var kindBySymbol: [String: Bytecode.FunctionKind] = [:]
        var adapterBySymbol: [
            String: CanonicalSIL.DirectCallBinding.ABIAdapter
        ] = [:]
        var replacementBySymbol: [String: CanonicalSIL.Function] = [:]
        var bindingSymbolBySymbol: [String: String] = [:]
        var specializationBySymbol: [
            String: CanonicalSIL.GenericFunction.Specialization
        ] = [:]
        var result: [String: Discovered] = [:]

        while let next = pending.popLast() {
            let reference = next.reference
            let symbol = reference.symbol
            let bindingSymbol = reference.bindingSymbol ?? symbol
            let hadIdentity = bindingSymbolBySymbol[symbol] != nil
            if hadIdentity {
                guard bindingSymbolBySymbol[symbol] == bindingSymbol else {
                    throw DiscoveryError.unsupported(
                        symbol: bindingSymbol,
                        reason: "one image-local identity aliases different Swift callees"
                    )
                }
                guard specializationBySymbol[symbol]
                        == reference.genericSpecialization
                else {
                    throw DiscoveryError.unsupported(
                        symbol: bindingSymbol,
                        reason: "one image-local identity aliases different generic specializations"
                    )
                }
            }
            bindingSymbolBySymbol[symbol] = bindingSymbol
            if let specialization = reference.genericSpecialization {
                specializationBySymbol[symbol] = specialization
            }
            let kind: Bytecode.FunctionKind
            if let existingKind = kindBySymbol[symbol] {
                guard let merged = mergedFunctionKind(
                    existingKind,
                    reference.kind
                ) else {
                    throw DiscoveryError.unsupported(
                        symbol: symbol,
                        reason: "different callers use it as incompatible function roles"
                    )
                }
                kind = merged
            } else {
                kind = reference.kind
            }
            kindBySymbol[symbol] = kind
            // A later recursive/direct edge can reveal a second use of a body
            // already discovered through partial_apply. Closure-body is the
            // stronger role and remains a valid direct apply target.
            result[symbol]?.kind = kind
            if let existingAdapter = adapterBySymbol[symbol],
               existingAdapter != reference.abiAdapter {
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "different callers require incompatible physical ABI adapters"
                )
            }
            adapterBySymbol[symbol] = reference.abiAdapter
            if let replacement = reference.replacement {
                if let existing = replacementBySymbol[symbol],
                   existing != replacement {
                    throw DiscoveryError.unsupported(
                        symbol: symbol,
                        reason: "different callers synthesize incompatible replacement bodies"
                    )
                }
                replacementBySymbol[symbol] = replacement
            } else if case .staticKeyPathProjection = reference.abiAdapter {
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "static KeyPath projection has no synthesized replacement body"
                )
            }
            let isFirstVisit = visited.insert(symbol).inserted
            let previousAuthority = authorityBySymbol[symbol, default: .init()]
            var mergedAuthority = previousAuthority
            mergedAuthority.formUnion(next.authority)
            authorityBySymbol[symbol] = mergedAuthority
            if result[symbol] != nil {
                result[symbol]?.executionEffectEnvelope = mergedAuthority.effects
            }
            guard (isFirstVisit || mergedAuthority != previousAuthority),
                  !excludedSymbols.contains(symbol)
            else { continue }
            guard let function = replacementBySymbol[symbol]
                    ?? file.function(mangledName: bindingSymbol)
            else {
                // A generated symbol without a body remains eligible for a
                // separately frozen Shell binding. Lowering reports an
                // actionable unbound-callee diagnostic when none exists.
                continue
            }
            result[symbol] = .init(
                function: function,
                kind: kind,
                abiAdapter: reference.abiAdapter,
                executionEffectEnvelope: mergedAuthority.effects,
                bindingSymbol: reference.bindingSymbol,
                genericSpecialization: reference.genericSpecialization
            )
            pending.append(contentsOf: try references(
                    in: function,
                    file: file,
                    environment: environment,
                    kindForSymbol: kindForSymbol
                ).map { ($0, mergedAuthority) })
        }
        return result
    }

    private static func mergedFunctionKind(
        _ lhs: Bytecode.FunctionKind,
        _ rhs: Bytecode.FunctionKind
    ) -> Bytecode.FunctionKind? {
        if lhs == rhs { return lhs }
        // Only closure-body changes the callable ABI role. Ordinary and
        // concrete-specialization identities remain distinct classifications,
        // but either may also be used through a closure when its exact body is
        // the make_closure target.
        if lhs == .closureBody || rhs == .closureBody { return .closureBody }
        return nil
    }

    static func signature(
        of function: CanonicalSIL.Function,
        environment: CanonicalSIL.TypeEnvironment,
        symbol: String,
        kind: Bytecode.FunctionKind,
        executionEffectEnvelope: Core.Effects = .init(),
        file: CanonicalSIL.File? = nil
    ) throws -> Signature {
        do {
            let parsed = try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).parseFunctionType(function.loweredType)
            if parsed.effects.isAsync {
                guard kind != .closureBody else {
                    throw DiscoveryError.unsupported(
                        symbol: symbol,
                        reason: "async closure values are outside sequential async"
                    )
                }
                guard !parsed.parameterConventions.contains(.inout) else {
                    throw DiscoveryError.unsupported(
                        symbol: symbol,
                        reason: "an inout parameter cannot cross an async suspension boundary"
                    )
                }
            }
            var effects = parsed.effects
            let hostedContext = try environment.hostedMethodContext(for: function)
            let hostedRequiresMainActor = try hostedContext.map {
                try environment.hostedMethodRequiresMainActor($0)
            } ?? false
            switch function.isolation {
            case .globalActor where function.isolation.isMainActor:
                effects.requiresMainActor = true
            case let .globalActor(actor):
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "global actor \(actor) has no captured executor contract"
                )
            case let .unknown(description):
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "unknown Swift isolation metadata: \(description)"
                )
            case let .actorInstance(name) where !hostedRequiresMainActor:
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: "actor-instance isolation"
                        + (name.map { " (\($0))" } ?? "")
                        + " has no captured executor contract"
                )
            case .unspecified, .nonisolated, .actorInstance:
                break
            }
            if hostedRequiresMainActor {
                effects.requiresMainActor = true
            }
            // Image-local helpers are implementation details of their rooted
            // patch entry. Swift's lowered type remains authoritative for
            // throwing, async, and actor ABI, while these two policy effects
            // inherit the entry's already-frozen execution authority.
            effects.mayAllocate = executionEffectEnvelope.mayAllocate
            effects.hasExternalSideEffects = executionEffectEnvelope
                .hasExternalSideEffects
            let normalized = try CanonicalSIL.ManagedCaptureStorage.normalize(
                body: function.body,
                role: kind,
                parameters: parsed.parameters,
                parameterConventions: parsed.parameterConventions,
                erasedPhysicalIndices: Set(
                    parsed.erasedMetatypes.map(\.physicalIndex)
                ),
                indirectResultCount: parsed.indirectResultTypes.count,
                hasIndirectError: parsed.indirectErrorType != nil
            )
            let result = file.map {
                restoreImplicitClosureResultIsolation(
                    parsed.result,
                    function: function,
                    file: $0
                )
            } ?? parsed.result
            return .init(
                parameters: normalized.parameters,
                parameterConventions: normalized.parameterConventions,
                result: result,
                thrownType: parsed.thrownType,
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

    /// Canonical SIL erases the nested actor annotation from the result of
    /// Swift's implicit bound-method/autoclosure factories. Recover it only
    /// for compiler-generated factories whose every returned closure value is
    /// constructed from a MainActor body. An ordinary source factory may
    /// intentionally erase actor isolation and is therefore never inferred.
    private static func restoreImplicitClosureResultIsolation(
        _ result: Bytecode.ValueType,
        function: CanonicalSIL.Function,
        file: CanonicalSIL.File
    ) -> Bytecode.ValueType {
        guard case var .closure(signature) = result,
              !signature.effects.requiresMainActor,
              function.mangledName.range(
                of: #"(?:cfu|fu|cfU|fU)[0-9]*_$"#,
                options: .regularExpression
              ) != nil
        else { return result }

        var symbolByReference: [String: String] = [:]
        var targetByClosure: [String: String] = [:]
        var returnedValues: [String] = []
        for rawLine in function.body.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let marker = line.range(of: "function_ref @"),
               let value = silResultValue(in: line) {
                let suffix = line[marker.upperBound...]
                let end = suffix.firstIndex { $0 == " " || $0 == ":" }
                    ?? suffix.endIndex
                let symbol = String(suffix[..<end])
                if !symbol.isEmpty { symbolByReference[value] = symbol }
                continue
            }
            if let source = silValue(after: "partial_apply", in: line)
                ?? silValue(after: "thin_to_thick_function", in: line),
               let result = silResultValue(in: line),
               let symbol = symbolByReference[source] {
                targetByClosure[result] = symbol
                continue
            }
            for marker in [
                " = begin_borrow ", " = copy_value ", " = move_value ",
                " = convert_function ", " = convert_escape_to_noescape ",
                " = mark_dependence ",
            ] where line.contains(marker) {
                guard let result = silResultValue(in: line),
                      let source = silValue(after: marker, in: line),
                      let symbol = targetByClosure[source]
                else { continue }
                targetByClosure[result] = symbol
            }
            if line.hasPrefix("return "),
               let value = silValue(after: "return ", in: line) {
                returnedValues.append(value)
            }
        }
        guard !returnedValues.isEmpty,
              returnedValues.allSatisfy({ value in
                  targetByClosure[value].flatMap {
                      file.function(mangledName: $0)
                  }?.isolation.isMainActor == true
              })
        else { return result }
        signature.effects.requiresMainActor = true
        return .closure(signature)
    }

    private enum ReferenceUsage: Hashable {
        case closureConstruction
        case directCall
    }

    private struct Reference: Sendable {
        var symbol: String
        var kind: Bytecode.FunctionKind
        var replacement: CanonicalSIL.Function?
        var abiAdapter: CanonicalSIL.DirectCallBinding.ABIAdapter
        var bindingSymbol: String? = nil
        var genericSpecialization: CanonicalSIL.GenericFunction.Specialization?
            = nil
    }

    private struct MaterializedGenericReference: Sendable {
        var bindingSymbol: String
        var specialization: CanonicalSIL.GenericFunction.Specialization
        var function: CanonicalSIL.Function
        var usages: Set<ReferenceUsage>
    }

    private struct RootExecutionAuthority: Equatable, Sendable {
        var hasRoot = false
        var mayAllocate = false
        var hasExternalSideEffects = false

        init(effects: Core.Effects? = nil) {
            guard let effects else { return }
            hasRoot = true
            mayAllocate = effects.mayAllocate
            hasExternalSideEffects = effects.hasExternalSideEffects
        }

        mutating func formUnion(_ other: Self) {
            hasRoot = hasRoot || other.hasRoot
            mayAllocate = mayAllocate || other.mayAllocate
            hasExternalSideEffects = hasExternalSideEffects
                || other.hasExternalSideEffects
        }

        var effects: Core.Effects? {
            guard hasRoot else { return nil }
            return .init(
                mayAllocate: mayAllocate,
                hasExternalSideEffects: hasExternalSideEffects
            )
        }
    }

    private static func references(
        in function: CanonicalSIL.Function,
        file: CanonicalSIL.File,
        environment: CanonicalSIL.TypeEnvironment,
        kindForSymbol: (String) -> Bytecode.FunctionKind?
    ) throws -> [Reference] {
        let function = file.rewritingClosedProtocolDispatch(
            in: function,
            typeEnvironment: environment
        )
        let rewrites: [String: CanonicalSIL.StaticKeyPath.Rewrite]
        do {
            rewrites = try CanonicalSIL.StaticKeyPath.rewrites(
                in: function,
                file: file,
                environment: environment
            )
        } catch let error as CanonicalSIL.StaticKeyPath.RewriteError {
            throw DiscoveryError.unsupported(
                symbol: error.symbol,
                reason: error.reason
            )
        }
        let dynamicWitnessReferences: [Reference]
        do {
            let inventory = try CanonicalSIL.ProtocolExistential
                .WitnessReference.inventory(in: function.body)
            if inventory.isEmpty {
                dynamicWitnessReferences = []
            } else {
                let resolver = try CanonicalSIL.ProtocolExistential.Resolver(
                    file: file,
                    function: function,
                    typeEnvironment: environment
                )
                let witnesses = Set(inventory.values).sorted {
                    $0.result < $1.result
                }
                let symbols = try witnesses.flatMap {
                    try resolver.dispatchCandidates(for: $0).map(\.symbol)
                }
                dynamicWitnessReferences = try Set(symbols).sorted().map {
                    symbol in
                    guard kindForSymbol(symbol) == .concreteSpecialization else {
                        throw DiscoveryError.unsupported(
                            symbol: symbol,
                            reason: "an opened protocol witness is not a concrete image-local specialization"
                        )
                    }
                    return .init(
                        symbol: symbol,
                        kind: .concreteSpecialization,
                        replacement: nil,
                        abiAdapter: .direct
                    )
                }
            }
        } catch let error as DiscoveryError {
            throw error
        } catch {
            throw DiscoveryError.unsupported(
                symbol: function.mangledName,
                reason: "opened protocol witness discovery failed: \(error)"
            )
        }
        var symbolByValue: [String: String] = [:]
        var usageBySymbol: [String: Set<ReferenceUsage>] = [:]
        var unboundedRangeFunctionByValue: [String: String] = [:]
        var unboundedRangeClosureByValue: [String: String] = [:]
        var compilerOnlyUnboundedRangeSymbols = Set<String>()
        var compilerOnlyNativeBlockSymbols = Set<String>()
        var materializedGenericReferences: [
            String: MaterializedGenericReference
        ] = [:]

        func recordGenericReference(
            value: String,
            symbol: String,
            line: String,
            usage: ReferenceUsage
        ) throws -> Bool {
            // Direct semantic intrinsics are terminal compiler edges. Their
            // serialized standard-library bodies are not image-local helpers,
            // even when the SIL call carries concrete generic arguments.
            if usage == .directCall,
               CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol) != nil {
                return false
            }
            guard let rawArguments = genericArguments(
                appliedValue: value,
                in: line
            ), let declaration = file.function(mangledName: symbol),
                  kindForSymbol(symbol) != nil,
                  CanonicalSIL.GenericFunction.isGeneric(
                    loweredType: declaration.loweredType
                  )
            else { return false }
            let materialized: CanonicalSIL.GenericFunction.Materialized
            do {
                materialized = try file.materializeGenericFunction(
                    declaration,
                    arguments: rawArguments,
                    typeEnvironment: environment
                )
            } catch let error as CanonicalSIL.GenericFunction.SpecializationError {
                throw DiscoveryError.unsupported(
                    symbol: symbol,
                    reason: error.description
                )
            }
            let identity = materialized.function.mangledName
            if var existing = materializedGenericReferences[identity] {
                guard existing.bindingSymbol == symbol,
                      existing.specialization == materialized.descriptor,
                      existing.function == materialized.function
                else {
                    throw DiscoveryError.unsupported(
                        symbol: symbol,
                        reason: "generic specialization identity collision"
                    )
                }
                existing.usages.insert(usage)
                materializedGenericReferences[identity] = existing
            } else {
                materializedGenericReferences[identity] = .init(
                    bindingSymbol: symbol,
                    specialization: materialized.descriptor,
                    function: materialized.function,
                    usages: [usage]
                )
            }
            return true
        }

        for rawLine in function.body.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let marker = line.range(of: "function_ref @"),
               let result = silResultValue(in: line) {
                let suffix = line[marker.upperBound...]
                let end = suffix.firstIndex { $0 == " " || $0 == ":" }
                    ?? suffix.endIndex
                let symbol = String(suffix[..<end])
                if !symbol.isEmpty {
                    symbolByValue[result] = symbol
                    if let type = functionReferenceType(in: line) {
                        if CanonicalSIL.ClosureReabstraction.compilerThunkKind(
                            symbol: symbol,
                            loweredType: type
                        ) != nil {
                            compilerOnlyNativeBlockSymbols.insert(symbol)
                        }
                        if CanonicalSIL.RangeExpression
                        .isUnboundedMarkerFunctionType(type) {
                            // `UnboundedRange_` is an inaccessible stdlib marker
                            // used by the full-range subscript overload.
                            unboundedRangeFunctionByValue[result] = symbol
                        }
                    }
                }
                continue
            }
            for marker in [" = begin_borrow ", " = copy_value ", " = move_value "] {
                guard line.contains(marker),
                      let result = silResultValue(in: line),
                      let source = silValue(after: marker, in: line),
                      let symbol = symbolByValue[source]
                else { continue }
                symbolByValue[result] = symbol
                if let marker = unboundedRangeFunctionByValue[source] {
                    unboundedRangeFunctionByValue[result] = marker
                }
                if let marker = unboundedRangeClosureByValue[source] {
                    unboundedRangeClosureByValue[result] = marker
                }
            }
            if let source = silValue(after: "partial_apply", in: line)
                ?? silValue(after: "thin_to_thick_function", in: line),
               let symbol = symbolByValue[source] {
                if line.contains("thin_to_thick_function"),
                   let result = silResultValue(in: line),
                   let marker = unboundedRangeFunctionByValue[source],
                   let targetType = type(after: " to $", in: line),
                   CanonicalSIL.RangeExpression
                    .isUnboundedMarkerClosureType(targetType) {
                    unboundedRangeClosureByValue[result] = marker
                }
                if try !recordGenericReference(
                    value: source,
                    symbol: symbol,
                    line: line,
                    usage: .closureConstruction
                ) {
                    usageBySymbol[symbol, default: []].insert(
                        .closureConstruction
                    )
                }
                continue
            }
            if let source = silValue(after: "apply", in: line),
               let symbol = symbolByValue[source] {
                if CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol)
                    == .collection(.adapter(.fullRangeSlice)),
                   let arguments = applicationArguments(in: line),
                   arguments.count == 3,
                   let marker = unboundedRangeClosureByValue[arguments[1]] {
                    compilerOnlyUnboundedRangeSymbols.insert(marker)
                }
                if try !recordGenericReference(
                    value: source,
                    symbol: symbol,
                    line: line,
                    usage: .directCall
                ) {
                    usageBySymbol[symbol, default: []].insert(.directCall)
                }
            }
        }

        // A static KeyPath descriptor mentions accessor thunks that are
        // unreachable after a closure-form KeyPath object is erased. Remove
        // metadata-only edges; an explicit function_ref used by direct
        // subscript lowering remains visible in `usageBySymbol` below.
        let executableBody = function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).filter { !$0.contains(" = keypath $") }.joined(separator: "\n")
        let specializedBindingSymbols = Set(
            materializedGenericReferences.values.map(\.bindingSymbol)
        )
        let ordinary: [Reference] = ReleaseCompiler.ImplementationFingerprint
            .referencedSymbols(in: executableBody).sorted().compactMap { symbol in
                let usages = usageBySymbol[symbol, default: []]
                if usages.isEmpty,
                   specializedBindingSymbols.contains(symbol) {
                    return nil
                }
                if compilerOnlyNativeBlockSymbols.contains(symbol) {
                    return nil
                }
                if compilerOnlyUnboundedRangeSymbols.contains(symbol),
                   usages == [.closureConstruction] {
                    return nil
                }
                // A directly applied semantic intrinsic is a terminal compiler
                // edge. A reference converted into a closure still needs a
                // callable body and must never be silently discarded.
                if CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol) != nil,
                   usages.contains(.directCall),
                   !usages.contains(.closureConstruction) {
                    return nil
                }
                let intrinsicReplacement = file.function(
                    mangledName: symbol
                ).flatMap { function in
                    CanonicalSIL.SwiftCoreIntrinsic(
                        mangledName: symbol
                    )?.closureReplacement(for: function)
                }
                let fallback = kindForSymbol(symbol)
                    ?? file.function(mangledName: symbol).flatMap {
                        !usages.isEmpty
                            && CanonicalSIL.StaticKeyPath.isAccessorThunk($0)
                            ? .concreteSpecialization : nil
                    }
                    ?? intrinsicReplacement.map { _ in .closureBody }
                guard let fallback else { return nil }
                // Only a body that reaches partial_apply/thin_to_thick uses
                // the managed closure-capture ABI. Swift also emits direct-only
                // closure and defer helpers; those retain their physical
                // address parameters and link as concrete specializations.
                // When both forms occur, closure construction wins because
                // the same body must remain a valid make_closure target.
                let kind: Bytecode.FunctionKind
                if usages.contains(.closureConstruction) {
                    kind = .closureBody
                } else if usages.contains(.directCall), fallback == .closureBody {
                    kind = .concreteSpecialization
                } else {
                    kind = fallback
                }
                return .init(
                    symbol: symbol,
                    kind: kind,
                    replacement: rewrites[symbol]?.function
                        ?? intrinsicReplacement,
                    abiAdapter: rewrites[symbol]?.adapter ?? .direct
                )
            }
        let specialized: [Reference] = materializedGenericReferences.keys
            .sorted().compactMap { identity in
                guard let item = materializedGenericReferences[identity],
                      kindForSymbol(item.bindingSymbol) != nil
                else { return nil }
                let kind: Bytecode.FunctionKind = item.usages.contains(
                    .closureConstruction
                ) ? .closureBody : .concreteSpecialization
                return .init(
                    symbol: identity,
                    kind: kind,
                    replacement: item.function,
                    abiAdapter: .direct,
                    bindingSymbol: item.bindingSymbol,
                    genericSpecialization: item.specialization
                )
            }
        return ordinary + specialized + dynamicWitnessReferences
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

    private static func functionReferenceType(in line: String) -> String? {
        type(after: " : $", in: line)
    }

    private static func type(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let value = line[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func applicationArguments(in line: String) -> [String]? {
        guard let apply = line.range(of: "apply "),
              let open = line[apply.upperBound...].firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")")
        else { return nil }
        return silValues(in: line[line.index(after: open)..<close])
    }

    private static func genericArguments(
        appliedValue: String,
        in line: String
    ) -> String? {
        CanonicalSIL.GenericFunction.appliedArguments(
            to: appliedValue,
            in: line
        )
    }

    private static func silValues(in text: Substring) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex,
              let percent = text[index...].firstIndex(of: "%") {
            let digitsStart = text.index(after: percent)
            let digits = text[digitsStart...].prefix(while: \.isNumber)
            guard !digits.isEmpty else {
                index = digitsStart
                continue
            }
            result.append("%" + digits)
            index = text.index(digitsStart, offsetBy: digits.count)
        }
        return result
    }
}
}
