import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    struct ImportedOperationSurface: Sendable {
        var types: [ImportedNativeType]
        var operations: [ImportedOperation]
    }

    struct ImportedOperation: Hashable, Sendable {
        enum CompilerOperation: Hashable, Sendable {
            case rawValueInitializer
            case optionSetArrayLiteralInitializer
            case selectorInitializer
            case nativeUpcast
            case anyObjectBridge
        }

        enum IsolationEvidence: Hashable, Sendable {
            /// The declaration was unavailable, so isolation is conservatively
            /// inherited from the source context that performed the call.
            case enclosingContext
            /// A generated SDK probe captured the imported declaration itself.
            case importedDeclaration
        }

        var silReferences: [String]
        var sourceFileLogicalID: String
        var importedModules: [String]
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        /// Exact Swift parameter spellings used inside the generated invoker
        /// when a compiler-proven foreign boundary has a narrower source type
        /// than its frozen logical ABI (currently Objective-C protocols erased
        /// to AnyObject). Nil means the logical spellings are used directly.
        var invocationParameterSwiftTypes: [String]? = nil
        var parameterProjection: InterfaceArchive.NativeImportParameterProjection? = nil
        var resultSwiftType: String
        var requiresMainActor: Bool
        var mayThrow: Bool = false
        var witnessFunctions: [String] = []
        var compilerOperation: CompilerOperation? = nil
        var isolationEvidence: IsolationEvidence = .enclosingContext
    }

    private struct ImportedOperationIdentity: Hashable {
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var invocationParameterSwiftTypes: [String]
        var parameterProjection: InterfaceArchive.NativeImportParameterProjection
        var resultSwiftType: String

        init(_ operation: ImportedOperation) {
            dispatch = operation.dispatch
            ownerType = operation.ownerType
            baseName = operation.baseName
            argumentLabels = operation.argumentLabels
            parameterSwiftTypes = operation.parameterSwiftTypes
            invocationParameterSwiftTypes = operation.invocationParameterSwiftTypes
                ?? operation.parameterSwiftTypes
            parameterProjection = operation.parameterProjection
                ?? .identity(parameterCount: operation.parameterSwiftTypes.count)
            resultSwiftType = operation.resultSwiftType
        }
    }

    private struct ImportedOperationPhysicalABI: Hashable {
        var dispatch: NativeImportDiscovery.Dispatch
        var physicalParameterCount: UInt16
        var resultSwiftType: String
        var requiresMainActor: Bool
        var mayThrow: Bool
        var compilerOperation: ImportedOperation.CompilerOperation?

        init(_ operation: ImportedOperation) {
            dispatch = operation.dispatch
            physicalParameterCount = (operation.parameterProjection
                ?? .identity(parameterCount: operation.parameterSwiftTypes.count))
                .physicalParameterCount
            resultSwiftType = operation.resultSwiftType
            requiresMainActor = operation.requiresMainActor
            mayThrow = operation.mayThrow
            compilerOperation = operation.compilerOperation
        }
    }

    private struct ImportedOperationLogicalABI: Hashable {
        var physical: ImportedOperationPhysicalABI
        var parameterSwiftTypes: [String]
        var invocationParameterSwiftTypes: [String]
        var parameterProjection: InterfaceArchive.NativeImportParameterProjection

        init(_ operation: ImportedOperation) {
            physical = .init(operation)
            parameterSwiftTypes = operation.parameterSwiftTypes
            invocationParameterSwiftTypes = operation.invocationParameterSwiftTypes
                ?? operation.parameterSwiftTypes
            parameterProjection = operation.parameterProjection
                ?? .identity(parameterCount: operation.parameterSwiftTypes.count)
        }
    }

    private enum ImportedOperationSymbolConflict {
        case physical
        case logical
    }

    func discoverImportedOperationSurface(
        documents: [FrontendReceipt.TypedAST.Object],
        sourcesByPhysicalPath: [String: SourceState],
        moduleName: String,
        demangled: [String: String],
        silFile: CanonicalSIL.File
    ) throws -> ImportedOperationSurface {
        var types: [ImportedNativeType] = []
        var operations: [ImportedOperation] = []
        let silResolver = FrontendReceipt.SILFunctionResolver(file: silFile)

        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "imported operation discovery source does not map to the requested source set"
                )
            }
            let items = try FrontendReceipt.TypedAST.items(in: document)
            let modules = imports(in: items).filter { $0 != moduleName }
            types += sourceOverlayTypes(
                in: items,
                source: source,
                importedModules: modules,
                demangled: demangled
            )
            try collectImportedOperations(
                items: items,
                inheritedMainActor: false,
                source: source,
                importedModules: modules,
                moduleName: moduleName,
                demangled: demangled,
                silResolver: silResolver,
                types: &types,
                operations: &operations
            )
        }

        let mergedTypes = try mergeOperationTypes(types)
        let mergedOperations = try mergeImportedOperations(operations)
        return .init(
            types: mergedTypes,
            operations: try normalizeImportedTypeAliases(
                in: mergedOperations,
                types: mergedTypes
            )
        )
    }

    func makeImportedOperationDeclarations(
        _ operations: [ImportedOperation],
        moduleName: String,
        nativeTypes: [String: Core.TypeID]
    ) throws -> [NativeImportDiscovery.Declaration] {
        try canonicalizePhysicalOperations(operations).compactMap {
            operation -> NativeImportDiscovery.Declaration? in
            func omit(_ reason: String) throws -> NativeImportDiscovery.Declaration? {
                guard operation.compilerOperation == nil else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "compiler bridge \(operation.ownerType).\(operation.baseName) "
                            + "cannot be represented: \(reason)"
                    )
                }
                return nil
            }
            let parameterTypes = operation.parameterSwiftTypes.compactMap {
                FrontendReceipt.ValueTypeParser.parse(
                    $0,
                    allowVoid: false,
                    nativeTypes: nativeTypes
                )
            }
            guard parameterTypes.count == operation.parameterSwiftTypes.count else {
                return try omit("unsupported parameter type")
            }
            guard let resultType = FrontendReceipt.ValueTypeParser.parse(
                operation.resultSwiftType,
                allowVoid: true,
                nativeTypes: nativeTypes
            ) else { return try omit("unsupported result type") }
            let silSymbols: [String]
            switch operation.compilerOperation {
            case nil:
                silSymbols = operation.silReferences
            case .rawValueInitializer:
                guard parameterTypes.count == 1,
                      case let .native(typeID) = resultType
                else { return try omit("raw-value initializer shape mismatch") }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.rawValueInitializer(for: typeID)]
            case .optionSetArrayLiteralInitializer:
                guard parameterTypes.count == 1,
                      case let .array(element) = parameterTypes[0],
                      case let .native(elementType) = element,
                      resultType == .native(elementType)
                else { return try omit("option-set initializer shape mismatch") }
                silSymbols = [
                    CanonicalSIL.NativeBridgeSymbols.optionSetArrayLiteralInitializer(
                        for: elementType
                    ),
                ]
            case .selectorInitializer:
                guard parameterTypes == [.string],
                      case let .native(typeID) = resultType
                else { return try omit("selector initializer shape mismatch") }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.selectorInitializer(for: typeID)]
            case .nativeUpcast:
                guard parameterTypes.count == 1,
                      case let .native(sourceType) = parameterTypes[0],
                      case let .native(targetType) = resultType,
                      sourceType != targetType
                else { return try omit("native upcast shape mismatch") }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: sourceType,
                    to: targetType
                )]
            case .anyObjectBridge:
                guard parameterTypes == [.any],
                      case let .native(targetType) = resultType
                else { return try omit("AnyObject bridge shape mismatch") }
                silSymbols = [
                    CanonicalSIL.NativeBridgeSymbols.anyObjectBridge(
                        to: targetType
                    ),
                ]
            }
            guard let primarySymbol = silSymbols.first else {
                return try omit("no physical SIL symbol")
            }
            let isolation = operation.requiresMainActor ? "MainActor" : nil
            let signature = Core.LoweredSignature(
                parameters: operation.parameterSwiftTypes,
                result: operation.resultSwiftType,
                isThrowing: operation.mayThrow,
                isolation: isolation
            )
            let storedValueLifetimes: [
                Int: Core.NativeImportCallbackLifetime
            ]? = switch operation.dispatch {
            case .instanceSetter, .instanceValueSetter, .staticSetter:
                FrontendReceipt.NativeBridgeProfile.storedValueLifetimes(
                    parameterTypes: parameterTypes
                )
            case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
                 .anyObjectBridge, .instanceMethod, .staticGetter,
                 .instanceGetter:
                nil
            }
            guard FrontendReceipt.NativeBridgeProfile.isResult(resultType),
                  let callbacks = FrontendReceipt.NativeBridgeProfile.callbacks(
                      parameterSpellings: operation.parameterSwiftTypes,
                      parameterTypes: parameterTypes,
                      authoritativeLifetimes: storedValueLifetimes
                  ),
                  let bridgeParameterTypes = FrontendReceipt.NativeBridgeProfile
                    .generatedParameterSpellings(
                        operation.parameterSwiftTypes,
                        parameterTypes: parameterTypes
                    )
            else { return try omit("unsupported native bridge profile") }
            // Imported operations have already passed through the compiler-
            // proven nominal alias map. Stripping a textual module prefix
            // here would be ambiguous when a source namespace has the same
            // spelling as its module (Module.Module.NestedType).
            let generatedOwnerType = operation.ownerType
            let generatedParameterTypes = bridgeParameterTypes
            let logicalInvocationParameterTypes = operation
                .invocationParameterSwiftTypes ?? operation.parameterSwiftTypes
            guard logicalInvocationParameterTypes.count
                    == operation.parameterSwiftTypes.count
            else { return try omit("invocation arity mismatch") }
            var generatedInvocationParameterTypes = generatedParameterTypes
            for index in logicalInvocationParameterTypes.indices
            where logicalInvocationParameterTypes[index]
                    != operation.parameterSwiftTypes[index] {
                generatedInvocationParameterTypes[index] =
                    logicalInvocationParameterTypes[index]
            }
            let invocationParameterSwiftTypes =
                generatedInvocationParameterTypes == generatedParameterTypes
                ? nil : generatedInvocationParameterTypes
            let generatedResultType = operation.resultSwiftType
            let prefix = [moduleName, "HelixExternal", operation.ownerType]
            let callableReference = operation.baseName + "("
                + operation.argumentLabels.map { ($0 == "_" ? "_" : $0) + ":" }
                    .joined() + ")"
            let canonicalCallee: String = switch operation.dispatch {
            case .initializer:
                (prefix + [callableReference]).joined(separator: ".")
            case .nativeUpcast:
                (prefix + [
                    "upcast(from:\(operation.parameterSwiftTypes[0]))"
                ]).joined(separator: ".")
            case .anyObjectBridge:
                (prefix + ["bridge(from:Swift.Any)"]).joined(separator: ".")
            case .instanceGetter, .staticGetter:
                (prefix + [operation.baseName, "get"]).joined(separator: ".")
            case .instanceSetter, .staticSetter:
                (prefix + [operation.baseName, "set"]).joined(separator: ".")
            case .instanceValueSetter:
                (prefix + [operation.baseName, "mutate"]).joined(separator: ".")
            case .globalFunction, .staticMethod, .instanceMethod:
                (prefix + [callableReference, "call"]).joined(separator: ".")
            }
            return NativeImportDiscovery.Declaration(
                moduleName: moduleName,
                sourceFileLogicalID: operation.sourceFileLogicalID,
                mangledName: primarySymbol,
                silSymbols: silSymbols,
                canonicalCallee: canonicalCallee,
                accessLevel: "internal",
                dispatch: operation.dispatch,
                ownerType: operation.dispatch == .globalFunction
                    ? nil : generatedOwnerType,
                baseName: operation.baseName,
                argumentLabels: operation.argumentLabels,
                parameterSwiftTypes: generatedParameterTypes,
                invocationParameterSwiftTypes: invocationParameterSwiftTypes,
                parameterProjection: operation.parameterProjection
                    ?? .identity(parameterCount: parameterTypes.count),
                resultSwiftType: generatedResultType,
                importedModules: operation.importedModules,
                parameterTypes: parameterTypes,
                resultType: resultType,
                signature: signature,
                callbacks: callbacks,
                inferredEffects: .init(
                    mayThrow: operation.mayThrow,
                    requiresMainActor: operation.requiresMainActor
                ),
                isGeneric: false,
                hasInOut: false,
                hasTypedThrows: false,
                hasUnsupportedAttributes: false,
                abiAdapter: operation.dispatch == .instanceValueSetter
                    ? .mutatingValueReceiver : .direct
            )
        }
    }

    private func canonicalizePhysicalOperations(
        _ operations: [ImportedOperation]
    ) throws -> [ImportedOperation] {
        var bySymbol: [String: [ImportedOperation]] = [:]
        for operation in operations {
            for symbol in operation.silReferences {
                bySymbol[symbol, default: []].append(operation)
            }
        }
        for (symbol, values) in bySymbol where values.count > 1 {
            switch importedOperationSymbolConflict(in: values) {
            case .physical:
                let logicalShapes = values.map {
                    "\($0.ownerType).\($0.baseName)("
                        + $0.parameterSwiftTypes.joined(separator: ", ")
                        + ") -> \($0.resultSwiftType)"
                }.sorted().joined(separator: " versus ")
                throw FrontendReceipt.Error.invalidRequest(
                    "imported SIL operation \(symbol) has conflicting logical ABIs: "
                        + logicalShapes
                )
            case .logical:
                throw FrontendReceipt.Error.invalidRequest(
                    "imported SIL operation \(symbol) has ambiguous logical variants"
                )
            case nil:
                break
            }
        }

        guard operations.count > 1 else { return operations }
        var parents = Array(operations.indices)
        var sizes = Array(repeating: 1, count: operations.count)
        func root(_ index: Int) -> Int {
            var value = index
            while parents[value] != value { value = parents[value] }
            return value
        }
        func unite(_ lhs: Int, _ rhs: Int) {
            let left = root(lhs)
            let right = root(rhs)
            guard left != right else { return }
            if sizes[left] < sizes[right] {
                parents[left] = right
                sizes[right] += sizes[left]
            } else {
                parents[right] = left
                sizes[left] += sizes[right]
            }
        }
        struct VariantSymbol: Hashable {
            var symbol: String
            var abi: ImportedOperationLogicalABI
        }
        var firstUse: [VariantSymbol: Int] = [:]
        for (index, operation) in operations.enumerated() {
            let abi = ImportedOperationLogicalABI(operation)
            for symbol in operation.silReferences {
                let key = VariantSymbol(symbol: symbol, abi: abi)
                if let existing = firstUse[key] {
                    unite(index, existing)
                } else {
                    firstUse[key] = index
                }
            }
        }
        var groups: [Int: [ImportedOperation]] = [:]
        for index in operations.indices {
            groups[root(index), default: []].append(operations[index])
        }
        return groups.values.map { values in
            guard values.count > 1 else { return values[0] }
            var selected = values.sorted(by: importedOperationOrdering)[0]
            selected.silReferences = Array(Set(values.flatMap(\.silReferences))).sorted()
            selected.witnessFunctions = Array(Set(
                values.flatMap(\.witnessFunctions)
            )).sorted()
            selected.importedModules = Array(Set(values.flatMap(\.importedModules))).sorted()
            selected.sourceFileLogicalID = values.map(\.sourceFileLogicalID).min()
                ?? selected.sourceFileLogicalID
            return selected
        }.sorted(by: importedOperationOrdering)
    }

    /// Managed Debug probes are additive. A generic SDK implementation may
    /// reuse one SIL symbol for multiple concrete overlay types, which cannot
    /// be selected by symbol alone. Discard only those speculative references;
    /// source-observed operations remain authoritative and fail closed later.
    func unambiguousAdditiveImportedOperations(
        _ additions: [ImportedOperation],
        authoritative: [ImportedOperation]
    ) -> [ImportedOperation] {
        let authoritativeIdentities = Set(
            authoritative.map(ImportedOperationIdentity.init)
        )
        let refinements = additions.filter {
            authoritativeIdentities.contains(ImportedOperationIdentity($0))
        }
        let speculative = additions.filter {
            !authoritativeIdentities.contains(ImportedOperationIdentity($0))
        }
        var bySymbol: [String: [ImportedOperation]] = [:]
        // An exact measured declaration refines contextual isolation for an
        // already-observed operation. It is not a competing generic ABI.
        // Only genuinely additive identities participate in symbol ambiguity.
        for operation in authoritative + speculative {
            for symbol in operation.silReferences {
                bySymbol[symbol, default: []].append(operation)
            }
        }
        let ambiguousSymbols = Set(bySymbol.compactMap { symbol, values in
            importedOperationSymbolConflict(in: values) == nil ? nil : symbol
        })
        return refinements + speculative.compactMap { addition in
            var addition = addition
            addition.silReferences.removeAll(where: ambiguousSymbols.contains)
            return addition.silReferences.isEmpty ? nil : addition
        }
    }

    private func importedOperationSymbolConflict(
        in values: [ImportedOperation]
    ) -> ImportedOperationSymbolConflict? {
        guard values.count > 1 else { return nil }
        guard Set(values.map(ImportedOperationPhysicalABI.init)).count == 1
        else { return .physical }
        let byProjection = Dictionary(grouping: values) {
            ($0.parameterProjection
                ?? .identity(parameterCount: $0.parameterSwiftTypes.count))
                .logicalParameterIndices
        }
        return byProjection.values.contains { projected in
            Set(projected.map(ImportedOperationLogicalABI.init)).count != 1
        } ? .logical : nil
    }

    private func importedOperationOrdering(
        _ lhs: ImportedOperation,
        _ rhs: ImportedOperation
    ) -> Bool {
        let left = [
            lhs.dispatch.rawValue, lhs.ownerType, lhs.baseName,
            lhs.argumentLabels.joined(separator: ":"),
            lhs.parameterSwiftTypes.joined(separator: ","), lhs.resultSwiftType,
            (lhs.invocationParameterSwiftTypes ?? lhs.parameterSwiftTypes)
                .joined(separator: ","),
            lhs.sourceFileLogicalID,
        ]
        let right = [
            rhs.dispatch.rawValue, rhs.ownerType, rhs.baseName,
            rhs.argumentLabels.joined(separator: ":"),
            rhs.parameterSwiftTypes.joined(separator: ","), rhs.resultSwiftType,
            (rhs.invocationParameterSwiftTypes ?? rhs.parameterSwiftTypes)
                .joined(separator: ","),
            rhs.sourceFileLogicalID,
        ]
        return left.lexicographicallyPrecedes(right)
    }

    private func collectImportedOperations(
        items: [Any],
        inheritedMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        demangled: [String: String],
        silResolver: FrontendReceipt.SILFunctionResolver,
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        for value in items {
            guard let item = value as? [String: Any],
                  let kind = item["_kind"] as? String
            else { continue }
            let requiresMainActor = inheritedMainActor
                || itemRequiresMainActor(item, demangled: demangled)

            if kind == "func_decl",
               let usr = item["usr"] as? String,
               usr.hasPrefix("s:"),
               let body = item["body"] as? [String: Any] {
                let astSymbol = "$s" + usr.dropFirst(2)
                guard let sil = try silResolver.function(
                    for: item,
                    source: source,
                    baseName: baseName(in: item)
                )
                else {
                    throw FrontendReceipt.Error.missingSILFunction(astSymbol)
                }
                // Swift compiler operations do not require an explicit module
                // import; framework expression discovery does.
                recordAnyObjectBridge(
                    function: sil,
                    source: source,
                    types: &types,
                    operations: &operations
                )
                if !importedModules.isEmpty {
                    let callbackActorBindings = callbackActorBindings(
                        in: body,
                        demangled: demangled
                    )
                    try visitImportedExpression(
                        body,
                        role: .value,
                        function: sil,
                        requiresMainActor: requiresMainActor,
                        source: source,
                        importedModules: importedModules,
                        moduleName: moduleName,
                        demangled: demangled,
                        callbackActorBindings: callbackActorBindings,
                        types: &types,
                        operations: &operations
                    )
                }
            }

            if let members = item["members"] as? [Any] {
                try collectImportedOperations(
                    items: members,
                    inheritedMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    silResolver: silResolver,
                    types: &types,
                    operations: &operations
                )
            }
        }
    }

    /// Xcode 26's JSON AST can canonicalize a public Swift overlay such as
    /// `FileManager` back to its unavailable Objective-C runtime spelling.
    /// Preserve a different source spelling only when the mangling proves one
    /// exact imported ABI nominal and all observed spellings name the same
    /// overlay leaf. The generated-source validator remains the injection
    /// boundary; ambiguous aliases deliberately fall back to the typed AST.
    func sourceOverlayTypes(
        in root: [Any],
        source: SourceState,
        importedModules: [String],
        demangled: [String: String]
    ) -> [ImportedNativeType] {
        guard !importedModules.isEmpty else { return [] }
        var candidates: [String: [(spelling: String, nominal: String)]] = [:]
        var pending: [Any] = root.reversed()
        while let value = pending.popLast() {
            if let values = value as? [Any] {
                pending.append(contentsOf: values.reversed())
                continue
            }
            guard let item = value as? [String: Any] else { continue }
            if let members = item["members"] as? [Any] {
                pending.append(contentsOf: members.reversed())
            }
            guard item["_kind"] as? String == "func_decl",
                  let parameters = item["params"] as? [String: Any],
                  let parameterItems = parameters["params"] as? [[String: Any]],
                  let range = sourceRange(in: parameters),
                  range.start >= 0, range.end >= range.start,
                  range.end < source.contents.count,
                  range.end - range.start <= 512 * 1_024,
                  let rawList = String(
                      data: source.contents.subdata(
                          in: range.start..<(range.end + 1)
                      ),
                      encoding: .utf8
                  ),
                  let spellings = FrontendReceipt.SourceParameterSpelling
                    .types(in: rawList),
                  spellings.count == parameterItems.count
            else { continue }

            for (parameter, sourceSpelling) in zip(parameterItems, spellings) {
                guard let mangled = parameter["interface_type"] as? String,
                      isImportedMangledType(
                          mangled,
                          importedModules: importedModules
                      ),
                      let runtimeName = Self.objectiveCNominalIdentity(
                          inMangledType: mangled
                      ),
                      let typedSpelling = demangled[mangled].map(
                          normalizeImportedTypeSpelling
                      ),
                      let typedNominal = importedNativeNominal(
                          in: typedSpelling
                      ),
                      nominalBaseName(typedNominal) == runtimeName,
                      importedNominalRepresentation(
                          mangled,
                          spelling: typedNominal
                      ) == .reference,
                      let sourceNominal = importedNativeNominal(
                          in: sourceSpelling
                      ),
                      nominalBaseName(sourceNominal) != runtimeName,
                      importedNominalRepresentation(
                          mangled,
                          spelling: sourceNominal
                      ) == .reference
                else { continue }
                candidates[mangled, default: []].append(
                    (sourceSpelling, sourceNominal)
                )
            }
        }

        return candidates.compactMap { mangled, values in
            let overlayLeaves = Set(values.map { nominalBaseName($0.nominal) })
            guard overlayLeaves.count == 1 else { return nil }
            let spellings = Set(values.map(\.spelling))
            guard let spelling = spellings.sorted(by: {
                ($0.utf8.count, $0) < ($1.utf8.count, $1)
            }).first else { return nil }
            return importedNativeType(
                rawMangledType: mangled,
                spelling: spelling,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        }
    }

    private enum ImportedExpressionRole {
        case value
        case assignmentDestination
    }

    private struct CallbackActorBinding: Sendable {
        var name: String
        var declarationOffset: Int
        var scopeStart: Int
        var scopeEnd: Int
        var actor: String
    }

    private func callbackActorBindings(
        in body: [String: Any],
        demangled: [String: String]
    ) -> [CallbackActorBinding] {
        typealias Scope = (start: Int, end: Int)
        typealias Immutable = (
            name: String,
            offset: Int,
            scope: Scope
        )
        typealias Candidate = (
            name: String,
            declarationOffset: Int,
            declarationEnd: Int,
            scope: Scope,
            initializer: [String: Any],
            explicitType: Any?
        )
        var immutable: [Immutable] = []
        var candidates: [Candidate] = []

        func patternNames(in value: Any) -> [String] {
            if let values = value as? [Any] {
                return values.flatMap(patternNames)
            }
            guard let item = value as? [String: Any] else { return [] }
            if item["_kind"] as? String == "pattern_named",
               let name = baseName(in: item) {
                return [name]
            }
            return item.values.flatMap(patternNames)
        }

        func explicitPatternType(in value: Any) -> Any? {
            guard let item = value as? [String: Any] else { return nil }
            if item["_kind"] as? String == "pattern_typed" {
                return item["type"]
            }
            return item.values.lazy.compactMap(explicitPatternType).first
        }

        func mainActor(in rawType: Any?) -> String? {
            guard let type = importedSwiftType(
                rawType,
                demangled: demangled
            ), let actor = FrontendReceipt.FunctionTypeSpelling
                .callbackBoundary(in: type)?
                .function.attributes.globalActor,
                actor == "MainActor" || actor == "Swift.MainActor"
            else { return nil }
            return actor
        }

        func walk(_ value: Any, scope inheritedScope: Scope?) {
            if let values = value as? [Any] {
                for value in values { walk(value, scope: inheritedScope) }
                return
            }
            guard let item = value as? [String: Any] else { return }
            let kind = item["_kind"] as? String
            let itemRange = sourceRange(in: item)
            let scope: Scope? = if kind == "brace_stmt", let itemRange {
                (itemRange.start, itemRange.end)
            } else {
                inheritedScope
            }

            if kind == "var_decl", item["let"] as? Bool == true,
               let name = baseName(in: item), let itemRange, let scope {
                immutable.append((name, itemRange.start, scope))
            }
            if kind == "pattern_binding_decl", let itemRange, let scope,
               let entries = item["pattern_entries"] as? [[String: Any]] {
                for entry in entries {
                    guard let pattern = entry["pattern"] as? [String: Any],
                          case let names = patternNames(in: pattern),
                          names.count == 1,
                          let name = names.first,
                          let initializer = (entry["processed_init"]
                            ?? entry["original_init"]) as? [String: Any]
                    else { continue }
                    candidates.append((
                        name,
                        itemRange.start,
                        itemRange.end,
                        scope,
                        initializer,
                        explicitPatternType(in: pattern)
                    ))
                }
            }
            // A nested named function has its own lexical declaration
            // environment and canonical SIL body.
            if kind == "func_decl" { return }
            for (key, child) in item where key != "decl" {
                walk(child, scope: scope)
            }
        }

        walk(body, scope: nil)
        var bindings: [CallbackActorBinding] = []
        for candidate in candidates.sorted(by: {
            $0.declarationOffset < $1.declarationOffset
        }) {
            guard immutable.contains(where: {
                $0.name == candidate.name
                    && $0.scope == candidate.scope
                    && $0.offset >= candidate.declarationOffset
                    && $0.offset <= candidate.declarationEnd
            }) else { continue }
            let actor: String?
            if let explicitType = candidate.explicitType {
                // A source-written function type is authoritative. In
                // particular, do not undo an explicit actor erasure merely
                // because its initializer still carries MainActor provenance.
                actor = mainActor(in: explicitType)
            } else {
                actor = callbackGlobalActor(
                    in: candidate.initializer,
                    demangled: demangled,
                    bindings: bindings
                )
            }
            guard let actor else { continue }
            bindings.append(.init(
                name: candidate.name,
                declarationOffset: candidate.declarationOffset,
                scopeStart: candidate.scope.start,
                scopeEnd: candidate.scope.end,
                actor: actor
            ))
        }
        return bindings
    }

    private func visitImportedExpression(
        _ item: [String: Any],
        role: ImportedExpressionRole,
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        demangled: [String: String],
        callbackActorBindings: [CallbackActorBinding],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        let kind = item["_kind"] as? String
        if [
            "call_expr", "binary_expr", "prefix_unary_expr",
            "postfix_unary_expr",
        ].contains(kind) {
            try recordImportedSwiftCall(
                item,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                moduleName: moduleName,
                demangled: demangled,
                callbackActorBindings: callbackActorBindings,
                types: &types,
                operations: &operations
            )
        }
        if kind == "array_expr" {
            try recordImportedOptionSetArrayLiteral(
                item,
                function: function,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
        }
        if kind == "assign_expr",
           let destination = item["dest"] as? [String: Any] {
            try recordImportedProperty(
                destination,
                accessor: .instanceSetter,
                assignedValue: item["src"] as? [String: Any],
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                callbackActorBindings: callbackActorBindings,
                types: &types,
                operations: &operations
            )
            if let base = destination["base"] as? [String: Any] {
                try visitImportedExpression(
                    base,
                    role: .value,
                    function: function,
                    requiresMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    callbackActorBindings: callbackActorBindings,
                    types: &types,
                    operations: &operations
                )
            }
            if let value = item["src"] as? [String: Any] {
                try visitImportedExpression(
                    value,
                    role: .value,
                    function: function,
                    requiresMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    callbackActorBindings: callbackActorBindings,
                    types: &types,
                    operations: &operations
                )
            }
            return
        }

        if kind == "member_ref_expr", role == .value {
            try recordImportedProperty(
                item,
                accessor: .instanceGetter,
                assignedValue: nil,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                callbackActorBindings: callbackActorBindings,
                types: &types,
                operations: &operations
            )
            try recordImportedOptionSetMember(
                item,
                function: function,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
            try recordImportedGlobalMember(
                item,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
        }
        if kind == "erasure_expr" {
            recordAnyObjectErasure(
                item,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
        }
        if kind == "derived_to_base_expr" {
            recordImportedUpcast(
                item,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
        }
        if kind == "dot_syntax_call_expr" {
            try recordImportedEnumCase(
                item,
                function: function,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
                types: &types,
                operations: &operations
            )
        }

        for (key, value) in item where key != "decl" && key != "function_ref" {
            if let child = value as? [String: Any] {
                try visitImportedExpression(
                    child,
                    role: key == "dest" ? .assignmentDestination : .value,
                    function: function,
                    requiresMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    callbackActorBindings: callbackActorBindings,
                    types: &types,
                    operations: &operations
                )
            } else if let children = value as? [Any] {
                for case let child as [String: Any] in children {
                    try visitImportedExpression(
                        child,
                        role: .value,
                        function: function,
                        requiresMainActor: requiresMainActor,
                        source: source,
                        importedModules: importedModules,
                        moduleName: moduleName,
                        demangled: demangled,
                        callbackActorBindings: callbackActorBindings,
                        types: &types,
                        operations: &operations
                    )
                }
            }
        }
    }

    private func recordImportedProperty(
        _ expression: [String: Any],
        accessor: NativeImportDiscovery.Dispatch,
        assignedValue: [String: Any]?,
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        callbackActorBindings: [CallbackActorBinding],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard accessor == .instanceGetter || accessor == .instanceSetter,
              expression["_kind"] as? String == "member_ref_expr",
              let declaration = expression["decl"] as? [String: Any],
              let usr = declaration["decl_usr"] as? String,
              let rawBaseName = declaration["base_name"] as? String,
              let baseName = Core.SwiftName.normalizedIdentifier(rawBaseName),
              var propertyType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              ),
              let base = expression["base"] as? [String: Any]
        else { return }

        if accessor == .instanceSetter,
           let assignedValue,
           let actor = callbackGlobalActor(
               in: assignedValue,
               demangled: demangled,
               bindings: callbackActorBindings
           ), let isolated = FrontendReceipt.FunctionTypeSpelling
               .applyingGlobalActor(actor, to: propertyType) {
            propertyType = isolated
        }

        let staticOwner = importedMetatypeInstanceType(
            base["type"],
            demangled: demangled
        )
        let instanceOwner = importedSwiftType(
            base["type"],
            demangled: demangled
        )
        guard var receiverType = staticOwner ?? instanceOwner else { return }
        let isStatic = staticOwner != nil
        let marker = accessor == .instanceSetter ? "setter" : "getter"
        let expectedLocation = sourceRange(in: expression).flatMap {
            sourceLocation(atUTF8Offset: $0.start, in: source)
        }
        var references: [String]
        var foreignTypeEvidence: ForeignMemberTypeEvidence?
        let isObjectiveCProperty = usr.hasPrefix("c:")
            && (usr.contains("(py)") || usr.contains("(cpy)"))
        if isObjectiveCProperty {
            let physicalOwner = objectiveCPropertyOwner(usr)
            let ownerTypes = Set(
                [receiverType, nominalBaseName(receiverType)]
                    + [physicalOwner].compactMap { $0 }
            )
            references = Array(Set(ownerTypes.flatMap { ownerType in
                Self.foreignMemberReferences(
                    in: function.body,
                    ownerType: ownerType,
                    baseName: baseName,
                    marker: marker
                )
            })).sorted()
            if references.isEmpty {
                references = renamedForeignMemberReferences(
                    in: function,
                    baseName: baseName,
                    marker: marker,
                    sourceLocation: expectedLocation
                )
            }
            foreignTypeEvidence = foreignMemberTypeEvidence(
                in: function,
                baseName: baseName,
                marker: marker,
                sourceLocation: expectedLocation
            )
        } else if let reference = swiftPropertyReference(
            usr: usr,
            accessor: accessor,
            in: function.body
        ) {
            references = [reference]
        } else {
            references = []
        }
        guard !references.isEmpty else { return }

        if let evidence = foreignTypeEvidence {
            receiverType = resolvedForeignOwnerSpelling(
                logical: receiverType,
                physical: evidence.ownerType
            )
            if let mangled = expression["type"] as? String,
               Self.objectiveCNominalIdentity(inMangledType: mangled) != nil {
                let physical = accessor == .instanceSetter
                    ? physicalParameterSpellings(in: evidence.loweredType).first
                    : physicalResultSpelling(in: evidence.loweredType)
                if let physical,
                   let nominal = importedPhysicalNominalSpelling(physical) {
                    propertyType = nominal
                }
            }
        }

        let receiverRepresentation = isStatic ? nil : recordImportedNominalType(
            rawMangledType: base["type"],
            spelling: receiverType,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        _ = recordImportedNominalType(
            rawMangledType: expression["type"],
            spelling: propertyType,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        guard isStatic || receiverRepresentation != nil else { return }

        let dispatch: NativeImportDiscovery.Dispatch
        let parameterTypes: [String]
        let labels: [String]
        let resultType: String
        if isStatic {
            if accessor == .instanceSetter {
                dispatch = .staticSetter
                parameterTypes = [propertyType]
                labels = ["_"]
                resultType = "Swift.Void"
            } else {
                dispatch = .staticGetter
                parameterTypes = []
                labels = []
                resultType = propertyType
            }
        } else if accessor == .instanceSetter {
            dispatch = receiverRepresentation != .reference
                ? .instanceValueSetter : .instanceSetter
            parameterTypes = [propertyType, receiverType]
            labels = ["_"]
            resultType = dispatch == .instanceValueSetter
                ? receiverType : "Swift.Void"
        } else {
            dispatch = .instanceGetter
            parameterTypes = [receiverType]
            labels = []
            resultType = propertyType
        }
        operations.append(
            .init(
                silReferences: references,
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: dispatch,
                ownerType: receiverType,
                baseName: baseName,
                argumentLabels: labels,
                parameterSwiftTypes: parameterTypes,
                resultSwiftType: resultType,
                requiresMainActor: requiresMainActor,
                witnessFunctions: [function.mangledName]
            )
        )
    }

    private struct ImportedSILCall: Hashable {
        var referenceToken: String
        var symbol: String
        var loweredType: String
        /// Source-callable receiver spelling captured from `#Owner.member`.
        /// Nil for ordinary Swift function references and global functions.
        var foreignOwnerType: String? = nil
    }

    private func recordImportedSwiftCall(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        demangled: [String: String],
        callbackActorBindings: [CallbackActorBinding],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard let functionExpression = expression["fn"] as? [String: Any],
              let declaration = appliedDeclaration(in: functionExpression),
              let usr = declaration["decl_usr"] as? String,
              (usr.hasPrefix("s:") || usr.hasPrefix("c:")),
              !usr.hasPrefix("s:s"),
              !usr.hasPrefix("s:\(moduleName.utf8.count)\(moduleName)"),
              let rawBaseName = declaration["base_name"] as? String,
              let baseName = Core.SwiftName.normalizedIdentifier(rawBaseName)
                ?? (Core.SwiftName.isOperator(rawBaseName) ? rawBaseName : nil),
              var resultType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              )
        else { return }

        let formalArguments = ((expression["args"] as? [String: Any])?["args"]
            as? [[String: Any]]) ?? []
        var formalArgumentValues: [[String: Any]] = []
        var formalParameterTypes: [String] = []
        var explicitParameterIndices: [Int] = []
        var argumentLabels: [String] = []
        for (index, argument) in formalArguments.enumerated() {
            guard let value = argument["expr"] as? [String: Any],
                  var type = importedSwiftType(value["type"], demangled: demangled)
            else { return }
            if let actor = callbackGlobalActor(
                in: value,
                demangled: demangled,
                bindings: callbackActorBindings
            ), let isolated = FrontendReceipt.FunctionTypeSpelling
                .applyingGlobalActor(actor, to: type) {
                type = isolated
            }
            formalArgumentValues.append(value)
            formalParameterTypes.append(type)
            guard value["_kind"] as? String != "default_argument_expr" else {
                continue
            }
            explicitParameterIndices.append(index)
            argumentLabels.append(argument["label"] as? String ?? "_")
        }
        var declaredParameterTypes = formalParameterTypes
        let declaredObjectiveCProtocols = Set(
            (functionExpression["type"] as? String).map {
                Self.objectiveCProtocolNames(inMangledType: $0)
            } ?? []
        )
        if let formalFunctionType = importedSwiftType(
            functionExpression["type"],
            demangled: demangled
        ) {
            if let declared = FrontendReceipt.FunctionTypeSpelling
                .parameterSpellings(in: formalFunctionType),
               declared.count == formalParameterTypes.count {
                declaredParameterTypes = declared
            }
            // Closure expression types do not carry the callee parameter's
            // `@escaping` lifetime. The applied declaration's formal type is
            // the authoritative source for callback boundary annotations.
            formalParameterTypes = FrontendReceipt.FunctionTypeSpelling
                .overlayCallbackParameters(
                    formalParameterTypes,
                    formalFunctionType: formalFunctionType
                )
        }
        var parameterTypes = explicitParameterIndices.map {
            formalParameterTypes[$0]
        }
        var sourceInvocationParameterTypes = explicitParameterIndices.map {
            declaredParameterTypes[$0]
        }

        let dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String
        var receiver: [String: Any]?
        var staticOwner: [String: Any]?
        if functionExpression["_kind"] as? String == "constructor_ref_call_expr" {
            dispatch = .initializer
            ownerType = resultType
        } else if functionExpression["_kind"] as? String == "dot_syntax_call_expr",
                  let implicit = implicitReceiver(in: functionExpression) {
            if implicit["_kind"] as? String == "type_expr" {
                guard let owner = importedMetatypeInstanceType(
                    implicit["type"],
                    demangled: demangled
                ) else { return }
                dispatch = .staticMethod
                ownerType = owner
                staticOwner = implicit
            } else {
                guard let owner = importedSwiftType(
                    implicit["type"],
                    demangled: demangled
                ) else { return }
                dispatch = .instanceMethod
                ownerType = owner
                receiver = implicit
                parameterTypes.append(owner)
                sourceInvocationParameterTypes.append(owner)
            }
        } else {
            dispatch = .globalFunction
            ownerType = importedGlobalFunctionOwner(usr: usr)
        }
        guard Self.isSwiftIdentifier(baseName)
                || dispatch == .globalFunction
                    && Core.SwiftName.isOperator(baseName)
        else { return }

        let call: ImportedSILCall
        var invocationParameterOverrides: [Int: String] = [:]
        if usr.hasPrefix("s:") {
            let symbol = "$s" + usr.dropFirst(2)
            let expectedLocation = sourceRange(in: expression).flatMap {
                sourceLocation(atUTF8Offset: $0.start, in: source)
            }
            let exactReference = swiftFunctionReference(
                symbol: symbol,
                in: function,
                sourceLocation: expectedLocation
            )
            let structuralReference = foreignCallReference(
                in: function,
                ownerType: ownerType,
                baseName: baseName,
                sourceLocation: expectedLocation,
                allowsGlobalFunction: dispatch == .globalFunction
            )
            guard let reference = exactReference ?? structuralReference else { return }
            call = reference
        } else {
            let expectedLocation = sourceRange(in: expression).flatMap {
                sourceLocation(atUTF8Offset: $0.start, in: source)
            }
            guard let foreign = foreignCallReference(
                in: function,
                ownerType: ownerType,
                baseName: baseName,
                sourceLocation: expectedLocation,
                allowsGlobalFunction: dispatch == .globalFunction
            ) else { return }
            call = foreign
            let physicalParameters = physicalParameterSpellings(
                in: foreign.loweredType
            ).filter { !isPhysicalMetatypeParameter($0) }
            let alignedPhysicalParameters = alignForeignParameters(
                physicalParameters,
                logicalCount: parameterTypes.count,
                dispatch: dispatch
            )
            parameterTypes = parameterTypes.enumerated().map { index, logical in
                guard alignedPhysicalParameters.indices.contains(index) else {
                    return logical
                }
                let physical = alignedPhysicalParameters[index]
                if let invocationType = objectiveCProtocolInvocationType(
                    sourceInvocationParameterTypes[index],
                    physicalSpelling: physical,
                    declaredProtocolNames: declaredObjectiveCProtocols
                ) {
                    invocationParameterOverrides[index] = invocationType
                }
                return objcLogicalType(
                    logical,
                    physicalSpelling: physical
                )
            }
            if let physicalResult = physicalResultSpelling(in: foreign.loweredType) {
                resultType = objcLogicalType(
                    resultType,
                    physicalSpelling: physicalResult
                )
            }
        }
        if let physicalOwner = call.foreignOwnerType,
           dispatch != .globalFunction {
            ownerType = resolvedForeignOwnerSpelling(
                logical: ownerType,
                physical: physicalOwner
            )
            if dispatch == .instanceMethod,
               let receiverIndex = parameterTypes.indices.last {
                parameterTypes[receiverIndex] = ownerType
                sourceInvocationParameterTypes[receiverIndex] = ownerType
            } else if dispatch == .initializer {
                resultType = ownerType
            }
        }
        let physicalParameters = physicalParameterSpellings(
            in: call.loweredType
        ).filter { !isPhysicalMetatypeParameter($0) }
        var physicalParameterIndices = explicitParameterIndices
        if dispatch == .instanceMethod {
            guard let receiverIndex = physicalParameters.indices.last else {
                return
            }
            physicalParameterIndices.append(receiverIndex)
        }
        guard physicalParameters.count >= formalParameterTypes.count,
              physicalParameterIndices.allSatisfy(physicalParameters.indices.contains),
              let physicalParameterCount = UInt16(exactly: physicalParameters.count),
              physicalParameterIndices.compactMap(UInt16.init(exactly:)).count
                == physicalParameterIndices.count
        else { return }
        let logicalParameterIndices = physicalParameterIndices.compactMap(
            UInt16.init(exactly:)
        )
        let usesNSErrorBridge = dispatch == .instanceMethod
            && expression["throws"] != nil
            && call.loweredType.contains(
                "AutoreleasingUnsafeMutablePointer<Optional<NSError>>"
            )
            && physicalResultSpelling(in: call.loweredType) == "ObjCBool"
        let parameterProjection: InterfaceArchive.NativeImportParameterProjection
        if usesNSErrorBridge {
            // NSErrorBridgePlan removes Clang Importer's hidden NSError ** and
            // sentinel result before ordinary direct-call lowering. Its
            // NativeImport boundary is therefore already the logical Swift
            // throwing ABI, not a source-default projection.
            guard physicalParameters.count == parameterTypes.count + 1,
                  physicalParameterIndices.count == parameterTypes.count
            else { return }
            parameterProjection = .identity(
                parameterCount: parameterTypes.count
            )
        } else {
            guard let defaultArguments = nativeImportDefaultArguments(
                in: function,
                call: call,
                logicalParameterIndices: logicalParameterIndices
            ) else { return }
            parameterProjection = .init(
                physicalParameterCount: physicalParameterCount,
                logicalParameterIndices: logicalParameterIndices,
                defaultArguments: defaultArguments
            )
        }
        guard parameterProjection.isValid(
            logicalParameterCount: parameterTypes.count
        ) else { return }
        guard let callbackParameters = applyingNativeCallbackLifetimes(
            to: parameterTypes,
            physicalParameters: physicalParameterIndices.map {
                physicalParameters[$0]
            }
        ) else { return }
        parameterTypes = callbackParameters
        var invocationParameterTypes = parameterTypes
        for (index, spelling) in invocationParameterOverrides
        where invocationParameterTypes.indices.contains(index) {
            invocationParameterTypes[index] = spelling
        }
        let invocationParameterSwiftTypes = invocationParameterTypes == parameterTypes
            ? nil : invocationParameterTypes

        // Default argument values stay in the type environment so canonical
        // SIL can validate their compiler-only storage, but they do not cross
        // the NativeImport boundary or enter the generated invoker signature.
        for (index, pair) in zip(
            formalArgumentValues,
            formalParameterTypes
        ).enumerated() {
            let (value, formalType) = pair
            let rawMangledType = value["type"] as? String
            let logicalType: String? = rawMangledType
                .flatMap {
                    Self.objectiveCNominalIdentity(inMangledType: $0)
                } != nil
                ? explicitParameterIndices.firstIndex(of: index)
                    .flatMap { offset in
                        guard parameterTypes.indices.contains(offset) else {
                            return nil
                        }
                        if physicalParameters.indices.contains(index) {
                            if let physicalSpelling = importedPhysicalNominalSpelling(
                                physicalParameters[index]
                            ) {
                                return physicalSpelling
                            }
                        }
                        return parameterTypes[offset]
                    }
                : nil
            recordImportedTypeSurface(
                rawMangledType: value["type"],
                spelling: logicalType ?? formalType,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types
            )
        }
        if let receiver {
            recordImportedTypeSurface(
                rawMangledType: receiver["type"],
                spelling: ownerType,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types
            )
        }
        if let staticOwner {
            recordImportedTypeSurface(
                rawMangledType: staticOwner["type"],
                spelling: ownerType,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types
            )
        }
        let resultSurfaceSpelling: String = {
            guard let mangled = expression["type"] as? String,
                  Self.objectiveCNominalIdentity(inMangledType: mangled) != nil,
                  let physicalResult = physicalResultSpelling(
                      in: call.loweredType
                  ),
                  let physicalNominal = importedPhysicalNominalSpelling(
                      physicalResult
                  )
            else { return resultType }
            return physicalNominal
        }()
        recordImportedTypeSurface(
            rawMangledType: expression["type"],
            spelling: resultSurfaceSpelling,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        if dispatch == .initializer {
            _ = recordImportedNominalType(
                rawMangledType: expression["type"],
                spelling: ownerType,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types
            )
        }
        if parameterTypes.contains(where: isSelectorType) {
            recordSelectorSurface(
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types,
                operations: &operations
            )
        }

        operations.append(
            .init(
                silReferences: [call.symbol],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: dispatch,
                ownerType: ownerType,
                baseName: dispatch == .initializer ? "init" : baseName,
                argumentLabels: argumentLabels,
                parameterSwiftTypes: parameterTypes,
                invocationParameterSwiftTypes: invocationParameterSwiftTypes,
                parameterProjection: parameterProjection,
                resultSwiftType: resultType,
                requiresMainActor: requiresMainActor,
                mayThrow: expression["throws"] != nil
                    || call.loweredType.contains("@error"),
                witnessFunctions: [function.mangledName]
            )
        )
    }

    private func alignForeignParameters(
        _ physical: [String],
        logicalCount: Int,
        dispatch: NativeImportDiscovery.Dispatch
    ) -> [String] {
        guard logicalCount > 0 else { return [] }
        switch dispatch {
        case .instanceMethod:
            let explicitCount = logicalCount - 1
            guard physical.count >= logicalCount, let receiver = physical.last else {
                return Array(physical.prefix(logicalCount))
            }
            // Objective-C error bridging inserts NSError** before the receiver.
            return Array(physical.prefix(explicitCount)) + [receiver]
        case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
             .anyObjectBridge,
             .staticGetter, .staticSetter, .instanceGetter, .instanceSetter,
             .instanceValueSetter:
            return Array(physical.prefix(logicalCount))
        }
    }

    private func callbackGlobalActor(
        in expression: [String: Any],
        demangled: [String: String],
        bindings: [CallbackActorBinding] = []
    ) -> String? {
        if let raw = expression["global_actor_isolated"] as? String,
           let actor = demangled[raw],
           actor == "MainActor" || actor == "Swift.MainActor" {
            return actor
        }
        if expression["_kind"] as? String == "declref_expr",
           let declaration = expression["decl"] as? [String: Any],
           (declaration["decl_usr"] as? String) == "",
           let name = declaration["base_name"] as? String,
           let offset = sourceRange(in: expression)?.start,
           let binding = bindings.filter({ binding in
               binding.name == name
                   && binding.declarationOffset <= offset
                   && binding.scopeStart <= offset
                   && offset <= binding.scopeEnd
           }).max(by: { left, right in
               (left.scopeStart, left.declarationOffset)
                   < (right.scopeStart, right.declarationOffset)
           }) {
            return binding.actor
        }
        // Swift inserts function-conversion and Optional-injection wrappers
        // when an isolated closure value is passed to a less-specific SDK
        // parameter. The wrapper's result type has already erased isolation,
        // but its operand type remains authoritative provenance.
        if let type = importedSwiftType(
            expression["type"],
            demangled: demangled
        ), let actor = FrontendReceipt.FunctionTypeSpelling
            .callbackBoundary(in: type)?
            .function.attributes.globalActor,
           actor == "MainActor" || actor == "Swift.MainActor" {
            return actor
        }
        for key in ["sub_expr", "expr"] {
            if let child = expression[key] as? [String: Any],
               let actor = callbackGlobalActor(
                   in: child,
                   demangled: demangled,
                   bindings: bindings
               ) {
                return actor
            }
        }
        return nil
    }

    private func applyingNativeCallbackLifetimes(
        to logicalParameters: [String],
        physicalParameters: [String]
    ) -> [String]? {
        guard logicalParameters.count == physicalParameters.count else {
            return nil
        }
        var lifetimes: [Int: Core.NativeImportCallbackLifetime] = [:]
        for (index, pair) in zip(
            logicalParameters,
            physicalParameters
        ).enumerated() {
            guard let boundary = FrontendReceipt.FunctionTypeSpelling
                .callbackBoundary(in: pair.0)
            else {
                guard !pair.1.contains(" -> ") else { return nil }
                continue
            }
            guard pair.1.contains(" -> ") else { return nil }
            let isNonescaping = pair.1.range(
                of: #"(?:^|\s)@noescape(?:\s|$)"#,
                options: .regularExpression
            ) != nil
            guard !boundary.isOptional || !isNonescaping else {
                return nil
            }
            lifetimes[index] = isNonescaping ? .nonescaping : .escaping
        }
        guard !lifetimes.isEmpty else { return logicalParameters }
        return FrontendReceipt.FunctionTypeSpelling
            .applyingAuthoritativeLifetimes(
                lifetimes,
                to: logicalParameters
            )
    }

    private func swiftFunctionReference(
        symbol: String,
        in function: CanonicalSIL.Function,
        sourceLocation: Core.SourceLocation?
    ) -> ImportedSILCall? {
        struct Candidate: Hashable {
            var call: ImportedSILCall
            var location: Core.SourceLocation?
        }

        let marker = "function_ref @\(symbol) : $"
        let matches = Set(function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated().compactMap { offset, rawLine -> Candidate? in
            let line = String(rawLine)
            guard let range = line.range(of: marker),
                  let assignment = line.range(of: " = "),
                  assignment.lowerBound < range.lowerBound
            else { return nil }
            let token = line[..<assignment.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard token.hasPrefix("%") else { return nil }
            let loweredType = debugMetadataStrippedSuffix(
                String(line[range.upperBound...])
            )
            guard !loweredType.isEmpty else { return nil }
            return .init(
                call: .init(
                    referenceToken: token,
                    symbol: symbol,
                    loweredType: loweredType
                ),
                location: function.sourceLocation(atBodyLine: offset + 1)
            )
        })
        if let sourceLocation {
            let exact = Set(matches.compactMap { candidate in
                candidate.location == sourceLocation ? candidate.call : nil
            })
            if exact.count == 1 { return exact.first }
            let lineMatches = Set(matches.compactMap { candidate in
                candidate.location?.line == sourceLocation.line
                    ? candidate.call : nil
            })
            if lineMatches.count == 1 { return lineMatches.first }
        }
        let calls = Set(matches.map(\.call))
        return calls.count == 1 ? calls.first : nil
    }

    private struct ImportedSILApplication {
        var resultToken: String?
        var argumentTokens: [String]
    }

    /// Resolves the physical values supplied to one imported call without
    /// interpreting their Swift semantics. This is intentionally a small SSA
    /// provenance pass: the compiler may borrow or move a function reference,
    /// but an ambiguous or multiply-applied reference is not guessed.
    private func importedSILApplications(
        of referenceToken: String,
        in body: String
    ) -> [ImportedSILApplication] {
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var aliases: Set<String> = [referenceToken]
        var changed = true
        while changed {
            changed = false
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let assignment = line.range(of: " = ") else { continue }
                let destination = String(line[..<assignment.lowerBound])
                guard destination.hasPrefix("%") else { continue }
                let rhs = String(line[assignment.upperBound...])
                for operation in [
                    "begin_borrow ", "copy_value ", "move_value ",
                ] where rhs.hasPrefix(operation) {
                    let source = rhs.dropFirst(operation.count).prefix {
                        !$0.isWhitespace && $0 != ","
                    }
                    if aliases.contains(String(source)), aliases.insert(destination).inserted {
                        changed = true
                    }
                }
            }
        }

        return lines.compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for operation in ["try_apply", "apply"] {
                for token in aliases {
                    let marker = "\(operation) \(token)"
                    guard let call = line.range(of: marker) else { continue }
                    var cursor = call.upperBound
                    guard cursor < line.endIndex,
                          line[cursor] == "<" || line[cursor] == "("
                    else { continue }
                    var angleDepth = 0
                    var open: String.Index?
                    while cursor < line.endIndex {
                        switch line[cursor] {
                        case "<": angleDepth += 1
                        case ">": angleDepth -= 1
                        case "(" where angleDepth == 0:
                            open = cursor
                        default: break
                        }
                        if open != nil { break }
                        guard angleDepth >= 0 else { return nil }
                        cursor = line.index(after: cursor)
                    }
                    guard let open else { return nil }
                    var depth = 1
                    cursor = line.index(after: open)
                    var close: String.Index?
                    while cursor < line.endIndex {
                        switch line[cursor] {
                        case "(": depth += 1
                        case ")":
                            depth -= 1
                            if depth == 0 { close = cursor }
                        default: break
                        }
                        if close != nil { break }
                        cursor = line.index(after: cursor)
                    }
                    guard let close else { return nil }
                    let arguments = splitPhysicalTypeList(
                        String(line[line.index(after: open)..<close])
                    )
                    let result: String?
                    if operation == "apply",
                       let assignment = line[..<call.lowerBound].range(of: " = ") {
                        let candidate = line[..<assignment.lowerBound]
                            .trimmingCharacters(in: .whitespaces)
                        result = candidate.hasPrefix("%") ? candidate : nil
                    } else {
                        result = nil
                    }
                    return .init(resultToken: result, argumentTokens: arguments)
                }
            }
            return nil
        }
    }

    private func importedSILValueAliases(in body: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let assignment = line.range(of: " = ") else { continue }
            let destination = String(line[..<assignment.lowerBound])
            guard destination.hasPrefix("%") else { continue }
            let rhs = String(line[assignment.upperBound...])
            for operation in [
                "begin_borrow ", "copy_value ", "move_value ",
                "begin_access [read] ", "begin_access [modify] ",
            ] where rhs.hasPrefix(operation) {
                let tail = rhs.dropFirst(operation.count)
                if let source = tail.split(whereSeparator: {
                    $0.isWhitespace || $0 == ","
                }).first(where: { $0.hasPrefix("%") }) {
                    result[destination] = String(source)
                }
            }
        }
        return result
    }

    private func canonicalSILOrigin(
        of token: String,
        aliases: [String: String]
    ) -> String {
        var current = token
        var visited = Set<String>()
        while visited.insert(current).inserted, let source = aliases[current] {
            current = source
        }
        return current
    }

    private func nativeImportDefaultArguments(
        in function: CanonicalSIL.Function,
        call: ImportedSILCall,
        logicalParameterIndices: [UInt16]
    ) -> [InterfaceArchive.NativeImportDefaultArgument]? {
        let rawParameters = physicalParameterSpellings(in: call.loweredType)
        let physicalParameters = rawParameters.filter {
            !isPhysicalMetatypeParameter($0)
        }
        let selected = Set(logicalParameterIndices.map(Int.init))
        let omitted = physicalParameters.indices.filter {
            !selected.contains($0)
        }
        guard !omitted.isEmpty else { return [] }

        let applications = importedSILApplications(
            of: call.referenceToken,
            in: function.body
        )
        guard applications.count == 1,
              let application = applications.first,
              application.argumentTokens.count >= rawParameters.count
        else { return nil }
        let rawArguments = Array(application.argumentTokens.suffix(rawParameters.count))
        let physicalArguments = zip(rawParameters, rawArguments).compactMap {
            isPhysicalMetatypeParameter($0.0) ? nil : $0.1
        }
        guard physicalArguments.count == physicalParameters.count else { return nil }

        let aliases = importedSILValueAliases(in: function.body)
        var inlineOptionalNone = Set<String>()
        var generatorReferences: [String: (symbol: String, loweredType: String)] = [:]
        for rawLine in function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let assignment = line.range(of: " = enum $"),
               line.contains("#Optional.none!enumelt") {
                let token = String(line[..<assignment.lowerBound])
                if token.hasPrefix("%") { inlineOptionalNone.insert(token) }
            }
            guard let assignment = line.range(of: " = function_ref @"),
                  let separator = line.range(
                      of: " : $",
                      range: assignment.upperBound..<line.endIndex
                  )
            else { continue }
            let token = String(line[..<assignment.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let symbol = String(line[assignment.upperBound..<separator.lowerBound])
            if token.hasPrefix("%"), ReleaseCompiler.ImplementationFingerprint
                .isDefaultArgumentGenerator(symbol) {
                generatorReferences[token] = (
                    symbol,
                    debugMetadataStrippedSuffix(
                        String(line[separator.upperBound...])
                    )
                )
            }
        }

        var generatedValues: [String: String] = [:]
        var hasAmbiguousGeneratedValue = false
        for (reference, generator) in generatorReferences {
            for generated in importedSILApplications(
                of: reference,
                in: function.body
            ) {
                if let resultToken = generated.resultToken {
                    let origin = canonicalSILOrigin(
                        of: resultToken,
                        aliases: aliases
                    )
                    if let existing = generatedValues[origin],
                       existing != generator.symbol {
                        hasAmbiguousGeneratedValue = true
                    } else {
                        generatedValues[origin] = generator.symbol
                    }
                }
                let indirectResultCount = physicalResultSpelling(
                    in: generator.loweredType
                )?.hasPrefix("@out ") == true ? 1 : 0
                for argument in generated.argumentTokens
                    .prefix(indirectResultCount)
                where argument.hasPrefix("%") {
                    let origin = canonicalSILOrigin(
                        of: argument,
                        aliases: aliases
                    )
                    if let existing = generatedValues[origin],
                       existing != generator.symbol {
                        hasAmbiguousGeneratedValue = true
                    } else {
                        generatedValues[origin] = generator.symbol
                    }
                }
            }
        }
        guard !hasAmbiguousGeneratedValue else { return nil }

        var defaults: [InterfaceArchive.NativeImportDefaultArgument] = []
        defaults.reserveCapacity(omitted.count)
        for index in omitted {
            guard let physicalIndex = UInt16(exactly: index) else { return nil }
            let origin = canonicalSILOrigin(
                of: physicalArguments[index],
                aliases: aliases
            )
            if inlineOptionalNone.contains(origin) {
                guard generatedValues[origin] == nil else { return nil }
                defaults.append(
                    .optionalNone(physicalParameterIndex: physicalIndex)
                )
                continue
            }
            guard let generator = generatedValues[origin] else { return nil }
            defaults.append(
                .externalGenerator(
                    physicalParameterIndex: physicalIndex,
                    symbol: generator
                )
            )
        }
        return defaults
    }

    private func objcLogicalType(
        _ swiftType: String,
        physicalSpelling rawPhysical: String
    ) -> String {
        if let callback = FrontendReceipt.FunctionTypeSpelling
            .callbackBoundary(in: swiftType) {
            return callback.declaredSpelling
        }
        let logical = swiftType.replacingOccurrences(of: "Swift.", with: "")
        let physical = strippingPhysicalOwnership(rawPhysical)
        if physical == "()" { return "Swift.Void" }
        if physical.hasPrefix("any ") {
            // Objective-C protocol existentials are class-bound. Their dynamic
            // conformance is not a frozen NativeImport ABI, so erase it to the
            // existing identity-preserving AnyObject bridge.
            return "Swift.AnyObject"
        }
        for prefix in ["Optional<", "Swift.Optional<"]
        where physical.hasPrefix(prefix) && physical.hasSuffix(">") {
            let body = String(physical.dropFirst(prefix.count).dropLast())
            let logicalBody: String
            if logical.hasSuffix("?") {
                logicalBody = String(logical.dropLast())
            } else if logical.hasPrefix("Optional<"), logical.hasSuffix(">") {
                logicalBody = String(logical.dropFirst("Optional<".count).dropLast())
            } else {
                logicalBody = swiftType
            }
            return objcLogicalType(logicalBody, physicalSpelling: body) + "?"
        }
        if physical.contains("τ_") { return swiftType }
        if ["NSString", "Foundation.NSString", "__C.NSString"].contains(physical) {
            return "Swift.String"
        }
        if physical == "AnyObject" { return "Swift.AnyObject" }
        if physical == "NSArray" || physical == "Foundation.NSArray" {
            return swiftType
        }
        if FrontendReceipt.ValueTypeParser.parse(swiftType, allowVoid: true) != nil {
            return swiftType
        }
        if FrontendReceipt.SwiftTypeSpelling.isGeneratedType(swiftType) {
            // Generated adapters call the source-level Swift overlay, so its
            // safe logical spelling is authoritative even when canonical SIL
            // uses an Objective-C bridge type such as NSURL.
            return swiftType
        }
        return normalizeImportedTypeSpelling(physical)
    }

    private func resolvedForeignOwnerSpelling(
        logical: String,
        physical: String
    ) -> String {
        // Clang's SIL member reference may erase Objective-C lightweight
        // generic arguments even though the typed AST retained the concrete
        // Swift specialization. Physical evidence can correct a renamed owner
        // (for example NSFileManager -> FileManager), but it must never make a
        // previously concrete generated type unnameable.
        if logical.contains("<"), !physical.contains("<") {
            return logical
        }
        return physical
    }

    /// Keeps the source-level Objective-C protocol type only inside the
    /// generated Swift invoker. The artifact ABI remains AnyObject, while the
    /// typed decoder performs the dynamic conformance check before the call.
    private func objectiveCProtocolInvocationType(
        _ swiftType: String,
        physicalSpelling rawPhysical: String,
        declaredProtocolNames: Set<String>
    ) -> String? {
        let physical = strippingPhysicalOwnership(rawPhysical)
        for prefix in ["Optional<", "Swift.Optional<"]
        where physical.hasPrefix(prefix) && physical.hasSuffix(">") {
            let body = String(physical.dropFirst(prefix.count).dropLast())
            guard let logicalBody = optionalWrappedSwiftType(swiftType),
                  let invocation = objectiveCProtocolInvocationType(
                      logicalBody,
                      physicalSpelling: body,
                      declaredProtocolNames: declaredProtocolNames
                  )
            else { return nil }
            return "Swift.Optional<\(invocation)>"
        }
        guard physical.hasPrefix("any ")
                || ["AnyObject", "Swift.AnyObject"].contains(physical)
        else { return nil }
        var logical = swiftType.trimmingCharacters(in: .whitespacesAndNewlines)
        if logical.hasPrefix("("), logical.hasSuffix(")") {
            logical.removeFirst()
            logical.removeLast()
            logical = logical.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = logical.hasPrefix("any ")
            ? String(logical.dropFirst("any ".count)) : logical
        let protocols = body.split(separator: "&").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !protocols.isEmpty,
              protocols.allSatisfy({ protocolName in
                  let unqualified = protocolName.split(separator: ".").last
                    .map(String.init) ?? protocolName
                  return declaredProtocolNames.contains(unqualified)
              })
        else { return nil }
        let existential = "any \(body)"
        return FrontendReceipt.SwiftTypeSpelling.isGeneratedType(existential)
            ? existential : nil
    }

    private func optionalWrappedSwiftType(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("?") {
            var wrapped = String(value.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if wrapped.hasPrefix("("), wrapped.hasSuffix(")") {
                wrapped.removeFirst()
                wrapped.removeLast()
            }
            return wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Optional<", "Swift.Optional<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            return String(value.dropFirst(prefix.count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func strippingPhysicalOwnership(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in_guaranteed ", "@out ",
            ] where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
                value = value.trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return value
    }

    private func physicalParameterSpellings(in loweredType: String) -> [String] {
        guard let arrow = loweredType.range(of: " -> ", options: .backwards) else {
            return []
        }
        let prefix = loweredType[..<arrow.lowerBound]
        guard let close = prefix.lastIndex(of: ")") else { return [] }
        var depth = 0
        var cursor = close
        var open: String.Index?
        while true {
            if prefix[cursor] == ")" { depth += 1 }
            if prefix[cursor] == "(" {
                depth -= 1
                if depth == 0 {
                    open = cursor
                    break
                }
            }
            guard cursor > prefix.startIndex else { break }
            cursor = prefix.index(before: cursor)
        }
        guard let open else { return [] }
        return splitPhysicalTypeList(
            String(prefix[prefix.index(after: open)..<close])
        )
    }

    private func debugMetadataStrippedSuffix(_ raw: String) -> String {
        let end = raw.range(of: ", loc ")?.lowerBound ?? raw.endIndex
        return String(raw[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private func isPhysicalMetatypeParameter(_ raw: String) -> Bool {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        if spelling.hasPrefix("$") {
            spelling.removeFirst()
            spelling = spelling.trimmingCharacters(in: .whitespaces)
        }
        if spelling.contains("_metatype ") { return true }
        for prefix in ["@thin ", "@thick ", "@objc_metatype "]
        where spelling.hasPrefix(prefix) {
            return spelling.hasSuffix(".Type")
        }
        return false
    }

    private func physicalResultSpelling(in loweredType: String) -> String? {
        guard let arrow = loweredType.range(of: " -> ", options: .backwards) else {
            return nil
        }
        let result = loweredType[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    private func splitPhysicalTypeList(_ raw: String) -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        for index in raw.indices {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "," where angleDepth == 0 && parenthesisDepth == 0
                    && bracketDepth == 0:
                result.append(
                    String(raw[start..<index]).trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0,
                  bracketDepth >= 0
            else { return [] }
        }
        guard angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 else {
            return []
        }
        let tail = String(raw[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private func foreignCallReference(
        in function: CanonicalSIL.Function,
        ownerType: String,
        baseName: String,
        sourceLocation: Core.SourceLocation?,
        allowsGlobalFunction: Bool = false
    ) -> ImportedSILCall? {
        struct Candidate: Hashable {
            var call: ImportedSILCall
            var location: Core.SourceLocation?
        }

        let owner = nominalBaseName(ownerType)
        var methodCandidates: [Candidate] = []
        var functionCandidates: [Candidate] = []
        for (offset, rawLine) in function.body
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let location = function.sourceLocation(atBodyLine: offset + 1)
            if !allowsGlobalFunction,
               line.contains("_method "),
               let assignment = line.range(of: " = "),
               let hash = line.firstIndex(of: "#"),
               let separator = line[hash...].range(of: " : "),
               let loweredMarker = line.range(of: ", $", options: .backwards) {
                let token = String(line[..<assignment.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let reference = String(line[hash..<separator.lowerBound])
                let loweredType = debugMetadataStrippedSuffix(
                    String(line[loweredMarker.upperBound...])
                )
                let baseNameMatches = Self.foreignReference(
                    reference,
                    hasBaseName: baseName
                )
                    || (baseName == "init" && reference.contains(".init!"))
                let ownerMatches = reference.hasPrefix("#\(owner).")
                let sourceMatches = sourceLocation != nil
                    && location?.line == sourceLocation?.line
                let isPseudogeneric = loweredType.contains("@pseudogeneric")
                    || loweredType.contains("τ_")
                let genericArguments = foreignApplyGenericArguments(
                    for: token,
                    in: function.body
                )
                if baseNameMatches, ownerMatches || sourceMatches,
                   !isPseudogeneric || !genericArguments.isEmpty {
                    let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
                        reference: reference,
                        loweredType: loweredType,
                        genericArguments: genericArguments
                    )
                    methodCandidates.append(
                        .init(
                            call: .init(
                                referenceToken: token,
                                symbol: symbol,
                                loweredType: loweredType,
                                foreignOwnerType: Self.foreignOwnerType(
                                    in: reference,
                                    baseName: baseName
                                )
                            ),
                            location: location
                        )
                    )
                }
                continue
            }
            guard let marker = line.range(of: " = function_ref @"),
                  let separator = line.range(of: " : $", range: marker.upperBound..<line.endIndex)
            else { continue }
            let symbol = String(line[marker.upperBound..<separator.lowerBound])
            let loweredType = debugMetadataStrippedSuffix(
                String(line[separator.upperBound...])
            )
            let token = line[..<marker.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard symbol.hasPrefix("$s"),
                  token.hasPrefix("%"),
                  !loweredType.isEmpty,
                  !ReleaseCompiler.ImplementationFingerprint
                    .isDefaultArgumentGenerator(symbol),
                  baseName == "init" || symbol.contains(baseName),
                  allowsGlobalFunction || symbol.contains(owner)
            else { continue }
            functionCandidates.append(
                .init(
                    call: .init(
                        referenceToken: token,
                        symbol: symbol,
                        loweredType: loweredType
                    ),
                    location: location
                )
            )
        }

        func selected(from values: [Candidate]) -> ImportedSILCall? {
            let unique = Array(Set(values))
            if let sourceLocation {
                let exact = Set(unique.compactMap { candidate -> ImportedSILCall? in
                    guard candidate.location?.line == sourceLocation.line,
                          candidate.location?.column == sourceLocation.column
                    else { return nil }
                    return candidate.call
                })
                if exact.count == 1 { return exact.first }
                let lineMatches = Set(unique.compactMap { candidate -> ImportedSILCall? in
                    candidate.location?.line == sourceLocation.line ? candidate.call : nil
                })
                if lineMatches.count == 1 { return lineMatches.first }
            }
            let calls = Set(unique.map(\.call))
            return calls.count == 1 ? calls.first : nil
        }
        return selected(from: methodCandidates) ?? selected(from: functionCandidates)
    }

    private func nominalBaseName(_ raw: String) -> String {
        let nominal = String(raw.prefix { $0 != "<" && $0 != "?" })
        return nominal.split(separator: ".").last.map(String.init) ?? nominal
    }

    private func foreignApplyGenericArguments(
        for token: String,
        in body: String
    ) -> [String] {
        var specializations = Set<[String]>()
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            for operation in ["apply", "try_apply"] {
                let marker = "\(operation) \(token)<"
                guard let start = line.range(of: marker) else { continue }
                let argumentStart = start.upperBound
                var depth = 1
                var cursor = argumentStart
                while cursor < line.endIndex {
                    switch line[cursor] {
                    case "<": depth += 1
                    case ">":
                        depth -= 1
                        if depth == 0 {
                            let raw = String(line[argumentStart..<cursor])
                            let arguments = splitPhysicalTypeList(raw)
                            if !arguments.isEmpty { specializations.insert(arguments) }
                            cursor = line.endIndex
                            continue
                        }
                    default: break
                    }
                    cursor = line.index(after: cursor)
                }
            }
        }
        return specializations.count == 1 ? specializations.first! : []
    }

    private func appliedDeclaration(
        in expression: [String: Any]
    ) -> [String: Any]? {
        if let declaration = expression["decl"] as? [String: Any],
           let reference = expression["function_ref"] as? [String: Any],
           reference["apply_level"] as? String == "single_apply" {
            return declaration
        }
        for key in ["fn", "sub_expr", "rhs"] {
            if let child = expression[key] as? [String: Any],
               let declaration = appliedDeclaration(in: child) {
                return declaration
            }
        }
        return nil
    }

    private func importedGlobalFunctionOwner(usr: String) -> String {
        guard usr.hasPrefix("s:") else { return "__C" }
        let suffix = usr.dropFirst(2)
        let digits = suffix.prefix(while: \.isNumber)
        guard let length = Int(digits), length > 0 else { return "Swift" }
        let start = suffix.index(suffix.startIndex, offsetBy: digits.count)
        guard let end = suffix.index(
            start,
            offsetBy: length,
            limitedBy: suffix.endIndex
        ), start < end else {
            return "Swift"
        }
        let module = String(suffix[start..<end])
        return Self.isSwiftIdentifier(module) ? module : "Swift"
    }

    private func implicitReceiver(
        in expression: [String: Any]
    ) -> [String: Any]? {
        guard let arguments = expression["args"] as? [String: Any],
              let values = arguments["args"] as? [[String: Any]],
              values.count == 1
        else { return nil }
        return values[0]["expr"] as? [String: Any]
    }

    private func recordImportedEnumCase(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard let functionExpression = expression["fn"] as? [String: Any],
              let declaration = functionExpression["decl"] as? [String: Any],
              let usr = declaration["decl_usr"] as? String,
              usr.hasPrefix("c:@E@"),
              let rawCaseName = declaration["base_name"] as? String,
              let caseName = Core.SwiftName.normalizedIdentifier(rawCaseName),
              let ownerType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              )
        else { return }
        let expectedLocation = sourceRange(in: expression).flatMap {
            self.sourceLocation(atUTF8Offset: $0.start, in: source)
        }
        guard let reference = enumCaseReference(
            in: function,
            caseName: caseName,
            astOwnerType: ownerType,
            sourceLocation: expectedLocation
        ), let canonicalOwner = enumOwner(in: reference)
        else { return }

        types.append(
            importedType(
                canonicalName: canonicalOwner,
                swiftType: canonicalOwner,
                kind: .enumeration,
                aliases: canonicalOwner == ownerType ? [] : [ownerType],
                representation: .rawRepresentable,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        )
        operations.append(
            .init(
                silReferences: [reference],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .staticGetter,
                ownerType: canonicalOwner,
                baseName: caseName,
                argumentLabels: [],
                parameterSwiftTypes: [],
                resultSwiftType: canonicalOwner,
                requiresMainActor: false
            )
        )
    }

    private func recordImportedGlobalMember(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard expression["_kind"] as? String == "member_ref_expr",
              let declaration = expression["decl"] as? [String: Any],
              let usr = declaration["decl_usr"] as? String,
              usr.hasPrefix("c:@"),
              !usr.hasPrefix("c:@E@"),
              !usr.contains("(py)"),
              let rawBaseName = declaration["base_name"] as? String,
              let baseName = Core.SwiftName.normalizedIdentifier(rawBaseName),
              let symbol = usr.split(separator: "@").last.map(String.init),
              let physicalType = importedGlobalType(
                  symbol: symbol,
                  in: function.body
              ),
              FrontendReceipt.ValueTypeParser.parse(
                  physicalType,
                  allowVoid: true
              ) == nil
        else { return }

        let astType = importedSwiftType(expression["type"], demangled: demangled)
            ?? physicalType
        let aliases = astType == physicalType ? [] : [astType]
        types.append(
            importedType(
                canonicalName: physicalType,
                swiftType: physicalType,
                kind: .value,
                aliases: aliases,
                representation: .opaqueValue,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        )
        operations.append(
            .init(
                silReferences: [CanonicalSIL.NativeBridgeSymbols.importedGlobal(
                    symbol: symbol,
                    loweredType: physicalType
                )],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .staticGetter,
                ownerType: physicalType,
                baseName: baseName,
                argumentLabels: [],
                parameterSwiftTypes: [],
                resultSwiftType: physicalType,
                requiresMainActor: requiresMainActor
            )
        )
    }

    private func importedGlobalType(symbol: String, in body: String) -> String? {
        let markers = [
            "global_addr @\(symbol) : $*",
            "global_value @\(symbol) : $",
        ]
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let marker = markers.first(where: line.contains),
                  let range = line.range(of: marker)
            else { continue }
            let type = line[range.upperBound...]
                .split(separator: " ", maxSplits: 1).first.map(String.init)
                ?? ""
            if !type.isEmpty { return normalizeImportedTypeSpelling(type) }
        }
        return nil
    }

    private func recordImportedOptionSetArrayLiteral(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard let initializer = expression["initializer"] as? [String: Any],
              let usr = initializer["decl_usr"] as? String,
              usr == CanonicalSIL.NativeBridgeSymbols.optionSetArrayLiteralUSR,
              function.body.contains(
                  "function_ref @\(CanonicalSIL.NativeBridgeSymbols.optionSetArrayLiteralSILSymbol) "
              ),
              let ownerType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              )
        else { return }

        types.append(
            importedType(
                canonicalName: ownerType,
                swiftType: ownerType,
                kind: .value,
                representation: .rawRepresentable,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .initializer,
                ownerType: ownerType,
                baseName: "init",
                argumentLabels: ["_"],
                parameterSwiftTypes: ["[\(ownerType)]"],
                resultSwiftType: ownerType,
                requiresMainActor: false,
                compilerOperation: .optionSetArrayLiteralInitializer
            )
        )
    }

    private func recordImportedOptionSetMember(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard let declaration = expression["decl"] as? [String: Any],
              let usr = declaration["decl_usr"] as? String,
              usr.hasPrefix("c:@E@"),
              let astOwner = importedSwiftType(expression["type"], demangled: demangled),
              let sourceRange = sourceRange(in: expression),
              let location = sourceLocation(atUTF8Offset: sourceRange.start, in: source),
              let construction = rawValueConstruction(in: function, at: location)
        else { return }

        types.append(
            importedType(
                canonicalName: construction.ownerType,
                swiftType: construction.ownerType,
                kind: .value,
                aliases: construction.ownerType == astOwner ? [] : [astOwner],
                representation: .rawRepresentable,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .initializer,
                ownerType: construction.ownerType,
                baseName: "init",
                argumentLabels: ["rawValue"],
                parameterSwiftTypes: [construction.rawType],
                resultSwiftType: construction.ownerType,
                requiresMainActor: false,
                compilerOperation: .rawValueInitializer
            )
        )
    }

    private func recordImportedUpcast(
        _ expression: [String: Any],
        function _: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) {
        guard let operand = expression["sub_expr"] as? [String: Any],
              let sourceType = importedSwiftType(operand["type"], demangled: demangled),
              let targetType = importedSwiftType(expression["type"], demangled: demangled),
              sourceType != targetType
        else { return }

        recordImportedTypeSurface(
            rawMangledType: operand["type"],
            spelling: sourceType,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        recordImportedTypeSurface(
            rawMangledType: expression["type"],
            spelling: targetType,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .nativeUpcast,
                ownerType: targetType,
                baseName: "upcast",
                argumentLabels: ["_"],
                parameterSwiftTypes: [sourceType],
                resultSwiftType: targetType,
                requiresMainActor: requiresMainActor,
                compilerOperation: .nativeUpcast
            )
        )
    }

    private struct RawValueConstruction: Hashable {
        var ownerType: String
        var rawType: String
        var location: Core.SourceLocation?
    }

    private func rawValueConstruction(
        in function: CanonicalSIL.Function,
        at sourceLocation: Core.SourceLocation
    ) -> RawValueConstruction? {
        let lines = function.body.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var structTypes: [String: String] = [:]
        var parsed: [(result: String, type: String, operand: String, line: Int)] = []
        for (offset, line) in lines.enumerated() {
            guard let instruction = singlePayloadStruct(in: line) else { continue }
            structTypes[instruction.result] = instruction.type
            parsed.append((instruction.result, instruction.type, instruction.operand, offset + 1))
        }
        let rawTypes: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        ]
        let candidates = parsed.compactMap { item -> RawValueConstruction? in
            guard let rawType = structTypes[item.operand],
                  rawTypes.contains(rawType),
                  !rawTypes.contains(item.type)
            else { return nil }
            return .init(
                ownerType: item.type,
                rawType: "Swift.\(rawType)",
                location: function.sourceLocation(atBodyLine: item.line)
            )
        }
        let located = Set(candidates.filter {
            $0.location?.line == sourceLocation.line
                && $0.location?.column == sourceLocation.column
        })
        if located.count == 1 { return located.first }
        let unique = Set(candidates.map { candidate in
            RawValueConstruction(
                ownerType: candidate.ownerType,
                rawType: candidate.rawType,
                location: nil
            )
        })
        return unique.count == 1 ? unique.first : nil
    }

    private func singlePayloadStruct(
        in rawLine: String
    ) -> (result: String, type: String, operand: String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let marker = line.range(of: " = struct $"),
              let argument = line.range(of: " (", options: .backwards),
              marker.upperBound <= argument.lowerBound,
              line.hasSuffix(")")
        else { return nil }
        let result = String(line[..<marker.lowerBound])
        let type = String(line[marker.upperBound..<argument.lowerBound])
        let operand = String(line[argument.upperBound..<line.index(before: line.endIndex)])
        guard result.first == "%", operand.first == "%",
              !result.dropFirst().isEmpty,
              !operand.dropFirst().isEmpty,
              result.dropFirst().allSatisfy(\.isNumber),
              operand.dropFirst().allSatisfy(\.isNumber),
              !type.isEmpty,
              !operand.contains(",")
        else { return nil }
        return (result, type, operand)
    }

    private func recordAnyObjectErasure(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) {
        guard let target = importedSwiftType(expression["type"], demangled: demangled),
              ["Any", "Swift.Any"].contains(target),
              let operand = expression["sub_expr"] as? [String: Any],
              let sourceType = importedSwiftType(operand["type"], demangled: demangled),
              function.body.contains("init_existential_ref"),
              function.body.contains("$AnyObject")
        else { return }
        let swiftValueType = FrontendReceipt.ValueTypeParser.parse(
            sourceType,
            allowVoid: false,
            nativeTypes: [:]
        )
        let boxesSwiftValue = swiftValueType?
            .isOrdinaryNativeImportBridgeValue == true
        let operationModules = boxesSwiftValue ? ["Swift"] : importedModules
        types.append(
            importedType(
                canonicalName: "Swift.AnyObject",
                swiftType: "Swift.AnyObject",
                kind: .reference,
                aliases: ["AnyObject"],
                representation: .reference,
                source: source,
                importedModules: operationModules,
                requiresMainActor: boxesSwiftValue ? false : requiresMainActor
            )
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: operationModules,
                dispatch: boxesSwiftValue ? .anyObjectBridge : .nativeUpcast,
                ownerType: "Swift.AnyObject",
                baseName: boxesSwiftValue ? "bridge" : "upcast",
                argumentLabels: ["_"],
                parameterSwiftTypes: [boxesSwiftValue ? "Swift.Any" : sourceType],
                resultSwiftType: "Swift.AnyObject",
                requiresMainActor: boxesSwiftValue ? false : requiresMainActor,
                compilerOperation: boxesSwiftValue ? .anyObjectBridge : .nativeUpcast
            )
        )
    }

    private func recordAnyObjectBridge(
        function: CanonicalSIL.Function,
        source: SourceState,
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) {
        guard function.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).contains(where: {
            CanonicalSIL.AnyObjectBridge.isReferenceInstruction(String($0))
        }) else { return }
        types.append(
            importedType(
                canonicalName: "Swift.AnyObject",
                swiftType: "Swift.AnyObject",
                kind: .reference,
                aliases: ["AnyObject"],
                representation: .reference,
                source: source,
                importedModules: ["Swift"],
                requiresMainActor: false
            )
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: ["Swift"],
                dispatch: .anyObjectBridge,
                ownerType: "Swift.AnyObject",
                baseName: "bridge",
                argumentLabels: ["_"],
                parameterSwiftTypes: ["Swift.Any"],
                resultSwiftType: "Swift.AnyObject",
                requiresMainActor: false,
                compilerOperation: .anyObjectBridge
            )
        )
    }

    private func recordSelectorSurface(
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool,
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) {
        let spelling = "ObjectiveC.Selector"
        types.append(
            importedType(
                canonicalName: spelling,
                swiftType: spelling,
                kind: .value,
                aliases: ["Selector"],
                representation: .opaqueValue,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor
            )
        )
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .initializer,
                ownerType: spelling,
                baseName: "init",
                argumentLabels: ["_"],
                parameterSwiftTypes: ["Swift.String"],
                resultSwiftType: spelling,
                requiresMainActor: requiresMainActor,
                compilerOperation: .selectorInitializer
            )
        )
    }

    func isSelectorType(_ raw: String) -> Bool {
        ["Selector", "ObjectiveC.Selector"].contains(raw)
    }

    private func recordImportedTypeSurface(
        rawMangledType: Any?,
        spelling: String,
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool,
        types: inout [ImportedNativeType]
    ) {
        guard let mangled = rawMangledType as? String else { return }
        types += importedClangTypealiasTypes(
            inMangledType: mangled,
            source: source,
            importedModules: importedModules
        )
        let objectiveCClasses = Self.objectiveCClassNames(
            inMangledType: mangled
        )
        let exactObjectiveCIdentity = Self.objectiveCNominalIdentity(
            inMangledType: mangled
        )
        let logicalNominal = importedNativeNominal(in: spelling)
        let exactObjectiveCReference: ImportedNativeType? = {
            guard let runtimeName = exactObjectiveCIdentity,
                  let logicalNominal,
                  !logicalNominal.contains("<"),
                  importedNominalRepresentation(
                      mangled,
                      spelling: logicalNominal
                  ) == .reference
            else { return nil }
            let moduleRelative = logicalNominal.split(separator: ".")
                .last.map(String.init) ?? logicalNominal
            return importedType(
                canonicalName: runtimeName,
                swiftType: logicalNominal,
                kind: .reference,
                aliases: Array(Set([
                    runtimeName, "__C.\(runtimeName)", moduleRelative,
                ])).sorted(),
                representation: .reference,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor
            )
        }()
        if let exactObjectiveCReference {
            types.append(exactObjectiveCReference)
        } else if isImportedMangledType(
            mangled,
            importedModules: importedModules
        ) {
            _ = recordImportedNominalType(
                rawMangledType: rawMangledType,
                spelling: spelling,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor,
                types: &types
            )
        }
        let unavailableGenericBase = spelling.contains("<")
            ? nominalBaseName(spelling) : nil
        for name in objectiveCClasses
        where name != exactObjectiveCReference?.canonicalName
                && name != unavailableGenericBase {
            types.append(
                importedType(
                    canonicalName: name,
                    swiftType: name,
                    kind: .reference,
                    representation: .reference,
                    source: source,
                    importedModules: importedModules,
                    requiresMainActor: requiresMainActor
                )
            )
        }
        if spelling == "Swift.AnyObject" || spelling == "Swift.AnyObject?" {
            types.append(
                importedType(
                    canonicalName: "Swift.AnyObject",
                    swiftType: "Swift.AnyObject",
                    kind: .reference,
                    aliases: ["AnyObject"],
                    representation: .reference,
                    source: source,
                    importedModules: importedModules,
                    requiresMainActor: requiresMainActor
                )
            )
        }
    }

    @discardableResult
    private func recordImportedNominalType(
        rawMangledType: Any?,
        spelling: String,
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool,
        types: inout [ImportedNativeType]
    ) -> ImportedNativeType.Representation? {
        guard let type = importedNativeType(
            rawMangledType: rawMangledType,
            spelling: spelling,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor
        ) else { return nil }
        types.append(type)
        return type.representation
    }

    private func swiftPropertyReference(
        usr: String,
        accessor: NativeImportDiscovery.Dispatch,
        in body: String
    ) -> String? {
        guard usr.hasPrefix("s:") else { return nil }
        var mangling = String(usr.dropFirst(2))
        guard let property = mangling.range(of: "vp", options: .backwards),
              property.upperBound == mangling.endIndex
                || mangling[property.upperBound...] == "Z"
        else { return nil }
        mangling.replaceSubrange(
            property,
            with: accessor == .instanceSetter ? "vs" : "vg"
        )
        let symbol = "$s" + mangling
        return body.contains("function_ref @\(symbol) ") ? symbol : nil
    }

    private func objectiveCPropertyOwner(_ usr: String) -> String? {
        guard usr.hasPrefix("c:objc"),
              let propertyMarker = ["(cpy)", "(py)"].compactMap({
                  usr.range(of: $0)
              }).min(by: { $0.lowerBound < $1.lowerBound }),
              let ownerMarker = ["(cs)", "(pl)"].compactMap({
                  usr.range(of: $0)
              }).filter({ $0.upperBound <= propertyMarker.lowerBound })
                .min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let ownerType = String(usr[ownerMarker.upperBound..<propertyMarker.lowerBound])
        return Self.isSwiftIdentifier(ownerType) ? ownerType : nil
    }

    private func importedMetatypeInstanceType(
        _ rawType: Any?,
        demangled: [String: String]
    ) -> String? {
        guard let mangled = rawType as? String,
              var value = demangled[mangled]
        else { return nil }
        value = normalizeImportedTypeSpelling(value)
        guard value.hasSuffix(".Type") else { return nil }
        value.removeLast(".Type".count)
        return value.isEmpty ? nil : value
    }

    private func importedSwiftType(
        _ rawType: Any?,
        demangled: [String: String]
    ) -> String? {
        guard let mangled = rawType as? String,
              var value = demangled[mangled]
        else { return nil }
        value = normalizeImportedTypeSpelling(value)
        guard !value.isEmpty,
              !value.hasSuffix(".Type")
        else { return nil }
        return value
    }

    /// Accepts only a nominal imported type or Optional wrappers around one.
    /// Ownership attributes, functions, collections, and arbitrary generic
    /// surfaces cannot become source-level aliases through this path.
    private func importedPhysicalNominalSpelling(_ raw: String) -> String? {
        let spelling = normalizeImportedTypeSpelling(
            strippingPhysicalOwnership(raw)
        )
        guard let nominal = importedNativeNominal(in: spelling) else {
            return nil
        }
        let components = nominal.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  Self.isSwiftIdentifier(String($0))
              })
        else { return nil }
        return spelling
    }

    private func normalizeImportedTypeAliases(
        in operations: [ImportedOperation],
        types: [ImportedNativeType]
    ) throws -> [ImportedOperation] {
        var aliases: [
            String: (
                swiftType: String,
                canonicalName: String,
                representation: ImportedNativeType.Representation,
                aliases: [String]
            )
        ] = [:]
        for type in types {
            for alias in Set([type.canonicalName, type.swiftType] + type.aliases) {
                if let existing = aliases[alias],
                   existing.swiftType != type.swiftType {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported type alias \(alias) resolves to both "
                            + "\(existing.canonicalName) as \(existing.swiftType) "
                            + "[\(existing.representation.rawValue); "
                            + "aliases=\(existing.aliases)] and "
                            + "\(type.canonicalName) as \(type.swiftType) "
                            + "[\(type.representation.rawValue); "
                            + "aliases=\(type.aliases)]"
                    )
                }
                aliases[alias] = (
                    type.swiftType,
                    type.canonicalName,
                    type.representation,
                    type.aliases
                )
            }
        }
        let swiftTypes = aliases.mapValues(\.swiftType)
        return operations.map {
            applyingSwiftTypeAliases($0, aliases: swiftTypes)
        }
    }

    private func enumCaseReference(
        in function: CanonicalSIL.Function,
        caseName: String,
        astOwnerType: String,
        sourceLocation: Core.SourceLocation?
    ) -> String? {
        struct Candidate: Hashable {
            var reference: String
            var location: Core.SourceLocation?
        }

        let candidates = Array(Set(
            function.body.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().compactMap { offset, rawLine -> Candidate? in
            let line = String(rawLine)
            guard line.contains(" = enum $"),
                  let hash = line.firstIndex(of: "#"),
                  let suffix = line[hash...].range(of: "!enumelt")
            else { return nil }
            let reference = String(line[hash..<suffix.upperBound])
            guard enumCaseName(in: reference) == caseName else { return nil }
            return Candidate(
                reference: reference,
                location: function.sourceLocation(atBodyLine: offset + 1)
            )
        })).sorted { lhs, rhs in
            lhs.reference < rhs.reference
        }

        if let sourceLocation {
            let located = Set(candidates.compactMap { candidate -> String? in
                guard candidate.location?.line == sourceLocation.line,
                      candidate.location?.column == sourceLocation.column
                else { return nil }
                return candidate.reference
            })
            if located.count == 1 { return located.first }
        }

        let structurallyMatched = Set(candidates.compactMap { candidate -> String? in
            guard enumOwner(in: candidate.reference)?
                .replacingOccurrences(of: ".", with: "")
                == astOwnerType.replacingOccurrences(of: ".", with: "")
            else { return nil }
            return candidate.reference
        })
        if structurallyMatched.count == 1 { return structurallyMatched.first }

        let unique = Set(candidates.map(\.reference))
        return unique.count == 1 ? unique.first : nil
    }

    private func sourceLocation(
        atUTF8Offset offset: Int,
        in source: SourceState
    ) -> Core.SourceLocation? {
        guard offset >= 0, offset <= source.contents.count else { return nil }
        let prefix = source.contents.prefix(offset)
        var line = 1
        var column = 1
        for byte in prefix {
            if byte == UInt8(ascii: "\n") {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return .init(file: source.url.path, line: line, column: column)
    }

    private func enumOwner(in reference: String) -> String? {
        guard reference.hasPrefix("#"),
              reference.hasSuffix("!enumelt")
        else { return nil }
        let body = reference.dropFirst().dropLast("!enumelt".count)
        guard let separator = body.lastIndex(of: ".") else { return nil }
        let owner = String(body[..<separator])
        return owner.isEmpty ? nil : owner
    }

    private func enumCaseName(in reference: String) -> String? {
        guard reference.hasPrefix("#"),
              reference.hasSuffix("!enumelt")
        else { return nil }
        let body = reference.dropFirst().dropLast("!enumelt".count)
        guard let separator = body.lastIndex(of: ".") else { return nil }
        return Core.SwiftName.normalizedIdentifier(
            String(body[body.index(after: separator)...])
        )
    }

    private struct ForeignMemberTypeEvidence: Hashable {
        var ownerType: String
        var loweredType: String
    }

    private func foreignMemberTypeEvidence(
        in function: CanonicalSIL.Function,
        baseName: String,
        marker: String,
        sourceLocation: Core.SourceLocation?
    ) -> ForeignMemberTypeEvidence? {
        struct Candidate: Hashable {
            var evidence: ForeignMemberTypeEvidence
            var location: Core.SourceLocation?
        }

        let candidates = Set(function.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().compactMap { offset, rawLine -> Candidate? in
                let line = String(rawLine)
                guard line.contains("_method "),
                      let hash = line.firstIndex(of: "#"),
                      let separator = line[hash...].range(of: " : "),
                      let loweredMarker = line.range(of: ", $", options: .backwards)
                else { return nil }
                let reference = String(line[hash..<separator.lowerBound])
                guard Self.foreignReference(reference, hasBaseName: baseName),
                      reference.contains("!\(marker)"),
                      reference.hasSuffix(".foreign"),
                      let owner = Self.foreignOwnerType(
                          in: reference,
                          baseName: baseName
                      )
                else { return nil }
                return .init(
                    evidence: .init(
                        ownerType: owner,
                        loweredType: debugMetadataStrippedSuffix(
                            String(line[loweredMarker.upperBound...])
                        )
                    ),
                    location: function.sourceLocation(atBodyLine: offset + 1)
                )
            })
        if let sourceLocation {
            let exact = Set(candidates.compactMap { candidate in
                candidate.location == sourceLocation ? candidate.evidence : nil
            })
            if exact.count == 1 { return exact.first }
            let lineMatches = Set(candidates.compactMap { candidate in
                candidate.location?.line == sourceLocation.line
                    ? candidate.evidence : nil
            })
            if lineMatches.count == 1 { return lineMatches.first }
        }
        let evidence = Set(candidates.map(\.evidence))
        return evidence.count == 1 ? evidence.first : nil
    }

    static func foreignMemberReferences(
        in body: String,
        ownerType: String,
        baseName: String,
        marker: String
    ) -> [String] {
        return Array(Set(body.split(separator: "\n").compactMap { rawLine -> String? in
            let line = String(rawLine)
            guard line.contains("_method "),
                  let hash = line.firstIndex(of: "#"),
                  let separator = line[hash...].range(of: " : "),
                  let loweredMarker = line.range(of: ", $", options: .backwards)
            else { return nil }
            let reference = String(line[hash..<separator.lowerBound])
            guard reference.hasPrefix("#\(ownerType)."),
                  foreignReference(reference, hasBaseName: baseName),
                  reference.contains("!\(marker)"),
                  reference.hasSuffix(".foreign")
            else { return nil }
            return CanonicalSIL.NativeBridgeSymbols.foreignCall(
                reference: reference,
                loweredType: String(line[loweredMarker.upperBound...])
            )
        })).sorted()
    }

    private static func foreignReference(
        _ reference: String,
        hasBaseName baseName: String
    ) -> Bool {
        reference.contains(".\(baseName)!")
            || reference.contains(".`\(baseName)`!")
    }

    private static func foreignOwnerType(
        in reference: String,
        baseName: String
    ) -> String? {
        guard reference.hasPrefix("#") else { return nil }
        for marker in [".\(baseName)!", ".`\(baseName)`!"] {
            guard let range = reference.range(of: marker) else { continue }
            let start = reference.index(after: reference.startIndex)
            let owner = String(reference[start..<range.lowerBound])
            guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner) else {
                return nil
            }
            return owner
        }
        return nil
    }

    private func renamedForeignMemberReferences(
        in function: CanonicalSIL.Function,
        baseName: String,
        marker: String,
        sourceLocation: Core.SourceLocation?
    ) -> [String] {
        struct Candidate: Hashable {
            var symbol: String
            var location: Core.SourceLocation?
        }

        let candidates = Array(Set(function.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().compactMap { offset, rawLine -> Candidate? in
            let line = String(rawLine)
            guard line.contains("_method "),
                  let hash = line.firstIndex(of: "#"),
                  let separator = line[hash...].range(of: " : "),
                  let loweredMarker = line.range(of: ", $", options: .backwards)
            else { return nil }
            let reference = String(line[hash..<separator.lowerBound])
            guard Self.foreignReference(reference, hasBaseName: baseName),
                  reference.contains("!\(marker)"),
                  reference.hasSuffix(".foreign")
            else { return nil }
            return Candidate(
                symbol: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: reference,
                    loweredType: String(line[loweredMarker.upperBound...])
                ),
                location: function.sourceLocation(atBodyLine: offset + 1)
            )
        }))
        if let sourceLocation {
            let exact = Set(candidates.compactMap { candidate -> String? in
                guard candidate.location?.line == sourceLocation.line,
                      candidate.location?.column == sourceLocation.column
                else { return nil }
                return candidate.symbol
            })
            if exact.count == 1 { return exact.sorted() }
            let lineMatches = Set(candidates.compactMap { candidate -> String? in
                candidate.location?.line == sourceLocation.line
                    ? candidate.symbol : nil
            })
            if lineMatches.count == 1 { return lineMatches.sorted() }
        }
        let symbols = Set(candidates.map(\.symbol))
        return symbols.count == 1 ? symbols.sorted() : []
    }

    private func mergeOperationTypes(
        _ values: [ImportedNativeType]
    ) throws -> [ImportedNativeType] {
        try mergeImportedNativeTypes(discoveredTypes: [], operationTypes: values)
    }

    func mergeImportedOperations(
        _ values: [ImportedOperation]
    ) throws -> [ImportedOperation] {
        var byIdentity: [ImportedOperationIdentity: ImportedOperation] = [:]
        for value in values {
            let identity = ImportedOperationIdentity(value)
            if var existing = byIdentity[identity] {
                guard existing.argumentLabels == value.argumentLabels,
                      existing.mayThrow == value.mayThrow,
                      existing.compilerOperation == value.compilerOperation
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported operation \(value.ownerType).\(value.baseName) "
                            + "has conflicting typed call sites"
                    )
                }
                switch (existing.isolationEvidence, value.isolationEvidence) {
                case (.importedDeclaration, .importedDeclaration):
                    guard existing.requiresMainActor == value.requiresMainActor else {
                        throw FrontendReceipt.Error.invalidRequest(
                            "imported operation \(value.ownerType).\(value.baseName) "
                                + "has conflicting declaration isolation"
                        )
                    }
                case (.importedDeclaration, .enclosingContext):
                    break
                case (.enclosingContext, .importedDeclaration):
                    existing.requiresMainActor = value.requiresMainActor
                    existing.isolationEvidence = .importedDeclaration
                case (.enclosingContext, .enclosingContext):
                    // A source call made from MainActor supplies conservative
                    // evidence until an imported declaration is measured.
                    existing.requiresMainActor = existing.requiresMainActor
                        || value.requiresMainActor
                }
                existing.silReferences = Array(Set(
                    existing.silReferences + value.silReferences
                )).sorted()
                existing.witnessFunctions = Array(Set(
                    existing.witnessFunctions + value.witnessFunctions
                )).sorted()
                existing.importedModules = Array(Set(
                    existing.importedModules + value.importedModules
                )).sorted()
                existing.sourceFileLogicalID = min(
                    existing.sourceFileLogicalID,
                    value.sourceFileLogicalID
                )
                byIdentity[identity] = existing
            } else {
                var canonical = value
                canonical.silReferences = Array(Set(value.silReferences)).sorted()
                canonical.witnessFunctions = Array(Set(
                    value.witnessFunctions
                )).sorted()
                canonical.importedModules = Array(Set(value.importedModules)).sorted()
                byIdentity[identity] = canonical
            }
        }
        return byIdentity.values.sorted {
            let lhs = ($0.dispatch.rawValue, $0.ownerType, $0.baseName,
                       $0.argumentLabels.joined(separator: ":") + "|"
                           + $0.parameterSwiftTypes.joined(separator: ",") + "|"
                           + ($0.invocationParameterSwiftTypes
                                ?? $0.parameterSwiftTypes).joined(separator: ","),
                       $0.sourceFileLogicalID)
            let rhs = ($1.dispatch.rawValue, $1.ownerType, $1.baseName,
                       $1.argumentLabels.joined(separator: ":") + "|"
                           + $1.parameterSwiftTypes.joined(separator: ",") + "|"
                           + ($1.invocationParameterSwiftTypes
                                ?? $1.parameterSwiftTypes).joined(separator: ","),
                       $1.sourceFileLogicalID)
            return lhs < rhs
        }
    }

    func applyingSwiftTypeAliases(
        _ operation: ImportedOperation,
        aliases: [String: String]
    ) -> ImportedOperation {
        var result = operation
        result.ownerType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(in: operation.ownerType, aliases: aliases)
        result.parameterSwiftTypes = operation.parameterSwiftTypes.map {
            FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                in: $0,
                aliases: aliases
            )
        }
        result.invocationParameterSwiftTypes = operation
            .invocationParameterSwiftTypes?.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: aliases
                )
            }
        result.resultSwiftType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(
                in: operation.resultSwiftType,
                aliases: aliases
            )
        return result
    }
}
