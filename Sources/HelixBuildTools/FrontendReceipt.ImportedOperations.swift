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
        }

        enum IsolationEvidence: Hashable, Sendable {
            /// The declaration was unavailable, so isolation is conservatively
            /// inherited from the source context that performed the call.
            case enclosingContext
            /// The captured SDK declaration supplied the isolation contract.
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
        var resultSwiftType: String
        var requiresMainActor: Bool
        var compilerOperation: CompilerOperation? = nil
        var isolationEvidence: IsolationEvidence = .enclosingContext
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

        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ],
                  let items = document["items"] as? [Any]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "imported operation discovery source does not map to the requested source set"
                )
            }
            let modules = imports(in: items).filter { $0 != moduleName }
            guard !modules.isEmpty else { continue }
            try collectImportedOperations(
                items: items,
                inheritedMainActor: false,
                source: source,
                importedModules: modules,
                moduleName: moduleName,
                demangled: demangled,
                silFile: silFile,
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
        try operations.map { operation in
            let parameterTypes = try operation.parameterSwiftTypes.map { spelling in
                guard let type = FrontendReceipt.ValueTypeParser.parse(
                    spelling,
                    allowVoid: false,
                    nativeTypes: nativeTypes
                ) else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported operation \(operation.ownerType).\(operation.baseName) "
                            + "has unsupported parameter type \(spelling)"
                    )
                }
                return type
            }
            guard let resultType = FrontendReceipt.ValueTypeParser.parse(
                operation.resultSwiftType,
                allowVoid: true,
                nativeTypes: nativeTypes
            ) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported operation \(operation.ownerType).\(operation.baseName) "
                        + "has unsupported result type \(operation.resultSwiftType)"
                )
            }
            let silSymbols: [String]
            switch operation.compilerOperation {
            case nil:
                silSymbols = operation.silReferences
            case .rawValueInitializer:
                guard parameterTypes.count == 1,
                      case let .native(typeID) = resultType
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported raw-value initializer has an invalid frozen signature"
                    )
                }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.rawValueInitializer(for: typeID)]
            case .optionSetArrayLiteralInitializer:
                guard parameterTypes.count == 1,
                      case let .array(element) = parameterTypes[0],
                      case let .native(elementType) = element,
                      resultType == .native(elementType)
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported OptionSet array-literal initializer has an invalid frozen signature"
                    )
                }
                silSymbols = [
                    CanonicalSIL.NativeBridgeSymbols.optionSetArrayLiteralInitializer(
                        for: elementType
                    ),
                ]
            case .selectorInitializer:
                guard parameterTypes == [.string],
                      case let .native(typeID) = resultType
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported Selector initializer has an invalid frozen signature"
                    )
                }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.selectorInitializer(for: typeID)]
            case .nativeUpcast:
                guard parameterTypes.count == 1,
                      case let .native(sourceType) = parameterTypes[0],
                      case let .native(targetType) = resultType,
                      sourceType != targetType
                else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported native upcast has an invalid frozen signature"
                    )
                }
                silSymbols = [CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: sourceType,
                    to: targetType
                )]
            }
            guard let primarySymbol = silSymbols.first else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported operation has no exact SIL or compiler-operation symbol"
                )
            }
            let isolation = operation.requiresMainActor ? "MainActor" : nil
            let signature = Core.LoweredSignature(
                parameters: operation.parameterSwiftTypes,
                result: operation.resultSwiftType,
                isolation: isolation
            )
            let modulePrefix = moduleName + "."
            func generatedSpelling(_ canonical: String) -> String {
                canonical.hasPrefix(modulePrefix)
                    ? String(canonical.dropFirst(modulePrefix.count))
                    : canonical
            }
            let generatedOwnerType = generatedSpelling(operation.ownerType)
            let generatedParameterTypes = operation.parameterSwiftTypes.map(generatedSpelling)
            let generatedResultType = generatedSpelling(operation.resultSwiftType)
            let prefix = [moduleName, "HelixExternal", operation.ownerType]
            let canonicalCallee: String = switch operation.dispatch {
            case .initializer:
                (prefix + [
                    "init(\(operation.argumentLabels.joined(separator: ":")):)"
                ]).joined(separator: ".")
            case .nativeUpcast:
                (prefix + [
                    "upcast(from:\(operation.parameterSwiftTypes[0]))"
                ]).joined(separator: ".")
            case .instanceGetter, .staticGetter:
                (prefix + [operation.baseName, "get"]).joined(separator: ".")
            case .instanceSetter:
                (prefix + [operation.baseName, "set"]).joined(separator: ".")
            case .instanceValueSetter:
                (prefix + [operation.baseName, "mutate"]).joined(separator: ".")
            case .globalFunction, .staticMethod, .instanceMethod:
                (prefix + [operation.baseName, "call"]).joined(separator: ".")
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
                resultSwiftType: generatedResultType,
                importedModules: operation.importedModules,
                parameterTypes: parameterTypes,
                resultType: resultType,
                signature: signature,
                inferredEffects: .init(
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

    private func collectImportedOperations(
        items: [Any],
        inheritedMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        demangled: [String: String],
        silFile: CanonicalSIL.File,
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
                let symbol = "$s" + usr.dropFirst(2)
                guard let sil = silFile.function(mangledName: symbol) else {
                    throw FrontendReceipt.Error.missingSILFunction(symbol)
                }
                try visitImportedExpression(
                    body,
                    role: .value,
                    function: sil,
                    requiresMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    types: &types,
                    operations: &operations
                )
            }

            if let members = item["members"] as? [Any] {
                try collectImportedOperations(
                    items: members,
                    inheritedMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    demangled: demangled,
                    silFile: silFile,
                    types: &types,
                    operations: &operations
                )
            }
        }
    }

    private enum ImportedExpressionRole {
        case value
        case assignmentDestination
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
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        let kind = item["_kind"] as? String
        if kind == "call_expr" {
            try recordImportedSwiftCall(
                item,
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                moduleName: moduleName,
                demangled: demangled,
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
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
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
                function: function,
                requiresMainActor: requiresMainActor,
                source: source,
                importedModules: importedModules,
                demangled: demangled,
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
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard accessor == .instanceGetter || accessor == .instanceSetter,
              expression["_kind"] as? String == "member_ref_expr",
              let declaration = expression["decl"] as? [String: Any],
              let usr = declaration["decl_usr"] as? String,
              let baseName = declaration["base_name"] as? String,
              Self.isSwiftIdentifier(baseName),
              let propertyType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              ),
              let base = expression["base"] as? [String: Any]
        else { return }

        let staticOwner = importedMetatypeInstanceType(
            base["type"],
            demangled: demangled
        )
        let instanceOwner = importedSwiftType(
            base["type"],
            demangled: demangled
        )
        guard let receiverType = staticOwner ?? instanceOwner else { return }
        let isStatic = staticOwner != nil
        // The generated bridge currently models class-property reads but not
        // class-property mutation. Keep writes fail-closed until that physical
        // metatype ABI has an explicit NativeImport dispatch.
        guard !isStatic || accessor == .instanceGetter else { return }

        let marker = accessor == .instanceSetter ? "setter" : "getter"
        var references: [String]
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
                let expectedLocation = sourceRange(in: expression).flatMap {
                    sourceLocation(atUTF8Offset: $0.start, in: source)
                }
                references = renamedForeignMemberReferences(
                    in: function,
                    baseName: baseName,
                    marker: marker,
                    sourceLocation: expectedLocation
                )
            }
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
            dispatch = .staticGetter
            parameterTypes = []
            labels = []
            resultType = propertyType
        } else if accessor == .instanceSetter {
            dispatch = receiverRepresentation == .opaqueValue
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
                requiresMainActor: requiresMainActor
            )
        )
    }

    private struct ImportedSILCall: Hashable {
        var symbol: String
        var loweredType: String
    }

    private func recordImportedSwiftCall(
        _ expression: [String: Any],
        function: CanonicalSIL.Function,
        requiresMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        demangled: [String: String],
        types: inout [ImportedNativeType],
        operations: inout [ImportedOperation]
    ) throws {
        guard let functionExpression = expression["fn"] as? [String: Any],
              let declaration = appliedDeclaration(in: functionExpression),
              let usr = declaration["decl_usr"] as? String,
              (usr.hasPrefix("s:") || usr.hasPrefix("c:")),
              !usr.hasPrefix("s:s"),
              !usr.hasPrefix("s:\(moduleName.utf8.count)\(moduleName)"),
              let baseName = declaration["base_name"] as? String,
              Self.isSwiftIdentifier(baseName),
              var resultType = importedSwiftType(
                  expression["type"],
                  demangled: demangled
              )
        else { return }

        let explicitArguments = ((expression["args"] as? [String: Any])?["args"]
            as? [[String: Any]]) ?? []
        var argumentValues: [[String: Any]] = []
        var parameterTypes: [String] = []
        var argumentLabels: [String] = []
        for argument in explicitArguments {
            guard let value = argument["expr"] as? [String: Any],
                  let type = importedSwiftType(value["type"], demangled: demangled)
            else { return }
            argumentValues.append(value)
            parameterTypes.append(type)
            argumentLabels.append(argument["label"] as? String ?? "_")
        }

        let dispatch: NativeImportDiscovery.Dispatch
        let ownerType: String
        var receiver: [String: Any]?
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
            } else {
                guard let owner = importedSwiftType(
                    implicit["type"],
                    demangled: demangled
                ) else { return }
                dispatch = .instanceMethod
                ownerType = owner
                receiver = implicit
                parameterTypes.append(owner)
            }
        } else {
            dispatch = .globalFunction
            ownerType = importedGlobalFunctionOwner(usr: usr)
        }

        let call: ImportedSILCall
        if usr.hasPrefix("s:") {
            let symbol = "$s" + usr.dropFirst(2)
            guard function.body.contains("function_ref @\(symbol) ") else { return }
            call = .init(symbol: symbol, loweredType: "")
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
            ).filter { !$0.contains("_metatype ") }
            parameterTypes = parameterTypes.enumerated().map { index, logical in
                guard physicalParameters.indices.contains(index) else { return logical }
                return objcLogicalType(
                    logical,
                    physicalSpelling: physicalParameters[index]
                )
            }
            if let physicalResult = physicalResultSpelling(in: foreign.loweredType) {
                resultType = objcLogicalType(
                    resultType,
                    physicalSpelling: physicalResult
                )
            }
        }

        for (value, type) in zip(argumentValues, parameterTypes) {
            recordImportedTypeSurface(
                rawMangledType: value["type"],
                spelling: type,
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
        recordImportedTypeSurface(
            rawMangledType: expression["type"],
            spelling: resultType,
            source: source,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor,
            types: &types
        )
        if dispatch == .initializer || dispatch == .staticMethod {
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
                resultSwiftType: resultType,
                requiresMainActor: requiresMainActor
            )
        )
    }

    private func objcLogicalType(
        _ swiftType: String,
        physicalSpelling rawPhysical: String
    ) -> String {
        let logical = swiftType.replacingOccurrences(of: "Swift.", with: "")
        var physical = rawPhysical.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in_guaranteed ", "@out ",
            ] where physical.hasPrefix(prefix) {
                physical.removeFirst(prefix.count)
                physical = physical.trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        if physical == "()" { return "Swift.Void" }
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
        return normalizeImportedTypeSpelling(physical)
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
        for index in raw.indices {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">": angleDepth -= 1
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "," where angleDepth == 0 && parenthesisDepth == 0:
                result.append(
                    String(raw[start..<index]).trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            default: break
            }
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
                let loweredType = String(line[loweredMarker.upperBound...])
                let memberMatches = reference.hasPrefix("#\(owner).")
                    && (reference.contains(".\(baseName)!")
                        || (baseName == "init" && reference.contains(".init!")))
                let isPseudogeneric = loweredType.contains("@pseudogeneric")
                    || loweredType.contains("τ_")
                let genericArguments = foreignApplyGenericArguments(
                    for: token,
                    in: function.body
                )
                if memberMatches, !isPseudogeneric || !genericArguments.isEmpty {
                    let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
                        reference: reference,
                        loweredType: loweredType,
                        genericArguments: genericArguments
                    )
                    methodCandidates.append(
                        .init(
                            call: .init(symbol: symbol, loweredType: loweredType),
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
            let loweredType = String(line[separator.upperBound...])
            guard symbol.hasPrefix("$s"),
                  baseName == "init" || symbol.contains(baseName),
                  allowsGlobalFunction || symbol.contains(owner)
            else { continue }
            functionCandidates.append(
                .init(call: .init(symbol: symbol, loweredType: loweredType), location: location)
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
              let caseName = declaration["base_name"] as? String,
              Self.isSwiftIdentifier(caseName),
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
              let baseName = declaration["base_name"] as? String,
              Self.isSwiftIdentifier(baseName),
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
        operations.append(
            .init(
                silReferences: [],
                sourceFileLogicalID: source.logicalPath,
                importedModules: importedModules,
                dispatch: .nativeUpcast,
                ownerType: "Swift.AnyObject",
                baseName: "upcast",
                argumentLabels: ["_"],
                parameterSwiftTypes: [sourceType],
                resultSwiftType: "Swift.AnyObject",
                requiresMainActor: requiresMainActor,
                compilerOperation: .nativeUpcast
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

    private func isSelectorType(_ raw: String) -> Bool {
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
        let rootModule = spelling.split(separator: ".").first.map(String.init)
        let isImportedRoot = mangled.hasPrefix("$sSo")
            || rootModule.map(importedModules.contains) == true
        if isImportedRoot {
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
        for name in Self.objectiveCClassNames(inMangledType: mangled)
        where name != unavailableGenericBase {
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
        guard let discovered = importedNativeNominal(in: spelling),
              let mangled = rawMangledType as? String
        else { return nil }
        let canonical = isSelectorType(discovered)
            ? "ObjectiveC.Selector" : discovered
        guard let representation = importedNominalRepresentation(
            mangled,
            spelling: canonical
        ) else { return nil }
        let kind: InterfaceArchive.TypeKind = representation == .reference
            ? .reference : .value
        types.append(
            importedType(
                canonicalName: canonical,
                swiftType: canonical,
                kind: kind,
                representation: representation,
                source: source,
                importedModules: importedModules,
                requiresMainActor: requiresMainActor
            )
        )
        return representation
    }

    private func importedNominalRepresentation(
        _ rawMangledType: String,
        spelling: String
    ) -> ImportedNativeType.Representation? {
        var value = rawMangledType
        guard value.hasPrefix("$s"), value.hasSuffix("D") else { return nil }
        value.removeLast()
        while value.hasSuffix("Sg") { value.removeLast(2) }
        switch value.last {
        case "C": return .reference
        case "V", "O": return .opaqueValue
        case "G" where rawMangledType.hasPrefix("$sSo") && spelling.contains("<"):
            return .reference
        default: return nil
        }
    }

    private func importedNativeNominal(in raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("?") { value.removeLast() }
        for prefix in ["Swift.Optional<", "Optional<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return importedNativeNominal(
                in: String(value[start..<value.index(before: value.endIndex)])
            )
        }
        if value.hasPrefix("["), value.hasSuffix("]")
            || value.hasPrefix("Swift.Array<") || value.hasPrefix("Array<")
            || value.hasPrefix("Swift.Dictionary<") || value.hasPrefix("Dictionary<") {
            return nil
        }
        guard FrontendReceipt.ValueTypeParser.parse(
            value,
            allowVoid: true
        ) == nil,
              !value.contains(" -> "),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func swiftPropertyReference(
        usr: String,
        accessor: NativeImportDiscovery.Dispatch,
        in body: String
    ) -> String? {
        guard usr.hasPrefix("s:"), usr.hasSuffix("vp") else { return nil }
        let suffix = accessor == .instanceSetter ? "s" : "g"
        let symbol = "$s" + usr.dropFirst(2).dropLast() + suffix
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

    private func normalizeImportedTypeSpelling(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("(extension in "),
              let separator = value.range(of: "):") {
            value = String(value[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.replacingOccurrences(of: "__C.", with: "")
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
              !value.hasSuffix(".Type"),
              !value.contains(" -> ")
        else { return nil }
        return value
    }

    private func importedType(
        canonicalName: String,
        swiftType: String,
        kind: InterfaceArchive.TypeKind,
        aliases: [String] = [],
        representation: ImportedNativeType.Representation,
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool
    ) -> ImportedNativeType {
        .init(
            canonicalName: canonicalName,
            swiftType: swiftType,
            kind: kind,
            aliases: aliases,
            representation: representation,
            sourceFileLogicalID: source.logicalPath,
            importedModules: importedModules,
            requiresMainActor: requiresMainActor
        )
    }

    private func normalizeImportedTypeAliases(
        in operations: [ImportedOperation],
        types: [ImportedNativeType]
    ) throws -> [ImportedOperation] {
        var aliases: [String: String] = [:]
        for type in types {
            for alias in Set([type.canonicalName, type.swiftType] + type.aliases) {
                if let existing = aliases[alias], existing != type.swiftType {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported type alias \(alias) resolves to multiple Swift types"
                    )
                }
                aliases[alias] = type.swiftType
            }
        }
        return operations.map { operation in
            var normalized = operation
            normalized.ownerType = aliases[operation.ownerType] ?? operation.ownerType
            normalized.parameterSwiftTypes = operation.parameterSwiftTypes.map {
                aliases[$0] ?? $0
            }
            normalized.resultSwiftType = aliases[operation.resultSwiftType]
                ?? operation.resultSwiftType
            return normalized
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
            guard reference.hasSuffix(".\(caseName)!enumelt") else { return nil }
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

    static func foreignMemberReferences(
        in body: String,
        ownerType: String,
        baseName: String,
        marker: String
    ) -> [String] {
        let expectedPrefix = "#\(ownerType).\(baseName)!"
        return Array(Set(body.split(separator: "\n").compactMap { rawLine -> String? in
            let line = String(rawLine)
            guard line.contains("_method "),
                  let hash = line.firstIndex(of: "#"),
                  let separator = line[hash...].range(of: " : "),
                  let loweredMarker = line.range(of: ", $", options: .backwards)
            else { return nil }
            let reference = String(line[hash..<separator.lowerBound])
            guard reference.hasPrefix(expectedPrefix),
                  reference.contains("!\(marker)"),
                  reference.hasSuffix(".foreign")
            else { return nil }
            return CanonicalSIL.NativeBridgeSymbols.foreignCall(
                reference: reference,
                loweredType: String(line[loweredMarker.upperBound...])
            )
        })).sorted()
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
            guard reference.contains(".\(baseName)!"),
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
        try mergeImportedNativeTypes(references: [], operationTypes: values)
    }

    func mergeImportedOperations(
        _ values: [ImportedOperation]
    ) throws -> [ImportedOperation] {
        var byIdentity: [String: ImportedOperation] = [:]
        for value in values {
            let identity = [
                value.dispatch.rawValue,
                value.ownerType,
                value.baseName,
                value.parameterSwiftTypes.joined(separator: ","),
                value.resultSwiftType,
            ].joined(separator: "|")
            if var existing = byIdentity[identity] {
                guard existing.argumentLabels == value.argumentLabels,
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
                    existing.requiresMainActor = existing.requiresMainActor
                        || value.requiresMainActor
                }
                existing.silReferences = Array(Set(
                    existing.silReferences + value.silReferences
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
                canonical.importedModules = Array(Set(value.importedModules)).sorted()
                byIdentity[identity] = canonical
            }
        }
        return byIdentity.values.sorted {
            let lhs = ($0.dispatch.rawValue, $0.ownerType, $0.baseName,
                       $0.parameterSwiftTypes.joined(separator: ","),
                       $0.sourceFileLogicalID)
            let rhs = ($1.dispatch.rawValue, $1.ownerType, $1.baseName,
                       $1.parameterSwiftTypes.joined(separator: ","),
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
        result.resultSwiftType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(
                in: operation.resultSwiftType,
                aliases: aliases
            )
        return result
    }
}
